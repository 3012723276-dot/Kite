package moe.kite.android.player

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.contentOrNull
import moe.kite.android.model.Track
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.URLEncoder
import java.security.MessageDigest

/**
 * 第三方音源兜底，与 iOS 版 UnblockService 同策略：
 * 网易拒绝（无链接 / 只给试听）时依次尝试：
 * 1. pyncmd（按网易歌 ID 要 320k 链接）
 * 2. 酷狗（按歌名+歌手搜索，匹配标题、歌手、时长 ±5 秒）
 * 3. 酷我（同上）
 * 匹配规则照搬 iOS：标题归一化后相等、歌手包含、时长差 ≤5000ms、
 * live/remix/伴奏/dj/cover/翻唱/instrumental/karaoke 版本标记不能冲突。
 */
object UnblockService {
    private val client = OkHttpClient()
    private val json = Json { ignoreUnknownKeys = true }

    data class ResolvedSource(val name: String, val url: String)

    fun resolve(track: Track): ResolvedSource? {
        return try { pyncmd(track) }
            ?: try { kugou(track) } catch (e: Exception) { null }
            ?: try { kuwo(track) } catch (e: Exception) { null }
    }

    private fun get(url: String, userAgent: String? = null): String {
        val builder = Request.Builder().url(url)
        if (userAgent != null) builder.header("User-Agent", userAgent)
        client.newCall(builder.build()).execute().use { resp ->
            return resp.body?.string() ?: ""
        }
    }

    private fun pyncmd(track: Track): ResolvedSource? {
        val raw = get(
            "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=${track.id}&br=320"
        )
        val obj = json.parseToJsonElement(raw).jsonObject
        val br = obj["br"]?.jsonPrimitive?.longOrNull ?: 0L
        val url = obj["url"]?.jsonPrimitive?.contentOrNull
        if (br <= 0 || url.isNullOrBlank()) return null
        return ResolvedSource("pyncmd", url.replace("http://", "https://"))
    }

    private fun keyword(track: Track): String {
        val firstArtist = track.artist.split("/", "、", ",", "，").firstOrNull()?.trim() ?: ""
        return "${track.name} $firstArtist".trim()
    }

    private fun normalized(value: String): String {
        return value.lowercase().filter { it.isLetterOrDigit() }
    }

    private fun hasVersionConflict(original: String, candidate: String): Boolean {
        val markers = listOf("live", "remix", "伴奏", "dj", "cover", "翻唱", "instrumental", "karaoke")
        val o = markers.filter { normalized(original).contains(it) }.toSet()
        val c = markers.filter { normalized(candidate).contains(it) }.toSet()
        return o != c
    }

    private fun matches(track: Track, title: String, artist: String, durationMs: Long): Boolean {
        if (track.durationMs <= 0 || durationMs <= 0) return false
        if (kotlin.math.abs(durationMs - track.durationMs) > 5000) return false
        if (normalized(title) != normalized(track.name)) return false
        if (hasVersionConflict(track.name, title)) return false
        val expected = normalized(track.artist.split("/", "、", ",", "，").firstOrNull()?.trim() ?: "")
        if (expected.isEmpty()) return false
        val artists = artist.split("/", "、", ",", "，", ";", "；").map { normalized(it) }
        return artists.contains(expected)
    }

    private fun md5Hex(input: String): String {
        val digest = MessageDigest.getInstance("MD5").digest(input.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun kugou(track: Track): ResolvedSource? {
        val query = URLEncoder.encode(keyword(track), "UTF-8")
        val raw = get("http://mobilecdn.kugou.com/api/v3/search/song?format=json&keyword=$query&page=1&pagesize=10")
        val info = json.parseToJsonElement(raw).jsonObject["data"]
            ?.jsonObject?.get("info")?.jsonArray ?: return null
        val match = info.take(5).firstNotNullOfOrNull { item ->
            val obj = item.jsonObject
            val hash = obj["hash"]?.jsonPrimitive?.contentOrNull ?: return@firstNotNullOfOrNull null
            val title = obj["songname"]?.jsonPrimitive?.contentOrNull ?: return@firstNotNullOfOrNull null
            val artist = obj["singername"]?.jsonPrimitive?.contentOrNull ?: ""
            val duration = obj["duration"]?.jsonPrimitive?.longOrNull ?: 0L
            if (!matches(track, title, artist, duration * 1000)) return@firstNotNullOfOrNull null
            val albumId = obj["album_id"]?.jsonPrimitive?.contentOrNull ?: "0"
            hash to albumId
        } ?: return null
        val key = md5Hex("${match.first}kgcloudv2")
        val streamRaw = get(
            "https://trackercdn.kugou.com/i/v2/?key=$key&hash=${match.first}" +
                "&appid=1005&pid=2&cmd=25&behavior=play&album_id=${match.second}"
        )
        val url = json.parseToJsonElement(streamRaw).jsonObject["url"]
            ?.jsonArray?.firstOrNull()?.jsonPrimitive?.contentOrNull ?: return null
        return ResolvedSource("酷狗音乐", url)
    }

    private fun kuwo(track: Track): ResolvedSource? {
        val query = URLEncoder.encode(keyword(track), "UTF-8")
        val raw = get(
            "https://search.kuwo.cn/r.s?&correct=1&vipver=1&stype=comprehensive&encoding=utf8" +
                "&rformat=json&mobi=1&show_copyright_off=1&searchapi=6&all=$query"
        )
        val content = json.parseToJsonElement(raw).jsonObject["content"]?.jsonArray ?: return null
        if (content.size < 2) return null
        val songs = content[1].jsonObject["musicpage"]?.jsonObject?.get("abslist")?.jsonArray ?: return null
        val rid = songs.take(5).firstNotNullOfOrNull { item ->
            val obj = item.jsonObject
            val musicRid = obj["MUSICRID"]?.jsonPrimitive?.contentOrNull ?: return@firstNotNullOfOrNull null
            val ridValue = musicRid.substringAfterLast("_")
            val title = obj["SONGNAME"]?.jsonPrimitive?.contentOrNull ?: return@firstNotNullOfOrNull null
            val artist = obj["ARTIST"]?.jsonPrimitive?.contentOrNull ?: ""
            val durationSec = obj["DURATION"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
                ?: obj["DURATION"]?.jsonPrimitive?.longOrNull ?: 0L
            if (!matches(track, title, artist, durationSec * 1000)) return@firstNotNullOfOrNull null
            ridValue
        } ?: return null
        val body = get(
            "https://antiserver.kuwo.cn/anti.s?type=convert_url&format=mp3&response=url&rid=MUSIC_$rid",
            userAgent = "okhttp/3.10.0"
        )
        val url = Regex("""http[^\s$"]+""").find(body)?.value ?: return null
        return ResolvedSource("酷我音乐", url)
    }
}
