--[[
character_sheet.lua — KOReader plugin for advanced character management.

Provides:
  * Color-coded highlighting of every character name occurrence in EPUB/KEPUB.
  * Per-character sheets (variants, notes, color) persisted per-book in JSON.
  * Global alias / name replacement with confirmation + progress.
  * Import / Export of the character database via FileChooser.

Self-contained: only depends on KOReader's standard `libs` (json, logger, util,
lfs) and native widgets (UIManager, InputDialog, ButtonDialog, ColorPicker,
FileChooser, ConfirmBox, ProgressWidget, Menu).

Copyright (C) 2024 Character_Sheets contributors

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.

Provenance / disclosure:
  This file is original work written from a feature specification against
  KOReader's public plugin API (WidgetContainer, UIManager, doc:search,
  doc:addHighlight, doc:replaceString, etc.). No source code was copied from
  any existing KOReader plugin or third-party project. Where KOReader's public
  API signatures differ across versions, calls are wrapped in pcall and degrade
  gracefully. The implementation follows the same AGPL-3.0 licensing standard
  as the KOReader project.
--]]

local _meta = {
    name = "character_sheet",
    version = "1.0.0",
    author = "Arararararagi",
    description = "Advanced character management for EPUB/KEPUB: color-code name " ..
                  "occurrences, manage character sheets, rename aliases, import/export.",
}

-- ---------------------------------------------------------------------------
-- Imports (all standard KOReader libs / widgets)
-- ---------------------------------------------------------------------------
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ColorPicker = require("ui/widget/colorpicker")
local FileChooser = require("ui/widget/filechooser")
local ConfirmBox = require("ui/widget/confirmbox")
local ProgressWidget = require("ui/widget/progresswidget")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Device = require("device")
local json = require("json")
local logger = require("logger")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

local md5
pcall(function() md5 = require("ffi/sha2") end)

local Blitbuffer
pcall(function() Blitbuffer = require("ffi/blitbuffer") end)

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------
local CHARACTER_DATA_FILENAME = "character_data.json"
local BATCH_SIZE = 50
local SUPPORTED_DOC_TYPES = { ["cre"] = true } -- EPUB / KEPUB

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Convert a hex color string ("#RRGGBB") to a Blitbuffer color value when
-- possible, otherwise return the raw string (KOReader may accept it directly
-- in newer builds, or the highlight manager will degrade gracefully).
local function hexToColor(hex)
    if not hex then return nil end
    if Blitbuffer and Blitbuffer.ColorFromHex then
        local ok, c = pcall(Blitbuffer.ColorFromHex, hex)
        if ok and c then return c end
    end
    return hex
end

