--[[
CharacterSheets.koplugin/main.lua — KOReader plugin for advanced character management.

Provides:
  * Color-coded highlighting of every character name occurrence in EPUB/KEPUB.
  * On-page name underlining + tap-to-detail (view module + tap zone).
  * Per-character sheets: variants, aliases, multiple notes, color, role,
    typed relationships, and appearance statistics.
  * Global alias / name replacement with confirmation + progress.
  * Series/book linking so characters are shared across a series.
  * Glossary export (Markdown/CSV) and cloud/sync-friendly data export.
  * Jump-to-mention navigation and a dispatcher action for quick access.
  * Import / Export of the character database via FileChooser.

Self-contained: only depends on KOReader's standard `libs` (json, logger, util,
lfs, datastorage) and native widgets.

Copyright (C) 2024 Arararararagi

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
  KOReader's public plugin API. No source code was copied verbatim from any
  existing project. It was iteratively improved taking *inspiration* from:
    - Shac0x/charactertracker.koplugin (on-page name underlining + tap-to-
      detail view module, typed relationships, roles, multiple notes, alias
      dedupe, highlight-dialog integration, series/book linking, dispatcher
      actions, doc_settings preferences).
    - Community feature requests for KOReader (Vocabulary Builder export,
      Statistics/quantified reading, Series tracking, annotation/cloud sync,
      dictionary/selection integration) which informed the glossary export,
      appearance statistics, jump-to-mention, and sync-friendly export.
  The star-rating feature from the reference was deliberately EXCLUDED.
  Where KOReader's public API signatures differ across versions, calls are
  wrapped in pcall and degrade gracefully. Licensed under AGPL-3.0 like
  KOReader itself.
--]]

local Event = require("ui/event")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local FileChooser = require("ui/widget/filechooser")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Device = require("device")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Trapper = require("ui/trapper")
local json = require("json")
local logger = require("logger")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template
local _ = require("gettext")

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

-- Preset highlight colors (KOReader has no built-in ColorPicker widget).
local PRESET_COLORS = {
    "#FF4500", "#FF8C00", "#FFD700", "#32CD32", "#1E90FF",
    "#9370DB", "#FF69B4", "#DC143C", "#00CED1", "#8B4513",
}

-- Role definitions (star rating intentionally excluded).
local ROLES = {
    { key = "",           label = _("Not set") },
    { key = "main",       label = _("Main") },
    { key = "secondary",  label = _("Secondary") },
    { key = "tertiary",   label = _("Tertiary") },
    { key = "mentioned",  label = _("Mentioned") },
    { key = "antagonist", label = _("Antagonist") },
    { key = "narrator",   label = _("Narrator") },
}

local function getRoleLabel(role_key)
    for _i, r in ipairs(ROLES) do
        if r.key == (role_key or "") then return r.label end
    end
    return _("Not set")
end

-- Relationship type definitions.
local RELATIONSHIP_TYPES = {
    { key = "father",   label = _("Father"),   category = "family" },
    { key = "mother",   label = _("Mother"),   category = "family" },
    { key = "son",      label = _("Son"),      category = "family" },
    { key = "daughter", label = _("Daughter"), category = "family" },
    { key = "brother",  label = _("Brother"),  category = "family" },
    { key = "sister",   label = _("Sister"),   category = "family" },
    { key = "spouse",   label = _("Spouse"),   category = "family" },
    { key = "ally",     label = _("Ally"),     category = "social" },
    { key = "enemy",    label = _("Enemy"),    category = "social" },
    { key = "friend",   label = _("Friend"),   category = "social" },
    { key = "mentor",   label = _("Mentor"),   category = "social" },
    { key = "servant",  label = _("Servant"),  category = "social" },
    { key = "master",   label = _("Master"),   category = "social" },
    { key = "lover",    label = _("Lover"),    category = "social" },
    { key = "custom",   label = _("Custom…"),  category = "other" },
}

local function getRelationshipLabel(type_key)
    for _i, rt in ipairs(RELATIONSHIP_TYPES) do
        if rt.key == type_key then return rt.label end
    end
    return type_key or _("Unknown")
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

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
        local line = trim(raw_line)
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

local function normalizeId(name)
    return tostring(name or ""):lower():gsub("%s+", "_"):gsub("[^%w_]", "")
end

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
    o.series_name = o.series_name or nil
    return o
end

function CharacterDB:setPath(holding_path)
    if holding_path and lfs.attributes(holding_path, "mode") == "directory" then
        self.data_path = util.pathJoin(holding_path, CHARACTER_DATA_FILENAME)
    elseif holding_path then
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
        self.series_name = decoded.series_name or nil
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
        series_name = self.series_name,
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

-- Create or update a character.
function CharacterDB:upsert(id, data)
    id = id or normalizeId(data.display_name)
    if id == "" then return nil end
    local existing = self.characters[id] or {}
    existing.id = id
    existing.display_name = data.display_name or existing.display_name or id
    existing.variants = data.variants or existing.variants or { existing.display_name }
    existing.aliases = data.aliases or existing.aliases or {}
    existing.notes = data.notes or existing.notes or {}
    existing.color = data.color or existing.color or "#FF4500"
    existing.role = data.role or existing.role or ""
    existing.relationships = data.relationships or existing.relationships or {}
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

-- Check if a name/alias is already used by another character.
function CharacterDB:isNameOrAliasTaken(text, exclude_id)
    local text_lower = (text or ""):lower()
    if text_lower == "" then return nil end
    for id, char in pairs(self.characters) do
        if id ~= exclude_id then
            if (char.display_name or ""):lower() == text_lower then
                return char.display_name
            end
            if char.aliases then
                for _, alias in ipairs(char.aliases) do
                    if alias:lower() == text_lower then
                        return char.display_name
                    end
                end
            end
            if char.variants then
                for _, v in ipairs(char.variants) do
                    if v:lower() == text_lower then
                        return char.display_name
                    end
                end
            end
        end
    end
    return nil
