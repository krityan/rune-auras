-- The Aura record: its fields and defaults, what a group is, and the
-- conversion between an aura and its saved form (Load, Save and sharing all
-- go through FromSaved and ToSaved). Holds no auras itself.

--- An aura or group, as the plugin holds it (colours as numbers). Display
--- types add their own options through their `defaults`.
---
--- A group (display "group") has no size: its anchor and x/y place a point
--- that its contents are placed from, so it moves as one. Groups nest; a
--- nested group has only an offset from its parent's point. A dynamic group
--- (display "dynamicGroup") lays out its auras from its point, so their own
--- anchor and x/y are unused while in it, and it holds no groups.
---@class Aura
---@field id integer Unique, never reused.
---@field name string Shown in the aura list.
---@field display DisplayID
---@field source string? Data source id; nil until chosen.
---@field enabled boolean Whether it's drawn.
---@field colour integer Fill, 0xRRGGBBAA.
---@field showText boolean
---@field unlocked boolean Whether it can be dragged on screen.
---@field anchor AnchorID At the top level, the screen point x/y measure from; in a group, the point of the aura that attaches to the group's point.
---@field x number Offset from the anchor, inwards from the screen's edges; in a group, right and down from its point.
---@field y number
---@field textColour integer 0xRRGGBBAA.
---@field textFont string Font family (see GameData/Catalogues/font-catalogue).
---@field textSize integer
---@field textTemplate string Value text with placeholders (see Auras/Helpers/text-template).
---@field limitDecimals boolean Show values at or above `decimalsBelow` without decimals.
---@field decimalsBelow number Seconds.
---@field texts TextNode[]? A Bar's or Icon's value texts; the Text display uses the aura's own text fields.
---@field conditions Condition[]? Display changes made while checks pass.
---@field load AuraLoad? What decides whether it loads at all; nil: always.
---@field group integer? Parent group's id; nil at the top level.
---@field width number? From the display type's defaults; groups have none.
---@field height number?

local anchors = require("Auras/Helpers/anchors")
local conditions = require("Auras/Registries/conditions")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local textTemplate = require("Auras/Helpers/text-template")
local auraTexts = require("Auras/Store/aura-texts")
local savedValues = require("Auras/Store/saved-values")

local auraRecord = {}

local DECODE, ENCODE = savedValues.DECODE, savedValues.ENCODE
local isColourKey = savedValues.IsColourKey
local toInteger = savedValues.ToInteger
local encodeColour, decodeColour = savedValues.EncodeColour, savedValues.DecodeColour

auraRecord.DEFAULT_COLOUR = 0xFFFFFFFF
local DEFAULT_COLOUR = auraRecord.DEFAULT_COLOUR
local DEFAULT_DISPLAY = "bar"
-- A new aura's name, which the Trigger tab replaces with its source's name until
-- the player names it (see HasDefaultName).
local DEFAULT_NAME = "New aura"
local GROUP_DISPLAY = "group"
local DYNAMIC_GROUP_DISPLAY = "dynamicGroup"
local BAR_DISPLAY = "bar"
local ICON_DISPLAY = "icon"
-- New auras sit just below the middle of the screen.
local NEW_AURA_ANCHOR = "centre"
local NEW_AURA_X, NEW_AURA_Y = 0, 150
-- New groups' points start in the middle of the screen.
local NEW_GROUP_ANCHOR = "centre"
-- Options that no longer exist, dropped on load so they stop being saved:
-- showInitialTick went with reading buffs off the buff bar.
local RETIRED_FIELDS = { showInitialTick = true }

--- Whether an aura is a group or a dynamic group.
---@param aura Aura?
---@return boolean
function auraRecord.IsGroup(aura)
    return aura ~= nil and (aura.display == GROUP_DISPLAY or aura.display == DYNAMIC_GROUP_DISPLAY)
end

--- Whether an aura is a dynamic group.
---@param aura Aura?
---@return boolean
function auraRecord.IsDynamicGroup(aura)
    return aura ~= nil and aura.display == DYNAMIC_GROUP_DISPLAY
end

