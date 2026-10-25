package dev.yuxinqiao.kumone.data

import android.content.Context
import dev.yuxinqiao.kumone.core.FfiKugouMatch
import dev.yuxinqiao.kumone.core.FfiLyricLine
import dev.yuxinqiao.kumone.core.FfiPlaybackData
import dev.yuxinqiao.kumone.core.FfiPlaylistDetail
import dev.yuxinqiao.kumone.core.FfiPlaylistSummary
import dev.yuxinqiao.kumone.core.FfiRequestSpec
import dev.yuxinqiao.kumone.core.FfiSearchTrack
import dev.yuxinqiao.kumone.core.FfiUnblockRequest
import dev.yuxinqiao.kumone.core.FfiUnblockTrack
import dev.yuxinqiao.kumone.core.FfiUserProfile
import dev.yuxinqiao.kumone.core.buildDailySongsRequest
import dev.yuxinqiao.kumone.core.buildLyricRequest
import dev.yuxinqiao.kumone.core.buildPersonalizedPlaylistsRequest
import dev.yuxinqiao.kumone.core.buildPlaylistDetailRequest
import dev.yuxinqiao.kumone.core.buildQrCheckRequest
import dev.yuxinqiao.kumone.core.buildQrKeyRequest
import dev.yuxinqiao.kumone.core.buildRecommendResourceRequest
import dev.yuxinqiao.kumone.core.buildSongSearchRequest
import dev.yuxinqiao.kumone.core.buildSongUrlRequest
import dev.yuxinqiao.kumone.core.buildUserAccountRequest
import dev.yuxinqiao.kumone.core.buildUserPlaylistsRequest
import dev.yuxinqiao.kumone.core.clearAuthCookies
import dev.yuxinqiao.kumone.core.decodeDailySongsResponse
import dev.yuxinqiao.kumone.core.decodeLyricsResponse
import dev.yuxinqiao.kumone.core.decodePersonalizedPlaylistsResponse
import dev.yuxinqiao.kumone.core.decodePlaylistDetailResponse
import dev.yuxinqiao.kumone.core.decodeQrCheckResponse
import dev.yuxinqiao.kumone.core.decodeQrKeyResponse
import dev.yuxinqiao.kumone.core.decodeRecommendResourceResponse
import dev.yuxinqiao.kumone.core.decodeSongSearchResponse
import dev.yuxinqiao.kumone.core.decodeSongUrlResponse
import dev.yuxinqiao.kumone.core.decodeUserAccountResponse
import dev.yuxinqiao.kumone.core.decodeUserPlaylistsResponse
import dev.yuxinqiao.kumone.core.ingestCookieString
import dev.yuxinqiao.kumone.core.isLoggedIn as coreIsLoggedIn
import dev.yuxinqiao.kumone.core.unblockDecodeKugouSearchResponse
import dev.yuxinqiao.kumone.core.unblockDecodeKugouTrackResponse
import dev.yuxinqiao.kumone.core.unblockDecodeKuwoConvertResponse
import dev.yuxinqiao.kumone.core.unblockDecodeKuwoSearchResponse
import dev.yuxinqiao.kumone.core.unblockDecodePyncmdResponse
import dev.yuxinqiao.kumone.core.unblockKugouSearchRequest
import dev.yuxinqiao.kumone.core.unblockKugouTrackRequest
import dev.yuxinqiao.kumone.core.unblockKuwoConvertRequest
import dev.yuxinqiao.kumone.core.unblockKuwoSearchRequest
import dev.yuxinqiao.kumone.core.unblockPyncmdRequest
import java.net.HttpURLConnection
import java.net.URL
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Thin Android transport around the shared Rust protocol core.
 *
 * Rust owns request construction, crypto, response decoding, unblock provider
 * protocol and deterministic business rules. Android owns HTTP I/O and durable
 * cookie storage.
 */
class NeteaseRepository(context: Context) {
    private val appContext = context.applicationContext
    private val session = SessionStore(appContext)
    private val diagnostics = DiagnosticsStore(appContext)
    private val trackCache = ConcurrentHashMap<Long, FfiSearchTrack>()

    fun isLoggedIn(): Boolean = coreIsLoggedIn(session.snapshot())

    fun logout() {
        session.replace(clearAuthCookies(session.snapshot()))
    }

    fun exportDiagnostics(): String {
        val file = File(appContext.filesDir, "diagnostics.json")
        file.writeText(diagnostics.json(), Charsets.UTF_8)
        return file.absolutePath
    }

