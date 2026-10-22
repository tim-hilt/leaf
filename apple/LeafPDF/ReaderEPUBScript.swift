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
/// The text size is a CSS `zoom` on each chapter's body, so the book's own sizes scale
/// with it while the side margin on the page stays as it is. `leaf.setTextSize` keeps
/// the position at the top of the viewport.
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

              // The top of the line holding the character at offset, in the frame's coordinates.
              const lineTop = (frame, offset) => {
                const text = textOf(frame.contentDocument);
                const k = nodeIndex(text, offset, false);
                const node = text.nodes[k];
                if (!node) return 0;
                const character = Math.min(offset - text.starts[k], Math.max(node.length - 1, 0));
                const rect = lastRect(node, 0, character + 1) || node.parentElement.getBoundingClientRect();
                return rect.top;
              };

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
              const css = () => style + ' body { zoom: ' + textSize + ' }' + dark() + marks;
              let loaded = 0, ready = false, queued = false;
              const renderPage = () => {
                page.textContent = 'html { background: ' + (appearance ? appearance.paper : 'white') + ' }'
                  + (ready ? '' : ' iframe { visibility: hidden }');
              };
              const render = () => {
                renderPage();
                sheets.forEach(sheet => { sheet.textContent = css(); });
              };
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
                fit(frame);
                new ResizeObserver(() => fit(frame)).observe(doc.documentElement);
                doc.addEventListener('click', click => {
                  if (!click.target.closest('a[href]') && doc.getSelection().isCollapsed) post('tap');
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
