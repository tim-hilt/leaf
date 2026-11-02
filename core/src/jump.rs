//! Back and Document Search sessions (GLOSSARY.md) for one open document view,
//! whatever its Format: where the latest Jump came from, and where a session
//! started. The view passes the top of its viewport in and moves the viewport
//! itself.

use crate::progress::Place;

/// Where Back returns to, and where the Document Search session started.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct JumpHistory {
    back_place: Option<Place>,
    /// Where the latest Jump landed, or the first place seen after opening or a
    /// Document Search reveal; none until known. Moving far from it ends Back.
    landing: Option<Place>,
    /// Where the current Document Search session started; none outside one.
    search_start: Option<Place>,
}

impl JumpHistory {
    /// The top of the viewport before the latest Jump; none before any and after Back.
    pub fn back_place(&self) -> Option<Place> {
        self.back_place
    }

    /// Jump: remembers `from`, the top of the viewport, as the Back place in place of
    /// any earlier one. Returns false, changing nothing, if there is no top or `place`
    /// is already at it.
    pub fn jump(&mut self, place: Place, from: Option<Place>) -> bool {
        match from {
            Some(top) if !place.is_same_spot(top) => {
                self.back_place = Some(top);
                self.landing = Some(place);
                true
            }
            _ => false,
        }
    }

    /// Back: the Back place, which is forgotten; none without one.
    pub fn go_back(&mut self) -> Option<Place> {
        self.landing = None;
        self.back_place.take()
    }

    /// Starts a Document Search session at `top`. Until `end_search_session`, every
    /// `did_reveal` makes `top` the Back place, so the session is one Jump: Back
    /// returns to where the search started, also after an earlier Back.
    pub fn begin_search_session(&mut self, top: Option<Place>) {
        self.search_start = top;
    }

    /// Ends the session. The Back place it recorded stays.
    pub fn end_search_session(&mut self) {
        self.search_start = None;
    }

    /// A Document Search match was revealed by moving the viewport.
    pub fn did_reveal(&mut self) {
        if let Some(start) = self.search_start {
            self.back_place = Some(start);
            self.landing = None;
        }
    }

    /// The viewport moved to `top`. Back is forgotten once the reader has moved on:
    /// back at the Back place, or about a page or more from where they landed.
    /// Does nothing during a Document Search session.
    pub fn did_scroll(&mut self, top: Place) {
        let Some(back) = self.back_place else { return };
        if self.search_start.is_some() {
            return;
        }
        match self.landing {
            None => self.landing = Some(top),
            Some(landing) if top.is_same_spot(back) || top.is_far(landing) => {
                self.back_place = None;
                self.landing = None;
            }
            Some(_) => {}
        }
    }
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

    fn jumped(from: Place, to: Place) -> JumpHistory {
        let mut history = JumpHistory::default();
        history.jump(to, Some(from));
        history
    }

    #[test]
    fn back_stays_while_reading_near_the_landing() {
        let mut history = jumped(pdf(1, 700.0), pdf(10, 700.0));
        history.did_scroll(pdf(10, 100.0));
        history.did_scroll(pdf(11, 700.0));
        assert_eq!(history.back_place(), Some(pdf(1, 700.0)));
    }

    #[test]
    fn back_goes_once_reading_moves_a_page_and_more_away() {
        let mut history = jumped(pdf(1, 700.0), pdf(10, 700.0));
        history.did_scroll(pdf(12, 700.0));
        assert_eq!(history.back_place(), None);
    }

    #[test]
    fn back_goes_when_scrolling_back_to_where_the_jump_started() {
        let mut history = jumped(pdf(1, 700.0), pdf(10, 700.0));
        history.did_scroll(pdf(1, 700.0));
        assert_eq!(history.back_place(), None);
    }

    #[test]
    fn epub_back_goes_after_leaving_the_chapter_or_a_screen_of_text() {
        let start = Place::Epub {
            spine_index: 0,
            offset: 0,
        };
        let landing = Place::Epub {
            spine_index: 3,
            offset: 100,
        };
        let mut near = jumped(start, landing);
        near.did_scroll(Place::Epub {
            spine_index: 3,
            offset: 900,
        });
        assert_eq!(near.back_place(), Some(start));
        near.did_scroll(Place::Epub {
            spine_index: 3,
            offset: 5000,
        });
        assert_eq!(near.back_place(), None);

        let mut next = jumped(start, landing);
        next.did_scroll(Place::Epub {
            spine_index: 4,
            offset: 0,
        });
        assert_eq!(next.back_place(), None);
    }

    #[test]
    fn a_search_session_keeps_back_while_scrolling() {
        let mut history = JumpHistory::default();
        history.begin_search_session(Some(pdf(1, 700.0)));
        history.did_reveal();
        history.did_scroll(pdf(20, 700.0));
        assert_eq!(history.back_place(), Some(pdf(1, 700.0)));
    }

    #[test]
    fn a_jump_needs_a_top_and_a_different_place() {
        let mut history = JumpHistory::default();
        assert!(!history.jump(pdf(10, 700.0), None));
        assert!(!history.jump(pdf(10, 700.0), Some(pdf(10, 700.5))));
        assert_eq!(history.back_place(), None);
        assert!(history.jump(pdf(10, 700.0), Some(pdf(1, 700.0))));
        assert_eq!(history.back_place(), Some(pdf(1, 700.0)));
    }

    #[test]
    fn back_returns_the_back_place_once_and_forgets_it() {
        let mut history = jumped(pdf(1, 700.0), pdf(10, 700.0));
        assert_eq!(history.go_back(), Some(pdf(1, 700.0)));
        assert_eq!(history.back_place(), None);
        assert_eq!(history.go_back(), None);
    }

    #[test]
    fn a_second_jump_replaces_the_back_place() {
        let mut history = jumped(pdf(1, 700.0), pdf(10, 700.0));
        history.jump(pdf(20, 700.0), Some(pdf(12, 700.0)));
        assert_eq!(history.back_place(), Some(pdf(12, 700.0)));
    }

    #[test]
    fn a_search_session_leaves_its_back_place_after_it_ends() {
        let mut history = JumpHistory::default();
        history.begin_search_session(Some(pdf(1, 700.0)));
        history.did_reveal();
        history.end_search_session();
        history.did_scroll(pdf(20, 700.0));
        assert_eq!(history.back_place(), Some(pdf(1, 700.0)));
    }
}
