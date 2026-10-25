package moe.kite.android.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import moe.kite.android.api.NeteaseApi
import moe.kite.android.model.Album
import moe.kite.android.model.Track
import moe.kite.android.player.KitePlayer
import moe.kite.android.player.UnblockService

class MainActivity : ComponentActivity() {
    private lateinit var player: KitePlayer

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        player = KitePlayer(this)
        setContent {
            MaterialTheme {
                KiteApp(player = player, onDestroyPlayer = { player.release() })
            }
        }
    }

    override fun onDestroy() {
        player.release()
        super.onDestroy()
    }
}

@Composable
fun KiteApp(player: KitePlayer, onDestroyPlayer: () -> Unit) {
    val navController = rememberNavController()
    var currentTrack by remember { mutableStateOf<Track?>(null) }
    var currentSource by remember { mutableStateOf<String?>(null) }
    var playing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val api = remember { NeteaseApi() }

    fun playTrack(track: Track) {
        scope.launch {
            val url = withContext(Dispatchers.IO) { api.songUrl(track.id) }
            if (url.isNotBlank()) {
                player.play(track, url)
                currentTrack = track
                currentSource = null
                playing = true
            } else {
                // 网易拒绝 → 第三方音源兜底（pyncmd / 酷狗 / 酷我），与 iOS 版同策略
                val unblocked = withContext(Dispatchers.IO) { UnblockService.resolve(track) }
                if (unblocked != null) {
                    player.play(track, unblocked.url)
                    currentTrack = track
                    currentSource = unblocked.name
                    playing = true
                }
            }
        }
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Kite") }) },
        bottomBar = {
            Column {
                if (currentTrack != null) {
                    ListItem(
                        headlineContent = { Text(currentTrack!!.name) },
                        supportingContent = {
                            Text(
                                if (currentSource != null) "${currentTrack!!.artist} · 第三方音源：$currentSource"
                                else currentTrack!!.artist
                            )
                        },
                        modifier = Modifier.clickable { navController.navigate("player") },
                        trailingContent = {
                            TextButton(onClick = {
                                player.togglePlayPause()
                                playing = !playing
                            }) { Text(if (playing) "暂停" else "播放") }
                        }
                    )
                }
                NavigationBar {
                    NavigationBarItem(
                        selected = false, onClick = { navController.navigate("home") },
                        icon = {}, label = { Text("首页") }
                    )
                    NavigationBarItem(
                        selected = false, onClick = { navController.navigate("search") },
                        icon = {}, label = { Text("搜索") }
                    )
                    NavigationBarItem(
                        selected = false, onClick = { navController.navigate("login") },
                        icon = {}, label = { Text("我的") }
                    )
                }
            }
        }
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = "home",
            modifier = Modifier.padding(padding)
        ) {
            composable("home") {
                HomeScreen(
                    api = api,
                    onPlaylistClick = { id -> navController.navigate("playlist/$id") }
                )
            }
            composable("search") { SearchScreen(api = api, onPlay = ::playTrack) }
            composable("login") { LoginScreen(api = api) }
            composable("player") {
                PlayerScreen(
                    api = api,
                    player = player,
                    onNext = {
                        val next = player.nextTrack()
                        if (next != null) playTrack(next)
                    },
                    onPrev = {
                        val prev = player.prevTrack()
                        if (prev != null) playTrack(prev)
                    }
                )
            }
            composable("playlist/{id}") { backStackEntry ->
                val id = backStackEntry.arguments?.getString("id")?.toLongOrNull() ?: 0L
                PlaylistDetailScreen(
                    api = api,
                    playlistId = id,
                    onPlayQueue = { tracks, index ->
                        player.playQueue(tracks, index) { track -> "" }
                        playTrack(tracks[index])
                    }
                )
            }
        }
    }
}

