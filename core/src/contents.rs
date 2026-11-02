//! The Table of Contents (GLOSSARY.md): the Chapters and Sections of a Document
//! in reading order, and where a Place is in them. A client gives the entries
//! of its Format; the core answers in terms of them.

use crate::progress::Place;

/// A Chapter or Section as its Format gives it, for `TableOfContents::new`.
#[derive(Debug, Clone, PartialEq)]
pub struct ContentsEntry {
    pub title: String,
    /// The printed page number of the entry's Place, if the Format has them.
    pub page_label: Option<String>,
    /// Where the entry points. None for one that points nowhere: it is listed,
    /// but it is never current.
    pub place: Option<Place>,
    /// The Sections nested under it.
    pub sections: Vec<ContentsEntry>,
}

/// A Chapter or Section of a `TableOfContents`.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// Unique within the Table of Contents: its number in reading order, from 0.
    pub id: u32,
    pub title: String,
    pub page_label: Option<String>,
    pub place: Option<Place>,
    /// The Sections nested under it. Empty in a `Position`.
    pub sections: Vec<Entry>,
}

/// Where a Place is in the Table of Contents.
#[derive(Debug, Clone, PartialEq)]
pub struct Position {
    /// The deepest Chapter or Section starting at or before the Place.
    pub current: Entry,
    /// The Chapters and Sections that contain `current`, outermost first.
    pub containing: Vec<Entry>,
}

/// The entries of a Document's Table of Contents, indexed for `position`.
#[derive(Debug)]
pub struct TableOfContents {
    /// Every entry, by id.
    nodes: Vec<Node>,
    /// The ids of the Chapters.
    chapters: Vec<usize>,
    /// The entries with a place, in reading order, ties by id.
    index: Vec<(Place, usize)>,
}

#[derive(Debug)]
struct Node {
    /// The entry, without its Sections.
    entry: Entry,
    parent: Option<usize>,
    /// The ids of its Sections.
    sections: Vec<usize>,
}

