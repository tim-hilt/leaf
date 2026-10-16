---
name: software-design
description: Minimize complexity (Ousterhout's A Philosophy of Software Design). Use when implementing, modifying, or reviewing code.
---

# Software Design

The one goal, from Ousterhout's *A Philosophy of Software Design*, is to minimize **complexity**: anything in the structure of code that makes it hard to understand and modify. It shows up as three **symptoms**:

- **Change amplification**: a simple change needs edits in many places.
- **Cognitive load**: how much a developer must know to make a change.
- **Unknown unknowns**: it is unclear what must change or what must be known. The worst of the three.

It has two causes: **dependencies** (code that cannot be understood or changed in isolation) and **obscurity** (important information that is not obvious). Complexity is **incremental**: it accrues in small chunks, so every small one counts. It is judged by the reader, not the writer, and weighted by how often the code is touched.

Work **strategically**: working code is the floor, the target is a great design that also works. The **tactical** path (the quickest change that works) is how complexity accrues. Every principle below serves the goal; when applying one further would raise overall complexity, stop there. The goal outranks any rule.

## Workflows

**When in Rome**, in every workflow: before writing or editing code, study the local conventions (naming, structure, error handling, comment style) and find an existing example of a similar decision; follow it. A better idea alone does not justify inconsistency; replace a convention only everywhere at once, and only with the user's agreement.

**Scale to the change.** A trivial change (rename, typo, config value, one-line fix that touches no interface) needs only When in Rome and *Scan the diff*. Everything else runs its full workflow.

### Implementing new code

1. **Map the knowledge.** List the design decisions the feature embodies (formats, protocols, algorithms, policies, data structures). Done when each decision has exactly one owning module, grouped by knowledge (see *Temporal decomposition*).
2. **Design it twice.** For each significant interface, sketch two or more radically different alternatives (key signatures only). Rank by ease of use for callers, then interface simplicity, then generality, then efficiency. Pick one or combine them; if every alternative is unattractive, use their shared weakness to invent another. Done when you can say why the chosen design beats the others.
3. **Comments first.** Read [`references/comments-and-names.md`](references/comments-and-names.md). Before any bodies, write the class interface comment, then signature and interface comment for each public method, then comments for member variables. A *Hard to describe* hit here means revise the design now, while it is cheap.
4. **Implement against the comments.** Done when every body delivers what its step-3 comment promises, with implementation comments wherever the *what* or *why* is not obvious.
5. **Check.** Done when every new module, interface, and name has been run against every red flag, each hit is fixed or its trade-off stated, and every public interface has an interface comment.

Increments of development are **abstractions, not features**: when a feature first needs an abstraction, design that abstraction whole (its core functions, somewhat general-purpose) rather than growing it one feature at a time. When working test-first, finish steps 2–3 before the first test, so tests exercise a designed interface instead of dictating its shape.

### Modifying existing code

1. **Re-examine the design.** Target: after the change, the code has the structure it would have had if it had been designed with this change in mind from the start. The smallest working diff usually adds a special case, flag, parameter, or dependency; treat that as the **tactical** path and look for the design that absorbs the change.
2. **Refactor, then change.** In every touched area, fix at least one red-flag hit, or confirm it has none. When the right refactor is large, risky, or crosses ownership boundaries, do the cleanest version that fits the constraints and report the larger refactor to the user rather than expanding scope silently.
3. **Bugs: red test first**, where the project has tests. Write a test that fails because of the bug, fix, and watch it pass.
4. **Scan the diff.** Done when every behavior change is reflected in the nearest comment (see [`references/comments-and-names.md`](references/comments-and-names.md)), information a future developer needs (why a subtle fix exists) lives in a code comment rather than only in the commit message, debug code and resolved TODOs are gone, and touched code has been run against every red flag.

### Reviewing code

1. **Read as a newcomer.** Read the whole diff once at reading speed before judging. Every spot where your first guess about behavior was wrong is a finding (*Nonobvious code*), whether the cause is a name, a hidden dependency, or a missing comment: obviousness is decided by the reader.
2. **Apply every red flag** to every new or changed module, interface, name, and comment (judge names and comments by [`references/comments-and-names.md`](references/comments-and-names.md)), then check the diff once against each principle section below for issues the flags miss.
3. **Report** each finding with: `file:line`, red flag or principle, its **symptom**, and a concrete fix direction. Order by complexity impact: interface and information-leakage problems in new APIs first (they propagate to every caller), then internal ones. Keep design issues separate from nits; note where a fix would take a principle too far. When the design is sound, say so plainly.

Done when every new or changed module, interface, name, and comment has been checked against every red flag, every principle section has been checked against the diff, and each finding names its symptom.

## Red flags

Each red flag marks a **tactical** shortcut; the fix direction is the strategic alternative.

| Red flag | Symptom | Fix direction |
|---|---|---|
| Shallow module | Interface nearly as complex as the implementation | Merge into caller or neighbor; raise the interface level |
| Information leakage | One design decision reflected in several modules | Merge the modules, or extract the decision into one module with a simple interface |
| Temporal decomposition | Structure mirrors execution order (reader / parser / writer) | Organize by knowledge used, not by when it runs |
| Overexposure | Common use forces callers to learn rare features | Defaults; rare features in separate methods |
| Pass-through method | Forwards its arguments to a method with a similar signature | Expose the lower layer, redistribute responsibility, or merge |
| Pass-through variable | Parameter threaded through methods that never use it | Shared object or context object |
| Repetition | Nontrivial code repeated | Extract with a simple signature, or restructure so it runs once |
| Special-general mixture | General mechanism contains use-case-specific code | Move special-purpose code up into the layer that owns the use case |
| Conjoined methods | One can't be understood without reading the other | Merge, or re-split along a clean seam |
| Needless error | Exception or error return for a case the semantics could absorb | Define out of existence, mask, or aggregate |
| Punted decision | Config parameter or exception for something the module could decide itself | Compute internally; auto-default |
| Exposed internals | Getter/setter per field, internal collections returned | Offer operations instead of state |
| Comment repeats code | Comment derivable from the adjacent code or name | Add precision or intuition, or delete |
| Implementation contaminates interface | Interface comment describes internals | Move those details into the body |
| Vague name | Name could refer to many things | Precise name that creates an image |
| Hard to pick name | No short, precise name exists | Rethink the entity; it may be several things |
| Hard to describe | A complete interface comment must be long | Redesign the interface |
| Nonobvious code | Quick read doesn't reveal meaning or behavior | Simplify, rename, or comment the missing information |

## Principles

### Deep modules

A module is anything with an interface and an implementation: function, class, service. Its interface is everything a caller must know, formal (signatures) and informal (behavior, side effects, ordering constraints). Interface is cost, functionality is benefit. The best modules are **deep**: much functionality behind a simple interface (Unix `open/read/write/lseek/close`).

- A simple interface matters more than a simple implementation.
- Make the common case simple: sensible defaults, and the module *does the right thing* without being asked (buffering on by default, not opt-in via a wrapper class).
- A wrapper like `addNullValueForAttribute(attr)` around `data.put(attr, null)` is shallow: call `put` directly.
- Length alone is no reason to split. A long function with a simple signature that reads top to bottom and does its one job completely is deep and fine; many tiny classes and methods (**classitis**) raise system complexity.

### Information hiding

Each module encapsulates a few design decisions that appear nowhere else. Information can also leak through the back door: two modules that never call each other but both know a file format are coupled.

- `getParameter(name)` and `getIntParameter(name)` hide the store; `getParams(): Map` exposes it, even behind `private`.
- Inside a class, minimize the places each field is touched.
- Prefer composition to implementation inheritance; when inheriting, let the parent own its state.
- Hide only what callers truly don't need. Expose what they do need (e.g. when data reaches durable storage).

### Somewhat general-purpose

Functionality reflects today's needs; the interface is general enough for several uses. Ask:

- What is the simplest interface that covers all current needs? Fewer methods with equal capability is more general, unless each method grows many parameters.
- In how many situations will this method be used? A method for exactly one caller or UI action is a special-purpose red flag.
- Is it easy to use for current needs? Lots of glue code in callers means it is too low-level.

Example: a text class offering `insert(position, text)` and `delete(start, end)` beats one offering `backspace(cursor)` and `deleteSelection(selection)`; the UI builds backspace from the general operations.

### Different layer, different abstraction

Each layer should offer a different abstraction from its neighbors, and a module's interface should differ from its internal representation (character-range API over line storage). Same signatures are fine when each method adds distinct functionality: dispatchers, multiple implementations of one interface. Before writing a decorator, consider adding the feature to the base class, merging it into the use case, or making it standalone. The context object that cures a *Pass-through variable* lives in major objects, is passed via constructors, is preferably immutable, and beats a global.

### Pull complexity downward

When unavoidable complexity relates to a module's own functionality, absorb it inside the module: it has more users than developers. Most *Punted decisions* are ones callers cannot make better than the module (compute a retry interval from measured response times instead of exposing one). Pull down only what is closely related to the module, simplifies callers, and simplifies the interface; anything else is leakage.

### Together or apart

Bring code together when it shares information, is used together in both directions, overlaps conceptually, or can't be understood alone; also when merging simplifies the interface or removes duplication. Keep it apart when independent, and to separate general-purpose mechanisms from special-purpose uses: a general `History` class stores undo actions and knows nothing about text; each module supplies its own action type, and the UI owns the grouping policy. Split a function only by:

- extracting a subtask that reads alone, so the parent needn't know its internals and the child needn't know its parent; or
- dividing an interface that did unrelated things, so most callers need only one of the new pieces.

### Errors and special cases

Exceptions are part of the interface, and every handler adds complexity. Reduce the number of places that handle them, preferring in order:

1. **Define errors out of existence**: redefine semantics so normal behavior covers the case (`unset` means "ensure the variable doesn't exist"; substring clamps out-of-range indices).
2. **Mask** at a low level (a transport retries lost packets internally).
3. **Aggregate**: let many errors propagate to one handler (a top-level request loop turns any request error into an error response).
4. **Crash** with a clear message on rare, unrecoverable errors (out of memory, corrupted internal state), where the application can tolerate it.

Treat special cases the same way: shape the normal path to cover them (an empty selection instead of a "no selection" flag). Expose errors callers genuinely must react to.

### Obvious code

A reader's first quick guess should be correct. Levers: precise names, consistency, blank lines between blocks, comments for information the code cannot carry. Compensate for obscuring constructs: document when an event handler is invoked; replace generic pairs/tuples with a named type; match declared and actual types; comment any behavior that violates reader expectations (a constructor that starts threads).

### Comments and names

Comments hold what the code cannot: the abstraction, units, boundaries, invariants, ownership, rationale. A name creates an image: someone seeing it alone should guess what it refers to. Rules and examples for both live in [`references/comments-and-names.md`](references/comments-and-names.md).

## References

- [`references/performance.md`](references/performance.md): read when a change targets speed or touches a hot path.
