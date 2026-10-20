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
-- plus any option the display type adds through its `defaults`.
-- Usage: local auraStore = require("Auras/aura-store")

local anchors = require("Auras/anchors")
local displayTypes = require("Auras/display-types")
local fonts = require("Auras/fonts")
local textTemplate = require("Auras/text-template")

local auraStore = {}

local STORAGE_KEY = "auras"
local DEFAULT_COLOUR = 0xFFFFFFFF
auraStore.DEFAULT_COLOUR = DEFAULT_COLOUR
local DEFAULT_DISPLAY = "bar"
local DEFAULT_TEXT_COLOUR = 0xFFFFFFFF
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
    }
    applyDisplayDefaults(aura)
    nextID = nextID + 1
    auras[#auras + 1] = aura
    auraStore.Save()
    return aura
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
    aura[key] = value
    if key == "display" then applyDisplayDefaults(aura) end
    auraStore.Save()
    return aura
end

return auraStore
