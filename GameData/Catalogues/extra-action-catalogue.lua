-- The extra action buttons some fights and quests show (Kerapac's Warp
-- time), from the game's EXTRA_ACTION_BUTTON DB table. Owns the
-- ExtraActionButton record; which button is showing, and its cooldown, are
-- the extra-action tracker's.

local gameApi = require("GameData/game-api")

local extraActionCatalogue = {}

--- One extra action button.
---@class ExtraActionButton
---@field id integer The button's id, as TOPLEVEL_V2_EXTRA_ACTION_BUTTON_ID holds it.
---@field key string Its row's name without the table's prefix (EGWD_JAS_BOSS), to name its source after.
---@field name string Its name ("Warp time"); the key, readable, if it has none.
---@field label string `name`, plus the key when two listed buttons share a name, so the picker can tell them apart.
---@field icon integer? Sprite id.
---@field cooldownTicks integer Its full cooldown in server ticks; 0 for a button without one.

local EVENT_ID = "runeAuras_extraActionCatalogue"
-- The start of every row name in the table (EXTRA_ACTION_BUTTON_EGWD_JAS_BOSS).
local ROW_PREFIX = "EXTRA_ACTION_BUTTON_"
-- The table's columns: the button's id, name, icon sprite and cooldown in server ticks.
local COLUMNS = { id = 1, name = 2, icon = 5, cooldownTicks = 7 }
-- DB row names read per Logic tick while the table is being found.
local ROWS_PER_TICK = 500
-- The start of the keys of buttons only a quest shows (QUEST_WENDLE_SECRETS).
local QUEST_KEY_PREFIX = "QUEST_"
-- Keys of buttons the game has a row for but never shows.
local UNUSED_KEYS = {
    -- Revive Player.
    REVIVE = true,
}

---@type table<integer, ExtraActionButton> Button id to its button, listed or not.
local buttonsByID = {}
---@type ExtraActionButton[] The listed buttons (see isListed), sorted by label.
local buttons = {}
---@type ConfigWalk? The walk of every DB row, while it runs.
local walk = nil
local loaded = false

--- A row key as words, for a button without a name or one whose name clashes
--- ("QUEST_WENDLE_SECRETS" is "Quest wendle secrets").
---@param key string
---@return string
local function readableKey(key)
    local words = key:lower():gsub("_", " ")
    return (words:gsub("^%l", string.upper))
end

--- Reads one row of the table.
---@param rowID integer
---@param rowName string
---@return ExtraActionButton? button nil if the row has no button id.
local function readRow(rowID, rowName)
    local row = gameApi.DBRow(rowID)
    if row == nil then return nil end
    local buttonID = tonumber(gameApi.ColumnValue(row, COLUMNS.id))
    if buttonID == nil then return nil end
    local key = rowName:sub(#ROW_PREFIX + 1)
    local name = gameApi.ColumnValue(row, COLUMNS.name)
    if type(name) ~= "string" or name == "" then name = readableKey(key) end
    return {
        id = buttonID,
        key = key,
        name = name,
        label = name,
        icon = tonumber(gameApi.ColumnValue(row, COLUMNS.icon)),
        cooldownTicks = tonumber(gameApi.ColumnValue(row, COLUMNS.cooldownTicks)) or 0,
    }
end

--- Whether a button is offered as a source of its own: not one only a
--- quest shows, which players can't go back to, nor one never shown.
---@param button ExtraActionButton
---@return boolean
local function isListed(button)
    local isQuest = button.key:sub(1, #QUEST_KEY_PREFIX) == QUEST_KEY_PREFIX
    return not isQuest and not UNUSED_KEYS[button.key]
end

--- Makes the found buttons the catalogue: every one found by id, and the
--- listed ones with unique labels, sorted by label.
---@param found ExtraActionButton[]
local function setButtons(found)
    buttons, buttonsByID = {}, {}
    local counts = {}
    for _, button in ipairs(found) do
        buttonsByID[button.id] = button
        if isListed(button) then
            buttons[#buttons + 1] = button
            counts[button.name] = (counts[button.name] or 0) + 1
        end
    end
    for _, button in ipairs(buttons) do
        if counts[button.name] > 1 then button.label = button.name .. " (" .. readableKey(button.key) .. ")" end
    end
    table.sort(buttons, function(first, second) return first.label:lower() < second.label:lower() end)
end

--- Finds the buttons in the background, once a session (a walk cut short by
--- Stop starts over next time). Nothing indexes the table's rows, so every
--- DB row's name is walked, a batch per Logic tick, and the table's rows
--- read as they come up. Needs the player in game.
---@param onLoaded fun() Called once the buttons are listed.
function extraActionCatalogue.Load(onLoaded)
    if loaded or walk ~= nil then return end
    walk = gameApi.ConfigWalk("DBRow")
    if walk == nil then return end
    local found = {}
    Event.Logic.Subscribe(EVENT_ID, function()
        for _ = 1, ROWS_PER_TICK do
            local rowID, rowName, ok = gameApi.NextInWalk(walk)
            if not ok then
                extraActionCatalogue.Stop()
                return
            end
            if rowID == nil then
                extraActionCatalogue.Stop()
                loaded = true
                setButtons(found)
                onLoaded()
                return
            end
            local isButtonRow = type(rowName) == "string" and rowName:sub(1, #ROW_PREFIX) == ROW_PREFIX
            if isButtonRow then found[#found + 1] = readRow(rowID, rowName) end
        end
    end)
end

--- Stops a walk in progress.
function extraActionCatalogue.Stop()
    if walk == nil then return end
    Event.Logic.Unsubscribe(EVENT_ID)
    walk = nil
end

--- A button by id, listed or not.
---@param buttonID integer
---@return ExtraActionButton? button nil if unknown, or not loaded yet.
function extraActionCatalogue.Find(buttonID)
    return buttonsByID[buttonID]
end

--- The buttons offered as sources of their own, sorted by label; empty until loaded.
---@return ExtraActionButton[]
function extraActionCatalogue.List()
    return buttons
end

return extraActionCatalogue
