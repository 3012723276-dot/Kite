package moe.kite.android.player

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import moe.kite.android.model.Track

/**
 * 播放器封装：ExoPlayer 单例式简单封装，第一版只做播放 / 暂停 /
 * 切歌，具体 UI 状态后续用 StateFlow 接到 Compose。
 */
class KitePlayer(context: Context) {
    val exoPlayer: ExoPlayer = ExoPlayer.Builder(context).build()
    var current: Track? = null
        private set

    fun play(track: Track, url: String) {
        current = track
        exoPlayer.setMediaItem(MediaItem.fromUri(url))
        exoPlayer.prepare()
        exoPlayer.play()
    }

    fun togglePlayPause() {
        if (exoPlayer.isPlaying) exoPlayer.pause() else exoPlayer.play()
    }

    fun release() {
        exoPlayer.release()
    }
}
