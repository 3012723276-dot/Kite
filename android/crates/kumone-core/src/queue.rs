//! Platform-neutral playback queue rules.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RepeatMode {
    Off,
    One,
    All,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueuePlan {
    pub order: Vec<usize>,
    pub current_order_index: usize,
}

impl QueuePlan {
    #[must_use]
    pub fn current_item_index(&self) -> Option<usize> {
        self.order.get(self.current_order_index).copied()
    }

    #[must_use]
    pub fn next(&self, repeat: RepeatMode) -> Option<usize> {
        if self.order.is_empty() {
            return None;
        }
        if repeat == RepeatMode::One {
            return self.current_item_index();
        }
        if self.current_order_index + 1 < self.order.len() {
            return self.order.get(self.current_order_index + 1).copied();
        }
        (repeat == RepeatMode::All)
            .then(|| self.order.first().copied())
            .flatten()
    }

    #[must_use]
    pub fn previous(&self, repeat: RepeatMode) -> Option<usize> {
        if self.order.is_empty() {
            return None;
        }
        if repeat == RepeatMode::One {
            return self.current_item_index();
        }
        if self.current_order_index > 0 {
            return self.order.get(self.current_order_index - 1).copied();
        }
        (repeat == RepeatMode::All)
            .then(|| self.order.last().copied())
            .flatten()
    }
}

#[must_use]
pub fn sequential_plan(len: usize, current_item_index: usize) -> QueuePlan {
    let order: Vec<usize> = (0..len).collect();
    let current_order_index = current_item_index.min(len.saturating_sub(1));
    QueuePlan {
        order,
        current_order_index,
    }
}

/// Creates a deterministic shuffle plan without pulling an RNG dependency into
/// the shared core. The current item is always kept first so toggling shuffle
/// never changes the song that is currently playing.
#[must_use]
pub fn shuffled_plan(len: usize, current_item_index: usize, seed: u64) -> QueuePlan {
    if len == 0 {
        return QueuePlan {
            order: Vec::new(),
            current_order_index: 0,
        };
    }

    let current = current_item_index.min(len - 1);
    let mut rest: Vec<usize> = (0..len).filter(|index| *index != current).collect();
    let mut state = seed ^ (len as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    for index in (1..rest.len()).rev() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let swap_with = (state as usize) % (index + 1);
        rest.swap(index, swap_with);
    }

    let mut order = Vec::with_capacity(len);
    order.push(current);
    order.extend(rest);
    QueuePlan {
        order,
        current_order_index: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sequential_respects_repeat_modes() {
        let plan = sequential_plan(3, 2);
        assert_eq!(plan.next(RepeatMode::Off), None);
        assert_eq!(plan.next(RepeatMode::All), Some(0));
        assert_eq!(plan.next(RepeatMode::One), Some(2));
        assert_eq!(plan.previous(RepeatMode::Off), Some(1));
    }

    #[test]
    fn shuffle_keeps_current_song_and_covers_every_item_once() {
        let first = shuffled_plan(8, 3, 42);
        let second = shuffled_plan(8, 3, 42);
        assert_eq!(first, second);
        assert_eq!(first.current_item_index(), Some(3));
        let mut sorted = first.order.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, (0..8).collect::<Vec<_>>());
    }

    #[test]
    fn empty_queue_is_safe() {
        let plan = shuffled_plan(0, 0, 42);
        assert_eq!(plan.current_item_index(), None);
        assert_eq!(plan.next(RepeatMode::All), None);
    }
}
