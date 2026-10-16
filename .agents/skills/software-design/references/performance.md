# Designing for performance

Detail for performance work under [`../SKILL.md`](../SKILL.md). Clean design and speed are compatible: simple code does less extraneous work, deep modules cross fewer layers, and code with special cases defined away has fewer branches.

## Default: naturally efficient

Know what is fundamentally expensive, and pick the cheaper option when it is equally clean:

- Network round-trips: 10–50 µs within a datacenter, 10–100 ms wide-area.
- Storage I/O: 5–10 ms on disk, 10–100 µs on flash.
- Dynamic allocation (malloc, `new`, GC pressure).
- Cache misses: hundreds of instruction times per DRAM fetch.

Examples: a hash map over an ordered map unless ordering is needed; an array of structs over an array of pointers to separately allocated structs. Micro-benchmarks are the reliable way to learn real costs.

When the faster design costs complexity:

- small and hidden inside the module: it may be worth it (complexity is still incremental);
- large, or leaking into interfaces: start simple and optimize if measurements demand it;
- clear prior evidence that this spot is performance-critical: build the fast design now.

## Measure before modifying

Performance intuition is unreliable. Before tuning:

1. Measure deeply enough to find a few specific places where the time goes, not just that the system is slow.
2. Record a baseline.
3. After the change, re-measure. Back out changes that bring no significant speedup, unless they also simplified the code.

## Fix fundamentally first

Prefer a fundamental change: a cache, a better algorithm or data structure, an architectural bypass. Implement it with the normal design principles.

## Redesign around the critical path

Use this only when no fundamental fix exists:

1. Identify the most common case. Ignoring the existing structure, write the **ideal**: the minimum code and data that case must execute, as if in one function with the most convenient data layout.
2. Find the cleanest design that stays as close to the ideal as possible; a call into a general-purpose helper (e.g. a hash table) is fine.
3. Get special cases off the critical path: ideally one test at the entry detects all of them, and the common case then runs straight through. Special-case code elsewhere can favor simplicity over speed.
4. Remove shallow layers on the path; same-signature methods stacked on the critical path are both slow and a design red flag.
5. Adding a field that keeps a common query O(1) is a reasonable trade (e.g. maintaining `totalLength` or `extraAppendBytes`).

Result from the book's Buffer rewrite: about 2× faster and 20% less code.
