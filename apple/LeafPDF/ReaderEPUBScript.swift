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
enum ReaderEPUBScript {
    static let channel = "reader"

    /// The script for `frameCount` chapters; it scrolls to the position `start`
    /// (chapter index, offset) once all are laid out.
    static func source(frameCount: Int, start: (chapter: Int, offset: Int)?) -> String {
        let start = start.map { "[\($0.chapter), \($0.offset)]" } ?? "null"
        return """
            (() => {
              const style = ':where(html) { padding: 0 24px } :where(img, svg, video) { max-width: 100% }';
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

              // The top of the line holding the character at offset, in the frame's coordinates.
              const lineTop = (frame, offset) => {
                const { nodes, starts } = textOf(frame.contentDocument);
                let low = 0, high = nodes.length;
                while (low < high) {
                  const middle = (low + high) >> 1;
                  if (starts[middle] <= offset) low = middle + 1; else high = middle;
                }
                const node = nodes[Math.max(low - 1, 0)];
                if (!node) return 0;
                const character = Math.min(offset - starts[Math.max(low - 1, 0)], Math.max(node.length - 1, 0));
                const rect = lastRect(node, 0, character + 1) || node.parentElement.getBoundingClientRect();
                return rect.top;
              };

              const scrollToPosition = ([index, offset]) => {
                const frame = frames()[index];
                if (frame) window.scrollTo(0, window.scrollY + frame.getBoundingClientRect().top + lineTop(frame, offset));
              };

              window.leaf = {
                position,
                scrollToPosition,
                text: index => textOf(frames()[index].contentDocument).nodes.map(node => node.data).join(''),
                offset: (index, node, k) => {
                  const { nodes, starts } = textOf(frames()[index].contentDocument);
                  return starts[nodes.indexOf(node)] + k;
                },
              };

              let loaded = 0, ready = false, queued = false;
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
                sheet.textContent = style;
                (doc.head || doc.documentElement).append(sheet);
                const fit = () => { frame.style.height = doc.documentElement.offsetHeight + 'px'; };
                fit();
                new ResizeObserver(fit).observe(doc.documentElement);
                doc.addEventListener('click', click => {
                  if (!click.target.closest('a[href]') && doc.getSelection().isCollapsed) post('tap');
                });
                if (++loaded === \(frameCount)) {
                  const start = \(start);
                  if (start) scrollToPosition(start);
                  ready = true;
                  post(position());
                  post('opened');
                }
              }, true);
            })();
            """
    }
}
