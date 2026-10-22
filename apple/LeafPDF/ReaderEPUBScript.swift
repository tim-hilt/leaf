import CoreGraphics
import LeafCore

/// The script `ReaderEPUBView` injects into the page that stacks the chapter frames.
///
/// It owns the conversion between the DOM and the core's positions (ADR-0022): the
/// text of a chapter is its body's text nodes in document order, and a position is
/// a chapter index and a UTF-16 offset into that text. Change it only together with
/// the core's `epub::text_of`; `ReaderEPUBViewTests` cross-checks the two.
///
/// The page stacks one frame per chapter, but only the chapters near the viewport are
/// loaded: those within a viewport above and below it. A frame beyond twice that distance
/// is released, so a long book needs memory for what is on screen, and keeps its last
/// measured height. A frame that was never loaded has an estimated height, from the length
/// of its text (the `lengths` the core gives) at the average height per character of the
/// loaded chapters; the estimates scale with the text size and the page's width, and
/// improve as chapters are measured. When a frame above the viewport changes height, the
/// page scrolls by the difference, so what is on screen doesn't move. Going to a place
/// loads its chapter first and then scrolls to the exact line.
///
/// Everything the page draws over the text is page-level state, applied to a frame as it
/// loads: Highlights, page Notes, Document Search marks, the text size and the Page Style.
/// Hit-testing and selections work in loaded chapters only.
///
/// It posts to the `reader` message handler: "opened" once the opening chapter is laid out
/// at its place (the others load on from there), "tap" for a tap on text that isn't a link,
/// and `[chapter, offset]` for the position at the top of the viewport: once before
/// "opened", then as the page scrolls. The top of the viewport is always in a loaded
/// chapter, and the position is only reported while it is. Tests and later features call
/// `window.leaf` in the same content world.
///
/// `leaf.scrollToPosition` goes to a position and `leaf.reveal` scrolls a match into view
/// unless it is; both load the chapter if need be and return a promise.
/// `leaf.setFindMarks` marks Document Search matches as CSS highlights, the current one in
/// another color.
///
/// `leaf.setHighlights` draws Highlights as CSS highlights over their words, one color each,
/// so they follow the text when it reflows, and puts a Note icon at the end of those with a
/// Note, in a layer above the chapters that the text size doesn't scale. `leaf.takeSelection`
/// hands over the selection as `[chapter, offset, chapter, offset, text]` and clears it. A
/// click on a Highlight or its Note icon posts `{ highlight, x, y }`, the point in the view's
/// coordinates; `{ selection }` is posted when the selection appears or goes.
///
/// `leaf.setPageNotes` puts the icons of page Notes in the same layer, in the left margin at
/// the line of their spot, so they follow the text when it reflows; a click on one posts
/// `{ pageNote, x, y }`. `leaf.emptySpot` gives the position for a new Note at a point of the
/// view, or null where there is text, a link, a Highlight or an icon; `leaf.notePoint` is where
/// the icon of a Note at a position is. A right-click posts `{ contextSpot }`, the position
/// `emptySpot` gives there.
///
/// The text size is a CSS `zoom` on each chapter's body, so the book's own sizes scale
/// with it while the side margin on the page stays as it is. `leaf.setTextSize` reflows the
/// loaded chapters and keeps the position at the top of the viewport.
///
/// Raster images never grow past their pixels (`keepSharp`).
///
/// Light Pages leave the book's colors alone. Dark Pages override the text and background
/// of every chapter with the Page Colors, never touching images, and give the page behind
/// the chapters the paper. `leaf.setAppearance` switches between them in place: colors
/// don't move the text. The chapters stay hidden until the book is open, so none shows
/// in the book's colors first.
enum ReaderEPUBScript {
    static let channel = "reader"

    /// `appearance` as JavaScript for `leaf.setAppearance`: the Page Colors as CSS
    /// colors, or null for Light Pages.
    static func literal(of appearance: PageAppearance) -> String {
        guard case .dark(let colors) = appearance else { return "null" }
        func css(_ color: RGB) -> String {
            let byte = { (value: Double) in Int((value * 255).rounded()) }
            return "rgb(\(byte(color.r)), \(byte(color.g)), \(byte(color.b)))"
        }
        return "{ paper: '\(css(colors.paper))', ink: '\(css(colors.ink))' }"
    }

