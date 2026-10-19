//! Preferences and how they are kept in their Automerge document (ADR-0014):
//! per-user choices that belong to the Library, not to a Document.
//!
//! Schema, version 1: the root holds `version`, `default_color` and
//! `custom_colors`. `default_color` references the Default Highlight Color: a
//! built-in color by its name, a Custom Color by its ID, which is never a color
//! name. `custom_colors` maps each Custom Color's ID to its color (sRGB as
//! `0xRRGGBB`). An ID starts with the time it was added, so sorting IDs gives
//! the order added. Documents without `custom_colors` have no Custom Colors.
//!
//! Concurrent choices of the default leave Automerge's winner. Devices that
//! first add a Custom Color concurrently each create their own `custom_colors`
//! map; reading lists the colors of all of them, writing goes to the winner.

use crate::markup::Rgb;
use crate::state;
use automerge::{ActorId, AutoCommit, ROOT, ReadDoc, ScalarValue, transaction::Transactable};

pub(crate) const SCHEMA_VERSION: u64 = 1;

/// One of the Highlight Colors that always exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BuiltInColor {
    pub name: &'static str,
    pub rgb: Rgb,
}

const fn built_in(name: &'static str, r: u8, g: u8, b: u8) -> BuiltInColor {
    BuiltInColor {
        name,
        rgb: Rgb { r, g, b },
    }
}

/// The built-in Highlight Colors, yellow (the default) first.
pub const BUILT_IN_COLORS: [BuiltInColor; 6] = [
    built_in("Yellow", 255, 235, 60),
    built_in("Green", 126, 217, 87),
    built_in("Blue", 102, 178, 255),
    built_in("Pink", 255, 128, 191),
    built_in("Purple", 178, 140, 255),
    built_in("Red", 255, 99, 99),
];

impl BuiltInColor {
    /// The built-in color called `name`, if there is one.
    pub fn named(name: &str) -> Option<Self> {
        BUILT_IN_COLORS.into_iter().find(|c| c.name == name)
    }

    /// Yellow, the Default Highlight Color until the user picks another.
    pub const YELLOW: Self = BUILT_IN_COLORS[0];
}

/// A color to highlight in: a built-in one, or a Custom Color of the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HighlightColor {
    /// A built-in color's name, or a Custom Color's ID.
    pub id: String,
    pub rgb: Rgb,
    pub is_custom: bool,
}

impl From<BuiltInColor> for HighlightColor {
    fn from(color: BuiltInColor) -> Self {
        Self {
            id: color.name.to_owned(),
            rgb: color.rgb,
            is_custom: false,
        }
    }
}

fn load(bytes: Option<&[u8]>) -> AutoCommit {
    bytes
        .and_then(|bytes| AutoCommit::load(bytes).ok())
        .unwrap_or_default()
}

/// The Custom Colors in `doc`, in the order added.
fn custom_colors(doc: &AutoCommit) -> Vec<HighlightColor> {
    let mut colors: Vec<_> = state::maps(doc, "custom_colors")
        .iter()
        .flat_map(|map| {
            doc.keys(map).filter_map(|id| {
                let rgb = Rgb::unpacked(state::scalar(doc, map, id.as_str())?.as_u64()?)?;
                Some(HighlightColor {
                    id,
                    rgb,
                    is_custom: true,
                })
            })
        })
        .collect();
    colors.sort_by(|a, b| a.id.cmp(&b.id));
    colors
}

/// The Highlight Colors in a stored Automerge document (none if missing): the
/// built-in ones, then the Custom Colors in the order added. `bytes` that
/// aren't an Automerge document hold no Custom Colors.
pub(crate) fn colors(bytes: Option<&[u8]>) -> Vec<HighlightColor> {
    let custom = custom_colors(&load(bytes));
    BUILT_IN_COLORS
        .into_iter()
        .map(HighlightColor::from)
        .chain(custom)
        .collect()
}

/// The Default Highlight Color in a stored Automerge document (none if
/// missing). Yellow if `bytes` aren't one, hold none, or reference a color that
/// doesn't exist (any more).
pub(crate) fn default_color(bytes: Option<&[u8]>) -> HighlightColor {
    let doc = load(bytes);
    let referenced = state::scalar(&doc, &ROOT, "default_color").and_then(|r| r.into_string().ok());
    let color = referenced.and_then(|id| match BuiltInColor::named(&id) {
        Some(built_in) => Some(built_in.into()),
        None => custom_colors(&doc).into_iter().find(|c| c.id == id),
    });
    color.unwrap_or_else(|| BuiltInColor::YELLOW.into())
}

/// The Automerge document `existing` with `change` made as `actor`, stamped
/// with the schema version and compacted.
pub(crate) fn update(
    existing: Option<&[u8]>,
    actor: &ActorId,
    change: impl FnOnce(&mut AutoCommit),
) -> Vec<u8> {
    state::update_versioned(existing, actor, SCHEMA_VERSION, change)
}

