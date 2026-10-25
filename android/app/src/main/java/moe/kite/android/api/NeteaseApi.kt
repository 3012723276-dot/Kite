package moe.kite.android.api

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.contentOrNull
import moe.kite.android.model.Album
import moe.kite.android.model.Playlist
import moe.kite.android.model.Track
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * 最小 weapi 客户端：先跑通首页新专辑 + 歌曲 URL，后续再按 iOS 版
 * NeteaseAPI 的接口逐个加（搜索、歌单、登录、每日推荐等）。
 */
class NeteaseApi(
    private val client: OkHttpClient = OkHttpClient(),
    private val json: Json = Json { ignoreUnknownKeys = true }
) {
    companion object {
        /** 带 Cookie 持久化的客户端，登录后重启不用重登。 */
        fun withCookieJar(cookieJar: okhttp3.CookieJar): NeteaseApi {
            val client = OkHttpClient.Builder().cookieJar(cookieJar).build()
            return NeteaseApi(client)
        }
    }
    private val baseUrl = "https://music.163.com"

    private fun weapi(path: String, paramsJson: String): String {
        val (params, encSecKey) = NeteaseCrypto.weapiEncrypt(paramsJson)
        val body = FormBody.Builder()
            .add("params", params)
            .add("encSecKey", encSecKey)
            .build()
        val request = Request.Builder()
            .url("$baseUrl$path")
            .addHeader("User-Agent", "Mozilla/5.0")
            .addHeader("Referer", "https://music.163.com/")
            .post(body)
            .build()
        client.newCall(request).execute().use { response ->
            return response.body?.string() ?: ""
        }
    }

    /** 首页新专辑，对应 iOS 版 newAlbums。 */
    fun newAlbums(limit: Int = 30): List<Album> {
        val raw = weapi(
            "/weapi/album/new",
            """{"limit":$limit,"offset":0,"total":true,"area":"ALL"}"""
        )
        val root = json.parseToJsonElement(raw).jsonObject
        val albums = root["albums"]?.jsonArray ?: return emptyList()
        return albums.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null
            Album(
                id = id,
                name = obj["name"]?.jsonPrimitive?.contentOrNull ?: "",
                artist = obj["artist"]?.jsonObject
                    ?.get("name")?.jsonPrimitive?.contentOrNull ?: "",
                coverUrl = obj["picUrl"]?.jsonPrimitive?.contentOrNull ?: "",
                publishTime = obj["publishTime"]?.jsonPrimitive?.longOrNull ?: 0
            )
        }
    }

    /** 取歌曲播放 URL（后续接 ExoPlayer）。 */
    fun songUrl(id: Long, level: String = "standard"): String {
        val raw = weapi(
            "/weapi/song/enhance/player/url/v1",
            """{"ids":"[$id]","level":"$level","encodeType":"flac"}"""
        )
        val root = json.parseToJsonElement(raw).jsonObject
        val data = root["data"]?.jsonArray?.firstOrNull()?.jsonObject ?: return ""
        return data["url"]?.jsonPrimitive?.contentOrNull ?: ""
    }

    /** 发送短信验证码，对应 iOS 版 sendSMSCode：/sms/captcha/sent。 */
    fun sendSmsCode(phone: String, countryCode: String = "86"): Boolean {
        val raw = weapi(
            "/weapi/sms/captcha/sent",
            """{"ctcode":"$countryCode","cellphone":"$phone","secrete":"music_middleuser_pclogin"}"""
        )
        val code = json.parseToJsonElement(raw).jsonObject["code"]
            ?.jsonPrimitive?.longOrNull
        return code == 200L
    }

    /** 手机号 + 验证码登录，对应 iOS 版 loginCellphone：/w/login/cellphone。
     * 注意：正式登录需要持久化 Cookie（MUSIC_U 等），这里先返回 code，
     * Cookie 持久化到 SharedPreferences 是下一步，见 README。 */
    fun loginCellphone(phone: String, captcha: String, countryCode: String = "86"): Boolean {
        val raw = weapi(
            "/weapi/w/login/cellphone",
            """{"type":"1","https":"true","phone":"$phone","countrycode":"$countryCode","captcha":"$captcha","remember":"true","secureCaptcha":""}"""
        )
        val code = json.parseToJsonElement(raw).jsonObject["code"]
            ?.jsonPrimitive?.longOrNull
        return code == 200L
    }

    /** 搜索歌曲：weapi /cloudsearch/pc，type=1 为单曲。 */
    fun search(keyword: String, limit: Int = 30): List<Track> {
        val escaped = keyword.replace("\"", "")
        val raw = weapi(
            "/weapi/cloudsearch/pc",
            """{"s":"$escaped","type":1,"limit":$limit,"offset":0,"total":true}"""
        )
        val songs = json.parseToJsonElement(raw).jsonObject["result"]
            ?.jsonObject?.get("songs")?.jsonArray ?: return emptyList()
        return songs.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null
            val artists = obj["ar"]?.jsonArray?.mapNotNull {
                it.jsonObject["name"]?.jsonPrimitive?.contentOrNull
            }?.joinToString("/") ?: ""
            Track(
                id = id,
                name = obj["name"]?.jsonPrimitive?.contentOrNull ?: "",
                artist = artists,
                album = obj["al"]?.jsonObject
                    ?.get("name")?.jsonPrimitive?.contentOrNull ?: "",
                coverUrl = obj["al"]?.jsonObject
                    ?.get("picUrl")?.jsonPrimitive?.contentOrNull ?: "",
                durationMs = obj["dt"]?.jsonPrimitive?.longOrNull ?: 0
            )
        }
    }

    /** 专辑详情里的歌曲列表：weapi /v1/album/{id}，先取 songs 字段。 */
    fun albumTracks(albumId: Long): List<Track> {
        val raw = weapi("/weapi/v1/album/$albumId", """{"id":$albumId}""")
        val songs = json.parseToJsonElement(raw).jsonObject["songs"]
            ?.jsonArray ?: return emptyList()
        return songs.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null
            val artists = obj["ar"]?.jsonArray?.mapNotNull {
                it.jsonObject["name"]?.jsonPrimitive?.contentOrNull
            }?.joinToString("/") ?: ""
            Track(
                id = id,
                name = obj["name"]?.jsonPrimitive?.contentOrNull ?: "",
                artist = artists,
                album = "",
                coverUrl = "",
                durationMs = obj["dt"]?.jsonPrimitive?.longOrNull ?: 0
            )
        }
    }

    private fun parseTracks(array: kotlinx.serialization.json.JsonArray): List<Track> {
        return array.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null
            val artists = obj["ar"]?.jsonArray?.mapNotNull {
                it.jsonObject["name"]?.jsonPrimitive?.contentOrNull
            }?.joinToString("/") ?: ""
            Track(
                id = id,
                name = obj["name"]?.jsonPrimitive?.contentOrNull ?: "",
                artist = artists,
                album = obj["al"]?.jsonObject?.get("name")?.jsonPrimitive?.contentOrNull ?: "",
                coverUrl = obj["al"]?.jsonObject?.get("picUrl")?.jsonPrimitive?.contentOrNull ?: "",
                durationMs = obj["dt"]?.jsonPrimitive?.longOrNull ?: 0
            )
        }
    }

    private fun parsePlaylists(array: kotlinx.serialization.json.JsonArray): List<Playlist> {
        return array.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null
            Playlist(
                id = id,
                name = obj["name"]?.jsonPrimitive?.contentOrNull ?: "",
                coverUrl = obj["coverImgUrl"]?.jsonPrimitive?.contentOrNull
                    ?: obj["picUrl"]?.jsonPrimitive?.contentOrNull ?: "",
                trackCount = obj["trackCount"]?.jsonPrimitive?.longOrNull?.toInt() ?: 0
            )
        }
    }

    /** 推荐歌单：/personalized/playlist */
    fun personalizedPlaylists(limit: Int = 30): List<Playlist> {
        val raw = weapi("/weapi/personalized/playlist", """{"limit":$limit,"total":true,"n":1000}""")
        val result = json.parseToJsonElement(raw).jsonObject["result"]?.jsonArray ?: return emptyList()
        return parsePlaylists(result)
    }

    /** 每日推荐歌曲（需登录）：/v3/discovery/recommend/songs */
    fun dailyRecommendSongs(): List<Track> {
        val raw = weapi("/weapi/v3/discovery/recommend/songs", """{}""")
        val songs = json.parseToJsonElement(raw).jsonObject["data"]
            ?.jsonObject?.get("dailySongs")?.jsonArray ?: return emptyList()
        return parseTracks(songs)
    }

    /** 歌单详情：/v6/playlist/detail，返回歌单信息 + 歌曲列表 */
    fun playlistDetail(id: Long): Pair<Playlist, List<Track>> {
        val raw = weapi("/weapi/v6/playlist/detail", """{"id":$id,"n":100000,"s":8}""")
        val playlistObj = json.parseToJsonElement(raw).jsonObject["playlist"]?.jsonObject
            ?: return Playlist(id, "") to emptyList()
        val playlist = Playlist(
            id = id,
            name = playlistObj["name"]?.jsonPrimitive?.contentOrNull ?: "",
            coverUrl = playlistObj["coverImgUrl"]?.jsonPrimitive?.contentOrNull ?: "",
            trackCount = playlistObj["trackCount"]?.jsonPrimitive?.longOrNull?.toInt() ?: 0
        )
        val tracks = playlistObj["tracks"]?.jsonArray?.let { parseTracks(it) } ?: emptyList()
        return playlist to tracks
    }

    /** 我的歌单（需登录 + uid）：/user/playlist */
    fun userPlaylists(uid: Long, limit: Int = 200): List<Playlist> {
        val raw = weapi("/weapi/user/playlist", """{"uid":$uid,"limit":$limit,"offset":0,"includeVideo":true}""")
        val list = json.parseToJsonElement(raw).jsonObject["playlist"]?.jsonArray ?: return emptyList()
        return parsePlaylists(list)
    }

    /** 歌词：先 /song/lyric/v1，拿不到再 /song/lyric，与 iOS 版同策略 */
    fun lyric(id: Long): String {
        val rawV1 = weapi(
            "/weapi/song/lyric/v1",
            """{"id":$id,"cp":false,"lv":0,"kv":0,"tv":0,"rv":0,"yv":0,"ytv":0,"yrv":0}"""
        )
        val lrcV1 = json.parseToJsonElement(rawV1).jsonObject["lrc"]
            ?.jsonObject?.get("lyric")?.jsonPrimitive?.contentOrNull
        if (!lrcV1.isNullOrBlank()) return lrcV1
        val raw = weapi("/weapi/song/lyric", """{"id":$id,"lv":-1,"kv":-1,"tv":-1,"rv":-1}""")
        return json.parseToJsonElement(raw).jsonObject["lrc"]
            ?.jsonObject?.get("lyric")?.jsonPrimitive?.contentOrNull ?: ""
    }

    /** 私人 FM：/v1/radio/get */
    fun personalFm(): List<Track> {
        val raw = weapi("/weapi/v1/radio/get", """{}""")
        val data = json.parseToJsonElement(raw).jsonObject["data"]?.jsonArray ?: return emptyList()
        return parseTracks(data)
    }
}
