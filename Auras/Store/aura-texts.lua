-- A Bar's or Icon's text nodes as records: the TextNode record, new nodes
-- and their keys, their saved form, and giving older auras theirs. Drawing
-- them is Auras/Displays/Parts/text-nodes' job.

local conditions = require("Auras/Registries/conditions")
local displayTypes = require("Auras/Registries/display-types")
local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local textTemplate = require("Auras/Helpers/text-template")
local savedValues = require("Auras/Store/saved-values")

--- One value text: a text template placed at one of the nine anchor points
--- of the display's box, offset inwards from it by x/y as an aura is from
--- the screen's edges. Drawn in list order, so a later one sits over an
--- earlier one. Its text fields are the aura's own field names.
---@class TextNode
---@field key integer? Stable id, for conditions that change it (see Change.text); never reused.
---@field showText boolean Whether it's drawn.
---@field textTemplate string
---@field textColour integer 0xRRGGBBAA.
---@field textFont string
---@field textSize integer
---@field limitDecimals boolean
---@field decimalsBelow number
---@field anchor AnchorID Where it sits on the display.
---@field x number Offset, inwards from the anchor.
---@field y number

local auraTexts = {}

-- Also the aura's own text fields' defaults.
auraTexts.DEFAULT_COLOUR = 0xFFFFFFFF
-- With limitDecimals on, values at or above this many seconds show whole.
auraTexts.DEFAULT_DECIMALS_BELOW = 10
-- New text nodes sit in the middle of the display.
local NEW_TEXT_ANCHOR = "centre"
-- The fields a text node shares with the aura.
local SHARED_FIELDS = { "showText", "textTemplate", "textColour", "textFont", "textSize",
    "limitDecimals", "decimalsBelow" }

--- A key for a new text node: one more than the highest in use, counting
--- keys conditions still name, so a removed node's conditions never start
--- changing a new one.
---@param aura Aura
---@return integer
function auraTexts.NextKey(aura)
    local highest = 0
    --- Raises `highest` to a key in use.
    ---@param key any
    local function consider(key)
        key = tonumber(key)
        if key ~= nil and key > highest then highest = key end
    end
    for _, node in ipairs(aura.texts or {}) do consider(node.key) end
    for _, condition in ipairs(aura.conditions or {}) do
        for _, change in ipairs(condition.changes or {}) do consider(change.text) end
    end
    return highest + 1
end

--- A new text node, centred and styled like the aura's own text fields. It
--- isn't added to the aura.
---@param aura Aura
---@return TextNode
function auraTexts.New(aura)
    return {
        key = auraTexts.NextKey(aura),
        showText = true,
        textTemplate = aura.textTemplate or textTemplate.DEFAULT,
        textColour = aura.textColour or auraTexts.DEFAULT_COLOUR,
        textFont = aura.textFont or fontCatalogue.DEFAULT_FONT,
        textSize = aura.textSize or fontCatalogue.DEFAULT_SIZE,
        limitDecimals = aura.limitDecimals == true,
        decimalsBelow = aura.decimalsBelow or auraTexts.DEFAULT_DECIMALS_BELOW,
        anchor = NEW_TEXT_ANCHOR,
        x = 0,
        y = 0,
    }
end

--- What a text node's missing fields load as on a record: a new node
--- styled like its own text, without a key.
---@param record table An aura in saved form.
---@return TextNode node With no `key`.
function auraTexts.Defaults(record)
    local node = auraTexts.New(record)
    node.key = nil
    return node
end

--- Whether a display type draws text nodes (Bar, Icon).
---@param display DisplayID?
---@return boolean
function auraTexts.TypeUsesNodes(display)
    local displayType = displayTypes.Get(display)
    return displayType ~= nil and displayType.module.usesTextNodes == true
end

--- Gives a Bar or Icon without text nodes one, made from its own text
--- fields (as it showed before nodes existed), and points its per-text
--- condition changes at it.
---@param aura Aura Changed in place.
function auraTexts.Ensure(aura)
    if aura.texts ~= nil or not auraTexts.TypeUsesNodes(aura.display) then return end
    local node = auraTexts.New(aura)
    node.showText = aura.showText ~= false
    aura.texts = { node }
    for _, condition in ipairs(aura.conditions or {}) do
        for _, change in ipairs(condition.changes or {}) do
            local property = conditions.Property(change.property)
            if property ~= nil and property.perText and change.text == nil then change.text = node.key end
        end
    end
end

--- Fills gaps in text nodes (an import, or a damaged save) from a new
--- node's defaults, giving any without a key, or with one already taken, a
--- fresh one.
---@param aura Aura Its nodes are changed in place.
function auraTexts.Fill(aura)
    local seenKeys = {}
    for _, node in ipairs(aura.texts or {}) do
        local defaults = auraTexts.New(aura)
        if type(node.key) ~= "number" or seenKeys[node.key] then node.key = nil end
        for key, value in pairs(defaults) do
            if node[key] == nil then node[key] = value end
        end
        seenKeys[node.key] = true
    end
end

--- Copies the first node's text styling onto the aura's own text fields,
--- for an aura leaving text nodes for a type that uses its own (Text):
--- those haven't followed edits to the nodes.
---@param aura Aura Changed in place.
function auraTexts.CopyFirstToAura(aura)
    local firstNode = aura.texts and aura.texts[1]
    if firstNode == nil then return end
    for _, field in ipairs(SHARED_FIELDS) do
        if firstNode[field] ~= nil then aura[field] = firstNode[field] end
    end
end

--- Copies a text node list between its saved form (colours as hex) and the
--- one the plugin uses.
---@param list any
---@param direction boolean savedValues.DECODE (saved to plugin form) or ENCODE.
---@return TextNode[]? texts nil if `list` isn't a table.
function auraTexts.Convert(list, direction)
    if type(list) ~= "table" then return nil end
    local decode = direction == savedValues.DECODE
    local converted = {}
    for _, node in ipairs(list) do
        if type(node) == "table" then
            local copy = {}
            for key, value in pairs(node) do
                if savedValues.IsColourKey(key) then
                    -- Not `and/or`: a colour that doesn't decode would fall
                    -- through to EncodeColour and error on load.
                    if decode then
                        value = savedValues.DecodeColour(value) or auraTexts.DEFAULT_COLOUR
                    else
                        value = savedValues.EncodeColour(value)
                    end
                elseif decode and type(value) == "number" then
                    value = savedValues.ToInteger(value)
                end
                copy[key] = value
            end
            converted[#converted + 1] = copy
        end
    end
    return converted
end

return auraTexts