@Composable
fun HomeScreen(api: NeteaseApi, onPlaylistClick: (Long) -> Unit) {
    var albums by remember { mutableStateOf<List<Album>>(emptyList()) }
    var playlists by remember { mutableStateOf<List<moe.kite.android.model.Playlist>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) {
        try {
            albums = withContext(Dispatchers.IO) { api.newAlbums() }
            playlists = withContext(Dispatchers.IO) { api.personalizedPlaylists() }
        } catch (e: Exception) {
            error = e.message ?: "加载失败"
        } finally {
            loading = false
        }
    }

    Column(modifier = Modifier.padding(16.dp)) {
        Text("推荐歌单", style = MaterialTheme.typography.titleLarge)
        Spacer(modifier = Modifier.height(8.dp))
        LazyColumn {
            items(playlists) { playlist ->
                ListItem(
                    headlineContent = { Text(playlist.name) },
                    supportingContent = { Text("${playlist.trackCount} 首") },
                    modifier = Modifier.clickable { onPlaylistClick(playlist.id) }
                )
                HorizontalDivider()
            }
            item {
                Spacer(modifier = Modifier.height(16.dp))
                Text("新专辑", style = MaterialTheme.typography.titleLarge)
                Spacer(modifier = Modifier.height(8.dp))
            }
            if (loading) {
                item { CircularProgressIndicator() }
            } else if (error != null) {
                item { Text("加载失败：$error") }
            } else {
                items(albums) { album ->
                    ListItem(
                        headlineContent = { Text(album.name) },
                        supportingContent = { Text(album.artist) }
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
fun SearchScreen(api: NeteaseApi, onPlay: (Track) -> Unit) {
    var keyword by remember { mutableStateOf("") }
    var tracks by remember { mutableStateOf<List<Track>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    Column(modifier = Modifier.padding(16.dp)) {
        OutlinedTextField(
            value = keyword,
            onValueChange = { keyword = it },
            label = { Text("搜索歌曲") },
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(modifier = Modifier.height(8.dp))
        Button(onClick = {
            scope.launch {
                loading = true
                tracks = withContext(Dispatchers.IO) { api.search(keyword) }
                loading = false
            }
        }) { Text("搜索") }
        Spacer(modifier = Modifier.height(12.dp))
        if (loading) {
            CircularProgressIndicator()
        } else {
            LazyColumn {
                items(tracks) { track ->
                    ListItem(
                        headlineContent = { Text(track.name) },
                        supportingContent = { Text("${track.artist} · ${track.album}") },
                        modifier = Modifier.clickable { onPlay(track) }
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
fun LoginScreen(api: NeteaseApi) {
    var phone by remember { mutableStateOf("") }
    var captcha by remember { mutableStateOf("") }
    var message by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    Column(modifier = Modifier.padding(16.dp)) {
        Text("手机号登录", style = MaterialTheme.typography.titleLarge)
        Spacer(modifier = Modifier.height(12.dp))
        OutlinedTextField(
            value = phone,
            onValueChange = { phone = it },
            label = { Text("手机号") },
            modifier = Modifier.fillMaxWidth()
        )
        Spacer(modifier = Modifier.height(8.dp))
        Row {
            Button(onClick = {
                scope.launch {
                    val ok = withContext(Dispatchers.IO) { api.sendSmsCode(phone) }
                    message = if (ok) "验证码已发送" else "发送失败，请检查手机号"
                }
            }) { Text("获取验证码") }
            Spacer(modifier = Modifier.width(8.dp))
            OutlinedTextField(
                value = captcha,
                onValueChange = { captcha = it },
                label = { Text("验证码") },
                modifier = Modifier.weight(1f)
            )
        }
        Spacer(modifier = Modifier.height(12.dp))
        Button(onClick = {
            scope.launch {
                val ok = withContext(Dispatchers.IO) { api.loginCellphone(phone, captcha) }
                message = if (ok) "登录成功（Cookie 持久化待下一步完善）" else "登录失败，请检查验证码"
            }
        }) { Text("登录") }
        if (message.isNotBlank()) {
            Spacer(modifier = Modifier.height(12.dp))
            Text(message)
        }
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            "说明：正式登录需要把 MUSIC_U 等 Cookie 存到本地，" +
                "当前版本先验证接口通不通，持久化在下一步做。",
            style = MaterialTheme.typography.bodySmall
        )
    }
}
