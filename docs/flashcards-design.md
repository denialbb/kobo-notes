# Flashcards plugin — design record

**Status:** implemented (`plugins/flashcards.koplugin`), tests green (145 total), pending on-device verification.
**Companion to:** the desktop quiz tool `~/.local/bin/quiz.py`.

## Goal

Quiz yourself on the `flashcards.md` files in the synced notes tree, on the
Kobo, with an e-ink friendly touch UI — reading the **same files** and using
the **same format** as the desktop tool, so one corpus serves both.

## Format (parity with `quiz.py`)

```
---
Q: question — may span
   multiple lines
A: answer, also multi-line
---
```

* Blocks split on the literal string `---` (a plain, non-pattern search,
  exactly like Python's `content.split("---")`).
* A block becomes a card only when it has both a `Q:` and an `A:`; otherwise
  it is skipped.
* Continuation lines (anything after `Q:`/`A:`) are appended to that section
  with `\n`; interior blank lines are preserved; leading/trailing blank space
  is trimmed from each block and from the final question/answer.
* CRLF input is accepted.

**One deliberate relaxation:** `Q:`/`A:` may be indented (the desktop parser
requires them flush left). This cannot misparse a file that works there and
rescues sloppily-indented ones. Documented in the plugin README.

The parity quirks are locked in by `tests/flashcards_parser_spec.lua`, which
includes the odd-but-intended behaviors: a lone `---` inside prose splits the
block, and two `Q:`/`A:` pairs without a separator fold into one card.

## Architecture

```
parser.lua   file text → cards          pure Lua, unit-tested
quiz.lua     shuffle/score/missed FSM   pure Lua, unit-tested
main.lua     discovery + KOReader UI    thin widget adapter, exercised on device
tools/flashcards-cli.lua                host-side driver of parser+quiz
```

Splitting the logic from the widgets is the point: the quiz *behavior* is one
implementation, unit-tested on a PC and shared verbatim with the CLI, while
`main.lua` is a thin translation onto KOReader widgets (Menu, ScrollTextWidget,
ButtonTable, InputContainer-based dialogs). No KOReader module is required by
`parser.lua`/`quiz.lua`, so the test runner's stubs are not involved.

## UI flow (e-ink constraints)

1. **Tools → Flashcards → Start Quiz** → theme menu (each entry shows its card
   count, like the desktop tool's numbered list) → deck-length menu
   (all / 10 / 25 / 50, mirroring quiz.py's "how many questions" prompt).
2. Card dialog: header (`Card i/n` + theme), question in a scrollable
   `ScrollTextWidget`, an "answer hidden" placeholder, and a button row.
   Physical Back also asks to quit.
3. **Reveal Answer** swaps the placeholder for the answer and the buttons for
   **Got it** / **Missed** (self-scoring, matching quiz.py's y/n).
4. Summary: `Score: x/y (p%)`, plus **Review Missed (n)** when applicable.
   The missed set is persisted so it can be re-quizzed in a later session
   (**Review Missed Cards** menu entry).

Refresh strategy: state changes rebuild the dialog (full repaint per card),
which is the normal e-ink rhythm; the syncnotes-style sub-150ms throttle is
not needed because nothing repaints mid-animation.

### Dialog close semantics (verified against v2026.07 sources)

`UIManager:close(widget)` raises a distinct `CloseWidget` event and always
removes the widget — it never re-enters a widget's `onClose`. `onClose` is the
physical-Back handler. So buttons call `UIManager:close(dialog)` directly
(no double-prompt risk), while the dialog's `onClose` runs the quit-confirm
and leaves the card open beneath it (Cancel keeps the card intact).

## Discovery & persistence

* Root: `<koreader data>/notes` by default (the syncnotes download root),
  overridable via **Set Notes Folder**; stored in
  `<settings>/flashcards.lua` (`LuaSettings`).
* Recursive `lfs` walk; dot-directories skipped; theme = parent folder
  basename; duplicate names keep the last (deepest) file (desktop parity).
* Session (theme + score + missed cards) persisted under the same settings
  file; **Clear Quiz History** removes it.

## Testing

* `tests/flashcards_parser_spec.lua` — format parity, multi-line, edge cases.
* `tests/flashcards_quiz_spec.lua` — state machine: deterministic shuffle,
  scoring, percent rounding, early quit, `fromMissed` review.
* `tests/flashcards_cli_spec.lua` — runs the CLI `--auto` over the fixture
  corpus (`tests/fixtures/notes/`) and asserts the totals, an end-to-end check
  that the plugin's parser+engine work off-device.
* On-device: `./deploy.sh` copies the plugin; manual pass is the remaining
  verification (see the plugin README's install steps).
* Review & Audit: Verified against KOReader v2026.07 widget APIs on `/mnt/kobo/.adds/koreader/frontend/` and confirmed logger method call safety and `lfs.dir` iterator wrapping.

## Known gaps / deferred

* Card text is rendered as-is (no Markdown emphasis or LaTeX typesetting).
  Rendering notes is `markdownreader.koplugin`'s job; doing math here would
  duplicate that pipeline.
* `quiz.py` has no missed-card persistence; "Review Missed" is an extension
  (it stores only the missed cards, never file paths, so it survives edits to
  the notes).
* No spaced-repetition scheduling — deliberately out of scope for a first cut.