/// Makes the color `id` the Default Highlight Color in `doc`. It doesn't check
/// that `id` is a color.
pub(crate) fn set_default_color(doc: &mut AutoCommit, id: &str) {
    doc.put(ROOT, "default_color", ScalarValue::Str(id.into()))
        .expect("a root map accepts new keys");
}

/// Adds a new Custom Color `rgb` to `doc`, added at `now` in milliseconds
/// since the Unix epoch, and returns it. It comes after every Custom Color
/// already there, even if clocks disagree.
pub(crate) fn add_custom_color(doc: &mut AutoCommit, rgb: Rgb, now: u64) -> HighlightColor {
    let after = custom_colors(doc).last().and_then(|c| added_at(&c.id));
    let time = after.map_or(now, |last| now.max(last + 1));
    let id = format!("{time:013x}-{}", state::new_id());
    let map = state::map_to_write(doc, "custom_colors");
    doc.put(&map, id.as_str(), ScalarValue::Uint(rgb.packed()))
        .expect("a map accepts new keys");
    HighlightColor {
        id,
        rgb,
        is_custom: true,
    }
}

/// When the Custom Color `id` was added, as it was given to `add_custom_color`.
fn added_at(id: &str) -> Option<u64> {
    u64::from_str_radix(id.split_once('-')?.0, 16).ok()
}