end

-- Series support: shared characters live in DataStorage.
function CharacterDB:getSeriesDir()
    local dir = DataStorage:getDataDir() .. "/character_sheet/series"
    lfs.mkdir(dir)
    return dir
end

function CharacterDB:getSeriesPath(name)
    return util.pathJoin(self:getSeriesDir(), (name or "default") .. ".json")
end

function CharacterDB:saveSeries(name)
    name = name or self.series_name
    if not name then return false end
    local path = self:getSeriesPath(name)
    local file = io.open(path, "w")
    if not file then return false end
    file:write(json.encode({ name = name, characters = self.characters }))
    file:close()
    self.series_name = name
    return true
end

function CharacterDB:loadSeries(name)
    local path = self:getSeriesPath(name)
    local file = io.open(path, "r")
    if not file then return false end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(json.decode, content)
    if ok and data and type(data.characters) == "table" then
        -- Merge: series characters fill in what the book lacks.
        for id, c in pairs(data.characters) do
            if not self.characters[id] then
                self.characters[id] = c
            end
        end
        self.series_name = name
        return true
    end
    return false
end

-- Glossary export (Markdown / CSV) — complements Vocabulary Builder export.
function CharacterDB:exportGlossary(format, resolveName)
    local lines = {}
    if format == "csv" then
        lines[#lines + 1] = "Name,Role,Relationships,Notes"
        for _, entry in ipairs(self:getAll()) do
            local c = entry.data
            local rels = {}
            for _, r in ipairs(c.relationships or {}) do
                local target = resolveName and resolveName(r.target) or r.target
                rels[#rels + 1] = getRelationshipLabel(r.type) .. ": " .. (target or "?")
            end
            local notes = table.concat(c.notes or {}, " | ")
            notes = notes:gsub('"', '""')
            lines[#lines + 1] = string.format('"%s","%s","%s","%s"',
                c.display_name:gsub('"', '""'), getRoleLabel(c.role),
                table.concat(rels, "; "):gsub('"', '""'), notes)
        end
        return table.concat(lines, "\n")
    else
        lines[#lines + 1] = "# Character Glossary"
        lines[#lines + 1] = ""
        for _, entry in ipairs(self:getAll()) do
            local c = entry.data
            lines[#lines + 1] = "## " .. c.display_name
            lines[#lines + 1] = "- **Role:** " .. getRoleLabel(c.role)
            if c.variants and #c.variants > 0 then
                lines[#lines + 1] = "- **Also known as:** " .. table.concat(c.variants, ", ")
            end
            if c.relationships and #c.relationships > 0 then
                local rels = {}
                for _, r in ipairs(c.relationships) do
                    local target = resolveName and resolveName(r.target) or r.target
                    rels[#rels + 1] = "- " .. getRelationshipLabel(r.type) .. " → " .. (target or "?")
                end
                lines[#lines + 1] = "- **Relationships:**"
                for _, rl in ipairs(rels) do lines[#lines + 1] = rl end
            end
            if c.notes and #c.notes > 0 then
                lines[#lines + 1] = "- **Notes:**"
                for _, n in ipairs(c.notes) do
                    lines[#lines + 1] = "  - " .. n
                end
            end
            lines[#lines + 1] = ""
        end
        return table.concat(lines, "\n")
    end
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
            local pos0, pos1, page = m.pos0 or m.xp, m.pos1 or m.xp, m.page
            if pos0 then
                results[#results + 1] = { page = page, pos0 = pos0, pos1 = pos1 or pos0 }
            end
        end
    end
    return results
end

function HighlightManager:highlightMatch(match, color, note)
    local doc = self.doc
    if not doc or not match or not match.pos0 then return false end
    local c = hexToColor(color)
    pcall(function() doc:deleteHighlight(match.pos0) end)
    local ok, err = pcall(function()
        doc:addHighlight(match.pos0, match.pos1, c)
    end)
    if ok then
        if type(doc.setHighlightNote) == "function" then
            pcall(doc.setHighlightNote, doc, match.pos0, note or "")
        end
        return true
    else
        logger.warn("[CharacterSheet] addHighlight failed:", err)
        return false
    end
end

function HighlightManager:applyCharacter(char)
    if not char then return 0 end
    local count = 0
    local terms = {}
    for _, v in ipairs(char.variants or {}) do terms[#terms + 1] = v end
    for _, v in ipairs(char.aliases or {}) do terms[#terms + 1] = v end
    for _, term in ipairs(terms) do
        local matches = self:findOccurrences(term)
        for _, m in ipairs(matches) do
            if self:highlightMatch(m, char.color, char.display_name) then
                count = count + 1
            end
        end
    end
    self:refresh()
    return count
end

function HighlightManager:clearCharacter(char)
    if not char then return 0 end
    local count = 0
    local terms = {}
    for _, v in ipairs(char.variants or {}) do terms[#terms + 1] = v end
    for _, v in ipairs(char.aliases or {}) do terms[#terms + 1] = v end
    for _, term in ipairs(terms) do
        local matches = self:findOccurrences(term)
        for _, m in ipairs(matches) do
            local ok = pcall(function() self.doc:deleteHighlight(m.pos0) end)
            if ok then count = count + 1 end
        end
    end
    self:refresh()
    return count
end

-- Appearance statistics for a character (complements Statistics plugin).
function HighlightManager:getStats(char)
    if not char then return { total = 0, first_page = nil, on_current = 0 } end
    local terms = {}
    for _, v in ipairs(char.variants or {}) do terms[#terms + 1] = v end
    for _, v in ipairs(char.aliases or {}) do terms[#terms + 1] = v end
    local total = 0
    local first_page = nil
    local cur_page = self.ui and self.doc and self.doc.getCurrentPage and self.doc:getCurrentPage()
    local on_current = 0
    for _, term in ipairs(terms) do
        local matches = self:findOccurrences(term)
        for _, m in ipairs(matches) do
            total = total + 1
            local p = m.page
            if type(p) == "number" then
                if not first_page or p < first_page then first_page = p end
                if cur_page and p == cur_page then on_current = on_current + 1 end
            end
        end
    end
    return { total = total, first_page = first_page, on_current = on_current }
end

-- Jump to the next (or first) mention of a character.
function HighlightManager:jumpToMention(char, after_page)
    if not char or not self.doc then return false end
    local terms = {}
    for _, v in ipairs(char.variants or {}) do terms[#terms + 1] = v end
    for _, v in ipairs(char.aliases or {}) do terms[#terms + 1] = v end
    local all = {}
    for _, term in ipairs(terms) do
        local matches = self:findOccurrences(term)
        for _, m in ipairs(matches) do all[#all + 1] = m end
    end
    if #all == 0 then return false end
    table.sort(all, function(a, b) return (a.page or 0) < (b.page or 0) end)
    local target = all[1]
    if after_page then
        for _, m in ipairs(all) do
            if (m.page or 0) > after_page then target = m break end
        end
    end
    local ok = pcall(function()
        self.doc:gotoXPointer(target.pos0)
        if self.ui then self.ui:handleEvent(Event:new("RefreshPage")) end
    end)
    return ok
end

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
    o.hm = o.hm
    return o
end

function TextReplacer:count(pattern)
    local hm = self.hm or HighlightManager:new{ doc = self.doc, db = self.db }
    return #hm:findOccurrences(pattern)
end

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

    local progress
    if self.ui then
        progress = ProgressWidget and ProgressWidget:new{
            width = math.floor(Screen:getWidth() * 0.8),
            height = 20,
            percentage = 0,
            text = "Replacing… 0/" .. total,
        }
        if progress then UIManager:show(progress) end
    end

    local i = 0
    local function step()
        local batch_end = math.min(i + BATCH_SIZE, total)
        for k = i + 1, batch_end do
            local m = matches[k]
            pcall(function()
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
local ReaderCharacterSheet = WidgetContainer:extend{
    name = "character_sheet",
    is_doc_only = true,
    is_doc_supported = false,
    char_marks = nil,
    mark_enabled = false,
    visible_boxes = nil,
}

function ReaderCharacterSheet:init()
    logger.info("[CharacterSheet] init() entered; ui=", self.ui ~= nil,
        "ui.menu=", self.ui and self.ui.menu ~= nil,
        "document=", self.document ~= nil)
    self.db = CharacterDB:new{}
    self.hm = nil
    self.replacer = nil
    self.char_marks = {}
    self.visible_boxes = {}
    self._menu_registered = false

    -- Register the main-menu entry FIRST so the plugin is always usable,
    -- even if later document access fails for some reason.
    self:registerMainMenu()

    self:onDispatcherRegisterActions()

    -- Detect EPUB/KEPUB by file extension (Document:getDocumentType does
    -- not exist in KOReader; getFileNameSuffix is what built-ins use).
    local ext = self.document and util.getFileNameSuffix(self.document.file) or ""
    self.is_doc_supported = (ext == "epub")
    logger.info("[CharacterSheet] doc ext=", ext, "is_doc_supported=", self.is_doc_supported)

    if self.is_doc_supported and self.document then
        local ok, err = pcall(function()
            -- Document:getDocumentHoldingPath does not exist; derive the
            -- book's directory from its file path instead.
            local holding = util.splitFilePathName(self.document.file)
            self.db:setPath(holding)
            self.db:load()
            self.hm = HighlightManager:new{ doc = self.document, db = self.db, ui = self.ui }
            self.replacer = TextReplacer:new{ doc = self.document, db = self.db, ui = self.ui, hm = self.hm }
        end)
        if not ok then
            logger.warn("[CharacterSheet] init doc setup failed:", err)
            self.is_doc_supported = false
        end
    end
    logger.info("[CharacterSheet] init() done")
end

-- Register the reader main-menu entry (idempotent).
function ReaderCharacterSheet:registerMainMenu()
    if self._menu_registered then
        logger.info("[CharacterSheet] registerMainMenu: already registered")
        return
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
        self._menu_registered = true
        logger.info("[CharacterSheet] registered to main menu")
    else
        logger.warn("[CharacterSheet] registerMainMenu: ui.menu missing, will retry in onReaderReady")
    end
end

function ReaderCharacterSheet:onDispatcherRegisterActions()
    pcall(function()
        Dispatcher:registerAction("character_sheet_show", {
            category = "none",
            event = "ShowCharacterList",
            title = _("Character Sheet: show characters"),
            reader = true,
        })
    end)
end

function ReaderCharacterSheet:onShowCharacterList()
    if self:ensureSupported() then self:showCharacterManager() end
    return true
end

function ReaderCharacterSheet:onReaderReady()
    logger.info("[CharacterSheet] onReaderReady entered; is_doc_supported=", self.is_doc_supported,
        "document=", self.document ~= nil, "ui.menu=", self.ui and self.ui.menu ~= nil)
    if not self.is_doc_supported or not self.document then return end
    -- Fallback: ensure the menu is registered (in case init() ran before ui.menu existed).
    self:registerMainMenu()
    local ok, err = pcall(function()
        -- Document:getDocumentHoldingPath does not exist; derive the book's
        -- directory from its file path instead.
        local holding = util.splitFilePathName(self.document.file)
        self.db:setPath(holding)
        self.db:load()
        self.hm = HighlightManager:new{ doc = self.document, db = self.db, ui = self.ui }
        self.replacer = TextReplacer:new{ doc = self.document, db = self.db, ui = self.ui, hm = self.hm }
    end)
    if not ok then
        logger.warn("[CharacterSheet] onReaderReady doc setup failed:", err)
        return
    end

    -- Underline preference (default off).
    local saved = self.ui.doc_settings:readSetting("character_sheet_underline")
    if saved ~= nil then
        self.mark_enabled = saved
    else
        self.mark_enabled = self.db.settings.underline or false
    end

    -- Register as a view module so paintTo runs each render.
    if self.ui.view then
        self.view = self.ui.view
        self.ui.view:registerViewModule("character_sheet", self)
    end

    -- Tap zone to detect taps on underlined names.
    if self.ui.registerTouchZones then
        self.ui:registerTouchZones({
            {
                id = "character_sheet_tap",
                ges = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                overrides = { "readerhighlight_tap" },
                handler = function(ges) return self:onTapUnderline(ges) end,
            },
        })
    end

    -- Highlight-dialog integration: assign selected text to a character.
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("character_sheet_assign", function(this)
            return {
                text = _("Character"),
                callback = function()
                    local selected = this.selected_text
                    this:onClose()
                    self:onAssignSelectionToCharacter(selected)
                end,
            }
        end)
    end

    self:rebuildMarks()
end

function ReaderCharacterSheet:onCloseDocument()
    if self.db then self.db:save() end
end

function ReaderCharacterSheet:onPageUpdate()
    self.visible_boxes = {}
end

-- ---------------------------------------------------------------------------
-- On-page name underlining (view module) + tap-to-detail
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:paintTo(bb, x, y)
    self.visible_boxes = {}
    if not self.char_marks or #self.char_marks == 0 then return end
    local ok, err = pcall(function()
        if self.ui.rolling then
            self:_paintToRolling(bb, x, y)
        elseif self.ui.paging then
            self:_paintToPaging(bb, x, y)
        end
    end)
    if not ok then
        logger.warn("CharacterSheet: paintTo error:", err)
        self.char_marks = {}
        self.visible_boxes = {}
    end
end

function ReaderCharacterSheet:_paintToRolling(bb, x, y)
    local cur_view_top = self.ui.document:getCurrentPos()
    local cur_view_bottom
    if self.view.view_mode == "page" and self.ui.document:getVisiblePageCount() > 1 then
        cur_view_bottom = cur_view_top + 2 * self.ui.dimen.h
    else
        cur_view_bottom = cur_view_top + self.ui.dimen.h
    end
    for _i, mark in ipairs(self.char_marks) do
        if mark.start and mark["end"] then
            local start_pos = self.ui.document:getPosFromXPointer(mark.start)
            if start_pos and start_pos <= cur_view_bottom then
                local end_pos = self.ui.document:getPosFromXPointer(mark["end"])
                if end_pos and end_pos >= cur_view_top then
                    local boxes = self.ui.document:getScreenBoxesFromPositions(mark.start, mark["end"], true)
                    if boxes then
                        for _j, box in ipairs(boxes) do
                            if box.h ~= 0 then
                                if self.mark_enabled then
                                    self.view:drawHighlightRect(bb, x, y, box, "underscore")
                                end
                                self.visible_boxes[#self.visible_boxes + 1] = {
                                    rect = box, char_id = mark.char_id,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
end

function ReaderCharacterSheet:_paintToPaging(bb, x, y)
    local cur_page = self.ui.document:getCurrentPage()
    for _i, mark in ipairs(self.char_marks) do
        if mark.start == cur_page and mark.boxes then
            for _j, box in ipairs(mark.boxes) do
                local native_box = self.ui.document:nativeToPageRectTransform(cur_page, box)
                if native_box then
                    local screen_rect = self.view:pageToScreenTransform(cur_page, native_box)
                    if screen_rect then
                        if self.mark_enabled then
                            self.view:drawHighlightRect(bb, x, y, screen_rect, "underscore")
                        end
                        self.visible_boxes[#self.visible_boxes + 1] = {
                            rect = screen_rect, char_id = mark.char_id,
                        }
                    end
                end
            end
        end
    end
end

function ReaderCharacterSheet:rebuildMarks()
    if not self.ui or not self.ui.document then return end
    self.char_marks = {}
    local names = {}
    for id, char in pairs(self.db.characters) do
        local entry = { text = char.display_name, char_id = id }
        names[#names + 1] = entry
        if char.variants then
            for _, v in ipairs(char.variants) do
                names[#names + 1] = { text = v, char_id = id }
            end
        end
        if char.aliases then
            for _, a in ipairs(char.aliases) do
                names[#names + 1] = { text = a, char_id = id }
            end
        end
    end
    if #names == 0 then return end

    local info = InfoMessage:new{ text = _("Indexing character names…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local completed, results = Trapper:dismissableRunInSubprocess(function()
        local all_marks = {}
        local doc = self.ui.document
        for _i, name in ipairs(names) do
            local res = doc:findAllText(name.text, not self.db:isCaseSensitive(), 0, 10000, false)
            if res then
                for _j, item in ipairs(res) do
                    item.char_id = name.char_id
                    all_marks[#all_marks + 1] = item
                end
            end
        end
        return all_marks
    end, info)
    UIManager:close(info)
    if completed and results then
        self.char_marks = results
    end
    UIManager:setDirty(nil, "ui")
end

function ReaderCharacterSheet:onTapUnderline(ges)
    if not self.visible_boxes or #self.visible_boxes == 0 then return false end
    local ok, result = pcall(function()
        local pos = self.view:screenToPageTransform(ges.pos)
        if not pos then return false end
        for _i, vbox in ipairs(self.visible_boxes) do
            local r = vbox.rect
            if pos.x >= r.x and pos.y >= r.y and pos.x <= r.x + r.w and pos.y <= r.y + r.h then
                local char = self.db:get(vbox.char_id)
                if char then
                    self:showCharacterDetail(char)
                    return true
                end
            end
        end
        return false
    end)
    if not ok then
        logger.warn("CharacterSheet: tap error:", result)
        self.visible_boxes = {}
        return false
    end
    return result
end

-- ---------------------------------------------------------------------------
-- UI: Character Manager (with search)
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showCharacterManager()
    local chars = self.db:getAll()
    local items = {}
    for _, entry in ipairs(chars) do
        local c = entry.data
        items[#items + 1] = {
            text = c.display_name,
            mandatory = getRoleLabel(c.role),
            callback = function() self:showCharacterDetail(self.db:get(entry.id)) end,
        }
    end
    items[#items + 1] = {
        text = "➕ " .. _("Add new character"),
        callback = function() self:showAddCharacter() end,
    }

    local menu = Menu:new{
        title = _("Character Manager"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
        is_popout = false,
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function ReaderCharacterSheet:showAddCharacter()
    local dialog
    dialog = InputDialog:new{
        title = _("New Character"),
        input = "",
        input_hint = _("Primary name (e.g. Gandalf)"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Create"),
                    is_enter_default = true,
                    callback = function()
                        local name = trim(dialog:getInputText() or "")
                        UIManager:close(dialog)
                        if name == "" then return end
                        local taken = self.db:isNameOrAliasTaken(name, nil)
                        if taken then
                            UIManager:show(InfoMessage:new{
                                text = T(_("'%1' is already used by '%2'."), name, taken),
                            })
                            return
                        end
                        local id = self.db:upsert(nil, {
                            display_name = name,
                            variants = { name },
                            aliases = {},
                            notes = {},
                            color = "#FF4500",
                            role = "",
                            relationships = {},
                        })
                        self.db:save()
                        self:rebuildMarks()
                        self:showCharacterEditor(id)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- Multi-field editor (name, aliases, notes, role) in one dialog.
function ReaderCharacterSheet:showCharacterEditor(id)
    local char = self.db:get(id)
    if not char then return end

    local aliases_text = table.concat(char.aliases or {}, "\n")
    local notes_text = table.concat(char.notes or {}, "\n")

    local dialog
    dialog = MultiInputDialog:new{
        title = char.display_name,
        fields = {
            { text = char.display_name, hint = _("Display name"), },
            { text = aliases_text, hint = _("Aliases (one per line)"), input_type = "multiline" },
            { text = notes_text, hint = _("Notes (one per line)"), input_type = "multiline" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Role"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showRolePicker(id, function()
                            char = self.db:get(id)
                            self:showCharacterEditor(id)
                        end)
                    end,
                },
                {
                    text = _("Color"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showColorPicker(id, function()
                            char = self.db:get(id)
                            self:showCharacterEditor(id)
                        end)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = trim(dialog:getFieldValue(1) or "")
                        if name == "" then name = char.display_name end
                        local taken = self.db:isNameOrAliasTaken(name, id)
                        if taken then
                            UIManager:show(InfoMessage:new{
                                text = T(_("'%1' is already used by '%2'."), name, taken),
                            })
                            return
                        end
                        local new_aliases = parseVariants(dialog:getFieldValue(2))
                        local new_notes = parseVariants(dialog:getFieldValue(3))
                        char.display_name = name
                        char.aliases = new_aliases
                        char.notes = new_notes
                        self.db:upsert(id, char)
                        self.db:save()
                        UIManager:close(dialog)
                        self:rebuildMarks()
                        self.hm:applyCharacter(self.db:get(id))
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ReaderCharacterSheet:showRolePicker(id, on_close)
    local char = self.db:get(id)
    local items = {}
    for _, r in ipairs(ROLES) do
        items[#items + 1] = {
            text = r.label,
            checked = (char.role or "") == r.key,
            callback = function()
                char.role = r.key
                self.db:upsert(id, char)
                self.db:save()
                if on_close then on_close() end
            end,
        }
    end
    local menu = Menu:new{
        title = _("Select role"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.8),
        height = math.floor(Screen:getHeight() * 0.7),
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
    }
    UIManager:show(menu)
end

-- Character detail view (tap target): stats, relationships, notes, actions.
function ReaderCharacterSheet:showCharacterDetail(char)
    if not char then return end
    local stats = self.hm and self.hm:getStats(char) or { total = 0, first_page = nil, on_current = 0 }
    local lines = {}
    lines[#lines + 1] = _("Name: ") .. char.display_name
    lines[#lines + 1] = _("Role: ") .. getRoleLabel(char.role)
    if char.variants and #char.variants > 0 then
        lines[#lines + 1] = _("Also known as: ") .. table.concat(char.variants, ", ")
    end
    lines[#lines + 1] = T(_("Mentions: %1"), stats.total) ..
        (stats.first_page and T(_(" (first on page %1)"), stats.first_page) or "")
    if stats.on_current > 0 then
        lines[#lines + 1] = T(_("On this page: %1"), stats.on_current)
    end
    if char.relationships and #char.relationships > 0 then
        local rels = {}
        for _, r in ipairs(char.relationships) do
            local target = self.db:get(r.target)
            rels[#rels + 1] = "- " .. getRelationshipLabel(r.type) .. " → " ..
                (target and target.display_name or r.target or "?")
        end
        lines[#lines + 1] = _("Relationships:")
        for _, rl in ipairs(rels) do lines[#lines + 1] = rl end
    end
    if char.notes and #char.notes > 0 then
        lines[#lines + 1] = _("Notes:")
        for _, n in ipairs(char.notes) do lines[#lines + 1] = "  - " .. n end
    end

    local viewer = TextViewer:new{
        title = char.display_name,
        text = table.concat(lines, "\n"),
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.8),
    }
    viewer:addShowListener(function()
        -- Add action buttons below the viewer.
        local button_dialog
        button_dialog = ButtonDialog:new{
            title = char.display_name,
            buttons = {
                {
                    {
                        text = _("Edit"),
                        callback = function()
                            UIManager:close(button_dialog)
                            self:showCharacterEditor(char.id)
                        end,
                    },
                    {
                        text = _("Relations"),
                        callback = function()
                            UIManager:close(button_dialog)
                            self:showRelationshipManager(char.id)
                        end,
                    },
                    {
                        text = _("Jump"),
                        callback = function()
                            UIManager:close(button_dialog)
                            local cur = self.document and self.document:getCurrentPage()
                            self.hm:jumpToMention(self.db:get(char.id), cur)
                        end,
                    },
                    {
                        text = _("Delete"),
                        callback = function()
                            UIManager:close(button_dialog)
                            self:confirmDelete(char.id)
                        end,
                    },
                },
            },
        }
        UIManager:show(button_dialog)
    end)
    UIManager:show(viewer)
end

function ReaderCharacterSheet:confirmDelete(id)
    local char = self.db:get(id)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete character '%1' and clear its highlights?"),
            (char and char.display_name or id)),
        ok_text = _("Delete"),
        ok_callback = function()
            self.hm:clearCharacter(char)
            self.db:remove(id)
            self.db:save()
            self:rebuildMarks()
        end,
    })
end

-- Relationship manager between characters.
function ReaderCharacterSheet:showRelationshipManager(id)
    local char = self.db:get(id)
    if not char then return end
    char.relationships = char.relationships or {}

    local buttons = {}
    for i, rel in ipairs(char.relationships) do
        local target = self.db:get(rel.target)
        local label = getRelationshipLabel(rel.type) .. " → " ..
            (target and target.display_name or rel.target or "?")
        buttons[#buttons + 1] = {
            {
                text = label,
                callback = function()
                    UIManager:close(self._rel_dialog)
                    self._rel_dialog = nil
                    self:showEditRelationshipDialog(id, i)
                end,
            },
            {
                text = "✕",
                callback = function()
                    UIManager:close(self._rel_dialog)
                    self._rel_dialog = nil
                    table.remove(char.relationships, i)
                    self.db:upsert(id, char)
                    self.db:save()
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = "+ " .. _("Add relationship"),
            callback = function()
                UIManager:close(self._rel_dialog)
                self._rel_dialog = nil
                self:showAddRelationshipDialog(id)
            end,
        },
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(self._rel_dialog)
                self._rel_dialog = nil
            end,
        },
    }

    self._rel_dialog = ButtonDialog:new{
        title = T(_("Relationships - %1"), char.display_name),
        buttons = buttons,
    }
    UIManager:show(self._rel_dialog)
end

function ReaderCharacterSheet:showAddRelationshipDialog(id)
    local char = self.db:get(id)
    -- Pick relationship type.
    local type_items = {}
    for _, rt in ipairs(RELATIONSHIP_TYPES) do
        type_items[#type_items + 1] = {
            text = rt.label,
            callback = function()
                local rtype = rt.key
                if rtype == "custom" then
                    local d
                    d = InputDialog:new{
                        title = _("Custom relationship"),
                        input_hint = _("e.g. Rival"),
                        buttons = {
                            {
                                { text = _("Cancel"), callback = function() UIManager:close(d) end },
                                { text = _("OK"), is_enter_default = true, callback = function()
                                    rtype = trim(d:getInputText() or "")
                                    UIManager:close(d)
                                    self:pickRelationshipTarget(id, rtype)
                                end },
                            },
                        },
                    }
                    UIManager:show(d)
                else
                    self:pickRelationshipTarget(id, rtype)
                end
            end,
        }
    end
    local menu = Menu:new{
        title = _("Relationship type"),
        item_table = type_items,
        width = math.floor(Screen:getWidth() * 0.8),
        height = math.floor(Screen:getHeight() * 0.8),
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
    }
    UIManager:show(menu)
end

function ReaderCharacterSheet:pickRelationshipTarget(id, rtype)
    local char = self.db:get(id)
    local items = {}
    for tid, tchar in pairs(self.db.characters) do
        if tid ~= id then
            items[#items + 1] = {
                text = tchar.display_name,
                callback = function()
                    char.relationships = char.relationships or {}
                    char.relationships[#char.relationships + 1] = { type = rtype, target = tid }
                    self.db:upsert(id, char)
                    self.db:save()
                    UIManager:show(InfoMessage:new{ text = _("Relationship added."), timeout = 1 })
                end,
            }
        end
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("No other characters to link.") })
        return
    end
    local menu = Menu:new{
        title = _("Link to…"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.8),
        height = math.floor(Screen:getHeight() * 0.8),
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
    }
    UIManager:show(menu)
end

function ReaderCharacterSheet:showEditRelationshipDialog(id, index)
    local char = self.db:get(id)
    local rel = char.relationships[index]
    if not rel then return end
    local target = self.db:get(rel.target)
    UIManager:show(ConfirmBox:new{
        text = T(_("Remove relationship %1 → %2?"),
            getRelationshipLabel(rel.type), target and target.display_name or rel.target),
        ok_text = _("Remove"),
        ok_callback = function()
            table.remove(char.relationships, index)
            self.db:upsert(id, char)
            self.db:save()
        end,
    })
end

-- ---------------------------------------------------------------------------
-- UI: Color picker
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showColorPicker(id, on_close)
    local char = self.db:get(id)
    local buttons = {}
    local row = {}
    for _i, color in ipairs(PRESET_COLORS) do
        row[#row + 1] = {
            text = "▰", -- ▰
            align = "center",
            callback = function()
                UIManager:close(self._color_dialog)
                self._color_dialog = nil
                char.color = color
                self.db:upsert(id, char)
                self.db:save()
                self.hm:applyCharacter(self.db:get(id))
                if on_close then on_close() end
            end,
        }
        if #row >= 5 then
            buttons[#buttons + 1] = row
            row = {}
        end
    end
    if #row > 0 then buttons[#buttons + 1] = row end
    buttons[#buttons + 1] = {
        {
            text = _("Custom hex…"),
            callback = function()
                UIManager:close(self._color_dialog)
                self._color_dialog = nil
                self:showCustomColorDialog(id, on_close)
            end,
        },
    }
    self._color_dialog = ButtonDialog:new{
        title = _("Pick color for ") .. (char and char.display_name or "") ..
            "  (" .. (char and char.color or "#FF4500") .. ")",
        buttons = buttons,
    }
    UIManager:show(self._color_dialog)
end

function ReaderCharacterSheet:showCustomColorDialog(id, on_close)
    local char = self.db:get(id)
    local d = InputDialog:new{
        title = _("Custom color (hex)"),
        input = char.color or "#FF4500",
        input_hint = "#RRGGBB",
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(d) end },
                {
                    text = _("Set"),
                    is_enter_default = true,
                    callback = function()
                        local hex = trim(d:getInputText() or "")
                        UIManager:close(d)
                        if hex:match("^#%x%x%x%x%x%x$") then
                            char.color = hex
                            self.db:upsert(id, char)
                            self.db:save()
                            self.hm:applyCharacter(self.db:get(id))
                            if on_close then on_close() end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Invalid hex color. Use #RRGGBB."),
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(d)
end

-- ---------------------------------------------------------------------------
-- UI: Apply color / highlight all
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showApplyColorMenu()
    local chars = self.db:getAll()
    if #chars == 0 then
        UIManager:show(InfoMessage:new{ text = _("No characters yet. Add one first.") })
        return
    end
    local items = {}
    for _, entry in ipairs(chars) do
        items[#items + 1] = {
            text = entry.data.display_name,
            callback = function()
                local n = self.hm:applyCharacter(entry.data)
                UIManager:show(InfoMessage:new{
                    text = T(_("Highlighted %1 occurrence(s) of %2."), n, entry.data.display_name),
                    timeout = 2,
                })
            end,
        }
    end
    local menu = Menu:new{
        title = _("Apply Color"),
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
        UIManager:show(InfoMessage:new{ text = _("No characters to rename.") })
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
        title = _("Rename Character"),
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
        title = T(_("Rename '%1'"), char.display_name),
        input = "",
        input_hint = _("New name for all occurrences"),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(d) end },
                {
                    text = _("Replace"),
                    is_enter_default = true,
                    callback = function()
                        local new_name = trim(d:getInputText() or "")
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

function ReaderCharacterSheet:doReplace(char, new_name)
    local pattern = (char.variants and char.variants[1]) or char.display_name
    local total = self.replacer:count(pattern)
    if total == 0 then
        UIManager:show(InfoMessage:new{ text = T(_("No occurrences of '%1' found."), pattern) })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Replace %1 instance(s) of '%2' with '%3'?\n\nThis uses KOReader's replaceString and is NOT easily undone. Back up your book first!"),
            total, pattern, new_name),
        ok_text = _("Replace"),
        ok_callback = function()
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
                self.hm:applyCharacter(self.db:get(char.id))
                self:rebuildMarks()
                UIManager:show(InfoMessage:new{
                    text = T(_("Replaced %1 occurrence(s). Highlights refreshed."), done),
                    timeout = 2,
                })
            end)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- UI: Assign selected text (from highlight dialog) to a character
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:onAssignSelectionToCharacter(selected)
    if not selected then
        UIManager:show(InfoMessage:new{ text = _("No text selected.") })
        return
    end
    local text = type(selected) == "table" and selected.text or tostring(selected)
    text = trim(text)
    if text == "" then return end

    local items = {}
    for id, char in pairs(self.db.characters) do
        items[#items + 1] = {
            text = char.display_name,
            callback = function()
                char.variants = char.variants or {}
                local dup = false
                for _, v in ipairs(char.variants) do
                    if v:lower() == text:lower() then dup = true break end
                end
                if not dup then
                    char.variants[#char.variants + 1] = text
                    self.db:upsert(id, char)
                    self.db:save()
                    self:rebuildMarks()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Added '%1' as a name of %2."), text, char.display_name),
                        timeout = 2,
                    })
                end
            end,
        }
    end
    items[#items + 1] = {
        text = "+ " .. _("New character from selection"),
        callback = function()
            local taken = self.db:isNameOrAliasTaken(text, nil)
            if taken then
                UIManager:show(InfoMessage:new{
                    text = T(_("'%1' is already used by '%2'."), text, taken),
                })
                return
            end
            local nid = self.db:upsert(nil, {
                display_name = text, variants = { text }, aliases = {},
                notes = {}, color = "#FF4500", role = "", relationships = {},
            })
            self.db:save()
            self:rebuildMarks()
            UIManager:show(InfoMessage:new{
                text = T(_("Created character '%1'."), text), timeout = 2,
            })
        end,
    }
    local menu = Menu:new{
        title = T(_("Assign '%1' to…"), text),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
    }
    UIManager:show(menu)
end

-- ---------------------------------------------------------------------------
-- UI: Series linking
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showSeriesMenu()
    local items = {}
    items[#items + 1] = {
        text = self.db.series_name and (T(_("Linked series: %1"), self.db.series_name)) or _("Not linked to a series"),
        enabled = false,
    }
    items[#items + 1] = {
        text = _("Link / create series"),
        callback = function() self:showSeriesLinkDialog() end,
    }
    if self.db.series_name then
        items[#items + 1] = {
            text = _("Unlink from series"),
            callback = function()
                self.db.series_name = nil
                self.db:save()
                UIManager:show(InfoMessage:new{ text = _("Unlinked from series."), timeout = 1 })
            end,
        }
    end
    local menu = Menu:new{
        title = _("Series linking"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.7),
        onMenuChoice = function(_, item) if item and item.callback then item.callback() end end,
    }
    UIManager:show(menu)
end

function ReaderCharacterSheet:showSeriesLinkDialog()
    local d = InputDialog:new{
        title = _("Series name"),
        input = self.db.series_name or "",
        input_hint = _("e.g. The Lord of the Rings"),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(d) end },
                {
                    text = _("Link"),
                    is_enter_default = true,
                    callback = function()
                        local name = trim(d:getInputText() or "")
                        UIManager:close(d)
                        if name == "" then return end
                        self.db:loadSeries(name)
                        self.db:saveSeries(name)
                        self.db:save()
                        self:rebuildMarks()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Linked to series '%1'."), name), timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(d)
end

-- ---------------------------------------------------------------------------
-- UI: Import / Export (data + glossary, local + sync-friendly)
-- ---------------------------------------------------------------------------
function ReaderCharacterSheet:showExport()
    local items = {
        { text = _("Export character data (JSON)"), callback = function() self:exportFile("data") end },
        { text = _("Export glossary (Markdown)"), callback = function() self:exportFile("md") end },
        { text = _("Export glossary (CSV)"), callback = function() self:exportFile("csv") end },
    }
    local menu = Menu:new{
        title = _("Export"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.6),
        onMenuChoice = function(_, item) if item.callback then item.callback() end end,
    }
    UIManager:show(menu)
end

function ReaderCharacterSheet:exportFile(kind)
    local default_dir = "/mnt/onboard/" .. (_meta_name or "character_sheet")
    lfs.mkdir(default_dir)
    local title = kind == "data" and _("Export character data to…")
        or kind == "md" and _("Export glossary (Markdown) to…")
        or _("Export glossary (CSV) to…")
    local chooser = FileChooser:new{
        title = title,
        path = default_dir,
        select_directory = true,
        show_files = false,
        callback = function(path)
            local dest, content
            if kind == "data" then
                dest = util.pathJoin(path, CHARACTER_DATA_FILENAME)
                content = json.encode({
                    book_hash = self.db.book_hash,
                    settings = self.db.settings,
                    series_name = self.db.series_name,
                    characters = self.db.characters,
                })
            else
                dest = util.pathJoin(path, "character_glossary." .. (kind == "md" and "md" or "csv"))
                content = self.db:exportGlossary(kind, function(id)
                    local c = self.db:get(id)
                    return c and c.display_name or id
                end)
            end
            local file = io.open(dest, "w")
            if file then
                file:write(content)
                file:close()
                UIManager:show(InfoMessage:new{ text = T(_("Exported to %1"), dest), timeout = 2 })
            else
                logger.warn("[CharacterSheet] Export failed:", dest)
            end
        end,
    }
    UIManager:show(chooser)
end

function ReaderCharacterSheet:showImport()
    local chooser = FileChooser:new{
        title = _("Import character data"),
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
                UIManager:show(InfoMessage:new{ text = _("Invalid character data file.") })
                return
            end
            UIManager:show(ButtonDialog:new{
                title = _("Import mode"),
                text = _("Merge (keep existing, add missing) or Overwrite completely?"),
                buttons = {
                    {
                        {
                            text = _("Merge"),
                            callback = function()
                                for id, c in pairs(data.characters) do
                                    if not self.db:get(id) then self.db:upsert(id, c) end
                                end
                                self.db:save()
                                self:rebuildMarks()
                                self:refreshAllHighlights()
                            end,
                        },
                        {
                            text = _("Overwrite"),
                            callback = function()
                                self.db.characters = data.characters
                                if data.settings then self.db.settings = data.settings end
                                if data.series_name then self.db.series_name = data.series_name end
                                self.db:save()
                                self:rebuildMarks()
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

-- ---------------------------------------------------------------------------
-- Main menu integration
-- ---------------------------------------------------------------------------
local _meta_name = "character_sheet"

function ReaderCharacterSheet:addToMainMenu(menu_items)
    logger.info("[CharacterSheet] addToMainMenu called")
    menu_items.character_sheet = {
        text = _("Character Sheet"),
        sub_item_table = {
            {
                text = _("Manage Characters"),
                callback = function()
                    if self:ensureSupported() then self:showCharacterManager() end
                end,
            },
            {
                text = _("Apply Color"),
                callback = function()
                    if self:ensureSupported() then self:showApplyColorMenu() end
                end,
            },
            {
                text = _("Rename Character"),
                callback = function()
                    if self:ensureSupported() then self:showRenameMenu() end
                end,
            },
            {
                text_func = function()
                    return self.mark_enabled and _("Underline names: ON") or _("Underline names: OFF")
                end,
                callback = function()
                    self.mark_enabled = not self.mark_enabled
                    self.db.settings.underline = self.mark_enabled
                    self.db:save()
                    if self.ui and self.ui.doc_settings then
                        self.ui.doc_settings:saveSetting("character_sheet_underline", self.mark_enabled)
                    end
                    self:rebuildMarks()
                end,
                hold_callback = function()
                    self.mark_enabled = not self.mark_enabled
                    self.db.settings.underline = self.mark_enabled
                    self.db:save()
                    if self.ui and self.ui.doc_settings then
                        self.ui.doc_settings:saveSetting("character_sheet_underline", self.mark_enabled)
                    end
                    self:rebuildMarks()
                    return true
                end,
            },
            {
                text = _("Series linking"),
                callback = function()
                    if self:ensureSupported() then self:showSeriesMenu() end
                end,
            },
            {
                text = _("Import / Export"),
                sub_item_table = {
                    {
                        text = _("Export"),
                        callback = function()
                            if self:ensureSupported() then self:showExport() end
                        end,
                    },
                    {
                        text = _("Import"),
                        callback = function()
                            if self:ensureSupported() then self:showImport() end
                        end,
                    },
                },
            },
            {
                text_func = function()
                    return _("Case-sensitive matching: ") ..
                        (self.db:isCaseSensitive() and "ON" or "OFF")
                end,
                callback = function()
                    self.db:setSetting("case_sensitive", not self.db:isCaseSensitive())
                    self.db:save()
                    self:rebuildMarks()
                end,
                hold_callback = function()
                    self.db:setSetting("case_sensitive", not self.db:isCaseSensitive())
                    self.db:save()
                    self:rebuildMarks()
                    return true
                end,
            },
        },
    }
end

function ReaderCharacterSheet:ensureSupported()
    if not self.is_doc_supported then
        UIManager:show(InfoMessage:new{
            text = _("Unsupported document type.\nThis plugin only works with EPUB/KEPUB books."),
        })
        return false
    end
    return true
end

return ReaderCharacterSheet