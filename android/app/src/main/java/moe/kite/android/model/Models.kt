package moe.kite.android.model

import kotlinx.serialization.Serializable

@Serializable
data class Track(
    val id: Long,
    val name: String,
    val artist: String = "",
    val album: String = "",
    val coverUrl: String = "",
    val durationMs: Long = 0
)

@Serializable
data class Album(
    val id: Long,
    val name: String,
    val artist: String = "",
    val coverUrl: String = "",
    val publishTime: Long = 0
)

@Serializable
data class Playlist(
    val id: Long,
    val name: String,
    val coverUrl: String = "",
    val trackCount: Int = 0
)