--- Whether an aura can go in a group: a group holds anything, a dynamic
--- group only auras.
---@param group Aura? Anything but a group gives false.
---@param aura Aura
---@return boolean
function auraRecord.CanHold(group, aura)
    if not auraRecord.IsGroup(group) then return false end
    return not (auraRecord.IsDynamicGroup(group) and auraRecord.IsGroup(aura))
end

--- Whether an aura still has the name it was made with, rather than one the player gave it.
---@param aura Aura
---@return boolean
function auraRecord.HasDefaultName(aura)
    return aura.name == DEFAULT_NAME
end

--- Fills in the display type's option defaults the aura lacks.
---@param aura Aura Changed in place.
local function applyDisplayDefaults(aura)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    for key, value in pairs(displayType.module.defaults or {}) do
        if aura[key] == nil then aura[key] = value end
    end
end

--- Gives an Icon made from a Bar the Icon's own background: switching type
--- kept the Bar's (a 70% black), which Icons ignored until they had a
--- background colour of their own.
---@param aura Aura Changed in place, before applyDisplayDefaults.
local function dropBarBackground(aura)
    if aura.display ~= ICON_DISPLAY then return end
    local barType = displayTypes.Get(BAR_DISPLAY)
    local barBackground = barType and barType.module.defaults.backgroundColour
    if aura.backgroundColour == barBackground then aura.backgroundColour = nil end
end

--- Drops an aura's empty condition list and load tables, so an aura with
--- none saves and exports no empty tables. Unticked load options keep their
--- value (ticking one again brings back what was picked), so they stay.
---@param aura Aura Changed in place.
function auraRecord.Tidy(aura)
    if aura.conditions ~= nil and #aura.conditions == 0 then aura.conditions = nil end
    local load = aura.load
    if load == nil then return end
    if load.options ~= nil and next(load.options) == nil then load.options = nil end
    if load.checks ~= nil and #load.checks == 0 then load.checks = nil end
    if load.options == nil and load.checks == nil then aura.load = nil end
end

--- A new aura with default options, not yet in the list. Below the middle
--- of the screen at the top level, on the group's point in one.
---@param auraID integer
---@param groupID integer? Group to put it in (not checked); nil for the top level.
---@return Aura
function auraRecord.NewAura(auraID, groupID)
    local aura = {
        id = auraID,
        name = DEFAULT_NAME,
        display = DEFAULT_DISPLAY,
        source = nil,
        enabled = true,
        colour = DEFAULT_COLOUR,
        showText = true,
        unlocked = false,
        anchor = NEW_AURA_ANCHOR,
        x = NEW_AURA_X,
        y = NEW_AURA_Y,
        textColour = auraTexts.DEFAULT_COLOUR,
        textFont = fontCatalogue.DEFAULT_FONT,
        textSize = fontCatalogue.DEFAULT_SIZE,
        textTemplate = textTemplate.DEFAULT,
        limitDecimals = false,
        decimalsBelow = auraTexts.DEFAULT_DECIMALS_BELOW,
        group = groupID,
    }
    -- The usual spot below the middle of the screen can be outside a group.
    if groupID ~= nil then aura.x, aura.y = 0, 0 end
    applyDisplayDefaults(aura)
    auraTexts.Ensure(aura)
    return aura
end

--- A new, empty group of either kind, not yet in the list. Its point
--- starts at the middle of the screen, or on its parent's point.
---@param groupID integer
---@param parentID integer? Parent group (not checked); nil for the top level.
---@param display DisplayID GROUP_DISPLAY or DYNAMIC_GROUP_DISPLAY.
---@param name string
---@return Aura group
local function newGroupOf(groupID, parentID, display, name)
    local group = {
        id = groupID,
        name = name,
        display = display,
        enabled = true,
        unlocked = false,
        anchor = NEW_GROUP_ANCHOR,
        x = 0,
        y = 0,
        group = parentID,
    }
    applyDisplayDefaults(group)
    return group
end

--- A new, empty group, not yet in the list (see newGroupOf).
---@param groupID integer
---@param parentID integer? Parent group (not checked); nil for the top level.
---@return Aura group
function auraRecord.NewGroup(groupID, parentID)
    return newGroupOf(groupID, parentID, GROUP_DISPLAY, "New group")
end

