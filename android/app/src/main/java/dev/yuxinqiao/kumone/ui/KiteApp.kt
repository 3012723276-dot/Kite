package dev.yuxinqiao.kumone.ui

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import dev.yuxinqiao.kumone.core.FfiLyricLine
import dev.yuxinqiao.kumone.core.FfiPlaylistDetail
import dev.yuxinqiao.kumone.core.FfiPlaylistSummary
import dev.yuxinqiao.kumone.core.FfiSearchTrack
import dev.yuxinqiao.kumone.core.FfiUserProfile
import dev.yuxinqiao.kumone.data.LyricsPage
import dev.yuxinqiao.kumone.data.NeteaseRepository
import dev.yuxinqiao.kumone.data.QrLoginSession
import dev.yuxinqiao.kumone.playback.PlaybackService
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class AppSection(val label: String, val glyph: String) {
    Home("Home", "⌂"),
    Search("Search", "⌕"),
    Library("Library", "♫"),
}

@Composable
fun KiteApp() {
    val context = LocalContext.current
    val repository = remember { NeteaseRepository(context) }
    val controller = rememberMediaController()
    val scope = rememberCoroutineScope()

    var section by remember { mutableStateOf(AppSection.Home) }
    var loggedIn by remember { mutableStateOf(repository.isLoggedIn()) }
    var loginVisible by remember { mutableStateOf(false) }
    var refreshVersion by remember { mutableIntStateOf(0) }
    var profile by remember { mutableStateOf<FfiUserProfile?>(null) }
    var dailySongs by remember { mutableStateOf<List<FfiSearchTrack>>(emptyList()) }
    var recommendations by remember { mutableStateOf<List<FfiPlaylistSummary>>(emptyList()) }
    var library by remember { mutableStateOf<List<FfiPlaylistSummary>>(emptyList()) }
    var homeLoading by remember { mutableStateOf(false) }
    var homeError by remember { mutableStateOf<String?>(null) }

    var selectedPlaylistId by remember { mutableStateOf<Long?>(null) }
    var playlistDetail by remember { mutableStateOf<FfiPlaylistDetail?>(null) }
    var playlistLoading by remember { mutableStateOf(false) }
    var playlistError by remember { mutableStateOf<String?>(null) }

    var nowPlaying by remember { mutableStateOf<FfiSearchTrack?>(null) }
    var lyrics by remember { mutableStateOf<LyricsPage?>(null) }
    var positionMs by remember { mutableLongStateOf(0L) }
    var playbackError by remember { mutableStateOf<String?>(null) }
    var loadingTrackId by remember { mutableStateOf<Long?>(null) }
    var updateMessage by remember { mutableStateOf<String?>(null) }
    var diagnosticsMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(loggedIn, refreshVersion) {
        homeLoading = true
        homeError = null
        if (loggedIn) {
            val accountResult = runCatching { repository.account() }
            profile = accountResult.getOrNull()
            if (accountResult.isFailure) {
                homeError = accountResult.exceptionOrNull()?.message
            }
            dailySongs = runCatching { repository.dailySongs() }.getOrDefault(emptyList())
            recommendations = runCatching { repository.recommendedPlaylists() }
                .getOrElse { repository.personalizedPlaylists() }
            val uid = profile?.userId
            library = if (uid != null && uid > 0) {
                runCatching { repository.userPlaylists(uid) }.getOrDefault(emptyList())
            } else {
                emptyList()
            }
        } else {
            profile = null
            dailySongs = emptyList()
            library = emptyList()
            recommendations = runCatching { repository.personalizedPlaylists() }.getOrDefault(emptyList())
        }
        homeLoading = false
    }

    LaunchedEffect(selectedPlaylistId) {
        val id = selectedPlaylistId ?: run {
            playlistDetail = null
            playlistError = null
            return@LaunchedEffect
        }
        playlistLoading = true
        playlistError = null
        runCatching { repository.playlistDetail(id) }
            .onSuccess { playlistDetail = it }
            .onFailure { playlistError = it.message ?: "Unable to load playlist" }
        playlistLoading = false
    }

    LaunchedEffect(controller, nowPlaying) {
        while (controller != null) {
            positionMs = controller.currentPosition.coerceAtLeast(0L)
            delay(250L)
        }
    }

    fun playTrack(track: FfiSearchTrack) {
        val mediaController = controller
        if (mediaController == null) {
            playbackError = "Playback service is still connecting"
            return
        }
        scope.launch {
            loadingTrackId = track.id
            playbackError = null
            runCatching {
                val playback = repository.resolvePlayback(track.id)
                val metadata = MediaMetadata.Builder()
                    .setTitle(track.name)
                    .setArtist(track.artistNames)
                    .setAlbumTitle(track.albumName)
                    .apply {
                        track.albumPicUrl?.let { setArtworkUri(Uri.parse(it)) }
                    }
                    .build()
                mediaController.setMediaItem(
                    MediaItem.Builder()
                        .setMediaId(track.id.toString())
                        .setUri(playback.url)
                        .setMediaMetadata(metadata)
                        .build(),
                )
                mediaController.prepare()
                mediaController.play()
                nowPlaying = track
                positionMs = 0L
                lyrics = runCatching { repository.lyrics(track.id) }.getOrNull()
            }.onFailure {
                playbackError = it.message ?: "Unable to play this track"
            }
            loadingTrackId = null
        }
    }

    if (loginVisible) {
        QrLoginDialog(
            repository = repository,
            onDismiss = { loginVisible = false },
            onAuthenticated = {
                loggedIn = true
                loginVisible = false
                refreshVersion += 1
            },
        )
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        bottomBar = {
            Column {
                nowPlaying?.let { track ->
                    MiniPlayer(
                        track = track,
                        lyrics = lyrics,
                        positionMs = positionMs,
                        isPlaying = controller?.isPlaying == true,
                        onToggle = {
                            controller?.let { player ->
                                if (player.isPlaying) player.pause() else player.play()
                            }
                        },
                        onSeek = { controller?.seekTo(it) },
                    )
                }
                NavigationBar {
                    AppSection.entries.forEach { item ->
                        NavigationBarItem(
                            selected = section == item,
                            onClick = {
                                section = item
                                selectedPlaylistId = null
                            },
                            icon = { Text(item.glyph) },
                            label = { Text(item.label) },
                        )
                    }
                }
            }
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(12.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column {
                    Text("Kite", style = MaterialTheme.typography.headlineMedium)
                    Text(
                        "Native Android · Rust Core · Media3",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                if (loggedIn) {
                    TextButton(
                        onClick = {
                            repository.logout()
                            loggedIn = false
                            selectedPlaylistId = null
                            refreshVersion += 1
                        },
                    ) {
                        Text("Sign out")
                    }
                }
                TextButton(
                    onClick = {
                        scope.launch {
                            updateMessage = runCatching {
                                val release = repository.latestRelease()
                                val current = context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty()
                                if (release.version.isNotBlank() && release.version != current) {
                                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(release.url)))
                                    "发现 Kite ${release.version}，已打开发布页"
                                } else {
                                    "当前已是最新版本"
                                }
                            }.getOrElse { "更新检查失败：${it.message ?: "网络不可用"}" }
                        }
                    },
                ) { Text("Check updates") }
                TextButton(onClick = { diagnosticsMessage = "诊断已保存：${repository.exportDiagnostics()}" }) {
                    Text("Export diagnostics")
                }
            }
            updateMessage?.let { message ->
                Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
            }
            diagnosticsMessage?.let { message ->
                Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
            }
            playbackError?.let { ErrorText(it) }
            Spacer(Modifier.height(8.dp))

            if (selectedPlaylistId != null) {
                PlaylistDetailScreen(
                    detail = playlistDetail,
                    loading = playlistLoading,
                    error = playlistError,
                    loadingTrackId = loadingTrackId,
                    onBack = { selectedPlaylistId = null },
                    onTrackClick = ::playTrack,
                )
            } else {
                when (section) {
                    AppSection.Home -> HomeScreen(
                        loggedIn = loggedIn,
                        profile = profile,
                        loading = homeLoading,
                        error = homeError,
                        dailySongs = dailySongs,
                        recommendations = recommendations,
                        loadingTrackId = loadingTrackId,
                        onLogin = { loginVisible = true },
                        onTrackClick = ::playTrack,
                        onPlaylistClick = { selectedPlaylistId = it.id },
                    )

                    AppSection.Search -> SearchScreen(
                        repository = repository,
                        loadingTrackId = loadingTrackId,
                        onTrackClick = ::playTrack,
                    )

                    AppSection.Library -> LibraryScreen(
                        loggedIn = loggedIn,
                        playlists = library,
                        loading = homeLoading,
                        onLogin = { loginVisible = true },
                        onPlaylistClick = { selectedPlaylistId = it.id },
                    )
                }
            }
        }
    }
}

