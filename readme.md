# Character Sheet — KOReader Plugin

A self-contained KOReader plugin for advanced character management in your
EPUB / KEPUB books. Color-code every mention of a character, keep per-character
notes/aliases/relationships, tap a name on the page to see its sheet, bulk-rename
characters, link characters across a series, export a "character bible", and
port your database between devices — all from KOReader's native menu.

> **Supported documents:** EPUB and KEPUB (CreDocument). PDFs and other formats
> show an "Unsupported document type" notice and the actions are disabled.

---

## Features

| Feature | Description |
| --- | --- |
| **Color-coded highlighting** | Search the whole book for every variant/alias of a character's name and apply a colored highlight via KOReader's native annotation layer. |
| **On-page name underlining + tap-to-detail** | Draws an underscore under each character name as you read; tapping a name opens that character's sheet (uses a view module + tap zone, indexed in a subprocess for speed). |
| **Per-character sheets** | Display name, multiple name variants/aliases, multiple free-text notes, a highlight color, a **role**, and **typed relationships**. |
| **Roles** | Main / Secondary / Tertiary / Mentioned / Antagonist / Narrator. |
| **Relationships** | Link characters with typed relations (family, social, custom) shown in the detail view. |
| **Appearance statistics** | Per character: total mentions, first-appearance page, and mentions on the current page. |
| **Jump to mention** | From a character's sheet, jump to the next (or first) occurrence in the book. |
| **Alias / variant management** | Add as many spelling variants as you like; duplicates and cross-character collisions are prevented. |
| **Selection → character** | Select text, open the highlight dialog, and assign it to an existing character or create a new one. |
| **Character renaming (alias replacement)** | Replace every occurrence of a name with a new one via `doc:replaceString`, with confirmation and a live progress bar; highlights are re-applied afterwards. |
| **Series linking** | Share characters across books in a series via a series file in DataStorage. |
| **Import / Export** | Dump the character database (JSON) or a **glossary** (Markdown/CSV) to a chosen folder; import with Merge or Overwrite. |
| **Case-sensitivity toggle** | Case-insensitive (default) or case-sensitive matching. |
| **Underline toggle** | Turn the on-page underlining on/off (persisted per book). |
| **Dispatcher action** | `character_sheet_show` can be bound to a gesture/shortcut. |
| **Persistence** | All data is saved next to the book in `character_data.json` and reloaded automatically. |

> **Note:** A star-rating feature (present in some similar plugins) was
> deliberately **not** included.

---

## Installation

KOReader loads plugins from folders whose name ends in `.koplugin`. This
repository already provides the correct layout:

```
CharacterSheets.koplugin/
├── _meta.lua      # plugin metadata (name, version, author, description)
└── main.lua       # the plugin entry point (returns the ReaderCharacterSheet module)
```

1. Copy the entire **`CharacterSheets.koplugin/`** folder into KOReader's plugin
   directory on your device:

   ```
   /mnt/onboard/.adds/koreader/plugins/CharacterSheets.koplugin/
   ```

   (The exact base path varies by device — e.g. `/koreader/plugins/` on some
   installs. The folder name **must** keep the `.koplugin` suffix.)

2. Restart KOReader (or use *Menu → Gear → Plugins* if hot-reload is available).
   The plugin loads automatically for EPUB/KEPUB documents.

3. Open an EPUB/KEPUB book, open the top-menu gear, and look for **Character Sheet**.

> Only KOReader's standard libraries (`json`, `logger`, `util`, `lfs`,
> `datastorage`) and native widgets are used — no extra dependencies. The
> `_meta.lua` metadata follows the canonical KOReader plugin convention
> (see the official `coverbrowser.koplugin` for a reference layout).

---

## How to Use

Open **gear menu → Character Sheet**.

### Manage Characters
Lists all characters (with role shown). Tap one to open its **detail sheet**
(stats, relationships, notes, and action buttons: Edit, Relations, Jump, Delete).
Tap **➕ Add new character** to create one.

### Apply Color
Highlights all occurrences of every variant/alias of the chosen character using
its stored color.

