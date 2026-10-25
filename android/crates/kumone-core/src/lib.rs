#![doc = "Shared, platform-neutral domain core for Kumone."]

pub mod account;
pub mod crypto;
pub mod errors;
pub mod lyrics;
pub mod netease;
pub mod playback;
pub mod queue;
pub mod search;
pub mod unblock;

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub type Result<T> = std::result::Result<T, CoreError>;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CoreError {
    #[error("invalid track id: {0}")]
    InvalidTrackId(String),
    #[error("unsupported audio quality: {0}")]
    UnsupportedAudioQuality(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct TrackId(u64);

impl TrackId {
    pub fn new(value: u64) -> Result<Self> {
        if value == 0 {
            return Err(CoreError::InvalidTrackId(value.to_string()));
        }
        Ok(Self(value))
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AudioQuality {
    Standard,
    Higher,
    ExHigh,
    Lossless,
    HiRes,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Artist {
    pub id: u64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Track {
    pub id: TrackId,
    pub name: String,
    pub artists: Vec<Artist>,
    pub album: String,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolvedAudio {
    pub track_id: TrackId,
    pub url: String,
    pub quality: AudioQuality,
    pub bitrate: Option<u32>,
    pub size_bytes: Option<u64>,
    pub source: AudioSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AudioSource {
    Netease,
    Kuwo,
    Kugou,
    Pyncmd,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn track_id_rejects_zero() {
        assert_eq!(
            TrackId::new(0),
            Err(CoreError::InvalidTrackId("0".to_owned()))
        );
    }

    #[test]
    fn track_id_accepts_positive_values() {
        let id = TrackId::new(42).expect("positive ids are valid");
        assert_eq!(id.get(), 42);
    }
}