/// Removes Custom Color `id` from `doc`. Built-in colors and unknown IDs are
/// left alone. A removal wins over a concurrent use of the color as the
/// Default Highlight Color.
pub(crate) fn remove_custom_color(doc: &mut AutoCommit, id: &str) {
    for map in state::maps(doc, "custom_colors") {
        doc.delete(&map, id).expect("a map accepts deletions");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use automerge::ActorId;

    const TEAL: Rgb = Rgb {
        r: 0,
        g: 128,
        b: 128,
    };
    const BROWN: Rgb = Rgb {
        r: 150,
        g: 75,
        b: 0,
    };

    fn built_in(name: &str) -> HighlightColor {
        BuiltInColor::named(name).unwrap().into()
    }

    fn edit(existing: Option<&[u8]>, change: impl FnOnce(&mut AutoCommit)) -> Vec<u8> {
        update(existing, &ActorId::random(), change)
    }

    fn set_default_color(existing: Option<&[u8]>, id: &str) -> Vec<u8> {
        edit(existing, |doc| super::set_default_color(doc, id))
    }

    fn add_custom_color(existing: Option<&[u8]>, rgb: Rgb, now: u64) -> (Vec<u8>, HighlightColor) {
        let mut added = None;
        let bytes = edit(existing, |doc| {
            added = Some(super::add_custom_color(doc, rgb, now));
        });
        (bytes, added.expect("the update ran"))
    }

    fn remove_custom_color(existing: Option<&[u8]>, id: &str) -> Vec<u8> {
        edit(existing, |doc| super::remove_custom_color(doc, id))
    }

    /// Two devices, with actor IDs 1 and 2, start from `base`, apply `one` and
    /// `other` offline, then merge. Returns the merged document in both
    /// directions.
    fn merged(
        base: Option<&[u8]>,
        one: impl FnOnce(Option<&[u8]>) -> Vec<u8>,
        other: impl FnOnce(Option<&[u8]>) -> Vec<u8>,
    ) -> [Vec<u8>; 2] {
        let device = |actor: u8, bytes: Vec<u8>| {
            AutoCommit::load(&bytes)
                .unwrap()
                .with_actor(ActorId::from([actor; 16]))
        };
        let base = base.map(<[u8]>::to_vec).unwrap_or_else(|| {
            // Both devices share the document's creation.
            edit(None, |_| {})
        });
        let (mut a, mut b) = (device(1, one(Some(&base))), device(2, other(Some(&base))));
        let mut a2 = AutoCommit::load(&a.save()).unwrap();
        let mut b2 = AutoCommit::load(&b.save()).unwrap();
        a.merge(&mut b).unwrap();
        b2.merge(&mut a2).unwrap();
        [a.save(), b2.save()]
    }

    #[test]
    fn the_built_in_colors_start_with_yellow_and_are_distinct() {
        assert_eq!(BUILT_IN_COLORS.len(), 6);
        assert_eq!(BUILT_IN_COLORS[0].name, "Yellow");
        for (i, a) in BUILT_IN_COLORS.iter().enumerate() {
            assert!(BUILT_IN_COLORS[i + 1..].iter().all(|b| a.rgb != b.rgb));
        }
    }

    #[test]
    fn a_stored_default_color_reads_back_with_schema_version_1() {
        let green = built_in("Green");
        let bytes = set_default_color(None, &green.id);
        assert_eq!(default_color(Some(&bytes)), green);
        let doc = AutoCommit::load(&bytes).unwrap();
        assert_eq!(
            state::scalar(&doc, &ROOT, "version"),
            Some(ScalarValue::Uint(1))
        );
    }

    #[test]
    fn a_reference_to_a_color_that_does_not_exist_reads_as_yellow() {
        let bytes = set_default_color(None, "0123abcd");
        assert_eq!(default_color(Some(&bytes)), built_in("Yellow"));
    }

    #[test]
    fn a_document_without_a_default_color_reads_as_yellow() {
        assert_eq!(default_color(None), built_in("Yellow"));
        assert_eq!(
            default_color(Some(&AutoCommit::new().save())),
            built_in("Yellow")
        );
        assert_eq!(default_color(Some(b"garbage")), built_in("Yellow"));
    }

    #[test]
    fn concurrent_choices_on_two_devices_settle_on_one_of_them() {
        let base = set_default_color(None, "Yellow");
        let [one, other] = merged(
            Some(&base),
            |b| set_default_color(b, "Red"),
            |b| set_default_color(b, "Blue"),
        );

        let merged = default_color(Some(&one));
        assert!([built_in("Red"), built_in("Blue")].contains(&merged));
        assert_eq!(merged, default_color(Some(&other)));
    }

    #[test]
    fn colors_are_the_built_in_ones_then_the_custom_ones_in_the_order_added() {
        let (bytes, teal) = add_custom_color(None, TEAL, 100);
        let (bytes, brown) = add_custom_color(Some(&bytes), BROWN, 200);

        let colors = colors(Some(&bytes));

        assert_eq!(colors[..6], BUILT_IN_COLORS.map(HighlightColor::from));
        assert_eq!(colors[6..], [teal.clone(), brown]);
        assert!(teal.is_custom && teal.rgb == TEAL);
        assert!(colors[..6].iter().all(|c| !c.is_custom));
    }

    #[test]
    fn colors_added_within_one_millisecond_or_with_a_slow_clock_keep_the_order_added() {
        let (bytes, first) = add_custom_color(None, TEAL, 500);
        let (bytes, second) = add_custom_color(Some(&bytes), BROWN, 500);
        let (bytes, third) = add_custom_color(Some(&bytes), TEAL, 10);

        assert_eq!(colors(Some(&bytes))[6..], [first, second, third]);
    }

    #[test]
    fn a_missing_or_unreadable_document_has_only_the_built_in_colors() {
        assert_eq!(colors(None).len(), 6);
        assert_eq!(colors(Some(b"garbage")).len(), 6);
    }

    #[test]
    fn a_removed_custom_color_is_gone_and_the_others_stay() {
        let (bytes, teal) = add_custom_color(None, TEAL, 100);
        let (bytes, brown) = add_custom_color(Some(&bytes), BROWN, 200);

        let bytes = remove_custom_color(Some(&bytes), &teal.id);

        assert_eq!(colors(Some(&bytes))[6..], [brown]);
    }

    #[test]
    fn built_in_colors_and_unknown_ids_cannot_be_removed() {
        let (bytes, teal) = add_custom_color(None, TEAL, 100);

        let bytes = remove_custom_color(Some(&bytes), "Yellow");
        let bytes = remove_custom_color(Some(&bytes), "nope");

        assert_eq!(colors(Some(&bytes)).len(), 7);
        assert_eq!(colors(Some(&bytes))[6], teal);
    }

    #[test]
    fn a_custom_color_can_be_the_default_until_it_is_removed() {
        let (bytes, teal) = add_custom_color(None, TEAL, 100);
        let bytes = set_default_color(Some(&bytes), &teal.id);
        assert_eq!(default_color(Some(&bytes)), teal);

        let bytes = remove_custom_color(Some(&bytes), &teal.id);

        assert_eq!(default_color(Some(&bytes)), built_in("Yellow"));
    }

    #[test]
    fn custom_colors_added_on_two_devices_are_both_kept_in_the_same_order() {
        let (base, _) = add_custom_color(None, BROWN, 100);
        let [one, other] = merged(
            Some(&base),
            |b| add_custom_color(b, TEAL, 200).0,
            |b| add_custom_color(b, TEAL, 300).0,
        );

        let merged = colors(Some(&one));
        assert_eq!(merged.len(), 6 + 3);
        assert_eq!(merged, colors(Some(&other)));
    }

    #[test]
    fn custom_colors_first_added_on_two_devices_are_both_kept() {
        let [one, other] = merged(
            None,
            |b| add_custom_color(b, TEAL, 200).0,
            |b| add_custom_color(b, BROWN, 300).0,
        );

        let merged = colors(Some(&one));
        assert_eq!(
            merged[6..].iter().map(|c| c.rgb).collect::<Vec<_>>(),
            [TEAL, BROWN]
        );
        assert_eq!(merged, colors(Some(&other)));
        // Later colors go into the winning map, and nothing gets lost.
        let (bytes, _) = add_custom_color(Some(&one), TEAL, 400);
        assert_eq!(colors(Some(&bytes)).len(), 6 + 3);
    }

    #[test]
    fn removing_the_default_custom_color_on_one_device_while_another_picks_it_falls_back_to_yellow()
    {
        let (base, teal) = add_custom_color(None, TEAL, 100);
        let [one, other] = merged(
            Some(&base),
            |b| remove_custom_color(b, &teal.id),
            |b| set_default_color(b, &teal.id),
        );

        for bytes in [one, other] {
            assert_eq!(default_color(Some(&bytes)), built_in("Yellow"));
            assert_eq!(colors(Some(&bytes)).len(), 6);
        }
    }
}