--- A new, empty dynamic group, not yet in the list (see newGroupOf). Its
--- parent must not be a dynamic group, which holds auras only.
---@param groupID integer
---@param parentID integer? Parent group (not checked); nil for the top level.
---@return Aura group
function auraRecord.NewDynamicGroup(groupID, parentID)
    return newGroupOf(groupID, parentID, DYNAMIC_GROUP_DISPLAY, "New dynamic group")
end

--- Prepares an aura for a new display type, before `display` is set:
--- resets its options to the new type's defaults and carries its text
--- styling across.
---@param aura Aura Still of its old type. Changed in place.
---@param newDisplay DisplayID
local function prepareDisplayChange(aura, newDisplay)
    -- A colour still at the old type's default (a segmented bar's green)
    -- wasn't picked, so it goes back to the store's default rather than
    -- following the aura into a type without one.
    local oldType = displayTypes.Get(aura.display)
    local oldDefaults = oldType and oldType.module.defaults or {}
    if oldDefaults.colour ~= nil and aura.colour == oldDefaults.colour then aura.colour = DEFAULT_COLOUR end
    -- Options mean different things per display type (a bar is wide, an
    -- icon square with a thinner border), so take all of the new type's
    -- defaults rather than keeping the old type's values.
    local newType = displayTypes.Get(newDisplay)
    for option, default in pairs(newType and newType.module.defaults or {}) do
        aura[option] = default
    end
    local leavingTextNodes = auraTexts.TypeUsesNodes(aura.display) and not auraTexts.TypeUsesNodes(newDisplay)
    if leavingTextNodes then auraTexts.CopyFirstToAura(aura) end
end

--- Sets one of an aura's fields. Changing `display` resets the options to
--- the new type's defaults and carries text styling across, so the aura
--- looks the same.
---@param aura Aura Changed in place.
---@param key string An Aura field, or a display type option.
---@param value any
function auraRecord.SetField(aura, key, value)
    local changesDisplay = key == "display" and value ~= aura.display
    if changesDisplay then prepareDisplayChange(aura, value) end
    aura[key] = value
    if key == "display" then
        applyDisplayDefaults(aura)
        auraTexts.Ensure(aura)
    end
end

--- A list if `value` is a table, else an empty one, for looping over
--- fields of saves that may be damaged.
---@param value any
---@return table
local function listOrEmpty(value)
    return type(value) == "table" and value or {}
end

