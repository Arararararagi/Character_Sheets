# Character Sheet — KOReader Plugin

A self-contained KOReader plugin that brings advanced character management to
your EPUB / KEPUB books. Color-code every mention of a character, keep
per-character notes and aliases, bulk-rename characters throughout a book, and
port your character database between devices — all from KOReader's native menu.

> **Supported documents:** EPUB and KEPUB (CreDocument). PDFs and other formats
> show an "Unsupported document type" warning and the menu actions are disabled.

---

## Features

| Feature | Description |
| --- | --- |
| **Color-coded highlighting** | Search the entire book for every variant of a character's name and apply a colored highlight to each occurrence via KOReader's native annotation layer. |
| **Per-book character sheets** | Store a display name, multiple name variants (nicknames, full names), free-text notes, and a highlight color for each character. |
| **Variant management** | Add as many spelling/alias variants as you like; duplicates are automatically removed. |
| **Character renaming (alias replacement)** | Replace every occurrence of a character's name with a new one using `doc:replaceString`, with a confirmation dialog and a live progress bar. Highlights are re-applied afterwards. |
| **Import / Export** | Dump your character database to a JSON file, or load one back, with Merge or Overwrite options. |
| **Case-sensitivity toggle** | Choose case-insensitive (default) or case-sensitive name matching. |
| **Persistence** | All data is saved next to the book in `character_data.json` and reloaded automatically when you reopen the book. |
| **Safety** | Replacements warn that they are irreversible; highlight operations never duplicate annotations. |

---

## Installation

1. **Get the plugin file** — copy `character_sheet.lua` into KOReader's plugin
   directory on your device:

   ```
   /mnt/onboard/.adds/koreader/plugins/character_sheet.koplugin/character_sheet.lua
   ```

   (On Kobo the SD-card root mounted at `/mnt/onboard/` is usually the
   `koreader` folder. The exact path may vary by device — place the file inside
   any `.../plugins/<name>.koplugin/` folder.)

2. **Restart KOReader** (or tap *Menu → Gear icon → Plugins* if a hot-reload is
   available). The plugin loads automatically for EPUB/KEPUB documents.

3. **Verify** — open an EPUB/KEPUB book, open the top-menu gear, and look for
   the **Character Sheet** submenu.

> The plugin depends only on KOReader's standard libraries (`json`, `logger`,
> `util`, `lfs`) and native widgets, so no extra dependencies are required.

---

## How to Use

Open the **gear menu → Character Sheet**. You will find these entries:

### 1. Manage Characters
Opens a list of all characters for the current book.

- **Tap a character** to edit it:
  - **Variants / nicknames** — one per line or comma-separated. Used as search
    terms when highlighting.
  - **Notes** — free-text notes (opened via the *Notes* button).
  - **Color** — pick the highlight color via the color picker.
  - **Save** — persists changes and re-highlights the book with the new color.
  - **Delete** — removes the character and clears its highlights.
- **➕ Add new character** — create a character by typing its primary name.

### 2. Apply Color
Highlights **all** occurrences of every variant of the chosen character in the
book using the character's stored color. Use this after adding or editing a
character, or to re-apply color after the book is reopened.

### 3. Rename Character
Permanently renames a character throughout the book:

1. Pick a character from the list.
2. Type the new name.
3. A confirmation box shows the number of occurrences that will be replaced and
   warns that the operation is **not easily undone**.
4. On confirm, KOReader processes the replacements in batches of 50 (with a
   progress bar) and then re-applies the character's highlight color to the new
   text.

> **Tip:** Back up your book file before a large rename — `replaceString`
> modifies the document in the current session.

### 4. Import / Export
- **Export characters** — choose a destination folder (defaults to a
  `character_sheet` directory on the device storage) and write
  `character_data.json` there.
- **Import characters** — pick a `.json` file. After validation you choose:
  - **Merge** — add missing characters, keep existing ones.
  - **Overwrite** — replace the entire character database.

### 5. Case-sensitive matching (toggle)
Shows the current mode (`ON`/`OFF`). Tap to switch. When **OFF** (default),
name searches ignore letter case.

---

## Data Format

The plugin stores everything in `character_data.json` inside the book's
companion (holding) directory:

```json
{
  "book_hash": "md5_or_uuid",
  "settings": { "case_sensitive": false },
  "characters": {
    "main_id": {
      "id": "main_id",
      "display_name": "Gandalf",
      "variants": ["Gandalf", "Mithrandir", "The Grey"],
      "notes": "Free-text notes about the character",
      "color": "#FF4500",
      "aliases": { "Gandalf": "Gandalf the White" }
    }
  }
}
```

- `book_hash` prevents cross-book collisions if you copy the file around.
- `settings.case_sensitive` drives the matching toggle.
- Each character keyed by a normalized internal `id` (lowercased,
  non-alphanumeric stripped).

You can hand-edit this file and re-import it, or share it between copies of the
same book.

---

## Technical Notes

- **Memory safe:** the plugin never loads the whole book into memory. It relies
  exclusively on `doc:search()` and XPointer objects, so it works on large
  books and low-RAM devices (e.g. 256 MB Kobo).
- **Non-blocking UI:** all dialogs are shown via `UIManager:show()`; bulk
  replacements are chunked with `UIManager:scheduleIn` so the interface stays
  responsive.
- **Error handling:** every `doc` call is wrapped in `pcall` and failures are
  logged with `logger.warn`, so a missing API on a given KOReader build will not
  crash the reader.
- **Native annotations:** highlighting uses KOReader's built-in annotation
  overlay, not a custom renderer, keeping the experience consistent with the
  rest of the app.

---

## License

**GNU Affero General Public License v3.0 (AGPL-3.0)** — the same license used
by the KOReader project.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License along
with this program. If not, see <https://www.gnu.org/licenses/>.

### Provenance / disclosure

`character_sheet.lua` is **original work** written from a feature specification
against KOReader's public plugin API (`WidgetContainer`, `UIManager`,
`doc:search`, `doc:addHighlight`, `doc:replaceString`, the standard widget
classes, etc.). **No source code was copied** from any existing KOReader plugin
or third-party project.

Where KOReader's public API signatures differ across versions, calls are
wrapped in `pcall` and degrade gracefully rather than crashing. The code
follows KOReader's own AGPL-3.0 licensing and contribution standards.