@Composable
private fun HomeScreen(
    loggedIn: Boolean,
    profile: FfiUserProfile?,
    loading: Boolean,
    error: String?,
    dailySongs: List<FfiSearchTrack>,
    recommendations: List<FfiPlaylistSummary>,
    loadingTrackId: Long?,
    onLogin: () -> Unit,
    onTrackClick: (FfiSearchTrack) -> Unit,
    onPlaylistClick: (FfiPlaylistSummary) -> Unit,
) {
    if (loading && recommendations.isEmpty() && dailySongs.isEmpty()) {
        LoadingBlock()
        return
    }
    LazyColumn(modifier = Modifier.fillMaxSize()) {
        item {
            if (loggedIn) {
                Text(
                    profile?.nickname?.let { "Welcome back, $it" } ?: "Welcome back",
                    style = MaterialTheme.typography.titleLarge,
                )
                profile?.signature?.takeIf(String::isNotBlank)?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall)
                }
            } else {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Sign in to sync your NetEase library", fontWeight = FontWeight.SemiBold)
                        Text(
                            "QR login keeps credentials out of the app and stores only session cookies on-device.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Spacer(Modifier.height(10.dp))
                        Button(onClick = onLogin) { Text("QR sign in") }
                    }
                }
            }
            error?.let { ErrorText(it) }
            Spacer(Modifier.height(16.dp))
        }
        if (dailySongs.isNotEmpty()) {
            item { SectionTitle("Daily songs") }
            items(dailySongs.take(12), key = { "daily-${it.id}" }) { track ->
                TrackRow(track, loadingTrackId == track.id) { onTrackClick(track) }
                HorizontalDivider()
            }
            item { Spacer(Modifier.height(16.dp)) }
        }
        if (recommendations.isNotEmpty()) {
            item { SectionTitle(if (loggedIn) "Recommended for you" else "Discover") }
            items(recommendations, key = { "rec-${it.id}" }) { playlist ->
                PlaylistRow(playlist) { onPlaylistClick(playlist) }
                HorizontalDivider()
            }
        }
    }
}

