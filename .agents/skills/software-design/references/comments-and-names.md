# Comments and names

Detail for the `Comments and names` principle in [`../SKILL.md`](../SKILL.md). Comments record what was in the designer's mind but could not be written as code. Without them there is no abstraction: a caller who must read the body to use a function sees all of its complexity.

## Conventions

Follow the language's documentation tool format (Javadoc, Doxygen, godoc, docstrings, JSDoc) and the project's existing style. Comment by category:

- **Interface**: before every class, function, and method.
- **Data member**: next to every class field and important struct member.
- **Implementation**: inside bodies, only where needed.
- **Cross-module**: for decisions spanning modules; rare but important.

Skip a comment only when the declaration is truly self-explanatory (simple getters, sometimes).

## The repetition test

Could someone who has never seen the code write this comment just from the adjacent code? If yes, it adds nothing: rewrite it at a different level of detail, or delete it. Using the name's own words ("Downcast PARAMETER to TYPE") is the common failure. Good comments are either:

- **lower-level**, adding **precision**, or
- **higher-level**, adding **intuition**.

## Precision (variables, arguments, return values)

Fill in what name and type leave out:

- Units (pixels or characters? ms or s?).
- Inclusive or exclusive bounds.
- Meaning of null, empty, zero, or a missing entry.
- Ownership: who frees or closes the resource.
- Invariants ("always contains at least one entry").

Describe what a variable *is* (nouns), not how code manipulates it (verbs).

```
// Bad:  The horizontal padding of each line in the text.
// Good: The amount of blank space to leave on the left and right
//       sides of each line of text, in pixels.
```

## Intuition (blocks, loops, classes)

Ask: what is this code trying to do? What is the simplest statement that explains everything in it? A good higher-level comment gives a conceptual frame ("Try to append the current key hash to an existing RPC to the same server that hasn't been sent yet") that lets the reader check the code against it. "How we get here" comments (why a block runs, when a function is typically called) are especially useful.

## Interface comments

**Class**: the abstraction it provides, what one instance represents, and limitations callers care about (e.g. not thread-safe). A short usage sketch helps for deep classes whose methods work together in nonobvious ways.

**Function or method**:

1. One or two sentences on behavior as the caller perceives it.
2. Each argument and the return value, precisely, including constraints and dependencies between arguments.
3. Side effects: anything that changes future behavior but isn't the result.
4. Errors and exceptions that can emerge.
5. Preconditions (minimize them; document the ones that remain).

Omit how it works. If the interface comment must describe the implementation to be complete, the function is shallow.

```
/**
 * Copy a range of bytes from a buffer to an external location.
 *
 * \param offset  Index within the buffer of the first byte to copy.
 * \param length  Number of bytes to copy.
 * \param dest    Where to copy the bytes: must have room for at least
 *                length bytes.
 * \return  The actual number of bytes copied, which may be less than
 *          length if the range extends past the end of the buffer;
 *          0 if the range and the buffer don't overlap.
 */
```

## Implementation comments: what and why

- Most short functions need none.
- For longer functions, put a comment before each major block saying what it does, and optionally an overview at the top ("We proceed in three phases: ...").
- Before a complex loop, say what one iteration does.
- Explain *why* for tricky code and non-obvious bug fixes; reference the issue ID instead of restating it.
- Comment a local variable only when it spans a lot of code.

## Cross-module decisions

Place the note where a developer is forced to go. Example: the comment at the end of a `Status` enum lists every other file to update when adding a value. With no such place, keep one central design-notes file with labeled sections, and leave short pointers in the code (`// See "Zombies" in designNotes`).

## Keeping comments alive

- Put the comment next to the code it describes (interface comments by the implementation, not in a distant header), at the narrowest scope that covers it. The farther a comment sits from its code, the more abstract it should be.
- Document each decision once, at its most obvious home. Elsewhere, point to it ("See the comment in xyz"). Call sites point to the callee's interface comment rather than restating it.
- Reference external docs (RFCs, user manual) rather than copying them.
- Information a future developer needs belongs in the code. The commit message may repeat it, never replace it.
- Before committing, scan the whole diff and confirm each change is reflected in the documentation.

## Names

Good names are **precise** and **consistent**.

**Precise**:

- Ask whether someone seeing the name in isolation would guess what it refers to, and whether another name would paint a clearer picture.
- Aim for two or three words that capture what matters most.
- Replace generic words (`count`, `result` in a void function, `status`, `data`, `x`/`y` for text positions) with the specific concept (`numIndexlets`, `mergedLine`, `charIndex`/`lineIndex`).
- Make boolean names predicates (`cursorVisible`, not `blinkStatus`).
- Name sentinels for their meaning (`NOT_YET_VOTED`, not `VOTED_FOR_SENTINEL_VALUE`).
- Avoid names that are too specific: a delete argument is a `range`, not a `selection`.

**Consistent**:

- Always use the common name for its purpose.
- Use it for nothing else.
- Keep the purpose narrow enough that every variable with the name behaves the same way.
- Distinguish siblings with prefixes (`srcFileBlock`, `dstFileBlock`).
- Keep loop variables consistent: `i` outer, `j` inner.

**Length** grows with the distance between declaration and use: `i` is fine in a short loop; a field read across a class needs a full name.

If no short, precise name comes to mind, the entity is probably poorly defined, perhaps one variable holding several meanings. Fix the design, not just the name. Readability is judged by readers: when reviewers find names cryptic, lengthen them.