impl TableOfContents {
    /// The Table of Contents of `entries`, the Chapters with their Sections.
    pub fn new(entries: Vec<ContentsEntry>) -> Self {
        let mut nodes = Vec::new();
        let chapters = add(&mut nodes, entries, None);
        let mut index: Vec<(Place, usize)> = nodes
            .iter()
            .enumerate()
            .filter_map(|(id, node)| Some((node.entry.place?, id)))
            .collect();
        index.sort_by(|(place, id), (other, other_id)| {
            place.cmp_reading(*other).then(id.cmp(other_id))
        });
        Self {
            nodes,
            chapters,
            index,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.chapters.is_empty()
    }

    /// The Chapters, with their Sections nested, in reading order.
    pub fn chapters(&self) -> Vec<Entry> {
        self.chapters.iter().map(|&id| self.tree(id)).collect()
    }

    /// Where `place` is. None before the first entry with a place.
    pub fn position(&self, place: Place) -> Option<Position> {
        let current = self.current(place)?;
        let mut containing = Vec::new();
        let mut parent = self.nodes[current].parent;
        while let Some(id) = parent {
            containing.push(self.nodes[id].entry.clone());
            parent = self.nodes[id].parent;
        }
        containing.reverse();
        Some(Position {
            current: self.nodes[current].entry.clone(),
            containing,
        })
    }

    /// The title of the Chapter `place` is in, as Back names it; none before the
    /// first entry with a place.
    pub fn chapter_title(&self, place: Place) -> Option<&str> {
        let mut id = self.current(place)?;
        while let Some(parent) = self.nodes[id].parent {
            id = parent;
        }
        Some(&self.nodes[id].entry.title)
    }

    /// The id of the deepest entry starting at or before `place`, which is the
    /// last of those in reading order. Entries within a point of it start at the
    /// same spot, and the one listed last among them wins.
    fn current(&self, place: Place) -> Option<usize> {
        let reached = self
            .index
            .partition_point(|(start, _)| start.is_at_or_before(place));
        let (&(last, mut current), earlier) = self.index[..reached].split_last()?;
        for &(start, id) in earlier.iter().rev() {
            if !start.is_same_spot(last) {
                break;
            }
            current = current.max(id);
        }
        Some(current)
    }

    /// The entry `id` with its Sections, nested.
    fn tree(&self, id: usize) -> Entry {
        let node = &self.nodes[id];
        Entry {
            sections: node.sections.iter().map(|&s| self.tree(s)).collect(),
            ..node.entry.clone()
        }
    }
}

/// Adds `entries` and their Sections to `nodes`, in listing order, under `parent`.
/// Returns the ids of `entries`.
fn add(nodes: &mut Vec<Node>, entries: Vec<ContentsEntry>, parent: Option<usize>) -> Vec<usize> {
    entries
        .into_iter()
        .map(|entry| {
            let id = nodes.len();
            nodes.push(Node {
                entry: Entry {
                    id: id as u32,
                    title: entry.title,
                    page_label: entry.page_label,
                    place: entry.place,
                    sections: Vec::new(),
                },
                parent,
                sections: Vec::new(),
            });
            nodes[id].sections = add(nodes, entry.sections, Some(id));
            id
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pdf(page_index: u32, y: f64) -> Place {
        Place::Pdf {
            page_index,
            x: 0.0,
            y,
        }
    }

    fn epub(spine_index: u32, offset: u64) -> Place {
        Place::Epub {
            spine_index,
            offset,
        }
    }

    /// An entry at `place`.
    fn entry(title: &str, place: Option<Place>, sections: Vec<ContentsEntry>) -> ContentsEntry {
        ContentsEntry {
            title: title.to_owned(),
            page_label: None,
            place,
            sections,
        }
    }

    /// An entry at the point `y` of page `page_index`.
    fn at(title: &str, page_index: u32, y: f64, sections: Vec<ContentsEntry>) -> ContentsEntry {
        entry(title, Some(pdf(page_index, y)), sections)
    }

    /// Part One, with Setup and Usage (which holds Advanced), then Part Two.
    fn outline() -> Vec<ContentsEntry> {
        vec![
            at(
                "Part One",
                0,
                792.0,
                vec![
                    at("Setup", 1, 500.0, vec![]),
                    at("Usage", 2, 792.0, vec![at("Advanced", 3, 300.0, vec![])]),
                ],
            ),
            at("Part Two", 4, 792.0, vec![]),
        ]
    }

    /// The titles of the current entry and of the entries containing it.
    fn locate(toc: &TableOfContents, place: Place) -> Option<(String, Vec<String>)> {
        toc.position(place).map(|found| {
            (
                found.current.title,
                found.containing.into_iter().map(|e| e.title).collect(),
            )
        })
    }

    fn current_at(toc: &TableOfContents, page_index: u32, y: f64) -> Option<String> {
        toc.position(pdf(page_index, y))
            .map(|found| found.current.title)
    }

    /// The ids and titles of `entries` and their Sections, in reading order.
    fn preorder(entries: &[Entry]) -> Vec<(u32, &str)> {
        let mut listed = Vec::new();
        for entry in entries {
            listed.push((entry.id, entry.title.as_str()));
            listed.extend(preorder(&entry.sections));
        }
        listed
    }

    #[test]
    fn chapters_list_their_sections_numbered_in_reading_order() {
        let toc = TableOfContents::new(outline());

        assert_eq!(
            preorder(&toc.chapters()),
            [
                (0, "Part One"),
                (1, "Setup"),
                (2, "Usage"),
                (3, "Advanced"),
                (4, "Part Two"),
            ]
        );
    }

    #[test]
    fn entries_keep_their_places_and_page_labels() {
        let labelled = ContentsEntry {
            page_label: Some("ii".to_owned()),
            ..at("Preface", 1, 700.0, vec![])
        };
        let chapter = TableOfContents::new(vec![labelled]).chapters().remove(0);

        assert_eq!(chapter.page_label.as_deref(), Some("ii"));
        assert_eq!(chapter.place, Some(pdf(1, 700.0)));
        assert!(chapter.sections.is_empty());
    }

    #[test]
    fn current_is_the_deepest_entry_at_or_before_the_place() {
        let toc = TableOfContents::new(outline());

        assert_eq!(current_at(&toc, 1, 500.0).as_deref(), Some("Setup")); // exactly at its target
        assert_eq!(current_at(&toc, 1, 100.0).as_deref(), Some("Setup")); // further down the page
        assert_eq!(current_at(&toc, 2, 792.0).as_deref(), Some("Usage"));
        assert_eq!(current_at(&toc, 4, 1.0).as_deref(), Some("Part Two"));
    }

    #[test]
    fn an_entry_below_the_place_on_its_page_is_not_yet_current() {
        let toc = TableOfContents::new(outline());

        assert_eq!(current_at(&toc, 1, 502.0).as_deref(), Some("Part One"));
    }

    #[test]
    fn a_hair_below_an_entrys_target_still_counts_as_at_it() {
        let toc = TableOfContents::new(outline());

        assert_eq!(current_at(&toc, 1, 500.4).as_deref(), Some("Setup"));
    }

    #[test]
    fn there_is_no_current_entry_before_the_first_one() {
        let toc = TableOfContents::new(vec![at("Chapter", 2, 400.0, vec![])]);

        assert_eq!(current_at(&toc, 1, 792.0), None);
        assert_eq!(current_at(&toc, 2, 402.0), None);
    }

    #[test]
    fn current_can_be_inside_a_nested_section() {
        let toc = TableOfContents::new(outline());

        assert_eq!(
            locate(&toc, pdf(3, 10.0)),
            Some((
                "Advanced".to_owned(),
                vec!["Part One".to_owned(), "Usage".to_owned()]
            ))
        );
    }

    #[test]
    fn a_chapter_is_contained_in_nothing() {
        let toc = TableOfContents::new(outline());

        assert_eq!(
            locate(&toc, pdf(4, 0.0)).map(|(_, containing)| containing),
            Some(vec![])
        );
    }

    #[test]
    fn entries_without_a_place_are_listed_but_never_current() {
        let toc = TableOfContents::new(vec![at(
            "One",
            0,
            792.0,
            vec![
                at("Setup", 1, 500.0, vec![]),
                entry("Dangling", None, vec![]),
            ],
        )]);

        assert_eq!(
            preorder(&toc.chapters()),
            [(0, "One"), (1, "Setup"), (2, "Dangling")]
        );
        assert_eq!(current_at(&toc, 1, 100.0).as_deref(), Some("Setup"));
        assert_eq!(toc.chapters()[0].sections[1].place, None);
    }

    #[test]
    fn a_later_entry_at_the_same_place_wins_and_the_deepest_one_at_it() {
        let toc = TableOfContents::new(vec![at(
            "Chapter",
            1,
            792.0,
            vec![at("Opening Section", 1, 792.0, vec![])],
        )]);

        assert_eq!(
            locate(&toc, pdf(1, 792.0)),
            Some(("Opening Section".to_owned(), vec!["Chapter".to_owned()]))
        );
    }

    #[test]
    fn a_section_a_hair_above_its_chapter_is_current_once_both_are_reached() {
        let toc = TableOfContents::new(vec![at(
            "Chapter",
            0,
            690.0,
            vec![at("Section", 0, 690.8, vec![])],
        )]);

        assert_eq!(current_at(&toc, 0, 689.5).as_deref(), Some("Section"));
    }

    #[test]
    fn epub_places_are_found_in_entries() {
        let toc = TableOfContents::new(vec![
            ContentsEntry {
                sections: vec![entry("Opening", Some(epub(0, 120)), vec![])],
                ..entry("One", Some(epub(0, 0)), vec![])
            },
            entry("Two", Some(epub(1, 0)), vec![]),
        ]);

        let current = |place| toc.position(place).map(|found| found.current.title);
        assert_eq!(current(epub(0, 50)).as_deref(), Some("One"));
        assert_eq!(current(epub(0, 120)).as_deref(), Some("Opening"));
        assert_eq!(current(epub(1, 5)).as_deref(), Some("Two"));
        assert_eq!(current(pdf(0, 0.0)), None);
    }

    #[test]
    fn back_names_the_chapter_a_place_is_in() {
        let toc = TableOfContents::new(vec![
            ContentsEntry {
                sections: vec![entry("Opening", Some(epub(0, 20)), vec![])],
                ..entry("One", Some(epub(0, 10)), vec![])
            },
            entry("Two", Some(epub(0, 100)), vec![]),
        ]);

        assert_eq!(toc.chapter_title(epub(0, 15)), Some("One"));
        // In a Section: still named by its Chapter, as the glossary has it.
        assert_eq!(toc.chapter_title(epub(0, 20)), Some("One"));
        assert_eq!(toc.chapter_title(epub(0, 500)), Some("Two"));
        // Before the first entry.
        assert_eq!(toc.chapter_title(epub(0, 5)), None);
    }

    #[test]
    fn a_table_of_contents_without_chapters_is_empty() {
        assert!(TableOfContents::new(vec![]).is_empty());
        assert!(!TableOfContents::new(outline()).is_empty());
    }

    #[test]
    fn a_table_of_contents_of_entries_without_places_finds_nothing() {
        let toc = TableOfContents::new(vec![entry("Dangling", None, vec![])]);

        assert!(!toc.is_empty());
        assert_eq!(current_at(&toc, 0, 792.0), None);
        assert_eq!(toc.chapter_title(pdf(0, 792.0)), None);
    }

    /// The answer of a walk over `entries` in listing order, as clients found it
    /// before the index: the last entry whose place is no later than `place`,
    /// with the entries containing it.
    fn walk(entries: &[ContentsEntry], place: Place) -> Option<(String, Vec<String>)> {
        type Best<'a> = Option<(&'a ContentsEntry, Vec<&'a ContentsEntry>)>;
        fn search<'a>(
            entries: &'a [ContentsEntry],
            place: Place,
            containing: &mut Vec<&'a ContentsEntry>,
            best: &mut Best<'a>,
        ) {
            for entry in entries {
                if let Some(start) = entry.place.filter(|start| start.is_at_or_before(place)) {
                    let is_later = best.as_ref().is_none_or(|(found, _)| {
                        found.place.is_none_or(|at| start.is_at_or_after(at))
                    });
                    if is_later {
                        *best = Some((entry, containing.clone()));
                    }
                }
                containing.push(entry);
                search(&entry.sections, place, containing, best);
                containing.pop();
            }
        }
        let mut best = None;
        search(entries, place, &mut Vec::new(), &mut best);
        best.map(|(current, containing)| {
            (
                current.title.clone(),
                containing.iter().map(|e| e.title.clone()).collect(),
            )
        })
    }

    #[test]
    fn the_index_answers_as_a_walk_over_the_entries_does() {
        // Entries a point or less apart on one page, in both listing orders, as
        // real outlines have them.
        let entries = vec![
            at(
                "One",
                0,
                792.0,
                vec![at("Setup", 0, 600.0, vec![]), at("Hair", 0, 600.8, vec![])],
            ),
            at(
                "Two",
                1,
                500.0,
                vec![at("Deep", 1, 499.5, vec![at("Deeper", 1, 300.0, vec![])])],
            ),
            at("Three", 2, 100.8, vec![at("Four", 2, 100.0, vec![])]),
        ];
        let toc = TableOfContents::new(entries.clone());

        for page_index in 0..3 {
            for step in 0..=3600 {
                let place = pdf(page_index, f64::from(step) * 0.25);
                let indexed = toc.position(place).map(|found| {
                    (
                        found.current.title,
                        found
                            .containing
                            .into_iter()
                            .map(|e| e.title)
                            .collect::<Vec<_>>(),
                    )
                });
                assert_eq!(indexed, walk(&entries, place), "{place:?}");
            }
        }
    }
}