@Composable
private fun SearchScreen(
    repository: NeteaseRepository,
    loadingTrackId: Long?,
    onTrackClick: (FfiSearchTrack) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var songs by remember { mutableStateOf<List<FfiSearchTrack>>(emptyList()) }
    var total by remember { mutableLongStateOf(0L) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun search() {
        val keyword = query.trim()
        if (keyword.isEmpty() || loading) return
        scope.launch {
            loading = true
            error = null
            runCatching { repository.searchSongs(keyword) }
                .onSuccess {
                    songs = it.songs
                    total = it.total
                }
                .onFailure { error = it.message ?: "Search failed" }
            loading = false
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.weight(1f),
                singleLine = true,
                label = { Text("Search songs") },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { search() }),
            )
            Button(onClick = { search() }, enabled = !loading && query.isNotBlank()) {
                Text("Search")
            }
        }
        error?.let { ErrorText(it) }
        if (loading) {
            LoadingBlock()
        } else if (songs.isNotEmpty()) {
            Text(
                "$total results",
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.padding(vertical = 8.dp),
            )
        }
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            items(songs, key = { "search-${it.id}" }) { track ->
                TrackRow(track, loadingTrackId == track.id) { onTrackClick(track) }
                HorizontalDivider()
            }
        }
    }
}