### Rename Character
Permanently renames a character throughout the book: pick → type new name →
confirm (shows occurrence count, warns it is irreversible) → batched replacement
with progress bar → highlights re-applied.

### Underline names (toggle)
Turns the on-page underlining on/off. When on, character names are underlined
and tappable.

### Series linking
Link the current book to a series (by name). Characters are merged from / saved
to a shared series file so they carry across books in the series.

### Import / Export
- **Export** submenu:
  - *Character data (JSON)* — full database.
  - *Glossary (Markdown)* / *Glossary (CSV)* — a "character bible" (name, role,
    relationships, notes) you can read or import into other tools.
  - Pick any folder (e.g. a cloud-sync directory) as the destination.
- **Import** — pick a `.json` file; choose **Merge** (add missing) or
  **Overwrite** (replace all).

### Case-sensitive matching (toggle)
Switches case-insensitive / case-sensitive name search.

### Quick assignment from reading
Select text → highlight it → tap **Character** in the highlight dialog → choose
an existing character to add the selection as a name, or create a new character.

### Gestures / shortcuts
Bind the **Character Sheet: show characters** dispatcher action to a gesture or
physical key in KOReader's Dispatcher settings.

---

## Data Format

Stored in `character_data.json` inside the book's companion (holding) directory:

```json
{
  "book_hash": "md5_or_uuid",
  "settings": { "case_sensitive": false, "underline": false },
  "series_name": "The Lord of the Rings",
  "characters": {
    "gandalf": {
      "id": "gandalf",
      "display_name": "Gandalf",
      "variants": ["Gandalf", "Mithrandir", "The Grey"],
      "aliases": ["Gandalf the White"],
      "notes": ["Appears at the birthday party.", "Mentor to Frodo."],
      "color": "#FF4500",
      "role": "main",
      "relationships": [
        { "type": "mentor", "target": "frodo" }
      ]
    }
  }
}
```

- `book_hash` prevents cross-book collisions.
- `settings.case_sensitive` / `settings.underline` drive the toggles.
- `series_name` links the book to a shared series file.
- Each character is keyed by a normalized internal `id`.

You can hand-edit this file and re-import it, or share it between copies of the
same book.

---

## Technical Notes

- **Memory safe:** never loads the whole book into memory; relies on
  `doc:search` / `doc:findAllText` and XPointer objects.
- **Non-blocking UI:** dialogs use `UIManager:show()`; bulk replacements are
  chunked; name indexing runs in a `Trapper` subprocess so the UI stays
  responsive.
- **Error handling:** every `doc`/view call is wrapped in `pcall` and failures
  are logged with `logger.warn`, so missing APIs on a given KOReader build will
  not crash the reader.
- **Native annotations & rendering:** highlighting uses KOReader's built-in
  annotation overlay; on-page underlines use the view-module paint hook.
- **i18n:** user-facing strings use `gettext` (`_()`), ready for translations.

---

## Provenance / Inspiration & License

This plugin is **original work** written against KOReader's public plugin API.
While developing it, we took *inspiration* from:

- **[Shac0x/charactertracker.koplugin](https://github.com/Shac0x/charactertracker.koplugin)**
  — for the ideas of on-page name underlining + tap-to-detail, typed
  relationships, roles, multiple notes, alias dedupe, highlight-dialog
  integration, series/book linking, dispatcher actions, and per-book
  `doc_settings` preferences.
- **KOReader community requests** (Vocabulary Builder export, Statistics /
  quantified reading, Series tracking, annotation / cloud sync, dictionary &
  selection integration) — which informed the glossary export, appearance
  statistics, jump-to-mention, and sync-friendly export.

No source code was copied verbatim. The star-rating feature from the reference
was deliberately excluded. Where KOReader's public API differs across versions,
calls are wrapped in `pcall` and degrade gracefully.

**License:** GNU Affero General Public License v3.0 (AGPL-3.0) — the same
license used by KOReader. See the license header in
`CharacterSheets.koplugin/main.lua` for the full text. Contributions welcome.
