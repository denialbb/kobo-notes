# Context Map

## Contexts

- [Note Synchronization](./plugins/syncnotes.koplugin/CONTEXT.md) — fetches, diffs, and synchronizes remote Markdown notes from GitHub to the local filesystem.
- [Markdown & Math Rendering](./plugins/markdownreader.koplugin/CONTEXT.md) — intercepts Markdown note opens, extracts LaTeX math expressions, and renders HTML and SVG graphics for display.
- [Flashcard Study](./plugins/flashcards.koplugin/CONTEXT.md) — parses question-and-answer pairs from Markdown notes and manages interactive recall quiz sessions.

## Relationships

- **Note Synchronization → Markdown & Math Rendering**: Note Synchronization provisions and updates source Markdown files on the device filesystem consumed by Markdown & Math Rendering.
- **Note Synchronization → Flashcard Study**: Note Synchronization provisions and updates source Markdown files parsed by Flashcard Study for quiz generation.
- **Markdown & Math Rendering ↔ Flashcard Study**: Both contexts operate concurrently on the shared on-device note hierarchy without direct inter-plugin coupling.
