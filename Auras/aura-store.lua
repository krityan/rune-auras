-- Saves and loads the player's auras in PersistentDB.
-- An aura is a table:
--   id        unique integer
--   name      shown in the aura list
--   display   display type id (see Auras/display-types)
--   source    data source id (see Auras/data-sources), nil until chosen
--   enabled   whether it is drawn
--   colour    0xRRGGBBAA
--   showText  whether to draw the value text
--   unlocked  whether it can be dragged on screen
--   anchor    anchor point id (see Auras/anchors)
--   x, y      offset from the anchor point
--   textColour, textFont, textSize  value text style (see Auras/fonts)
--   textTemplate  value text with placeholders (see Auras/text-template)
--   limitDecimals, decimalsBelow  show values at or above decimalsBelow
--                 without decimals
-- plus any option the display type adds through its `defaults`.
-- Usage: local auraStore = require("Auras/aura-store")

local anchors = require("Auras/anchors")
local dataSources = require("Auras/data-sources")
local displayTypes = require("Auras/display-types")
local fonts = require("Auras/fonts")
local textTemplate = require("Auras/text-template")

local auraStore = {}

local STORAGE_KEY = "auras"
local DEFAULT_COLOUR = 0xFFFFFFFF
auraStore.DEFAULT_COLOUR = DEFAULT_COLOUR
local DEFAULT_DISPLAY = "bar"
local DEFAULT_TEXT_COLOUR = 0xFFFFFFFF
-- With limitDecimals on, values at or above this many seconds show whole.
local DEFAULT_DECIMALS_BELOW = 10
-- New auras sit just below the middle of the screen.
local NEW_AURA_ANCHOR = "centre"
local NEW_AURA_X, NEW_AURA_Y = 0, 150

-- Fields holding 0xRRGGBBAA colours are named "colour" or end in "Colour".
-- PersistentDB rounds large numbers off (losing the alpha byte), so these
-- are saved as hex strings instead.
local function isColourKey(key)
    return key == "colour" or (type(key) == "string" and key:match("Colour$") ~= nil)
end

local auras = {}
local nextID = 1

