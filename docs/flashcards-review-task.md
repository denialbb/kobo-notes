# Flashcards plugin — review + continuation task

Target: **agy**. Review the `flashcards.koplugin` thoroughly (code correctness,
KOReader v2026.07 widget-API fit), finish the remaining docs, and report a
numbered findings list. Be conservative: where you find a clear bug, fix it;
where it is ambiguous, report it and **do not** change the design.

## Where things live (repo root = `/home/denial/Projects/kobo-notes`)

- `plugins/flashcards.koplugin/` — **a git submodule** (separate repo
  `denialbb/flashcards.koplugin`). Files:
  - `parser.lua` — pure `flashcards.md` → cards parser.
  - `quiz.lua` — pure shuffle/score/missed state machine.
  - `main.lua` — thin KOReader widget adapter. **Has uncommitted edits**
    (a driver-feature/mayfly check, feedback/logging). Review this file as-is.
- `tools/flashcards-cli.lua` — host-side driver of the *same* parser+quiz.
- `tests/flashcards_parser_spec.lua`, `tests/flashcards_quiz_spec.lua`,
  `tests/flashcards_cli_spec.lua`, `tests/fixtures/notes/…`.
- `docs/flashcards-design.md` — design record.
- `docs/quiz.py.spec.md`-style reference: the desktop tool spec is in
  `~/.local/bin/quiz.py` (read it directly).

## Recent work already done (just verify, do not redo)

1. **Fix** the startup crash that showed as "nothing happens": KOReader
   swallows menu-callback errors silently. The root IO bug: KOReader's `lfs`
   `dir` returns a `(closure, state)` pair; wrapping `pcall(lfs.dir, …)` and
   iterating the closure alone raised `directory metatable expected, got nil`.
   `main.lua:findThemeFiles` now pcall-wraps the WHOLE `for f in lfs.dir(dir)`
   loop. Look for *any other* spot that captures an lfs iterator into a
   variable and iterates it separately (same latent bug).

- **Feedback on screen**: `Flashcards:withFeedback(cb)` wraps menu handlers so a
  thrown error is both logged and shown via `InfoMessage`. All four menu
  callbacks use it. `onStartQuiz` now validates the root exists and shows a
  clearer "not found" message with a hint.
- **Debug logging**: `Flashcards:log(level, msg, …)` writes a timestamped line
  to KOReader's logger (→ `crash.log`) AND to `settings/flashcards.log`.

## Review checklist

1. **KOReader widget API (v2026.07)** — verify against the on-device KOReader
   (it is mounted at `/mnt/kobo/.adds/koreader/` — read the real
   `frontend/ui/…` sources there, they are on the device) that `main.lua` uses
   the widgets correctly and in a way that will build at runtime:
   - `ScrollTextWidget:new{ text, face, width, height, fgcolor }`
   - `ButtonTable:new{ width, buttons = { { {text, callback, id}, … }, … } }`
   - `Menu:new{ title, item_table, is_borderless }`
   - `ConfirmBox:new{ text, ok_text, ok_callback }`,
     `InfoMessage:new{ text, timeout }`
   - `InputDialog:new{ title, input, description, buttons }` + `onShowKeyboard`
   - Container/widget validity: `VerticalGroup`, `FrameContainer`, `CenterContainer`,
     `TextWidget`, `VerticalSpan`, `ScrollTextWidget`, `Font:getFace`,
     `Size.span`, `Screen:getWidth/getHeight/scaleBySize`, `Geom`.
   - `logger` API: methods actually present on the device (`logger.info`,
     `logger.warn`, `logger.err`, `logger.dbg`?) — confirm `logger[level]`
     fallback logic can't nil-deref.
   - `UIManager` show/close semantics and the `onClose` « physical Back » +
     `CloseWidget` assumption documented in `main.lua`.
2. **Parser parity** (`parser.lua` vs `~/.local/bin/quiz.py`): `---` block
   splits, `Q:` / `A:` mode switches, continuation lines, both-sides-required,
   CRLF handling, theme = parent-directory basename. Note the RELAXATION:
   indented `Q:`/`A:` are accepted — is that intentional and documented?
3. **Quiz state machine** (`quiz.lua`): shuffle determinism (seed), index/total,
   `reveal`, `mark`, summary math (score/answered/percent/missed_count), `quit`
   and `fromMissed`. Any off-by-one or double-count?
4. **Edge cases**: empty theme, single card, all-missed, `fromMissed` when
   missed set is empty, quit-before-answering, session persistence shape
   (`session.theme/score/answered/missed`), settings write/fail.
5. Anything that changes `parser.lua`/`quiz.lua` semantics must be justified or
   left as a finding — these are covered by unit tests.

## What to produce

- A **numbered findings list** (severity: blocker / important / minor).
- Apply **clear, low-risk fixes** inline (esp. any other latent
  iterator-state bug, logger method mismatches). Audit + comment:
  `Lua clean`/`lua -c`-style syntax validation for the submodule files.
- Finish the plugin documentation:
  - Add a **"Debugging"** section to `plugins/flashcards.koplugin/README.md`:
    the on-screen error dialog, `settings/flashcards.log`,
    `crash.log`, the CLI commands, and the host fixture smoke test.
  - Brief note in `docs/flashcards-design.md`.
- Run `lua run_busted_tests.lua` (expect **145 pass**) and
  `lua tools/flashcards-cli.lua tests/fixtures/notes --auto`.

## Hard constraints

- **Pure Lua.** Nothing cross-compiled.
- **Do NOT `git commit`** anything (neither the parent repo nor the submodule);
  I handle repository/commit management, deploy, and the `deploy.sh` piece.
- **Do NOT touch** other files in the parent repo — especially any
  `parse_tables.lua`, `test_bold*.lua`, and the modified
  `tests/markdown_interceptor_spec.lua` / `tests/math_renderer_spec.lua` —
  those belong to a different concurrent workflow.
- Do not modify the mounted device; the user deploys via `./deploy.sh`.
- Report where exactly you changed and why.