@Composable
private fun LibraryScreen(
    loggedIn: Boolean,
    playlists: List<FfiPlaylistSummary>,
    loading: Boolean,
    onLogin: () -> Unit,
    onPlaylistClick: (FfiPlaylistSummary) -> Unit,
) {
    if (!loggedIn) {
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Sign in to load your playlists")
            Spacer(Modifier.height(12.dp))
            Button(onClick = onLogin) { Text("QR sign in") }
        }
        return
    }
    if (loading && playlists.isEmpty()) {
        LoadingBlock()
        return
    }
    LazyColumn(modifier = Modifier.fillMaxSize()) {
        item { SectionTitle("Your library") }
        items(playlists, key = { "library-${it.id}" }) { playlist ->
            PlaylistRow(playlist) { onPlaylistClick(playlist) }
            HorizontalDivider()
        }
        if (playlists.isEmpty()) {
            item { Text("No playlists returned for this account.") }
        }
    }
}

@Composable
private fun PlaylistDetailScreen(
    detail: FfiPlaylistDetail?,
    loading: Boolean,
    error: String?,
    loadingTrackId: Long?,
    onBack: () -> Unit,
    onTrackClick: (FfiSearchTrack) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        TextButton(onClick = onBack) { Text("← Back") }
        if (loading && detail == null) {
            LoadingBlock()
            return@Column
        }
        error?.let { ErrorText(it) }
        detail?.let { value ->
            Text(value.summary.name, style = MaterialTheme.typography.titleLarge)
            Text(
                "${value.summary.trackCount} tracks · ${value.summary.playCount} plays",
                style = MaterialTheme.typography.bodySmall,
            )
            Spacer(Modifier.height(8.dp))
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(value.tracks, key = { "playlist-track-${it.id}" }) { track ->
                    TrackRow(track, loadingTrackId == track.id) { onTrackClick(track) }
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun QrLoginDialog(
    repository: NeteaseRepository,
    onDismiss: () -> Unit,
    onAuthenticated: () -> Unit,
) {
    var attempt by remember { mutableIntStateOf(0) }
    var session by remember { mutableStateOf<QrLoginSession?>(null) }
    var status by remember { mutableStateOf("Creating login code…") }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(attempt) {
        session = null
        error = null
        status = "Creating login code…"
        runCatching { repository.beginQrLogin() }
            .onSuccess {
                session = it
                status = "Scan with the NetEase Cloud Music app"
            }
            .onFailure {
                error = it.message ?: "Unable to create login code"
                status = "Login code failed"
            }
    }

    LaunchedEffect(session?.key) {
        val key = session?.key ?: return@LaunchedEffect
        var transientFailures = 0
        var polls = 0
        while (true) {
            delay(1_500L)
            polls += 1
            if (polls > 120) {
                status = "二维码轮询已超时，请生成新二维码"
                return@LaunchedEffect
            }
            val result = runCatching { repository.checkQrLogin(key) }
            if (result.isFailure) {
                transientFailures += 1
                error = if (transientFailures >= 3) {
                    "网络或网易云风控暂时不可用，请稍后重试"
                } else {
                    result.exceptionOrNull()?.message ?: "Unable to check login status"
                }
                continue
            }
            transientFailures = 0
            val login = result.getOrThrow()
            status = when {
                login.state == "waiting" -> "Waiting for scan…"
                login.state == "scanned" -> "Scanned — confirm login in NetEase"
                login.state == "success" -> "Signed in"
                login.state == "expired" -> "QR code expired"
                login.code == -462L || login.code == -460L -> "网易云要求完成验证，请稍后重试"
                else -> login.message ?: "NetEase status ${login.code}"
            }
            when (login.state) {
                "success" -> {
                    onAuthenticated()
                    return@LaunchedEffect
                }
                "expired" -> return@LaunchedEffect
            }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("NetEase QR sign in") },
        text = {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                session?.url?.let { value ->
                    val bitmap = remember(value) { qrCodeBitmap(value) }
                    Image(
                        bitmap = bitmap,
                        contentDescription = "NetEase login QR code",
                        modifier = Modifier.size(240.dp),
                    )
                    Spacer(Modifier.height(8.dp))
                }
                Text(status)
                error?.let { ErrorText(it) }
            }
        },
        confirmButton = {
            TextButton(onClick = { attempt += 1 }) { Text("New code") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun PlaylistRow(playlist: FfiPlaylistSummary, onClick: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 12.dp, horizontal = 4.dp),
    ) {
        Text(playlist.name, style = MaterialTheme.typography.titleMedium)
        Text(
            "${playlist.trackCount} tracks · ${playlist.playCount} plays",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun TrackRow(track: FfiSearchTrack, loading: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !loading, onClick = onClick)
            .padding(vertical = 12.dp, horizontal = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(track.name, style = MaterialTheme.typography.titleMedium)
            Text(
                listOf(track.artistNames, track.albumName)
                    .filter(String::isNotBlank)
                    .joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
            )
            track.subtitle?.takeIf(String::isNotBlank)?.let {
                Text(it, style = MaterialTheme.typography.labelSmall)
            }
        }
        if (loading) {
            CircularProgressIndicator(modifier = Modifier.size(24.dp))
        }
    }
}

@Composable
private fun MiniPlayer(
    track: FfiSearchTrack,
    lyrics: LyricsPage?,
    positionMs: Long,
    isPlaying: Boolean,
    onToggle: () -> Unit,
    onSeek: (Long) -> Unit,
) {
    val duration = track.durationMs.coerceAtLeast(1L)
    val activeLine = activeLyricLine(lyrics?.lines.orEmpty(), positionMs)
    Card(modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
        Column(modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(track.name, maxLines = 1, style = MaterialTheme.typography.titleSmall)
                    Text(track.artistNames, maxLines = 1, style = MaterialTheme.typography.bodySmall)
                }
                TextButton(onClick = onToggle) { Text(if (isPlaying) "Pause" else "Play") }
            }
            activeLine?.let { line ->
                Text(line.text, maxLines = 1, style = MaterialTheme.typography.bodySmall)
                line.translation?.takeIf(String::isNotBlank)?.let {
                    Text(it, maxLines = 1, style = MaterialTheme.typography.labelSmall)
                }
            }
            Slider(
                value = (positionMs.toFloat() / duration.toFloat()).coerceIn(0f, 1f),
                onValueChange = { fraction -> onSeek((fraction * duration).toLong()) },
            )
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleLarge,
        modifier = Modifier.padding(vertical = 8.dp),
    )
}

@Composable
private fun LoadingBlock() {
    Row(
        modifier = Modifier.fillMaxWidth().padding(24.dp),
        horizontalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun ErrorText(message: String) {
    Text(
        message,
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodySmall,
        modifier = Modifier.padding(vertical = 8.dp),
    )
}

private fun activeLyricLine(lines: List<FfiLyricLine>, positionMs: Long): FfiLyricLine? =
    lines.lastOrNull { it.timeMs <= positionMs }

@Composable
private fun rememberMediaController(): MediaController? {
    val context = LocalContext.current
    var controller by remember { mutableStateOf<MediaController?>(null) }

    DisposableEffect(context) {
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener(
            {
                runCatching { future.get() }.onSuccess { controller = it }
            },
            ContextCompat.getMainExecutor(context),
        )
        onDispose {
            controller?.release()
            controller = null
            future.cancel(true)
        }
    }
    return controller
}
