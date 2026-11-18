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
---@field hideWhenReady boolean Blank while a cooldown is ready or a buff inactive (only an Icon has either).
---@field textTemplate string
---@field textColour integer 0xRRGGBBAA.
---@field textFont string
---@field textSize integer
---@field timeFormat TimeFormatID How $value and $max are written when they're times.
---@field decimalsBelow number Seconds; with a format that has decimals, values at or above it show whole.
---@field bareSeconds boolean With hh:mm:ss, seconds alone under a minute ("59", not "0:59").
---@field fullTicks boolean With ticks, only whole ticks, rounded down; off counts the tick under way too.
---@field percentDecimals integer Decimals $percent shows.
---@field anchor AnchorID Where it sits on the display.
---@field x number Offset, inwards from the anchor.
---@field y number

local auraTexts = {}

-- Also the aura's own text fields' defaults.
auraTexts.DEFAULT_COLOUR = 0xFFFFFFFF
-- With a time format that has decimals, values at or above this many
-- seconds show whole.
auraTexts.DEFAULT_DECIMALS_BELOW = 10
-- $percent shows whole percents unless set otherwise.
auraTexts.DEFAULT_PERCENT_DECIMALS = 0
-- New text nodes sit in the middle of the display.
local NEW_TEXT_ANCHOR = "centre"
-- The fields a text node shares with the aura: the aura's own text fields.
auraTexts.SHARED_FIELDS = { "showText", "textTemplate", "textColour", "textFont", "textSize",
    "timeFormat", "decimalsBelow", "bareSeconds", "fullTicks", "percentDecimals" }
local SHARED_FIELDS = auraTexts.SHARED_FIELDS
-- What an aura's own missing text options are inherited from: nothing, so
-- they're the defaults (see migrateLimit).
local NO_OPTIONS = {}

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
        -- An Icon's hideTextWhenReady was once the aura's, for every text:
        -- a record saved then gives its nodes its setting (see MoveHideWhenReady).
        hideWhenReady = aura.hideTextWhenReady ~= false,
        textTemplate = aura.textTemplate or textTemplate.DEFAULT,
        textColour = aura.textColour or auraTexts.DEFAULT_COLOUR,
        textFont = aura.textFont or fontCatalogue.DEFAULT_FONT,
        textSize = aura.textSize or fontCatalogue.DEFAULT_SIZE,
        timeFormat = aura.timeFormat or textTemplate.DEFAULT_TIME_FORMAT,
        decimalsBelow = aura.decimalsBelow or auraTexts.DEFAULT_DECIMALS_BELOW,
        bareSeconds = aura.bareSeconds == true,
        fullTicks = aura.fullTicks ~= false,
        percentDecimals = aura.percentDecimals or auraTexts.DEFAULT_PERCENT_DECIMALS,
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
    return displayType ~= nil and displayType.options.usesTextNodes == true
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

--- Gives one text saved before time formats ss.ms in place of its Limit
--- decimals option (see MigrateLimitDecimals).
---@param text table An aura's own text fields or a text node; changed in place.
---@param inherited table Where its missing options came from: a node's aura, as saved.
local function migrateLimit(text, inherited)
    local limited, below = text.limitDecimals, text.decimalsBelow
    if limited == nil then limited = inherited.limitDecimals end
    if below == nil then below = inherited.decimalsBelow or auraTexts.DEFAULT_DECIMALS_BELOW end
    text.timeFormat = textTemplate.TENTHS_FORMAT
    -- Without the limit, decimals showed at any value.
    text.decimalsBelow = limited == true and below or textTemplate.MAX_DECIMALS_BELOW
end

--- Gives an aura saved before time formats (with no timeFormat) the one
--- closest to its Limit decimals options, on its own text fields and each
--- text node: ss.ms, showing decimals below the same value, or below
--- textTemplate.MAX_DECIMALS_BELOW where the limit was off (decimals at
--- any value). Drops those options. An aura saved since keeps its format
--- in saves and exports, so it's never taken for an older one.
---@param aura table An aura loaded from its saved form; changed in place.
function auraTexts.MigrateLimitDecimals(aura)
    local isOld = aura.timeFormat == nil
    -- Nodes first, while the aura still has the options they inherit.
    for _, node in ipairs(aura.texts or {}) do
        if isOld then migrateLimit(node, aura) end
        node.limitDecimals = nil
    end
    if isOld then migrateLimit(aura, NO_OPTIONS) end
    aura.limitDecimals = nil
end

--- Drops the aura-wide hideTextWhenReady an Icon had before each text node
--- had its own, once its nodes have been given it (by Ensure and Fill, as
--- a new node's default).
---@param aura Aura Changed in place.
function auraTexts.MoveHideWhenReady(aura)
    aura.hideTextWhenReady = nil
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