    suspend fun beginQrLogin(): QrLoginSession = withContext(Dispatchers.IO) {
        val requestResult = buildQrKeyRequest(session.snapshot())
        val request = requestResult.request
            ?: error(requestResult.error ?: "Unable to create QR login request")
        val decoded = decodeQrKeyResponse(execute(request))
        decoded.error?.let(::error)
        QrLoginSession(
            key = decoded.key ?: error("NetEase returned no QR login key"),
            url = decoded.url ?: error("NetEase returned no QR login URL"),
        )
    }

    suspend fun checkQrLogin(key: String): QrLoginStatus = withContext(Dispatchers.IO) {
        val requestResult = buildQrCheckRequest(key, session.snapshot())
        val request = requestResult.request
            ?: error(requestResult.error ?: "Unable to build QR check request")
        val decoded = decodeQrCheckResponse(execute(request))
        decoded.error?.let(::error)
        QrLoginStatus(
            code = decoded.code,
            state = decoded.state,
            message = decoded.message,
            nickname = decoded.nickname,
            avatarUrl = decoded.avatarUrl,
        )
    }

    suspend fun account(): FfiUserProfile? = withContext(Dispatchers.IO) {
        val requestResult = buildUserAccountRequest(session.snapshot())
        val request = requestResult.request
            ?: error(requestResult.error ?: "Unable to build account request")
        val decoded = decodeUserAccountResponse(execute(request))
        decoded.error?.let(::error)
        decoded.profile
    }

    suspend fun userPlaylists(uid: Long, limit: Long = 100, offset: Long = 0): List<FfiPlaylistSummary> =
        withContext(Dispatchers.IO) {
            val requestResult = buildUserPlaylistsRequest(uid, limit, offset, session.snapshot())
            val request = requestResult.request
                ?: error(requestResult.error ?: "Unable to build library request")
            val decoded = decodeUserPlaylistsResponse(execute(request))
            decoded.error?.let(::error)
            decoded.playlists
        }

    suspend fun personalizedPlaylists(limit: Long = 12): List<FfiPlaylistSummary> =
        withContext(Dispatchers.IO) {
            val requestResult = buildPersonalizedPlaylistsRequest(limit, session.snapshot())
            val request = requestResult.request
                ?: error(requestResult.error ?: "Unable to build recommendation request")
            val decoded = decodePersonalizedPlaylistsResponse(execute(request))
            decoded.error?.let(::error)
            decoded.playlists
        }

    suspend fun recommendedPlaylists(): List<FfiPlaylistSummary> = withContext(Dispatchers.IO) {
        val requestResult = buildRecommendResourceRequest(session.snapshot())
        val request = requestResult.request
            ?: error(requestResult.error ?: "Unable to build personalized recommendation request")
        val decoded = decodeRecommendResourceResponse(execute(request))
        decoded.error?.let(::error)
        decoded.playlists
    }

    suspend fun dailySongs(): List<FfiSearchTrack> = withContext(Dispatchers.IO) {
        val requestResult = buildDailySongsRequest(session.snapshot())
        val request = requestResult.request
            ?: error(requestResult.error ?: "Unable to build daily songs request")
        val decoded = decodeDailySongsResponse(execute(request))
        decoded.error?.let(::error)
        rememberTracks(decoded.tracks)
    }

    suspend fun playlistDetail(id: Long): FfiPlaylistDetail = withContext(Dispatchers.IO) {
        val requestResult = buildPlaylistDetailRequest(id, session.snapshot())
        val request = requestResult.request
            ?: error(requestResult.error ?: "Unable to build playlist request")
        val decoded = decodePlaylistDetailResponse(execute(request))
        decoded.error?.let(::error)
        val detail = decoded.detail ?: error("NetEase returned no playlist detail")
        rememberTracks(detail.tracks)
        detail
    }

    suspend fun searchSongs(query: String, limit: Long = 30, offset: Long = 0): SearchPage =
        withContext(Dispatchers.IO) {
            val requestResult = buildSongSearchRequest(
                keywords = query.trim(),
                limit = limit,
                offset = offset,
                cookies = session.snapshot(),
                requestId = requestId(),
                buildVersion = buildVersion(),
            )
            val request = requestResult.request
                ?: error(requestResult.error ?: "Unable to build search request")
            val decoded = decodeSongSearchResponse(execute(request))
            decoded.error?.let(::error)
            SearchPage(rememberTracks(decoded.songs), decoded.total)
        }

