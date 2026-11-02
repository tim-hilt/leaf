//! A per-Document value read from disk once and then kept in memory.

use std::collections::HashMap;
use std::convert::Infallible;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// The value of each Document read so far, by ID, with the Imports it was read
/// for: when a Document's Imports change, e.g. at a Re-Import, it is read again.
#[derive(Debug)]
pub(crate) struct DocCache<T> {
    known: Mutex<Known<T>>,
}

type Known<T> = HashMap<String, (Vec<String>, Option<T>)>;

impl<T: Clone> DocCache<T> {
    pub fn new() -> Self {
        Self {
            known: Mutex::default(),
        }
    }

    /// The value of Document `id` with `imports`: the one kept, else what
    /// `read` returns, which is then kept, unless a value was `set` meanwhile.
    pub fn get_or_read(
        &self,
        id: &str,
        imports: &[String],
        read: impl FnOnce() -> Option<T>,
    ) -> Option<T> {
        let Ok(value) = self.get_or_try_read(id, imports, || Ok::<_, Infallible>(read()));
        value
    }

    /// `get_or_read` for a `read` that can fail: a failure is returned, and
    /// nothing is kept.
    pub fn get_or_try_read<E>(
        &self,
        id: &str,
        imports: &[String],
        read: impl FnOnce() -> Result<Option<T>, E>,
    ) -> Result<Option<T>, E> {
        if let Some((kept, value)) = self.lock().get(id)
            && kept == imports
        {
            return Ok(value.clone());
        }
        let read = read()?;
        let mut known = self.lock();
        Ok(match known.get(id) {
            Some((kept, set)) if kept == imports => set.clone(),
            _ => {
                known.insert(id.to_owned(), (imports.to_vec(), read.clone()));
                read
            }
        })
    }

    /// Keeps `value` as that of Document `id` with `imports`.
    pub fn set(&self, id: &str, imports: &[String], value: Option<T>) {
        self.lock().insert(id.to_owned(), (imports.to_vec(), value));
    }

    fn lock(&self) -> MutexGuard<'_, Known<T>> {
        self.known.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn imports(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|&i| i.to_owned()).collect()
    }

    #[test]
    fn a_value_is_read_once_per_set_of_imports() {
        let cache = DocCache::new();
        let reads = Cell::new(0);
        let read = |value| {
            reads.set(reads.get() + 1);
            Some(value)
        };
        assert_eq!(
            cache.get_or_read("a", &imports(&["1"]), || read(1)),
            Some(1)
        );
        assert_eq!(
            cache.get_or_read("a", &imports(&["1"]), || read(2)),
            Some(1)
        );
        assert_eq!(reads.get(), 1);
        // A Re-Import reads again.
        assert_eq!(
            cache.get_or_read("a", &imports(&["1", "2"]), || read(3)),
            Some(3)
        );
        assert_eq!(reads.get(), 2);
    }

    #[test]
    fn a_value_set_is_kept_and_not_for_other_imports() {
        let cache = DocCache::new();
        cache.set("a", &imports(&["1"]), Some(5));
        assert_eq!(cache.get_or_read("a", &imports(&["1"]), || None), Some(5));
        assert_eq!(
            cache.get_or_read("a", &imports(&["2"]), || Some(7)),
            Some(7)
        );
    }

    #[test]
    fn a_failed_read_keeps_nothing_and_the_next_read_is_tried_again() {
        let cache = DocCache::new();
        let failed = cache.get_or_try_read("a", &imports(&["1"]), || Err::<Option<i32>, _>("gone"));
        assert_eq!(failed, Err("gone"));
        let read = cache.get_or_try_read("a", &imports(&["1"]), || Ok::<_, &str>(Some(2)));
        assert_eq!(read, Ok(Some(2)));
    }

    #[test]
    fn a_value_set_during_a_read_wins_over_the_read() {
        let cache = DocCache::new();
        let got = cache.get_or_read("a", &imports(&["1"]), || {
            cache.set("a", &imports(&["1"]), Some(9));
            Some(1)
        });
        assert_eq!(got, Some(9));
        assert_eq!(cache.get_or_read("a", &imports(&["1"]), || None), Some(9));
    }
}