    /// The script for the chapters whose texts are `lengths` long (UTF-16 units) at `textSize`
    /// (`TextSize`) in `appearance`; it opens at the position `start` (chapter index, offset).
    static func source(
        lengths: [UInt64], start: (chapter: Int, offset: Int)?, textSize: CGFloat, appearance: PageAppearance
    ) -> String {
        let start = start.map { "[\($0.chapter), \($0.offset)]" } ?? "null"
        return """
            (() => {
              // No text autosizing: on iOS it cancels most of the zoom, so the text size wouldn't change.
              const style = ':where(html) { padding: 0 24px; -webkit-text-size-adjust: none } '
                + ':where(img, svg, video) { max-width: 100% }';
              const lengths = [\(lengths.map(String.init).joined(separator: ","))];
              const count = lengths.length;
              let textSize = \(textSize);
              let appearance = \(literal(of: appearance));
              const page = document.createElement('style');
              document.documentElement.append(page);
              const post = message => window.webkit.messageHandlers.\(channel).postMessage(message);

              // The chapters' frames, in order, and for each: whether its chapter is 'empty' (no
              // source), 'loading' or 'loaded', its height (measured, or estimated if never
              // loaded) and whether that was measured.
              let frames = [];
              const status = [], heights = [], measured = [];
              const sheets = new Map(), watchers = new Map(), waiting = new Map();
              const loaded = () => frames.flatMap((frame, i) => status[i] === 'loaded' ? [i] : []);
              // The chapters are loaded within this many viewports of the viewport, and released
              // beyond that many.
              const loadMargin = 1, keepMargin = 2;
              const viewport = () => Math.max(window.innerHeight, 600);

              // The text of a chapter: its text nodes, and the offset each starts at.
              const texts = new WeakMap();
              const textOf = doc => {
                if (!texts.has(doc)) {
                  const nodes = [], starts = [];
                  let length = 0;
                  const walker = doc.createTreeWalker(
                    doc.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_CDATA_SECTION);
                  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                    nodes.push(node);
                    starts.push(length);
                    length += node.length;
                  }
                  texts.set(doc, { nodes, starts, length });
                }
                return texts.get(doc);
              };

              // The last box of the characters from..to of a text node; null if it has none.
              const lastRect = (node, from, to) => {
                const range = node.ownerDocument.createRange();
                range.setStart(node, from);
                range.setEnd(node, to);
                const rects = range.getClientRects();
                return rects.length ? rects[rects.length - 1] : null;
              };
              const lastRectOf = node => lastRect(node, 0, node.length);

              // The bottom of the first node from k on that has a box; Infinity if none.
              const bottomFrom = (nodes, k) => {
                for (; k < nodes.length; k++) {
                  const rect = lastRectOf(nodes[k]);
                  if (rect) return rect.bottom;
                }
                return Infinity;
              };

              // The position at the top of the viewport: the first character whose line
              // reaches below it. Frames have the height of their content, so a frame's
              // top is its distance to the top of the viewport. Null while that chapter isn't loaded.
              const position = () => {
                const index = frames.findIndex(frame => frame.getBoundingClientRect().bottom > 1);
                if (index < 0) return status[count - 1] === 'loaded' ? [count - 1, 0] : null;
                if (status[index] !== 'loaded') return null;
                const y = -frames[index].getBoundingClientRect().top;
                if (y <= 0) return [index, 0];
                const { nodes, starts, length } = textOf(frames[index].contentDocument);
                let low = 0, high = nodes.length;
                while (low < high) {
                  const middle = (low + high) >> 1;
                  if (bottomFrom(nodes, middle) > y + 1) high = middle; else low = middle + 1;
                }
                while (low < nodes.length && !lastRectOf(nodes[low])) low++;
                if (low === nodes.length) return [index, length];
                let from = 1, to = nodes[low].length;
                while (from < to) {
                  const middle = (from + to) >> 1;
                  const rect = lastRect(nodes[low], 0, middle);
                  if (rect && rect.bottom > y + 1) to = middle; else from = middle + 1;
                }
                return [index, starts[low] + from - 1];
              };
              const report = () => {
                const place = position();
                if (place) post(place);
              };

              // The index of the text node holding the character at offset: the last one
              // starting at or before it. At a boundary between nodes, `end` takes the node
              // that ends there instead, for the end of a range.
              const nodeIndex = ({ nodes, starts }, offset, end) => {
                let low = 0, high = nodes.length;
                while (low < high) {
                  const middle = (low + high) >> 1;
                  if (end ? starts[middle] < offset : starts[middle] <= offset) low = middle + 1; else high = middle;
                }
                return Math.max(low - 1, 0);
              };

              // The box of the line holding the character at offset, in the frame's coordinates.
              const lineBox = (frame, offset) => {
                const text = textOf(frame.contentDocument);
                const k = nodeIndex(text, offset, false);
                const node = text.nodes[k];
                if (!node) return { top: 0, height: 0 };
                const character = Math.min(offset - text.starts[k], Math.max(node.length - 1, 0));
                return lastRect(node, 0, character + 1) || node.parentElement.getBoundingClientRect();
              };
              const lineTop = (frame, offset) => lineBox(frame, offset).top;

              // The DOM range of the length characters at offset in the frame; null if it has no text.
              const rangeOf = (frame, offset, length) => {
                const doc = frame.contentDocument;
                const text = textOf(doc);
                const from = nodeIndex(text, offset, false), to = nodeIndex(text, offset + length, true);
                if (!text.nodes[from] || !text.nodes[to]) return null;
                const range = doc.createRange();
                range.setStart(text.nodes[from], Math.min(offset - text.starts[from], text.nodes[from].length));
                range.setEnd(text.nodes[to], Math.min(offset + length - text.starts[to], text.nodes[to].length));
                return range;
              };

              // The offset in the text of the point (container, offset) of the DOM: of a text
              // node's character, or of the first character at or after an element's point.
              const pointOffset = ({ nodes, starts, length }, container, offset) => {
                const k = nodes.indexOf(container);
                if (k >= 0) return starts[k] + offset;
                const child = container.childNodes[offset];
                const next = nodes.findIndex(node => {
                  const where = (child || container).compareDocumentPosition(node);
                  return child ? node === child || (where & Node.DOCUMENT_POSITION_FOLLOWING)
                    : (where & Node.DOCUMENT_POSITION_FOLLOWING) && !(where & Node.DOCUMENT_POSITION_CONTAINED_BY);
                });
                return next < 0 ? length : starts[next];
              };

              // The selection, as [chapter, start, chapter, end, text], and clears it; null
              // if no loaded chapter has one.
              const takeSelection = () => {
                for (const index of loaded()) {
                  const selection = frames[index].contentWindow.getSelection();
                  if (!selection || selection.isCollapsed || !selection.rangeCount) continue;
                  const range = selection.getRangeAt(0), text = textOf(frames[index].contentDocument);
                  const start = pointOffset(text, range.startContainer, range.startOffset);
                  const end = pointOffset(text, range.endContainer, range.endOffset);
                  if (end <= start) continue;
                  selection.removeAllRanges();
                  return [index, start, index, end, text.nodes.map(node => node.data).join('').slice(start, end)];
                }
                return null;
              };

              // Highlights: { id, color: 'rrggbb', note, start: [chapter, offset], end: [chapter, offset] },
              // oldest first, with the DOM ranges of their words in each loaded chapter.
              let placed = [], highlightNames = new Set(), highlightCss = '';
              const rgb = color => [0, 2, 4].map(i => parseInt(color.substr(i, 2), 16)).join(', ');

              // Finds the words of the Highlights in loaded chapter `index` and draws them.
              const placeHighlights = index => {
                const frame = frames[index], { CSS, Highlight } = frame.contentWindow;
                const length = textOf(frame.contentDocument).length;
                const groups = new Map();
                for (const highlight of placed) {
                  highlight.segments.delete(index);
                  if (index < highlight.start[0] || index > highlight.end[0]) continue;
                  const from = index === highlight.start[0] ? highlight.start[1] : 0;
                  const to = index === highlight.end[0] ? highlight.end[1] : length;
                  const range = to > from ? rangeOf(frame, from, to - from) : null;
                  if (!range) continue;
                  highlight.segments.set(index, range);
                  const name = 'leaf-hl-' + highlight.color;
                  if (!groups.has(name)) groups.set(name, new Highlight());
                  groups.get(name).add(range);
                }
                groups.forEach((group, name) => CSS.highlights.set(name, group));
              };

              // The newest Highlight with a box at (x, y) in chapter index; null if none.
              const highlightAt = (index, x, y) => {
                for (let i = placed.length - 1; i >= 0; i--) {
                  const range = placed[i].segments.get(index);
                  if (!range) continue;
                  for (const box of range.getClientRects()) {
                    if (x >= box.left && x <= box.right && y >= box.top && y <= box.bottom) return placed[i];
                  }
                }
                return null;
              };

              // Page Notes: { id, color: 'rrggbb', at: [chapter, offset] }.
              let pageNotes = [];
              const iconSize = 18;

              // Where the icon of a page Note is, in the viewport: in the left margin, centered on
              // the line of its spot. Null if the chapter isn't loaded.
              const pageNoteSpot = ({ at: [index, offset] }) => {
                if (status[index] !== 'loaded') return null;
                const line = lineBox(frames[index], offset);
                return { left: 3, top: frames[index].getBoundingClientRect().top + line.top + (line.height - iconSize) / 2 };
              };

              // The Note icons sit above the chapters, in the page's own coordinates.
              const notes = document.createElement('div');
              notes.style.cssText = 'position: absolute; left: 0; top: 0; width: 0; height: 0; z-index: 1';
              document.documentElement.append(notes);
              notes.addEventListener('click', click => {
                const icon = click.target.closest('.leaf-note');
                if (!icon) return;
                const box = icon.getBoundingClientRect();
                post({
                  [icon.dataset.page ? 'pageNote' : 'highlight']: icon.dataset.id,
                  x: box.left + box.width / 2, y: box.top + box.height / 2,
                });
              });

              // Puts each Note icon at the end of its Highlight, centered on its top-right corner.
              const layOutNotes = () => {
                notes.replaceChildren();
                for (const highlight of placed) {
                  // The chapter of its last word: the one before, if it ends right at the start of the next.
                  const last = highlight.end[1] > 0 || highlight.end[0] === highlight.start[0]
                    ? highlight.end[0] : highlight.end[0] - 1;
                  const range = highlight.note && highlight.segments.get(last);
                  const boxes = range ? range.getClientRects() : [];
                  if (!boxes.length) continue;
                  const box = boxes[boxes.length - 1], frame = frames[last].getBoundingClientRect();
                  const icon = document.createElement('div');
                  icon.className = 'leaf-note';
                  icon.dataset.id = highlight.id;
                  icon.style.backgroundColor = 'rgb(' + rgb(highlight.color) + ')';
                  icon.style.left = (window.scrollX + frame.left + box.right - 9) + 'px';
                  icon.style.top = (window.scrollY + frame.top + box.top - 9) + 'px';
                  notes.append(icon);
                }
                for (const note of pageNotes) {
                  const spot = pageNoteSpot(note);
                  if (!spot) continue;
                  const icon = document.createElement('div');
                  icon.className = 'leaf-note';
                  icon.dataset.id = note.id;
                  icon.dataset.page = '1';
                  icon.style.backgroundColor = 'rgb(' + rgb(note.color) + ')';
                  icon.style.left = (window.scrollX + spot.left) + 'px';
                  icon.style.top = (window.scrollY + spot.top) + 'px';
                  notes.append(icon);
                }
              };

              const setPageNotes = list => {
                pageNotes = list;
                layOutNotes();
              };

              // Where the icon of a page Note at [chapter, offset] is centered, in the viewport.
              const notePoint = at => {
                const spot = pageNoteSpot({ at });
                return spot && [spot.left + iconSize / 2, spot.top + iconSize / 2];
              };

              // Where a Note can be added at (x, y) in the viewport: [chapter, offset] of the nearest
              // character. Null unless the spot is empty: no text, link, Highlight or Note icon, the
              // margins and the space around the text being empty.
              const emptySpot = (x, y) => {
                const hit = document.elementFromPoint(x, y);
                if (hit && hit.closest('.leaf-note')) return null;
                const index = frames.findIndex(frame => {
                  const box = frame.getBoundingClientRect();
                  return y >= box.top && y < box.bottom;
                });
                if (index < 0 || status[index] !== 'loaded') return null;
                const frame = frames[index], box = frame.getBoundingClientRect(), doc = frame.contentDocument;
                const fx = x - box.left, fy = y - box.top, inside = fx >= 0 && fx < box.width;
                if (highlightAt(index, fx, fy)) return null;
                const element = inside && doc.elementFromPoint(fx, fy);
                if (element && element.closest('a[href]')) return null;
                const caret = doc.caretRangeFromPoint(Math.min(Math.max(fx, 0), box.width - 1), fy);
                if (!caret) return null;
                const text = textOf(doc);
                const offset = pointOffset(text, caret.startContainer, caret.startOffset);
                for (const from of inside ? [offset - 1, offset] : []) {
                  const range = from >= 0 && from < text.length ? rangeOf(frame, from, 1) : null;
                  for (const rect of range ? range.getClientRects() : []) {
                    if (fx >= rect.left && fx <= rect.right && fy >= rect.top && fy <= rect.bottom) return null;
                  }
                }
                return [index, offset];
              };

              const setHighlights = list => {
                const all = loaded();
                all.forEach(index => highlightNames.forEach(name => frames[index].contentWindow.CSS.highlights.delete(name)));
                highlightNames = new Set(list.map(highlight => 'leaf-hl-' + highlight.color));
                placed = list.map(highlight => ({ ...highlight, segments: new Map() }));
                all.forEach(placeHighlights);
                highlightCss = [...highlightNames].map(name =>
                  ' ::highlight(' + name + ') { background-color: rgba(' + rgb(name.slice(-6)) + ', 0.55) }').join('');
                render();
                layOutNotes();
              };

              // The Document Search matches by chapter, as [offset, length, number], and the number of
              // the current one.
              let found = new Map(), current = -1;

              // Marks the matches in loaded chapter `index`: the current one apart. The marks are CSS
              // highlights, so the text stays as it is.
              const markMatches = index => {
                const { CSS, Highlight } = frames[index].contentWindow;
                CSS.highlights.delete('leaf-find');
                CSS.highlights.delete('leaf-find-current');
                const others = new Highlight(), chosen = new Highlight();
                for (const [offset, length, number] of found.get(index) || []) {
                  const range = rangeOf(frames[index], offset, length);
                  if (range) (number === current ? chosen : others).add(range);
                }
                if (others.size) CSS.highlights.set('leaf-find', others);
                if (chosen.size) CSS.highlights.set('leaf-find-current', chosen);
              };

              // Marks the matches [[index, offset, length], ...] in the text, the one at `current` apart.
              const setFindMarks = (matches, chosen) => {
                found = new Map();
                matches.forEach(([index, offset, length], number) => {
                  if (!found.has(index)) found.set(index, []);
                  found.get(index).push([offset, length, number]);
                });
                current = chosen;
                loaded().forEach(markMatches);
              };

              // Where each frame starts, from the heights.
              const tops = () => {
                let y = 0;
                return heights.map(height => { const top = y; y += height; return top; });
              };

              // Sets the heights [[index, height], ...] of frames. Frames wholly above the viewport
              // scroll it by the difference, so what is on screen stays where it is.
              const setHeights = (changes, keepPlace = true) => {
                const y = window.scrollY, edges = tops();
                let shift = 0, changed = false;
                for (const [i, height] of changes) {
                  if (Math.abs(height - heights[i]) < 1) continue;
                  if (keepPlace && edges[i] + heights[i] <= y) shift += height - heights[i];
                  heights[i] = height;
                  frames[i].style.height = height + 'px';
                  changed = true;
                }
                if (shift) window.scrollBy(0, shift);
                if (changed) scheduleNotes();
              };
              const fit = i => setHeights([[i, frames[i].contentDocument.documentElement.offsetHeight]]);

              // The height per character of text: the average of the loaded chapters, or a guess
              // from the text size and the page's width before there is one.
              const rate = () => {
                let height = 0, units = 0;
                loaded().forEach(i => { if (lengths[i] > 0) { height += heights[i]; units += lengths[i]; } });
                return units ? height / units : 150 * textSize * textSize / Math.max(window.innerWidth - 48, 100);
              };
              const estimate = (i, perUnit) => Math.max(Math.round(lengths[i] * perUnit), 200);

              // Estimates the heights of the chapters never loaded again, as chapters are measured.
              const reestimate = () => {
                const perUnit = rate();
                setHeights(frames.flatMap((frame, i) => status[i] === 'empty' && !measured[i] ? [[i, estimate(i, perUnit)]] : []));
              };

              const settle = i => {
                (waiting.get(i) || []).forEach(resolve => resolve());
                waiting.delete(i);
              };
              const whenLoaded = i => status[i] === 'loaded' ? Promise.resolve()
                : new Promise(resolve => waiting.set(i, [...(waiting.get(i) || []), resolve]));

              // Gives chapter i its source, to load.
              const load = i => {
                status[i] = 'loading';
                frames[i].src = frames[i].dataset.src;
              };

              // Takes the source away from chapter i, keeping its height; a selection in it stays.
              const release = i => {
                if (status[i] === 'loaded' && !frames[i].contentDocument.getSelection().isCollapsed) return;
                const fresh = document.createElement('iframe');
                fresh.scrolling = 'no';
                fresh.dataset.src = frames[i].dataset.src;
                fresh.style.height = heights[i] + 'px';
                frames[i].replaceWith(fresh);
                frames[i] = fresh;
                status[i] = 'empty';
                if (watchers.has(i)) watchers.get(i).disconnect();
                watchers.delete(i);
                sheets.delete(i);
                placed.forEach(highlight => highlight.segments.delete(i));
                settle(i);
                scheduleNotes();
              };

              // Loads the chapters near the viewport and releases those far from it.
              const update = () => {
                const y = window.scrollY, vh = viewport(), edges = tops();
                for (let i = 0; i < count; i++) {
                  const top = edges[i], bottom = top + heights[i];
                  const near = bottom > y - vh * loadMargin && top < y + vh * (1 + loadMargin);
                  const far = bottom < y - vh * keepMargin || top > y + vh * (1 + keepMargin);
                  if (near && status[i] === 'empty') load(i);
                  else if (far && status[i] !== 'empty') release(i);
                }
              };
              let updating = false;
              const scheduleUpdate = () => {
                if (updating) return;
                updating = true;
                setTimeout(() => { updating = false; update(); }, 16);
              };

              // Loads chapter i if it isn't, scrolling to it first if it is far from the viewport;
              // resolves once it is, or no longer wanted. Returns whether it scrolled.
              const bring = async i => {
                if (status[i] === 'loaded') return false;
                const y = window.scrollY, vh = viewport(), top = tops()[i];
                const near = top + heights[i] > y - vh * loadMargin && top < y + vh * (1 + loadMargin);
                if (!near) window.scrollTo(0, top);
                update();
                await whenLoaded(i);
                return !near;
              };

              // Scrolls the line holding the character at offset of loaded chapter i to the top.
              const scrollToLine = (i, offset) => {
                const frame = frames[i];
                window.scrollTo(0, window.scrollY + frame.getBoundingClientRect().top + lineTop(frame, offset));
              };

              // Goes to a position, loading its chapter first; a later one replaces it. Returns whether
              // it got there.
              let latest = 0;
              const scrollToPosition = async ([index, offset]) => {
                const mine = ++latest;
                if (!(index >= 0 && index < count)) return false;
                await bring(index);
                if (mine !== latest || status[index] !== 'loaded') return false;
                scrollToLine(index, offset);
                return true;
              };

              // Scrolls the match [index, offset, length] a third of the way down the viewport
              // unless its first line is in view; returns whether it scrolled.
              const reveal = async ([index, offset, length]) => {
                const mine = ++latest;
                if (!(index >= 0 && index < count)) return false;
                const moved = await bring(index);
                if (mine !== latest || status[index] !== 'loaded') return moved;
                const frame = frames[index];
                const range = rangeOf(frame, offset, length);
                const rect = range && range.getClientRects()[0];
                if (!rect) return moved;
                const top = frame.getBoundingClientRect().top + rect.top;
                if (!moved && top >= 0 && top + rect.height <= window.innerHeight) return false;
                window.scrollTo(0, window.scrollY + top - window.innerHeight / 3);
                return true;
              };

              // Raster images, and SVGs wrapping one (Calibre's covers), never grow past their
              // pixels, however wide the book styles them: blown up they only get blocky.
              const keepSharp = doc => {
                const cap = (element, width) =>
                  element.style.setProperty('max-width', 'min(100%, ' + width + 'px)', 'important');
                doc.querySelectorAll('img').forEach(image => {
                  if (image.naturalWidth && !/\\.svg([?#]|$)/i.test(image.currentSrc)) cap(image, image.naturalWidth);
                });
                doc.querySelectorAll('svg').forEach(svg => {
                  const box = svg.viewBox.baseVal;
                  if (box && box.width && svg.querySelector('image')) cap(svg, box.width);
                });
              };

              // Reflows the loaded chapters at the new size and keeps the position; the others
              // are about as much taller as the text is larger (more lines, taller lines).
              const setTextSize = size => {
                const place = ready ? position() : null;
                const grow = (size / textSize) ** 2;
                textSize = size;
                render();
                setHeights(frames.map((frame, i) => [i, status[i] === 'loaded'
                  ? frame.contentDocument.documentElement.offsetHeight : Math.round(heights[i] * grow)]), false);
                reestimate();
                if (place) scrollToLine(...place);
                scheduleUpdate();
                layOutNotes();
                if (ready) report();
              };

              // Switches the Page Colors (null: Light Pages); the text stays where it is.
              const setAppearance = colors => {
                appearance = colors;
                render();
              };

              window.leaf = {
                position,
                scrollToPosition,
                setTextSize,
                setAppearance,
                reveal,
                setFindMarks,
                setHighlights,
                setPageNotes,
                notePoint,
                emptySpot,
                takeSelection,
                text: index => textOf(frames[index].contentDocument).nodes.map(node => node.data).join(''),
                offset: (index, node, k) => {
                  const { nodes, starts } = textOf(frames[index].contentDocument);
                  return starts[nodes.indexOf(node)] + k;
                },
              };

              // What Dark Pages add to a chapter: the ink on all text, the paper under it.
              const dark = () => appearance ? [
                'html, body { background: ' + appearance.paper + ' !important }',
                'body, body :not(img, svg, svg *, video) { color: ' + appearance.ink + ' !important }',
                'body :not(img, svg, svg *, video) { background-color: transparent !important }',
              ].join(' ') : '';
              const marks = ' ::highlight(leaf-find) { background-color: rgba(255, 204, 0, 0.4) }'
                + ' ::highlight(leaf-find-current) { background-color: rgb(255, 149, 0); color: black }';
              const css = () => style + ' body { zoom: ' + textSize + ' }' + dark() + marks + highlightCss;
              let ready = false, queued = false;
              const lines = 'linear-gradient(rgba(0, 0, 0, 0.6), rgba(0, 0, 0, 0.6))';
              const noteCss = ' .leaf-note { position: absolute; width: ' + iconSize + 'px; height: ' + iconSize + 'px; box-sizing: border-box;'
                + ' border-radius: 4px; border: 1px solid rgba(0, 0, 0, 0.3); cursor: pointer; background-repeat: no-repeat;'
                + ' background-size: 10px 1.5px; background-image: ' + [lines, lines, lines].join(', ') + ';'
                + ' background-position: 3px 3.25px, 3px 7.25px, 3px 11.25px }';
              const renderPage = () => {
                page.textContent = 'html { background: ' + (appearance ? appearance.paper : 'white') + ' }'
                  + (ready ? '' : ' iframe { visibility: hidden }') + noteCss;
              };
              let layingOut = false;
              const scheduleNotes = () => {
                if (layingOut) return;
                layingOut = true;
                requestAnimationFrame(() => { layingOut = false; layOutNotes(); });
              };
              let selecting = false;
              const selectionChanged = () => {
                const now = loaded().some(i => !frames[i].contentDocument.getSelection().isCollapsed);
                if (now !== selecting) post({ selection: selecting = now });
              };
              const render = () => {
                renderPage();
                sheets.forEach(sheet => { sheet.textContent = css(); });
              };
              // A right-click reports where a Note can be added there, if anywhere, before the menu opens.
              const watchContextMenu = (target, frame) => target.addEventListener('contextmenu', event => {
                const box = frame ? frame.getBoundingClientRect() : { left: 0, top: 0 };
                post({ contextSpot: emptySpot(box.left + event.clientX, box.top + event.clientY) });
              }, true);
              watchContextMenu(document);
              renderPage();
              window.addEventListener('scroll', () => {
                if (queued) return;
                queued = true;
                setTimeout(() => { queued = false; update(); if (ready) report(); }, 16);
              });

              // The text reflows with the page's width: the chapters that aren't loaded, about as
              // much taller as the page is narrower.
              let width = window.innerWidth;
              window.addEventListener('resize', () => {
                const was = width;
                width = window.innerWidth;
                if (was >= 100 && width >= 100) {
                  setHeights(frames.flatMap((frame, i) =>
                    status[i] === 'empty' && measured[i] ? [[i, Math.round(heights[i] * was / width)]] : []));
                }
                reestimate();
                scheduleUpdate();
              });

              // A chapter has loaded: styles it, measures it, and draws what the page keeps over the text.
              document.addEventListener('load', event => {
                const frame = event.target;
                const i = frames.indexOf(frame);
                if (frame.tagName !== 'IFRAME' || i < 0 || status[i] !== 'loading') return;
                status[i] = 'loaded';
                measured[i] = true;
                const doc = frame.contentDocument;
                const sheet = doc.createElement('style');
                sheet.textContent = css();
                sheets.set(i, sheet);
                (doc.head || doc.documentElement).append(sheet);
                keepSharp(doc);
                fit(i);
                const watcher = new ResizeObserver(() => { fit(i); scheduleNotes(); });
                watcher.observe(doc.documentElement);
                watchers.set(i, watcher);
                doc.addEventListener('selectionchange', selectionChanged);
                watchContextMenu(doc, frame);
                doc.addEventListener('click', click => {
                  if (click.target.closest('a[href]') || !doc.getSelection().isCollapsed) return;
                  const hit = highlightAt(i, click.clientX, click.clientY);
                  if (!hit) return post('tap');
                  const box = frame.getBoundingClientRect();
                  post({ highlight: hit.id, x: box.left + click.clientX, y: box.top + click.clientY });
                });
                placeHighlights(i);
                markMatches(i);
                reestimate();
                layOutNotes();
                scheduleUpdate();
                if (ready) report();
                settle(i);
              }, true);

              // Opens the book once its frames are there: the opening chapter loads and is placed.
              document.addEventListener('DOMContentLoaded', async () => {
                frames = [...document.querySelectorAll('iframe')];
                const perUnit = rate();
                frames.forEach((frame, i) => {
                  status[i] = 'empty';
                  measured[i] = false;
                  heights[i] = estimate(i, perUnit);
                  frame.style.height = heights[i] + 'px';
                });
                await scrollToPosition(\(start) || [0, 0]);
                ready = true;
                renderPage();
                report();
                post('opened');
              });
            })();
            """
    }
}
