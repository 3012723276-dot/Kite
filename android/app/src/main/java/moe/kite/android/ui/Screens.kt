package moe.kite.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import moe.kite.android.api.NeteaseApi
import moe.kite.android.model.Playlist
import moe.kite.android.model.Track
import moe.kite.android.player.KitePlayer

/** 歌单详情：点歌单进列表，点歌播放并进队列。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaylistDetailScreen(
    api: NeteaseApi,
    playlistId: Long,
    onPlayQueue: (List<Track>, Int) -> Unit
) {
    var playlist by remember { mutableStateOf<Playlist?>(null) }
    var tracks by remember { mutableStateOf<List<Track>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }

    LaunchedEffect(playlistId) {
        try {
            val (info, list) = withContext(Dispatchers.IO) { api.playlistDetail(playlistId) }
            playlist = info
            tracks = list
        } finally {
            loading = false
        }
    }

    Column(modifier = Modifier.padding(16.dp)) {
        Text(playlist?.name ?: "歌单", style = MaterialTheme.typography.titleLarge)
        Spacer(modifier = Modifier.height(12.dp))
        if (loading) {
            CircularProgressIndicator()
        } else {
            LazyColumn {
                items(tracks.withIndex().toList()) { (index, track) ->
                    ListItem(
                        headlineContent = { Text(track.name) },
                        supportingContent = { Text(track.artist) },
                        modifier = Modifier.clickable { onPlayQueue(tracks, index) }
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}

/** 播放页：封面占位、歌词、进度、上一首 / 下一首。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerScreen(
    api: NeteaseApi,
    player: KitePlayer,
    onNext: () -> Unit,
    onPrev: () -> Unit
) {
    val track = player.current
    var lyric by remember { mutableStateOf("") }

    LaunchedEffect(track?.id) {
        if (track != null) {
            lyric = withContext(Dispatchers.IO) { api.lyric(track.id) }
        }
    }

    Column(modifier = Modifier.padding(16.dp)) {
        Text(track?.name ?: "未在播放", style = MaterialTheme.typography.titleLarge)
        Text(track?.artist ?: "", style = MaterialTheme.typography.bodyMedium)
        Spacer(modifier = Modifier.height(16.dp))
        Row {
            Button(onClick = onPrev, enabled = player.hasPrev()) { Text("上一首") }
            Spacer(modifier = Modifier.width(8.dp))
            Button(onClick = { player.togglePlayPause() }) {
                Text(if (player.exoPlayer.isPlaying) "暂停" else "播放")
            }
            Spacer(modifier = Modifier.width(8.dp))
            Button(onClick = onNext, enabled = player.hasNext()) { Text("下一首") }
        }
        Spacer(modifier = Modifier.height(16.dp))
        Text("歌词", style = MaterialTheme.typography.titleMedium)
        Spacer(modifier = Modifier.height(8.dp))
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            val lines = lyric.lines().filter { it.isNotBlank() }
            if (lines.isEmpty()) {
                item { Text("暂无歌词") }
            } else {
                items(lines) { line -> Text(line, modifier = Modifier.padding(vertical = 2.dp)) }
            }
        }
    }
}