-- Numbers can come back from storage as floats; the UI wants integers.
local function toInteger(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.floor(number)
end

local function encodeColour(colour)
    return string.format("%08X", colour & 0xFFFFFFFF)
end

-- Older saves stored colours as numbers whose alpha byte was rounded away;
-- treat those as fully opaque.
local function decodeColour(value)
    if type(value) == "string" then
        return tonumber(value, 16)
    end
    local number = toInteger(value)
    if number == nil then return nil end
    return (number & 0xFFFFFF00) | 0xFF
end

local function applyDisplayDefaults(aura)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    for key, value in pairs(displayType.module.defaults or {}) do
        if aura[key] == nil then aura[key] = value end
    end
end

local function normalize(saved)
    if type(saved) ~= "table" or toInteger(saved.id) == nil then return nil end
    -- Every other numeric aura field (id, position, sizes) is an integer.
    local aura = {}
    for key, value in pairs(saved) do
        if isColourKey(key) then
            aura[key] = decodeColour(value)
        else
            aura[key] = type(value) == "number" and toInteger(value) or value
        end
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
    aura.textColour = aura.textColour or DEFAULT_TEXT_COLOUR
    aura.textFont = aura.textFont or fonts.DEFAULT_FONT
    aura.textSize = aura.textSize or fonts.DEFAULT_SIZE
    aura.textTemplate = aura.textTemplate or textTemplate.DEFAULT
    aura.limitDecimals = saved.limitDecimals == true
    aura.decimalsBelow = aura.decimalsBelow or DEFAULT_DECIMALS_BELOW
    applyDisplayDefaults(aura)
    return aura
end

function auraStore.Load()
    auras = {}
    nextID = 1
    local saved = PersistentDB:Get(STORAGE_KEY)
    if type(saved) ~= "table" then return end
    for _, savedAura in ipairs(saved.auras or {}) do
        local aura = normalize(savedAura)
        if aura ~= nil then
            auras[#auras + 1] = aura
            nextID = math.max(nextID, aura.id + 1)
        end
    end
    nextID = math.max(nextID, toInteger(saved.nextID) or 1)
end

function auraStore.Save()
    local saved = {}
    for index, aura in ipairs(auras) do
        local copy = {}
        for key, value in pairs(aura) do
            copy[key] = isColourKey(key) and encodeColour(value) or value
        end
        saved[index] = copy
    end
    PersistentDB:Set(STORAGE_KEY, {
        nextID = nextID,
        auras = saved,
    })
end

function auraStore.List()
    return auras
end

function auraStore.Get(auraID)
    for _, aura in ipairs(auras) do
        if aura.id == auraID then return aura end
    end
    return nil
end

function auraStore.Create()
    local aura = {
        id = nextID,
        name = "New aura",
        display = DEFAULT_DISPLAY,
        source = nil,
        enabled = true,
        colour = DEFAULT_COLOUR,
        showText = true,
        unlocked = false,
        anchor = NEW_AURA_ANCHOR,
        x = NEW_AURA_X,
        y = NEW_AURA_Y,
        textColour = DEFAULT_TEXT_COLOUR,
        textFont = fonts.DEFAULT_FONT,
        textSize = fonts.DEFAULT_SIZE,
        textTemplate = textTemplate.DEFAULT,
        limitDecimals = false,
        decimalsBelow = DEFAULT_DECIMALS_BELOW,
    }
    applyDisplayDefaults(aura)
    nextID = nextID + 1
    auras[#auras + 1] = aura
    auraStore.Save()
    return aura
end

-- How far a copy is nudged from its original, so it doesn't sit exactly on
-- top of it.
local DUPLICATE_OFFSET = 10

-- Nudges an offset by DUPLICATE_OFFSET, the other way if that would leave
-- the range that keeps the aura on screen.
local function nudge(offset, minimum, maximum)
    local nudged = offset + DUPLICATE_OFFSET
    if maximum ~= nil and nudged > maximum then nudged = offset - DUPLICATE_OFFSET end
    if minimum ~= nil then nudged = math.max(minimum, nudged) end
    if maximum ~= nil then nudged = math.min(maximum, nudged) end
    return nudged
end

-- Copies an aura with all its settings into a new one, listed right after
-- the original. areaWidth/areaHeight, the game area's size if known, keep
-- the copy's offset on screen. Returns the copy, or nil if the aura doesn't
-- exist.
function auraStore.Duplicate(auraID, areaWidth, areaHeight)
    for index, original in ipairs(auras) do
        if original.id == auraID then
            -- Every aura field is a plain value, so a shallow copy is a full one.
            local copy = {}
            for key, value in pairs(original) do copy[key] = value end
            copy.id = nextID
            copy.name = original.name .. " copy"
            copy.unlocked = false
            local minX, maxX, minY, maxY
            if areaWidth ~= nil and areaHeight ~= nil then
                minX, maxX, minY, maxY = anchors.OffsetRange(original.anchor,
                    original.width or 0, original.height or 0, areaWidth, areaHeight)
            end
            copy.x = nudge(original.x or 0, minX, maxX)
            copy.y = nudge(original.y or 0, minY, maxY)
            nextID = nextID + 1
            table.insert(auras, index + 1, copy)
            auraStore.Save()
            return copy
        end
    end
    return nil
end

function auraStore.Delete(auraID)
    for index, aura in ipairs(auras) do
        if aura.id == auraID then
            table.remove(auras, index)
            auraStore.Save()
            return true
        end
    end
    return false
end

-- Switching display type fills in the new type's option defaults.
function auraStore.Set(auraID, key, value)
    local aura = auraStore.Get(auraID)
    if aura == nil then return nil end
    if key == "display" and value ~= aura.display then
        -- Options mean different things per display type (a bar is wide, an
        -- icon square with a thinner border), so take all of the new type's
        -- defaults rather than keeping the old type's values.
        local displayType = displayTypes.Get(value)
        for option, default in pairs(displayType and displayType.module.defaults or {}) do
            aura[option] = default
        end
    end
    aura[key] = value
    if key == "display" then applyDisplayDefaults(aura) end
    auraStore.Save()
    return aura
end

return auraStore
