# Issue tracker: loop

Specs and tasks live in `loop` sessions (CLI, state outside the repo). One session = one spec + ordered tasks. Run `loop --help` for all commands.

Never write specs or tickets into the repo: draft any `--spec-file`/`--body-file` input in a temp dir outside it. `.scratch/` holds only legacy specs; ignore skill instructions to write there.

## Conventions

- Spec: markdown passed to `loop new`; title defaults to its first heading.
- Task: one per ticket, with a short `--title`, a markdown `--body`, and `--check` shell commands (all must exit 0, e.g. `cargo test`).
- Task status: `pending` (default), `running`, `in-review`, `done`, `failed`. `loop run` skips non-pending tasks.
- Task ids are global across sessions; see `loop show --id <n> --json`.
- `--blocked-by` is advisory: `loop run` does not enforce it; `loop task ready` honors it. Export/import keep type and blockers.
- Comments: none; amend the task body with `loop task edit`.

## Operations

- Create spec: `loop new --spec-file /tmp/<slug>/spec.md [--title t]` (prints session id). Use `--json -`/`@file` for stdin/file input; `loop schema new` shows the format.
- Add task: `loop task add --id <session> --title t --body-file b.md --check "cargo test"`; `loop schema task` shows the format.
- Fetch ticket: `loop task show --task <n>`; whole session: `loop show --id <n>`; all sessions: `loop ls`.
- Edit ticket: `loop task edit --task <n> [--title|--body|--check|--status|--type|--blocked-by]`.
- Edit spec: `loop edit --id <n> [--title t] [--spec s | --spec-file f]`.
- Execute: `loop run --id <n>` (blocking; `loop stop|status|logs --id <n>`).
- Export/import (only on explicit request, never into the repo): `loop export --id <n> --to dir` (writes `spec.md`, `issues/NN-slug.md`); `loop import --from dir`.

## When a skill says "publish to the issue tracker"

`loop new` for a spec, `loop task add` per ticket (never one combined ticket).

## When a skill says "fetch the relevant ticket"

`loop task show --task <n>` (or `loop show --id <n>` for the session). The user normally passes the number.

## When a skill looks for a spec (e.g. `code-review`)

Specs are not files in the repo. Read it with `loop show --id <n>`; without a number, find the session in `loop ls` by title, or ask.

## Wayfinding operations

Used by `/wayfinder`. The **map** is the session spec; each **child** is a task.

- **Map**: session spec (Notes / Decisions-so-far / Fog body); update with `loop edit --id <n> --spec-file /tmp/<slug>/map.md`.
- **Child ticket**: task with the question in `--body` and `--type research|prototype|grilling|task`.
- **Blocking**: `--blocked-by <task id>` (repeatable). A task is unblocked when every blocker is `done`.
- **Frontier**: `loop task ready --id <n> [--json]` (pending and unblocked); first by id wins.
- **Claim**: `loop task edit --task <n> --status running` before any work.
- **Resolve**: append the answer under `## Answer` via `loop task edit --body`, set `--status done`, then append a pointer to the map's Decisions-so-far with `loop edit`.