--- Copies a condition's checks, dropping malformed ones. Checks used to be
--- joined one by one with AND/OR (`join`), which is dropped.
---@param savedChecks any
---@return table[] checks
---@return boolean joinedByOr Whether any old check was joined with OR.
local function copyChecks(savedChecks)
    local checks, joinedByOr = {}, false
    for _, savedCheck in ipairs(listOrEmpty(savedChecks)) do
        if type(savedCheck) == "table" then
            local check = conditions.Copy(savedCheck)
            if check.join == "or" then joinedByOr = true end
            check.join = nil
            checks[#checks + 1] = check
        end
    end
    return checks, joinedByOr
end

--- Converts one condition change. A colour that doesn't decode is dropped
--- with its change: encoding it back would error on load.
---@param change any
---@param direction boolean DECODE or ENCODE.
---@return table? change nil if it's malformed or names no known property.
local function convertChange(change, direction)
    if type(change) ~= "table" then return nil end
    -- Conditions briefly offered "Dim while active"; it became Desaturate,
    -- which is what it was used for.
    if change.property == "dimWhileActive" then
        change = { property = "desaturate", value = change.value }
    end
    local property = conditions.Property(change.property)
    if property == nil then return nil end
    local value = change.value
    if property.kind == "colour" then
        if direction == DECODE then
            value = decodeColour(value)
            if value == nil then return nil end
        elseif value ~= nil then
            value = encodeColour(value)
        end
    end
    -- `text` names the text node a change is for.
    return { property = change.property, value = value, text = tonumber(change.text) }
end

--- Copies a conditions list between its saved form (colours as hex) and
--- the one the plugin uses. Decoding drops anything malformed and upgrades
--- older saves; every condition gets a key.
---@param list any
---@param direction boolean DECODE (saved to plugin form) or ENCODE.
---@return Condition[]? conditions nil if there are none.
local function convertConditions(list, direction)
    if type(list) ~= "table" then return nil end
    local converted = {}
    for _, condition in ipairs(list) do
        if type(condition) == "table" then
            local checks, joinedByOr = copyChecks(condition.checks)
            local match = condition.match == "any" and "any" or "all"
            -- An old condition with an OR is closest to "any".
            if condition.match == nil and joinedByOr then match = "any" end
            local changes = {}
            for _, change in ipairs(listOrEmpty(condition.changes)) do
                changes[#changes + 1] = convertChange(change, direction)
            end
            converted[#converted + 1] = {
                match = match,
                key = tonumber(condition.key),
                checks = checks,
                changes = changes,
            }
        end
    end
    -- Conditions saved before keys existed get one (see conditions.NextKey).
    for _, condition in ipairs(converted) do
        if condition.key == nil then condition.key = conditions.NextKey(converted) end
    end
    return #converted > 0 and converted or nil
end

--- A saved field's value as the plugin holds it.
---@param key string
---@param value any
---@return any
local function loadField(key, value)
    if key == "conditions" then return convertConditions(value, DECODE) end
    if key == "texts" then return auraTexts.Convert(value, DECODE) end
    -- Load options are plain values (no colours), so a copy is all they need.
    if key == "load" then return type(value) == "table" and conditions.Copy(value) or nil end
    if isColourKey(key) then return decodeColour(value) end
    -- Every other numeric aura field (id, position, sizes) is an integer.
    if type(value) == "number" then return toInteger(value) end
    return value
end

--- Turns a saved record (or an imported one) into an Aura: decodes
--- colours, rounds numbers, upgrades old fields, fills in every default and
--- drops empty tables.
---@param saved any
---@return Aura? aura nil if it isn't a record with an id.
function auraRecord.FromSaved(saved)
    if type(saved) ~= "table" or toInteger(saved.id) == nil then return nil end
    local aura = {}
    for key, value in pairs(saved) do
        if not RETIRED_FIELDS[key] then aura[key] = loadField(key, value) end
    end
    aura.name = tostring(saved.name or "Aura")
    aura.display = displayTypes.Get(saved.display) ~= nil and saved.display or DEFAULT_DISPLAY
    aura.enabled = saved.enabled ~= false
    -- Source ids can be renamed (e.g. cooldowns now follow their var name).
    if aura.source ~= nil then aura.source = dataSources.CurrentID(aura.source) end
    aura.colour = aura.colour or DEFAULT_COLOUR
    aura.showText = saved.showText ~= false
    aura.unlocked = saved.unlocked == true
    -- Auras saved before anchors existed were positioned from the top left.
    aura.anchor = aura.anchor or anchors.DEFAULT
    aura.x = aura.x or 0
    aura.y = aura.y or 0
    aura.textColour = aura.textColour or auraTexts.DEFAULT_COLOUR
    aura.textFont = aura.textFont or fontCatalogue.DEFAULT_FONT
    aura.textSize = aura.textSize or fontCatalogue.DEFAULT_SIZE
    aura.textTemplate = aura.textTemplate or textTemplate.DEFAULT
    aura.limitDecimals = saved.limitDecimals == true
    aura.decimalsBelow = aura.decimalsBelow or auraTexts.DEFAULT_DECIMALS_BELOW
    dropBarBackground(aura)
    applyDisplayDefaults(aura)
    auraTexts.Ensure(aura)
    auraTexts.Fill(aura)
    auraRecord.Tidy(aura)
    return aura
end

--- An aura's saved form, as Save writes and export shares it: colours as
--- hex, nested lists copied.
---@param aura Aura
---@return table record
function auraRecord.ToSaved(aura)
    local copy = {}
    for key, value in pairs(aura) do
        if key == "conditions" then
            copy[key] = convertConditions(value, ENCODE)
        elseif key == "texts" then
            copy[key] = auraTexts.Convert(value, ENCODE)
        elseif key == "load" then
            copy[key] = conditions.Copy(value)
        else
            copy[key] = isColourKey(key) and encodeColour(value) or value
        end
    end
    return copy
end

return auraRecord