    /**
     * Compatibility entry point used by the Compose player. Tracks returned by
     * search/home/playlist APIs are cached so provider fallbacks retain title,
     * artist and duration without duplicating those fields in UI callbacks.
     */
    suspend fun resolvePlayback(trackId: Long, level: String = "standard"): PlaybackResolution =
        withContext(Dispatchers.IO) {
            val track = trackCache[trackId]
            if (track != null) {
                return@withContext resolvePlaybackInternal(track, level)
            }

            runCatching { resolveNeteasePlayback(trackId, level) }
                .map { PlaybackResolution(url = it.url, source = "netease") }
                .getOrElse { neteaseError ->
                    val pyncmdOnlyTarget = FfiUnblockTrack(
                        id = trackId,
                        name = "",
                        artistName = "",
                        durationMs = 0,
                    )
                    runCatching {
                        unblockDecodePyncmdResponse(
                            executeUnblock(unblockPyncmdRequest(pyncmdOnlyTarget)),
                        )
                    }.getOrNull()?.let { url ->
                        return@withContext PlaybackResolution(url = url, source = "pyncmd")
                    }
                    error(neteaseError.message ?: "No playable source found")
                }
        }

    suspend fun resolvePlayback(track: FfiSearchTrack, level: String = "standard"): PlaybackResolution =
        withContext(Dispatchers.IO) {
            trackCache[track.id] = track
            resolvePlaybackInternal(track, level)
        }

    suspend fun lyrics(trackId: Long): LyricsPage = withContext(Dispatchers.IO) {
        val requestResult = buildLyricRequest(trackId, session.snapshot())
        val request = requestResult.request
            ?: error(requestResult.error ?: "Unable to build lyric request")
        val decoded = decodeLyricsResponse(execute(request))
        decoded.error?.let(::error)
        LyricsPage(
            lines = decoded.lines,
            isInstrumental = decoded.isInstrumental,
            contributor = decoded.contributor,
            translationContributor = decoded.translationContributor,
        )
    }

