package moe.kite.android.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import moe.kite.android.api.NeteaseApi
import moe.kite.android.api.PersistentCookieJar
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
            // iOS 版主题色 #EC4949（网易红），不再用 Material 默认紫色，
            // 这就是视频里按钮是紫色的原因之一。
            MaterialTheme(
                colorScheme = MaterialTheme.colorScheme.copy(
                    primary = Color(0xFFEC4949),
                    primaryContainer = Color(0xFFEC4949),
                    onPrimary = Color.White
                )
            ) {
                KiteApp(player = player, onDestroyPlayer = { player.release() })
            }
        }
    }

    override fun onDestroy() {
        player.release()
        super.onDestroy()
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KiteApp(player: KitePlayer, onDestroyPlayer: () -> Unit) {
    val navController = rememberNavController()
    var currentTrack by remember { mutableStateOf<Track?>(null) }
    var currentSource by remember { mutableStateOf<String?>(null) }
    var playing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    // 关键修复：之前这里用默认 NeteaseApi()，OkHttp 没有 CookieJar，
    // 发验证码和登录是两次请求，中间的会话 Cookie 全丢了，
    // 服务器对不上验证码会话，所以视频里明明验证码是对的也登录失败。
    // 现在用 PersistentCookieJar，扫码成功后的 MUSIC_U 也会存下来。
    val context = LocalContext.current
    val api = remember {
        NeteaseApi.withCookieJar(PersistentCookieJar(context.applicationContext))
    }

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

@OptIn(ExperimentalMaterial3Api::class)
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

    // 机型适配：GridCells.Adaptive 会按屏幕宽度自动算列数，
    // 手机 2 列、平板 / 折叠屏展开后更多列，不用写死列数。
    androidx.compose.foundation.lazy.grid.LazyVerticalGrid(
        columns = androidx.compose.foundation.lazy.grid.GridCells.Adaptive(minSize = 160.dp),
        modifier = Modifier.padding(16.dp),
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(16.dp)
    ) {
        item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
            Text("推荐歌单", style = MaterialTheme.typography.titleLarge)
        }
        if (loading) {
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                CircularProgressIndicator()
            }
        } else if (error != null) {
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                Text("加载失败：$error")
            }
        } else {
            items(playlists) { playlist ->
                Card(
                    modifier = Modifier.clickable { onPlaylistClick(playlist.id) },
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(14.dp)
                ) {
                    Column {
                        coil.compose.AsyncImage(
                            model = playlist.coverUrl, contentDescription = playlist.name,
                            modifier = Modifier.fillMaxWidth().aspectRatio(1f),
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop
                        )
                        Text(playlist.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, modifier = Modifier.padding(8.dp))
                        Text("${playlist.trackCount} 首", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 8.dp).padding(bottom = 8.dp))
                    }
                }
            }
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) {
                Text("新专辑", style = MaterialTheme.typography.titleLarge)
            }
            items(albums) { album ->
                Card(shape = androidx.compose.foundation.shape.RoundedCornerShape(14.dp)) {
                    Column {
                        coil.compose.AsyncImage(
                            model = album.coverUrl, contentDescription = album.name,
                            modifier = Modifier.fillMaxWidth().aspectRatio(1f),
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop
                        )
                        Text(album.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, modifier = Modifier.padding(8.dp))
                        Text(album.artist, style = MaterialTheme.typography.bodySmall, maxLines = 1, modifier = Modifier.padding(horizontal = 8.dp).padding(bottom = 8.dp))
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoginScreen(api: NeteaseApi) {
    // 与 iOS LoginSheet 同结构：默认扫码，切换到短信是第二页。
    var tab by remember { mutableStateOf(0) } // 0 = 扫码登录，1 = 手机验证码
    var nickname by remember { mutableStateOf<String?>(null) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 28.dp),
        horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally
    ) {
        Text("登录网易云音乐", style = MaterialTheme.typography.titleMedium)
        Spacer(modifier = Modifier.height(12.dp))
        SingleChoiceSegmentedButtonRow(modifier = Modifier.width(220.dp)) {
            SegmentedButton(selected = tab == 0, onClick = { tab = 0 }, shape = SegmentedButtonDefaults.itemShape(0, 2)) { Text("扫码登录") }
            SegmentedButton(selected = tab == 1, onClick = { tab = 1 }, shape = SegmentedButtonDefaults.itemShape(1, 2)) { Text("手机验证码") }
        }
        Spacer(modifier = Modifier.height(20.dp))
        if (nickname != null) {
            Text("欢迎回来，$nickname", style = MaterialTheme.typography.titleMedium)
        } else if (tab == 0) {
            QrLoginSection(api = api, onSuccess = { name -> nickname = name })
        } else {
            SmsLoginSection(api = api, onSuccess = { name -> nickname = name })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QrLoginSection(api: NeteaseApi, onSuccess: (String?) -> Unit) {
    var qrBitmap by remember { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var status by remember { mutableStateOf("正在获取二维码…") }
    var unikey by remember { mutableStateOf<String?>(null) }
    var expired by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun startQr() {
        scope.launch {
            status = "正在获取二维码…"
            expired = false
            qrBitmap = null
            try {
                val key = withContext(Dispatchers.IO) { api.qrKey() }
                if (key.isBlank()) { status = "获取二维码失败，请点刷新重试"; return@launch }
                unikey = key
                qrBitmap = generateQrBitmap(api.qrLoginUrl(key))
                status = "打开网易云音乐 App，扫一扫登录"
                var errors = 0
                while (true) {
                    kotlinx.coroutines.delay(1200)
                    val check = withContext(Dispatchers.IO) { api.qrCheck(key) }
                    when (check.code) {
                        800 -> { status = "二维码已失效，请刷新"; expired = true; break }
                        801 -> { status = "打开网易云音乐 App，扫一扫登录" }
                        802 -> { status = "已扫码，${check.nickname ?: ""}，请在手机上确认" }
                        803 -> {
                            val name = withContext(Dispatchers.IO) { api.userNickname() }
                            status = "登录成功！"
                            onSuccess(name)
                            break
                        }
                        else -> { errors += 1; if (errors >= 15) { status = "网络异常，请刷新重试"; break } }
                    }
                }
            } catch (e: Exception) {
                status = "获取二维码失败：${e.message ?: "网络错误"}"
            }
        }
    }

    LaunchedEffect(Unit) { startQr() }

    Text("使用网易云音乐 App 扫码登录", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Spacer(modifier = Modifier.height(20.dp))
    Card(
        modifier = Modifier.size(208.dp),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White),
        elevation = CardDefaults.cardElevation(defaultElevation = 4.dp)
    ) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = androidx.compose.ui.Alignment.Center) {
            if (qrBitmap != null) {
                androidx.compose.foundation.Image(bitmap = qrBitmap!!, contentDescription = "扫码登录二维码", modifier = Modifier.size(180.dp))
            } else {
                CircularProgressIndicator()
            }
        }
    }
    Spacer(modifier = Modifier.height(12.dp))
    Text(status, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (expired) {
        Spacer(modifier = Modifier.height(8.dp))
        Button(onClick = { startQr() }) { Text("刷新") }
    }
    Spacer(modifier = Modifier.height(12.dp))
    Text(
        "只有一台设备？截图二维码，到网易云音乐 App 的扫一扫里选择相册识别，然后回到这里即可",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = androidx.compose.ui.text.style.TextAlign.Center
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SmsLoginSection(api: NeteaseApi, onSuccess: (String?) -> Unit) {
    var phone by remember { mutableStateOf("") }
    var captcha by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var cooldown by remember { mutableStateOf(0) }
    var sending by remember { mutableStateOf(false) }
    var loggingIn by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(cooldown) {
        if (cooldown > 0) {
            kotlinx.coroutines.delay(1000)
            cooldown -= 1
        }
    }

    // iOS 版同款提示：短信登录可能被风控，推荐扫码。
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = Color(0xFFEC4949).copy(alpha = 0.1f))
    ) {
        Text(
            "可能被网易云风控拦截而不可用，推荐使用扫码登录",
            style = MaterialTheme.typography.bodySmall,
            color = Color(0xFFEC4949),
            modifier = Modifier.padding(12.dp)
        )
    }
    Spacer(modifier = Modifier.height(16.dp))
    OutlinedTextField(
        value = phone, onValueChange = { phone = it },
        label = { Text("手机号") }, prefix = { Text("+86  ") },
        modifier = Modifier.fillMaxWidth()
    )
    Spacer(modifier = Modifier.height(12.dp))
    Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        OutlinedTextField(
            value = captcha, onValueChange = { captcha = it },
            label = { Text("验证码") }, modifier = Modifier.weight(1f)
        )
        Spacer(modifier = Modifier.width(8.dp))
        TextButton(
            enabled = !sending && cooldown == 0 && phone.length >= 11,
            onClick = {
                scope.launch {
                    sending = true
                    val ok = withContext(Dispatchers.IO) { api.sendSmsCode(phone) }
                    sending = false
                    if (ok) { message = "验证码已发送"; cooldown = 60 } else { message = "发送失败，请检查手机号" }
                }
            }
        ) { Text(if (sending) "发送中…" else if (cooldown > 0) "${cooldown}s" else "获取验证码") }
    }
    if (message != null) {
        Spacer(modifier = Modifier.height(8.dp))
        Text(message!!, style = MaterialTheme.typography.bodySmall, color = Color(0xFFEC4949))
    }
    Spacer(modifier = Modifier.height(16.dp))
    Button(
        enabled = !loggingIn && phone.length >= 11 && captcha.length >= 4,
        onClick = {
            scope.launch {
                loggingIn = true
                val (ok, detail) = withContext(Dispatchers.IO) { api.loginCellphoneDetailed(phone, captcha) }
                loggingIn = false
                if (ok) {
                    val name = withContext(Dispatchers.IO) { api.userNickname() }
                    message = "登录成功"
                    onSuccess(name)
                } else {
                    // 不再笼统说“检查验证码”，显示服务器真实返回。
                    message = detail
                }
            }
        },
        modifier = Modifier.fillMaxWidth()
    ) { Text(if (loggingIn) "登录中…" else "登录") }
}