-- Split a multi-line / comma-separated string into a clean, de-duplicated list.
local function parseVariants(raw)
    local out = {}
    if not raw then return out end
    for raw_line in tostring(raw):gmatch("[^\r\n,]+") do
        local line = util.trim(raw_line)
        if line ~= "" then
            local dup = false
            for _, v in ipairs(out) do
                if v:lower() == line:lower() then dup = true break end
            end
            if not dup then out[#out + 1] = line end
        end
    end
    return out
end

-- Normalize a name into a stable internal id.
local function normalizeId(name)
    return tostring(name or ""):lower():gsub("%s+", "_"):gsub("[^%w_]", "")
end

-- Build a book hash from the holding path so data never collides across books.
local function computeBookHash(holding_path)
    local key = holding_path or tostring(os.time())
    if md5 then
        local ok, h = pcall(md5, key)
        if ok and h then return h end
    end
    return util.md5 and util.md5(key) or tostring(key):gsub("%W", "")
end

-- ---------------------------------------------------------------------------
-- CharacterDB — persistence layer (JSON in the book's holding directory)
-- ---------------------------------------------------------------------------
local CharacterDB = {}

function CharacterDB:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.characters = o.characters or {}
    o.settings = o.settings or { case_sensitive = false }
    o.book_hash = o.book_hash or nil
    o.data_path = o.data_path or nil
    return o
end

function CharacterDB:setPath(holding_path)
    if holding_path and lfs.attributes(holding_path, "mode") == "directory" then
        self.data_path = util.pathJoin(holding_path, CHARACTER_DATA_FILENAME)
    elseif holding_path then
        -- holding_path might already be a file-like dir; fallback to join anyway
        self.data_path = util.pathJoin(holding_path, CHARACTER_DATA_FILENAME)
    end
    self.book_hash = computeBookHash(holding_path)
end

function CharacterDB:load()
    if not self.data_path then return false end
    local file = io.open(self.data_path, "r")
    if not file then
        logger.info("[CharacterSheet] No existing data file at", self.data_path)
        return false
    end
    local ok, content = pcall(file.read, file)
    file:close()
    if not ok or not content then
        logger.warn("[CharacterSheet] Failed reading data file")
        return false
    end
    local decoded = json.decode(content)
    if decoded and type(decoded) == "table" then
        self.characters = decoded.characters or {}
        self.settings = decoded.settings or { case_sensitive = false }
        self.book_hash = decoded.book_hash or self.book_hash
        logger.info("[CharacterSheet] Loaded", self:count(), "characters")
        return true
    end
    logger.warn("[CharacterSheet] Corrupt data file, starting fresh")
    return false
end

function CharacterDB:save()
    if not self.data_path then
        logger.warn("[CharacterSheet] No data path set; cannot save")
        return false
    end
    local payload = {
        book_hash = self.book_hash,
        settings = self.settings,
        characters = self.characters,
    }
    local encoded = json.encode(payload)
    local file, err = io.open(self.data_path, "w")
    if not file then
        logger.warn("[CharacterSheet] Cannot open for write:", err)
        return false
    end
    local ok, werr = pcall(file.write, file, encoded)
    file:close()
    if not ok then
        logger.warn("[CharacterSheet] Write failed:", werr)
        return false
    end
    logger.info("[CharacterSheet] Saved data to", self.data_path)
    return true
end

function CharacterDB:count()
    local n = 0
    for _ in pairs(self.characters) do n = n + 1 end
    return n
end

function CharacterDB:get(id)
    return self.characters[id]
end

function CharacterDB:getAll()
    local list = {}
    for id, data in pairs(self.characters) do
        list[#list + 1] = { id = id, data = data }
    end
    table.sort(list, function(a, b)
        return (a.data.display_name or ""):lower() < (b.data.display_name or ""):lower()
    end)
    return list
end

-- Create or update a character. `data` may contain display_name, variants,
-- notes, color, aliases. Returns the character id.
function CharacterDB:upsert(id, data)
    id = id or normalizeId(data.display_name)
    if id == "" then return nil end
    local existing = self.characters[id] or {}
    existing.id = id
    existing.display_name = data.display_name or existing.display_name or id
    existing.variants = data.variants or existing.variants or { existing.display_name }
    existing.notes = data.notes or existing.notes or ""
    existing.color = data.color or existing.color or "#FF4500"
    existing.aliases = data.aliases or existing.aliases or {}
    self.characters[id] = existing
    return id
end

function CharacterDB:remove(id)
    self.characters[id] = nil
end

function CharacterDB:setSetting(key, value)
    self.settings[key] = value
end

function CharacterDB:isCaseSensitive()
    return self.settings.case_sensitive == true
end

-- ---------------------------------------------------------------------------
-- HighlightManager — search + highlight / clear using doc + XPointers
-- ---------------------------------------------------------------------------
local HighlightManager = {}

function HighlightManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.doc = o.doc
    o.db = o.db
    o.ui = o.ui
    return o
end

-- Search the whole book for `pattern`. Returns an array of
-- { page = n, pos0 = xp, pos1 = xp } tables. Case sensitivity from DB.
function HighlightManager:findOccurrences(pattern)
    local doc = self.doc
    if not doc or not pattern or pattern == "" then return {} end
    local results = {}
    local ok, res = pcall(function()
        return doc:search(pattern, 0, doc:getPageCount(), not self.db:isCaseSensitive())
    end)
    if not ok then
        logger.warn("[CharacterSheet] doc:search failed:", res)
        return results
    end
    if type(res) == "table" then
        for _, m in ipairs(res) do
            -- Normalize the result shape across KOReader versions.
            local pos0, pos1, page = m.pos0 or m.xp, m.pos1 or m.xp, m.page
            if pos0 then
                results[#results + 1] = { page = page, pos0 = pos0, pos1 = pos1 or pos0 }
            end
        end
    end
    return results
end

-- Apply (or update) a colored highlight for a single match.
function HighlightManager:highlightMatch(match, color, note)
    local doc = self.doc
    if not doc or not match or not match.pos0 then return false end
    local c = hexToColor(color)
    -- Best-effort de-duplication: remove any existing highlight at this span.
    pcall(function() doc:deleteHighlight(match.pos0) end)
    local ok, err = pcall(function()
        doc:addHighlight(match.pos0, match.pos1, c)
    end)
    if ok then
        -- Attempt to tag the highlight with our note/title for later filtering.
        if type(doc.setHighlightNote) == "function" then
            pcall(doc.setHighlightNote, doc, match.pos0, note or "")
        end
        return true
    else
        logger.warn("[CharacterSheet] addHighlight failed:", err)
        return false
    end
end

-- Apply highlights for every variant of a character.
function HighlightManager:applyCharacter(char)
    if not char then return 0 end
    local count = 0
    for _, variant in ipairs(char.variants or {}) do
        local matches = self:findOccurrences(variant)
        for _, m in ipairs(matches) do
            if self:highlightMatch(m, char.color, char.display_name) then
                count = count + 1
            end
        end
    end
    self:refresh()
    return count
end

-- Clear highlights that belong to a character by re-searching its variants
-- and removing the highlight spans.
function HighlightManager:clearCharacter(char)
    if not char then return 0 end
    local count = 0
    for _, variant in ipairs(char.variants or {}) do
        local matches = self:findOccurrences(variant)
        for _, m in ipairs(matches) do
            local ok = pcall(function() self.doc:deleteHighlight(m.pos0) end)
            if ok then count = count + 1 end
        end
    end
    self:refresh()
    return count
end

-- Refresh the current page so highlights show up.
function HighlightManager:refresh()
    if self.ui and self.ui.handleEvent then
        self.ui:handleEvent(Event:new("RefreshPage"))
    else
        UIManager:setDirty(nil, "partial")
    end
end

-- ---------------------------------------------------------------------------
-- TextReplacer — global alias / name replacement with progress + safety
-- ---------------------------------------------------------------------------
local TextReplacer = {}

function TextReplacer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.doc = o.doc
    o.db = o.db
    o.ui = o.ui
    o.hm = o.hm -- HighlightManager (optional)
    return o
end

function TextReplacer:count(pattern)
    local hm = self.hm or HighlightManager:new{ doc = self.doc, db = self.db }
    return #hm:findOccurrences(pattern)
end

-- Replace all occurrences of `pattern` with `new_text`.
-- on_done(total) is called when finished (or aborted).
function TextReplacer:replaceAll(pattern, new_text, on_done)
    if not pattern or pattern == "" then
        if on_done then on_done(0) end
        return
    end
    local hm = self.hm or HighlightManager:new{ doc = self.doc, db = self.db }
    local matches = hm:findOccurrences(pattern)
    local total = #matches
    if total == 0 then
        if on_done then on_done(0) end
        return
    end

    -- Progress widget
    local progress
    if self.ui then
        progress = ProgressWidget:new{
            width = math.floor(Screen:getWidth() * 0.8),
            height = 20,
            percentage = 0,
            text = "Replacing… 0/" .. total,
        }
        UIManager:show(progress)
    end

    -- Process in batches to keep the UI responsive on low-RAM devices.
    local i = 0
    local function step()
        local batch_end = math.min(i + BATCH_SIZE, total)
        for k = i + 1, batch_end do
            local m = matches[k]
            pcall(function()
                -- replaceString consumes the span and returns a new xpointer;
                -- KOReader's replaceString(pos0, pos1, text) is irreversible.
                self.doc:replaceString(m.pos0, m.pos1, new_text)
            end)
        end
        i = batch_end
        if progress then
            progress:setPercentage(i / total)
            progress:setText(string.format("Replacing… %d/%d", i, total))
            UIManager:setDirty(progress, "ui")
        end
        if i < total then
            UIManager:scheduleIn(0.01, step)
        else
            if progress then UIManager:close(progress) end
            if self.ui then
                self.ui:handleEvent(Event:new("RefreshPage"))
            end
            if on_done then on_done(total) end
        end
    end
    step()
end

-- ---------------------------------------------------------------------------
-- ReaderCharacterSheet — main ReaderPlugin
-- ---------------------------------------------------------------------------
local ReaderCharacterSheet = WidgetContainer:new{
    name = "character_sheet",
    is_doc_supported = false,
}

function ReaderCharacterSheet:init()
    self.db = CharacterDB:new{}
    self.hm = nil
    self.replacer = nil

    -- Document type guard: only CreDocument (EPUB/KEPUB) is supported.
    local doc_type = self.document and self.document:getDocumentType()
    if doc_type and SUPPORTED_DOC_TYPES[doc_type] then
        self.is_doc_supported = true
    elseif self.document and self.document.getDocumentType then
        -- CreDocument reports "cre"
        self.is_doc_supported = (self.document:getDocumentType() == "cre")
    else
        self.is_doc_supported = false
    end

    if self.is_doc_supported and self.document then
        local holding = self.document:getDocumentHoldingPath()
        self.db:setPath(holding)
        self.db:load()
        self.hm = HighlightManager:new{ doc = self.document, db = self.db, ui = self.ui }
        self.replacer = TextReplacer:new{ doc = self.document, db = self.db, ui = self.ui, hm = self.hm }
    end

    -- Reload data when the book is ready.
    self:registerEvents()
end

function ReaderCharacterSheet:registerEvents()
    if not self.ui or not self.ui.handleEvent then return end
    -- Hook into readerready to (re)load in case init ran early.
    self.onReaderReady = function()
        if self.is_doc_supported and self.document then
            local holding = self.document:getDocumentHoldingPath()
            self.db:setPath(holding)
            self.db:load()
            self.hm = HighlightManager:new{ doc = self.document, db = self.db, ui = self.ui }
            self.replacer = TextReplacer:new{ doc = self.document, db = self.db, ui = self.ui, hm = self.hm }
        end
    end
end

-- Warn on unsupported documents.
function ReaderCharacterSheet:ensureSupported()
    if not self.is_doc_supported then
        UIManager:show(ConfirmBox:new{
            text = "Unsupported document type.\nThis plugin only works with EPUB/KEPUB books.",
            ok_text = "OK",
            ok_callback = function() end,
        })
        return false
    end
    return true
end

function ReaderCharacterSheet:addToMainMenu(menu_items)
    menu_items.character_sheet = {
        text = "Character Sheet",
        sub_item_table = {
            {
                text = "Manage Characters",
                callback = function()
                    if self:ensureSupported() then self:showCharacterManager() end
                end,
            },
            {
                text = "Apply Color",
                callback = function()
                    if self:ensureSupported() then self:showApplyColorMenu() end
                end,
            },
            {
                text = "Rename Character",
                callback = function()
                    if self:ensureSupported() then self:showRenameMenu() end
                end,
            },
            {
                text = "Import / Export",
                sub_item_table = {
                    {
                        text = "Export characters",
                        callback = function()
                            if self:ensureSupported() then self:showExport() end
                        end,
                    },
                    {
                        text = "Import characters",
                        callback = function()
                            if self:ensureSupported() then self:showImport() end
                        end,
                    },
                },
            },
            {
                text_func = function()
                    return "Case-sensitive matching: " ..
                        (self.db:isCaseSensitive() and "ON" or "OFF")
                end,
                callback = function()
                    self.db:setSetting("case_sensitive", not self.db:isCaseSensitive())
                    self.db:save()
                end,
                hold_callback = function()
                    self.db:setSetting("case_sensitive", not self.db:isCaseSensitive())
                    self.db:save()
                    return true
                end,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- UI: Character Manager
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showCharacterManager()
    local items = {}
    local chars = self.db:getAll()
    for _, entry in ipairs(chars) do
        local c = entry.data
        items[#items + 1] = {
            text = c.display_name,
            mandatory = tostring(#(c.variants or {})),
            callback = function() self:showCharacterEditor(entry.id) end,
        }
    end
    items[#items + 1] = {
        text = "➕ Add new character",
        callback = function() self:showAddCharacter() end,
    }

    local menu = Menu:new{
        title = "Character Manager",
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function ReaderCharacterSheet:showAddCharacter()
    local dialog
    dialog = InputDialog:new{
        title = "New Character",
        input = "",
        input_hint = "Primary name (e.g. Gandalf)",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Create",
                    callback = function()
                        local name = util.trim(dialog:getInputText() or "")
                        UIManager:close(dialog)
                        if name == "" then return end
                        local id = self.db:upsert(nil, {
                            display_name = name,
                            variants = { name },
                            notes = "",
                            color = "#FF4500",
                        })
                        self.db:save()
                        self:showCharacterEditor(id)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ReaderCharacterSheet:showCharacterEditor(id)
    local char = self.db:get(id)
    if not char then return end

    local variants_text = table.concat(char.variants or {}, "\n")
    local notes_text = char.notes or ""

    local function rebuildEditor()
        local d
        d = InputDialog:new{
            title = char.display_name,
            input = variants_text,
            input_hint = "Variants / nicknames (one per line or comma separated)",
            input_type = "multiline",
            description = "Notes:",
            -- notes field is added below via a second dialog; keep it simple here.
            buttons = {
                {
                    {
                        text = "Cancel",
                        callback = function() UIManager:close(d) end,
                    },
                    {
                        text = "Color",
                        callback = function()
                            UIManager:close(d)
                            self:showColorPicker(id, function()
                                char = self.db:get(id)
                                rebuildEditor()
                            end)
                        end,
                    },
                    {
                        text = "Notes",
                        callback = function()
                            UIManager:close(d)
                            self:showNotesEditor(id, function()
                                char = self.db:get(id)
                                variants_text = table.concat(char.variants or {}, "\n")
                                rebuildEditor()
                            end)
                        end,
                    },
                    {
                        text = "Save",
                        callback = function()
                            local v = parseVariants(d:getInputText())
                            if #v == 0 then v = { char.display_name } end
                            char.variants = v
                            self.db:upsert(id, char)
                            self.db:save()
                            UIManager:close(d)
                            -- Re-apply highlights with the (possibly new) color.
                            self.hm:applyCharacter(self.db:get(id))
                        end,
                    },
                    {
                        text = "Delete",
                        callback = function()
                            UIManager:close(d)
                            self:confirmDelete(id)
                        end,
                    },
                },
            },
        }
        UIManager:show(d)
    end
    rebuildEditor()
end

function ReaderCharacterSheet:showNotesEditor(id, on_close)
    local char = self.db:get(id)
    local d = InputDialog:new{
        title = "Notes — " .. (char.display_name or ""),
        input = char.notes or "",
        input_type = "multiline",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function() UIManager:close(d) end,
                },
                {
                    text = "Save",
                    callback = function()
                        char.notes = d:getInputText() or ""
                        self.db:upsert(id, char)
                        self.db:save()
                        UIManager:close(d)
                        if on_close then on_close() end
                    end,
                },
            },
        },
    }
    UIManager:show(d)
end

function ReaderCharacterSheet:confirmDelete(id)
    local char = self.db:get(id)
    UIManager:show(ConfirmBox:new{
        text = "Delete character '" .. (char and char.display_name or id) ..
            "' and clear its highlights?",
        ok_text = "Delete",
        ok_callback = function()
            self.hm:clearCharacter(char)
            self.db:remove(id)
            self.db:save()
        end,
    })
end

-- ---------------------------------------------------------------------------
-- UI: Color picker
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showColorPicker(id, on_close)
    local char = self.db:get(id)
    local picker = ColorPicker:new{
        title = "Pick color for " .. (char and char.display_name or ""),
        old_color = char and char.color or "#FF4500",
        callback = function(color)
            char.color = color
            self.db:upsert(id, char)
            self.db:save()
            self.hm:applyCharacter(self.db:get(id))
            if on_close then on_close() end
        end,
    }
    UIManager:show(picker)
end

-- ---------------------------------------------------------------------------
-- UI: Apply color to a chosen character (re-highlight all occurrences)
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showApplyColorMenu()
    local chars = self.db:getAll()
    if #chars == 0 then
        UIManager:show(ConfirmBox:new{
            text = "No characters yet. Add one from Character Manager first.",
            ok_text = "OK", ok_callback = function() end,
        })
        return
    end
    local items = {}
    for _, entry in ipairs(chars) do
        items[#items + 1] = {
            text = entry.data.display_name,
            callback = function()
                local n = self.hm:applyCharacter(entry.data)
                UIManager:show(ConfirmBox:new{
                    text = "Highlighted " .. n .. " occurrence(s) of " ..
                        entry.data.display_name .. ".",
                    ok_text = "OK", ok_callback = function() end,
                })
            end,
        }
    end
    local menu = Menu:new{
        title = "Apply Color",
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- UI: Rename / replace text (global alias)
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showRenameMenu()
    local chars = self.db:getAll()
    if #chars == 0 then
        UIManager:show(ConfirmBox:new{
            text = "No characters to rename.",
            ok_text = "OK", ok_callback = function() end,
        })
        return
    end
    local items = {}
    for _, entry in ipairs(chars) do
        items[#items + 1] = {
            text = entry.data.display_name,
            callback = function() self:showRenameDialog(entry.id) end,
        }
    end
    local menu = Menu:new{
        title = "Rename Character",
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
    }
    UIManager:show(menu)
end

function ReaderCharacterSheet:showRenameDialog(id)
    local char = self.db:get(id)
    local d = InputDialog:new{
        title = "Rename '" .. char.display_name .. "'",
        input = "",
        input_hint = "New name for all occurrences",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function() UIManager:close(d) end,
                },
                {
                    text = "Replace",
                    callback = function()
                        local new_name = util.trim(d:getInputText() or "")
                        UIManager:close(d)
                        if new_name == "" then return end
                        self:doReplace(char, new_name)
                    end,
                },
            },
        },
    }
    UIManager:show(d)
end

-- Replace all occurrences of the character's first variant with new_name.
function ReaderCharacterSheet:doReplace(char, new_name)
    local pattern = (char.variants and char.variants[1]) or char.display_name
    local total = self.replacer:count(pattern)
    if total == 0 then
        UIManager:show(ConfirmBox:new{
            text = "No occurrences of '" .. pattern .. "' found.",
            ok_text = "OK", ok_callback = function() end,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = "Replace " .. total .. " instance(s) of '" .. pattern ..
            "' with '" .. new_name .. "'?\n\nThis uses KOReader's replaceString " ..
            "and is NOT easily undone. Back up your book first!",
        ok_text = "Replace",
        ok_callback = function()
            -- Update the variant list so future highlighting uses the new name.
            if char.variants and char.variants[1] then
                char.variants[1] = new_name
            else
                char.variants = { new_name }
            end
            if char.display_name == pattern then
                char.display_name = new_name
            end
            self.db:upsert(char.id, char)
            self.db:save()

            self.replacer:replaceAll(pattern, new_name, function(done)
                -- Re-apply the character's color to the new text.
                self.hm:applyCharacter(self.db:get(char.id))
                UIManager:show(ConfirmBox:new{
                    text = "Replaced " .. done .. " occurrence(s)." ..
                        "\nHighlights refreshed with character color.",
                    ok_text = "OK", ok_callback = function() end,
                })
            end)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- UI: Import / Export
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showExport()
    local default_dir = "/mnt/onboard/" .. (_meta.name or "character_sheet")
    lfs.mkdir(default_dir)
    local chooser = FileChooser:new{
        title = "Export character data to…",
        path = default_dir,
        select_directory = true,
        show_files = false,
        callback = function(path)
            local dest = util.pathJoin(path, CHARACTER_DATA_FILENAME)
            local file = io.open(dest, "w")
            if file then
                local payload = {
                    book_hash = self.db.book_hash,
                    settings = self.db.settings,
                    characters = self.db.characters,
                }
                file:write(json.encode(payload))
                file:close()
                UIManager:show(ConfirmBox:new{
                    text = "Exported to " .. dest,
                    ok_text = "OK", ok_callback = function() end,
                })
            else
                logger.warn("[CharacterSheet] Export failed:", dest)
            end
        end,
    }
    UIManager:show(chooser)
end

function ReaderCharacterSheet:showImport()
    local chooser = FileChooser:new{
        title = "Import character data",
        path = "/mnt/onboard/",
        file_filter = function(file) return file:match("%.json$") end,
        callback = function(file)
            local f = io.open(file, "r")
            if not f then
                logger.warn("[CharacterSheet] Cannot open import file")
                return
            end
            local content = f:read("*a")
            f:close()
            local ok, data = pcall(json.decode, content)
            if not ok or type(data) ~= "table" or type(data.characters) ~= "table" then
                UIManager:show(ConfirmBox:new{
                    text = "Invalid character data file.",
                    ok_text = "OK", ok_callback = function() end,
                })
                return
            end
            -- Offer Merge vs Overwrite
            UIManager:show(ButtonDialog:new{
                title = "Import mode",
                text = "Merge (keep existing, add missing) or Overwrite completely?",
                buttons = {
                    {
                        {
                            text = "Merge",
                            callback = function()
                                for id, c in pairs(data.characters) do
                                    if not self.db:get(id) then
                                        self.db:upsert(id, c)
                                    end
                                end
                                self.db:save()
                                self:refreshAllHighlights()
                            end,
                        },
                        {
                            text = "Overwrite",
                            callback = function()
                                self.db.characters = data.characters
                                if data.settings then
                                    self.db.settings = data.settings
                                end
                                self.db:save()
                                self:refreshAllHighlights()
                            end,
                        },
                    },
                },
            })
        end,
    }
    UIManager:show(chooser)
end

function ReaderCharacterSheet:refreshAllHighlights()
    local chars = self.db:getAll()
    for _, entry in ipairs(chars) do
        self.hm:applyCharacter(entry.data)
    end
end

return ReaderCharacterSheet