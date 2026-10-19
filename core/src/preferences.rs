//! Preferences and how they are kept in their Automerge document (ADR-0014):
//! per-user choices that belong to the Library, not to a Document.
//!
//! Schema, version 1: the root holds `version` and `default_color`, a
//! reference to the Default Highlight Color. A built-in color is referenced by
//! its name; Custom Colors will be referenced by their ID, which is never a
//! color name. Concurrent choices on several devices leave Automerge's winner.

use crate::markup::BuiltInColor;
use crate::state;
use automerge::{AutoCommit, ROOT, ScalarValue, transaction::Transactable};

const SCHEMA_VERSION: u64 = 1;

/// The Default Highlight Color in a stored Automerge document. Yellow if
/// `bytes` aren't one, hold none, or reference a color that doesn't exist.
pub(crate) fn default_color(bytes: &[u8]) -> BuiltInColor {
    AutoCommit::load(bytes)
        .ok()
        .and_then(|doc| state::scalar(&doc, &ROOT, "default_color"))
        .and_then(|reference| BuiltInColor::named(reference.as_str()?))
        .unwrap_or(BuiltInColor::YELLOW)
}

/// The Automerge document `existing` with `color` as the Default Highlight
/// Color, compacted. A missing or unreadable `existing` starts a new document.
pub(crate) fn set_default_color(existing: Option<&[u8]>, color: BuiltInColor) -> Vec<u8> {
    state::update_versioned(existing, SCHEMA_VERSION, |doc| {
        doc.put(ROOT, "default_color", ScalarValue::Str(color.name.into()))
            .expect("a root map accepts new keys");
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stored_default_color_reads_back_with_schema_version_1() {
        let green = BuiltInColor::named("Green").unwrap();
        let bytes = set_default_color(None, green);
        assert_eq!(default_color(&bytes), green);
        let doc = AutoCommit::load(&bytes).unwrap();
        assert_eq!(
            state::scalar(&doc, &ROOT, "version"),
            Some(ScalarValue::Uint(1))
        );
    }

    #[test]
    fn a_reference_to_a_color_that_does_not_exist_reads_as_yellow() {
        let bytes = state::update_versioned(None, 1, |doc| {
            doc.put(ROOT, "default_color", "0123abcd").unwrap();
        });
        assert_eq!(default_color(&bytes), BuiltInColor::YELLOW);
    }

    #[test]
    fn a_document_without_a_default_color_reads_as_yellow() {
        assert_eq!(
            default_color(&AutoCommit::new().save()),
            BuiltInColor::YELLOW
        );
    }

    #[test]
    fn concurrent_choices_on_two_devices_settle_on_one_of_them() {
        let base = set_default_color(None, BuiltInColor::YELLOW);
        let red = BuiltInColor::named("Red").unwrap();
        let blue = BuiltInColor::named("Blue").unwrap();
        let mut one = AutoCommit::load(&set_default_color(Some(&base), red)).unwrap();
        let mut other = AutoCommit::load(&set_default_color(Some(&base), blue)).unwrap();

        one.merge(&mut other).unwrap();
        other.merge(&mut one).unwrap();

        let merged = default_color(&one.save());
        assert!([red, blue].contains(&merged));
        assert_eq!(merged, default_color(&other.save()));
    }
}
