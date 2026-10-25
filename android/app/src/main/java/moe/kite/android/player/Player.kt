package moe.kite.android.player

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import moe.kite.android.model.Track

/**
 * 播放器封装：ExoPlayer + 播放队列（上一首 / 下一首）。
 * 安卓适配：后台播放走 MediaSession / 通知栏是下一步，
 * 这里先保证前台播放队列正确，通知栏用 Media3 Session 接入。
 */
class KitePlayer(context: Context) {
    val exoPlayer: ExoPlayer = ExoPlayer.Builder(context).build()

    var queue: List<Track> = emptyList()
        private set
    var currentIndex: Int = -1
        private set
    var current: Track? = null
        private set

    fun playQueue(tracks: List<Track>, startIndex: Int, urlProvider: suspend (Track) -> String) {
        // urlProvider 由界面层用协程调用 songUrl 后再调 playWithUrl，
        // 这里保留队列状态，避免播放页和列表页状态不一致。
        queue = tracks
        currentIndex = startIndex
        current = tracks.getOrNull(startIndex)
    }

    fun playWithUrl(track: Track, url: String) {
        current = track
        exoPlayer.setMediaItem(MediaItem.fromUri(url))
        exoPlayer.prepare()
        exoPlayer.play()
    }

    fun play(track: Track, url: String) {
        queue = listOf(track)
        currentIndex = 0
        playWithUrl(track, url)
    }

    fun togglePlayPause() {
        if (exoPlayer.isPlaying) exoPlayer.pause() else exoPlayer.play()
    }

    fun hasNext(): Boolean = currentIndex >= 0 && currentIndex + 1 < queue.size
    fun hasPrev(): Boolean = currentIndex > 0

    fun nextTrack(): Track? {
        if (!hasNext()) return null
        currentIndex += 1
        current = queue[currentIndex]
        return current
    }

    fun prevTrack(): Track? {
        if (!hasPrev()) return null
        currentIndex -= 1
        current = queue[currentIndex]
        return current
    }

    fun seekTo(positionMs: Long) {
        exoPlayer.seekTo(positionMs)
    }

    fun release() {
        exoPlayer.release()
    }
}