    /** Read-only GitHub Release check. Android delegates installation to the
     * system/browser; it never attempts to bypass package-signature policy. */
    suspend fun latestRelease(): ReleaseInfo = withContext(Dispatchers.IO) {
        val connection = (URL("https://api.github.com/repos/Yuxin-Qiao/kumone/releases/latest")
            .openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 10_000
            readTimeout = 10_000
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "Kite Android updater")
        }
        try {
            val status = connection.responseCode
            val body = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            if (status !in 200..299) error("Release check HTTP $status")
            val json = org.json.JSONObject(body)
            ReleaseInfo(
                version = json.optString("tag_name").removePrefix("downstream-v"),
                url = json.optString("html_url"),
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun resolvePlaybackInternal(track: FfiSearchTrack, level: String): PlaybackResolution {
        var lastError: Throwable? = null
        listOf(level, "lossless", "exhigh", "standard").distinct().forEach { candidate ->
            runCatching { resolveNeteasePlayback(track.id, candidate) }
                .onSuccess { resolved ->
                    return PlaybackResolution(url = resolved.url, source = "netease")
                }
                .onFailure { lastError = it }
        }
        return resolveUnblocked(track)
            ?: error(lastError?.message ?: "No playable source found")
    }

    private fun resolveNeteasePlayback(trackId: Long, level: String): FfiPlaybackData {
        val requestResult = buildSongUrlRequest(
            trackId = trackId,
            level = level,
            cookies = session.snapshot(),
            requestId = requestId(),
            buildVersion = buildVersion(),
        )
        val request = requestResult.request
            ?: error(requestResult.error ?: "Unable to build playback request")
        val decoded = decodeSongUrlResponse(execute(request), trackId)
        decoded.error?.let(::error)
        return decoded.data ?: error("NetEase returned no playable URL")
    }

    private fun resolveUnblocked(track: FfiSearchTrack): PlaybackResolution? {
        val target = FfiUnblockTrack(
            id = track.id,
            name = track.name,
            artistName = track.artistNames.substringBefore(" / "),
            durationMs = track.durationMs,
        )

        runCatching {
            val response = executeUnblock(unblockPyncmdRequest(target))
            unblockDecodePyncmdResponse(response)
        }.getOrNull()?.let { url ->
            return PlaybackResolution(url = url, source = "pyncmd")
        }

        runCatching {
            val searchBody = executeUnblock(unblockKuwoSearchRequest(target))
            val match = unblockDecodeKuwoSearchResponse(searchBody, target.durationMs)
                ?: return@runCatching null
            val convertBody = executeUnblock(unblockKuwoConvertRequest(match.rid))
            unblockDecodeKuwoConvertResponse(convertBody)
        }.getOrNull()?.let { url ->
            return PlaybackResolution(url = url, source = "kuwo")
        }

        runCatching {
            val searchBody = executeUnblock(unblockKugouSearchRequest(target))
            val match: FfiKugouMatch = unblockDecodeKugouSearchResponse(searchBody, target.durationMs)
                ?: return@runCatching null
            val trackBody = executeUnblock(unblockKugouTrackRequest(match))
            unblockDecodeKugouTrackResponse(trackBody)
        }.getOrNull()?.let { url ->
            return PlaybackResolution(url = url, source = "kugou")
        }

        return null
    }

    private fun rememberTracks(tracks: List<FfiSearchTrack>): List<FfiSearchTrack> {
        tracks.forEach { trackCache[it.id] = it }
        return tracks
    }

    private fun execute(request: FfiRequestSpec): String {
        var attempt = 0
        while (true) {
            try {
                return executeOnce(request)
            } catch (error: Throwable) {
                diagnostics.record(error.message.orEmpty())
                val message = error.message.orEmpty()
                val retryable = message.contains("HTTP 408") || message.contains("HTTP 429") ||
                    message.contains("HTTP 500") || message.contains("HTTP 502") ||
                    message.contains("HTTP 503") || message.contains("timed out", ignoreCase = true)
                if (!retryable || attempt >= 1) throw error
                attempt += 1
                Thread.sleep(350L)
            }
        }
    }

    private fun executeOnce(request: FfiRequestSpec): String {
        val connection = (URL(request.url).openConnection() as HttpURLConnection).apply {
            requestMethod = request.method
            connectTimeout = 15_000
            readTimeout = 20_000
            instanceFollowRedirects = true
            request.headers.forEach { (name, value) -> setRequestProperty(name, value) }
            if (request.body.isNotEmpty()) {
                doOutput = true
                outputStream.use { stream ->
                    stream.write(request.body.toByteArray(Charsets.UTF_8))
                }
            }
        }

        return try {
            val status = connection.responseCode
            absorbCookies(connection)
            val stream = if (status in 200..399) connection.inputStream else connection.errorStream
            val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            if (status !in 200..399) {
                error("NetEase HTTP $status${body.takeIf(String::isNotBlank)?.let { ": $it" }.orEmpty()}")
            }
            body
        } finally {
            connection.disconnect()
        }
    }

    private fun executeUnblock(request: FfiUnblockRequest): String {
        val connection = (URL(request.url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 10_000
            readTimeout = 10_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", request.userAgent)
        }
        return try {
            val status = connection.responseCode
            if (status !in 200..299) error("Unblock provider HTTP $status")
            connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
        } finally {
            connection.disconnect()
        }
    }

    private fun absorbCookies(connection: HttpURLConnection) {
        val raw = connection.headerFields
            .filterKeys { key -> key?.equals("Set-Cookie", ignoreCase = true) == true }
            .values
            .flatten()
            .filter(String::isNotBlank)
            .joinToString(";;")
        if (raw.isNotEmpty()) {
            session.replace(ingestCookieString(session.snapshot(), raw))
        }
    }

    private fun requestId(): String =
        (System.currentTimeMillis() % 100_000_000L).toString().padStart(8, '0')

    private fun buildVersion(): String = (System.currentTimeMillis() / 1000L).toString()
}

data class QrLoginSession(
    val key: String,
    val url: String,
)

data class QrLoginStatus(
    val code: Long,
    val state: String,
    val message: String?,
    val nickname: String?,
    val avatarUrl: String?,
)

data class PlaybackResolution(
    val url: String,
    val source: String,
)

data class SearchPage(
    val songs: List<FfiSearchTrack>,
    val total: Long,
)

data class LyricsPage(
    val lines: List<FfiLyricLine>,
    val isInstrumental: Boolean,
    val contributor: String?,
    val translationContributor: String?,
)

data class ReleaseInfo(
    val version: String,
    val url: String,
)

private class SessionStore(context: Context) {
    private val preferences = context.getSharedPreferences("netease-session", Context.MODE_PRIVATE)

    fun snapshot(): Map<String, String> = preferences.all.mapNotNull { (key, value) ->
        (value as? String)?.let { key to it }
    }.toMap()

    fun replace(values: Map<String, String>) {
        preferences.edit().clear().apply {
            values.forEach { (key, value) -> putString(key, value) }
        }.apply()
    }
}

private class DiagnosticsStore(context: Context) {
    private val preferences = context.getSharedPreferences("kumone-diagnostics", Context.MODE_PRIVATE)
    private val versionName = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull().orEmpty()

    fun record(message: String) {
        preferences.edit()
            .putLong("request_count", preferences.getLong("request_count", 0L) + 1L)
            .putString("last_error", message.take(240))
            .apply()
    }

    fun json(): String = org.json.JSONObject()
        .put("schema_version", 1)
        .put("product", "kumone")
        .put("platform", "android")
        .put("app_version", versionName)
        .put("privacy", org.json.JSONObject().put("redacted", true).put("network_upload", false))
        .put(
            "events",
            org.json.JSONArray().put(
                org.json.JSONObject()
                    .put("request_count", preferences.getLong("request_count", 0L))
                    .put("last_error", preferences.getString("last_error", null)),
            ),
        )
        .toString(2)
}
