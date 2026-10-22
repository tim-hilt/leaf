import CoreGraphics

/// The script `ReaderEPUBView` injects into the page that stacks the chapter frames.
///
/// It owns the conversion between the DOM and the core's positions (ADR-0022): the
/// text of a chapter is its body's text nodes in document order, and a position is
/// a chapter index and a UTF-16 offset into that text. Change it only together with
/// the core's `epub::text_of`; `ReaderEPUBViewTests` cross-checks the two.
///
/// It posts to the `reader` message handler: "opened" once every chapter is laid
/// out, "tap" for a tap on text that isn't a link, and `[chapter, offset]` for the
/// position at the top of the viewport: once before "opened", then as the page
/// scrolls. Tests and later features call `window.leaf` in the same content world.
///
/// `leaf.setFindMarks` marks Document Search matches as CSS highlights, the current one in
/// another color, and `leaf.reveal` scrolls one into view unless it is.
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
/// with it while the side margin on the page stays as it is. `leaf.setTextSize` keeps
/// the position at the top of the viewport.
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

    /// The script for `frameCount` chapters at `textSize` (`TextSize`) in `appearance`; it
    /// scrolls to the position `start` (chapter index, offset) once all are laid out.
    static func source(
        frameCount: Int, start: (chapter: Int, offset: Int)?, textSize: CGFloat, appearance: PageAppearance
    ) -> String {
        let start = start.map { "[\($0.chapter), \($0.offset)]" } ?? "null"
        return """
            (() => {
              // No text autosizing: on iOS it cancels most of the zoom, so the text size wouldn't change.
              const style = ':where(html) { padding: 0 24px; -webkit-text-size-adjust: none } '
                + ':where(img, svg, video) { max-width: 100% }';
              let textSize = \(textSize);
              let appearance = \(literal(of: appearance));
              const sheets = [];
              const page = document.createElement('style');
              document.documentElement.append(page);
              const post = message => window.webkit.messageHandlers.\(channel).postMessage(message);
              const frames = () => [...document.querySelectorAll('iframe')];

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
              // top is its distance to the top of the viewport.
              const position = () => {
                const all = frames();
                const index = all.findIndex(frame => frame.getBoundingClientRect().bottom > 1);
                if (index < 0) return [Math.max(all.length - 1, 0), 0];
                const frame = all[index];
                const y = -frame.getBoundingClientRect().top;
                if (y <= 0) return [index, 0];
                const { nodes, starts, length } = textOf(frame.contentDocument);
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
              // if no chapter has one.
              const takeSelection = () => {
                const all = frames();
                for (let index = 0; index < all.length; index++) {
                  const selection = all[index].contentWindow.getSelection();
                  if (!selection || selection.isCollapsed || !selection.rangeCount) continue;
                  const range = selection.getRangeAt(0), text = textOf(all[index].contentDocument);
                  const start = pointOffset(text, range.startContainer, range.startOffset);
                  const end = pointOffset(text, range.endContainer, range.endOffset);
                  if (end <= start) continue;
                  selection.removeAllRanges();
                  return [index, start, index, end, text.nodes.map(node => node.data).join('').slice(start, end)];
                }
                return null;
              };

              // Highlights: { id, color: 'rrggbb', note, start: [chapter, offset], end: [chapter, offset] },
              // oldest first, with the DOM ranges of their words per chapter.
              let placed = [], highlightNames = new Set(), highlightCss = '';
              const rgb = color => [0, 2, 4].map(i => parseInt(color.substr(i, 2), 16)).join(', ');

              // The [chapter, range] pieces of the words from start to end.
              const segmentsOf = (start, end) => {
                const pieces = [];
                for (let index = start[0]; index <= end[0]; index++) {
                  const frame = frames()[index];
                  if (!frame) break;
                  const from = index === start[0] ? start[1] : 0;
                  const to = index === end[0] ? end[1] : textOf(frame.contentDocument).length;
                  const range = to > from ? rangeOf(frame, from, to - from) : null;
                  if (range) pieces.push([index, range]);
                }
                return pieces;
              };

              // The newest Highlight with a box at (x, y) in chapter index; null if none.
              const highlightAt = (index, x, y) => {
                for (let i = placed.length - 1; i >= 0; i--) {
                  for (const [chapter, range] of placed[i].segments) {
                    if (chapter !== index) continue;
                    for (const box of range.getClientRects()) {
                      if (x >= box.left && x <= box.right && y >= box.top && y <= box.bottom) return placed[i];
                    }
                  }
                }
                return null;
              };

              // Page Notes: { id, color: 'rrggbb', at: [chapter, offset] }.
              let pageNotes = [];
              const iconSize = 18;

              // Where the icon of a page Note is, in the viewport: in the left margin, centered on
              // the line of its spot. Null if the chapter isn't there.
              const pageNoteSpot = ({ at: [index, offset] }) => {
                const frame = frames()[index];
                if (!frame) return null;
                const line = lineBox(frame, offset);
                return { left: 3, top: frame.getBoundingClientRect().top + line.top + (line.height - iconSize) / 2 };
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
                  const last = highlight.note && highlight.segments[highlight.segments.length - 1];
                  const boxes = last ? last[1].getClientRects() : [];
                  if (!boxes.length) continue;
                  const box = boxes[boxes.length - 1], frame = frames()[last[0]].getBoundingClientRect();
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
                const index = frames().findIndex(frame => {
                  const box = frame.getBoundingClientRect();
                  return y >= box.top && y < box.bottom;
                });
                if (index < 0) return null;
                const frame = frames()[index], box = frame.getBoundingClientRect(), doc = frame.contentDocument;
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
                frames().forEach(frame => highlightNames.forEach(name => frame.contentWindow.CSS.highlights.delete(name)));
                highlightNames = new Set(list.map(highlight => 'leaf-hl-' + highlight.color));
                placed = list.map(highlight => ({ ...highlight, segments: segmentsOf(highlight.start, highlight.end) }));
                const groups = new Map();
                for (const highlight of placed) {
                  for (const [index, range] of highlight.segments) {
                    const key = index + ' leaf-hl-' + highlight.color;
                    if (!groups.has(key)) groups.set(key, []);
                    groups.get(key).push(range);
                  }
                }
                groups.forEach((ranges, key) => {
                  const [index, name] = key.split(' ');
                  const { CSS, Highlight } = frames()[index].contentWindow;
                  const highlight = new Highlight();
                  ranges.forEach(range => highlight.add(range));
                  CSS.highlights.set(name, highlight);
                });
                highlightCss = [...highlightNames].map(name =>
                  ' ::highlight(' + name + ') { background-color: rgba(' + rgb(name.slice(-6)) + ', 0.55) }').join('');
                render();
                layOutNotes();
              };

              // Scrolls the match [index, offset, length] a third of the way down the viewport
              // unless its first line is in view; returns whether it scrolled.
              const reveal = ([index, offset, length]) => {
                const frame = frames()[index];
                const range = frame && rangeOf(frame, offset, length);
                const rect = range && range.getClientRects()[0];
                if (!rect) return false;
                const top = frame.getBoundingClientRect().top + rect.top;
                if (top >= 0 && top + rect.height <= window.innerHeight) return false;
                window.scrollTo(0, window.scrollY + top - window.innerHeight / 3);
                return true;
              };

              // Marks the matches [[index, offset, length], ...] in the text, the one at
              // `current` apart. The marks are CSS highlights, so the text stays as it is.
              const setFindMarks = (matches, current) => {
                frames().forEach(frame => {
                  frame.contentWindow.CSS.highlights.delete('leaf-find');
                  frame.contentWindow.CSS.highlights.delete('leaf-find-current');
                });
                const others = new Map(), chosen = new Map();
                matches.forEach(([index, offset, length], number) => {
                  const range = rangeOf(frames()[index], offset, length);
                  if (!range) return;
                  const group = number === current ? chosen : others;
                  if (!group.has(index)) group.set(index, []);
                  group.get(index).push(range);
                });
                const mark = (group, name) => group.forEach((ranges, index) => {
                  const { CSS, Highlight } = frames()[index].contentWindow;
                  const highlight = new Highlight();
                  ranges.forEach(range => highlight.add(range));
                  CSS.highlights.set(name, highlight);
                });
                mark(others, 'leaf-find');
                mark(chosen, 'leaf-find-current');
              };

              const scrollToPosition = ([index, offset]) => {
                const frame = frames()[index];
                if (frame) window.scrollTo(0, window.scrollY + frame.getBoundingClientRect().top + lineTop(frame, offset));
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
              const fit = frame => {
                frame.style.height = frame.contentDocument.documentElement.offsetHeight + 'px';
              };

              // Reflows every chapter at the new size and keeps the position.
              const setTextSize = size => {
                const place = ready ? position() : null;
                textSize = size;
                render();
                frames().forEach(fit);
                if (place) scrollToPosition(place);
                layOutNotes();
                if (ready) post(position());
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
                text: index => textOf(frames()[index].contentDocument).nodes.map(node => node.data).join(''),
                offset: (index, node, k) => {
                  const { nodes, starts } = textOf(frames()[index].contentDocument);
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
              let loaded = 0, ready = false, queued = false;
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
                const now = frames().some(frame => !frame.contentDocument.getSelection().isCollapsed);
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
                if (!ready || queued) return;
                queued = true;
                requestAnimationFrame(() => { queued = false; post(position()); });
              });
              document.addEventListener('load', event => {
                const frame = event.target;
                if (frame.tagName !== 'IFRAME') return;
                const doc = frame.contentDocument;
                const sheet = doc.createElement('style');
                sheet.textContent = css();
                sheets.push(sheet);
                (doc.head || doc.documentElement).append(sheet);
                keepSharp(doc);
                fit(frame);
                new ResizeObserver(() => { fit(frame); scheduleNotes(); }).observe(doc.documentElement);
                doc.addEventListener('selectionchange', selectionChanged);
                watchContextMenu(doc, frame);
                doc.addEventListener('click', click => {
                  if (click.target.closest('a[href]') || !doc.getSelection().isCollapsed) return;
                  const hit = highlightAt(frames().indexOf(frame), click.clientX, click.clientY);
                  if (!hit) return post('tap');
                  const box = frame.getBoundingClientRect();
                  post({ highlight: hit.id, x: box.left + click.clientX, y: box.top + click.clientY });
                });
                if (++loaded === \(frameCount)) {
                  const start = \(start);
                  if (start) scrollToPosition(start);
                  ready = true;
                  renderPage();
                  post(position());
                  post('opened');
                }
              }, true);
            })();
            """
    }
}
