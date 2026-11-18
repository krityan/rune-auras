-- Sharing auras as text: Export turns an aura or group (with everything in
-- it) into a string to copy, Import turns one back into new auras. Owns the
-- export format and checking imported text, which is untrusted: it's only
-- ever parsed, never run, and every record is checked field by field
-- before the store sees it (a wrong-typed value would otherwise reach a
-- display that does maths with it every frame).
--
-- Formats, all holding the saved records (auraStore.ExportRecords, see
-- Auras/Store/shared-records) with fields at the value loading would give
-- them anyway left out:
-- - JSON, `{"runeAuras": <version>, "records": [...]}`, to read and edit,
--   when it fits in one of the game's input fields (BOX_LIMIT).
-- - Otherwise "RA2:" then base64 of the same JSON with no spaces and field
--   names swapped for short codes (KEYS), LZW-compressed.
-- - "RA1:" then base64 of the records serialized (Auras/Helpers/serializer)
--   with short codes, LZW-compressed: what older versions exported. Import
--   still reads it.
-- Base64 too long for a field is split into parts, "RAP1:<checksum>:<i>/<n>:"
-- then its slice of the whole, which can be pasted in any order.

local auraStore = require("Auras/Store/aura-store")
local base64 = require("Auras/Sharing/base64")
local json = require("Auras/Sharing/json")
local lzw = require("Auras/Sharing/lzw")
local conditions = require("Auras/Registries/conditions")
local serializer = require("Auras/Helpers/serializer")
local textTemplate = require("Auras/Helpers/text-template")
local displayTypes = require("Auras/Registries/display-types")
local loadOptions = require("Auras/Registries/load-options")
local iconCatalogue = require("GameData/Catalogues/icon-catalogue")

local auraShare = {}

-- The most characters the game's input fields take, whatever their
-- maxLength asks for: a longer paste is cut off.
auraShare.BOX_LIMIT = 9999

-- Base64 forms start with one of these, saying what it is and which format,
-- so a later format can still read these.
local PREFIX = "RA2:"
local SERIALIZED_PREFIX = "RA1:"
-- The JSON forms' field holding the format version, which also says what it is.
local VERSION_KEY = "runeAuras"
-- Before 2, texts were typed (see auraStore.MigrateTexts); before 3,
-- offsets counted inwards from their anchor (see auraStore.MigrateOffsets).
local FORMAT_VERSION = 3
-- The first version with texts as fields.
local FIELD_TEXTS_VERSION = 2
-- The first version whose offsets count right and up.
local RIGHT_UP_OFFSETS_VERSION = 3
-- What a serialized export without a version is.
local FIRST_FORMAT_VERSION = 1
local PART_PREFIX = "RAP1:"
local PART_PATTERN = "^RAP1:(%x%x%x%x):(%d+)/(%d+):(.*)$"
-- The most of a base64 export one part carries: with its header, within BOX_LIMIT.
local PART_LENGTH = 9900
local MAX_PARTS = 50
-- Generous limits, far past any real aura, that keep a pasted wall of text
-- from tying the client up.
local MAX_TEXT = 1000000
local MAX_RECORDS = 500
local MAX_LIST = 64
local MAX_STRING = 1000
local MAX_NUMBER = 1000000
local MAX_RENAME_DEPTH = 16
-- The checksum naming a multi-part export's parts: djb2, cut to 4 hex digits.
local CHECKSUM_SEED, CHECKSUM_MULTIPLIER, CHECKSUM_BITS = 5381, 33, 0xFFFF

local isColourKey = auraStore.IsColourKey

-- Field to the Lua type it must have, for an aura record. Colours are hex
-- strings, as saved. Display types' own options are added from their
-- defaults below. Anything not listed is dropped.
local FIELDS = {
    id = "number", group = "number", name = "string", display = "string", source = "string",
    enabled = "boolean", colour = "string", showText = "boolean",
    anchor = "string", x = "number", y = "number",
    textColour = "string", textFont = "string", textSize = "number", textTemplate = "string",
    timeFormat = "string", decimalsBelow = "number", bareSeconds = "boolean", fullTicks = "boolean",
    percentDecimals = "number", conditions = "table", texts = "table", load = "table", sourceOptions = "table",
    -- An Icon's, from before each text node had its own: loading gives its
    -- nodes it (see auraTexts.MoveHideWhenReady).
    hideTextWhenReady = "boolean",
    -- From before time formats, the aura's and its nodes': loading gives
    -- them the closest format (see auraTexts.MigrateLimitDecimals).
    limitDecimals = "boolean",
}
for _, displayType in ipairs(displayTypes.List()) do
    for key, default in pairs(displayType.options.defaults or {}) do
        if FIELDS[key] == nil then FIELDS[key] = isColourKey(key) and "string" or type(default) end
    end
end

-- A text node's fields (see TextNode).
local TEXT_FIELDS = {
    key = "number", showText = "boolean", textTemplate = "string", textColour = "string",
    textFont = "string", textSize = "number", timeFormat = "string", decimalsBelow = "number",
    bareSeconds = "boolean", fullTicks = "boolean", percentDecimals = "number", anchor = "string", x = "number",
    y = "number", hideWhenReady = "boolean",
    -- From before time formats, as the aura's.
    limitDecimals = "boolean",
}

-- Field names and their short codes in exports: a name's code is its place
-- in this list, so it's append-only (new names at the end, none removed or
-- moved) or older exports would read wrong. Codes start with a capital and
-- every field name with a small letter, so they can't be mistaken for one
-- another; a name not listed is kept as it is.
local KEYS = {
    "id", "group", "name", "display", "source", "enabled", "colour", "showText", "anchor", "x", "y",
    "textColour", "textFont", "textSize", "textTemplate", "limitDecimals", "decimalsBelow",
    "conditions", "texts", "load", "width", "height", "backgroundColour", "borderColour",
    "borderThickness", "invertFill", "smoothFill", "hideWhenEmpty", "showIcon", "iconSide", "showTicks",
    "tickColour", "swipeStyle", "swipeColour", "iconColour", "invertSwipe", "dimWhileActive",
    "hideTextWhenReady", "hideWhileInactive", "hideWhileActive", "showActiveBelow", "maxWidth",
    "textAlign", "textShadow", "segments", "perRow", "grow", "segmentWidth", "segmentHeight", "sizeBy",
    "totalLength", "spacing", "showEmpty", "align", "key", "match", "checks", "changes", "kind", "op",
    "value", "sourceType", "property", "text", "options", "records", "version",
    "swipeAnticlockwise", "showProgressText", "fillStyle", "fillAnticlockwise", "wipeDirection",
    "sourceOptions", "hideWithoutSpecial", "rememberSpecial", "durationSeconds", "percentDecimals",
    "hideWhenReady", "timeFormat", "bareSeconds", "fullTicks", "iconSprite", "iconItem", "hands", "number",
    "fillDirection",
}
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
-- Field name to its code, and code to its name.
local SHORT, LONG = {}, {}
-- Field name to its place in readable JSON: the version first, then KEYS'
-- order (what an aura is, then how it looks), the rest after by name.
local KEY_RANKS = { [VERSION_KEY] = 0 }
for index, name in ipairs(KEYS) do
    -- A, B, ... Z, then AA, AB, ...
    local firstLetter, secondLetter = (index - 1) // #LETTERS, (index - 1) % #LETTERS + 1
    local code = (firstLetter > 0 and LETTERS:sub(firstLetter, firstLetter) or "")
        .. LETTERS:sub(secondLetter, secondLetter)
    SHORT[name], LONG[code] = code, name
    KEY_RANKS[name] = index
end

--- A copy of a value with every table key renamed.
---@param value any
---@param names table<string, string> Old key to new key; keys not in it are kept.
---@param depth integer
---@return any
local function renameKeys(value, names, depth)
    if type(value) ~= "table" or depth > MAX_RENAME_DEPTH then return value end
    local result = {}
    for key, item in pairs(value) do
        result[names[key] or key] = renameKeys(item, names, depth + 1)
    end
    return result
end

-- Fields with no default that sharing keeps whenever they're set.
local ALWAYS_KEPT = {
    id = true, group = true, source = true, conditions = true, texts = true, load = true, sourceOptions = true,
}
-- Fields kept even at their default: id and display say what a record is,
-- and timeFormat that it's from after time formats, as loading migrates a
-- record without one (see auraTexts.MigrateLimitDecimals). A group's is
-- left out with its other text fields (see dropGroupTexts).
local KEPT_AT_DEFAULT = { id = true, display = true, timeFormat = true }

--- A text as it is if it's a template (see textTemplate.IsValid), else the
--- default, which is what a display shows for it.
---@param text any
---@return any text nil stays nil.
local function asTemplate(text)
    if text == nil or textTemplate.IsValid(text) then return text end
    return textTemplate.DEFAULT
end

--- Makes every text in a record that isn't a template the default: the
--- aura's own, its text nodes' and its Text changes' values. A text is
--- only ever the source's values: displays already show any other text as
--- the default, so each shows as it did, but typed words are never stored
--- or passed on in an export, where they'd be one loosened check from showing.
---@param record table A saved or imported record; changed in place.
local function resetCustomTexts(record)
    record.textTemplate = asTemplate(record.textTemplate)
    for _, node in ipairs(record.texts or {}) do node.textTemplate = asTemplate(node.textTemplate) end
    for _, condition in ipairs(record.conditions or {}) do
        for _, change in ipairs(condition.changes or {}) do
            local property = conditions.Property(change.property)
            if property ~= nil and property.kind == "text" then change.value = asTemplate(change.value) end
        end
    end
end

--- Leaves out of a record (and its text nodes) whatever loading would give
--- it anyway. Text node defaults follow the aura's own text fields, so
--- they're worked out first.
---@param record table A saved record; changed in place.
local function dropDefaults(record)
    local textDefaults = auraStore.TextDefaults(record)
    for _, node in ipairs(record.texts or {}) do
        for key, value in pairs(textDefaults) do
            if node[key] == value then node[key] = nil end
        end
    end
    local defaults = auraStore.LoadDefaults(record.display)
    for key, value in pairs(defaults) do
        if not KEPT_AT_DEFAULT[key] and type(value) ~= "table" and record[key] == value then
            record[key] = nil
        end
    end
    -- Options of a type it used to be (a Bar's background on an Icon) do
    -- nothing, as switching type resets to the new type's defaults. What
    -- it uses is what loading gives it, plus what has no default.
    for key in pairs(record) do
        if defaults[key] == nil and not ALWAYS_KEPT[key] then record[key] = nil end
    end
end

--- Leaves out a record's unticked load options: they don't load or unload
--- it, and what was picked in them means nothing to whoever imports it.
--- Then drops the load if nothing's left in it. A save keeps them, so
--- ticking one again brings back what was picked.
---@param record table A saved record; changed in place.
local function dropUntickedLoadOptions(record)
    local load = record.load
    if load == nil then return end
    if load.options ~= nil then
        for optionID, setting in pairs(load.options) do
            if setting.enabled ~= true then load.options[optionID] = nil end
        end
        if next(load.options) == nil then load.options = nil end
    end
    if load.checks ~= nil and #load.checks == 0 then load.checks = nil end
    if load.options == nil and load.checks == nil then record.load = nil end
end

--- Leaves a group's own text fields out (see auraStore.AURA_TEXT_FIELDS):
--- every record has them, but groups and dynamic groups draw no text, so
--- they'd only carry whatever the group was saved with. Its time format
--- goes too, so loading takes it for a record from before time formats and
--- gives it their old decimals, which a group doesn't use either.
---@param record table A saved record; changed in place.
local function dropGroupTexts(record)
    if not auraStore.IsGroup(record) then return end
    for _, field in ipairs(auraStore.AURA_TEXT_FIELDS) do record[field] = nil end
end

-- A property kind to the type its changes' values must have.
local KIND_TYPES = { colour = "string", bool = "boolean", number = "number", text = "string" }

--- The ids in a list of `{ id }` tables, as a set.
---@param items { id: string }[]
---@return table<string, boolean>
local function idSet(items)
    local set = {}
    for _, item in ipairs(items) do set[item.id] = true end
    return set
end
local CHECK_KINDS = idSet(conditions.CHECKS)
local OPERATORS = idSet(conditions.OPERATORS)
local MATCHES = idSet(conditions.MATCHES)

--- A value if it's the expected type and within the limits.
---@param value any
---@param wanted string A Lua type name.
---@return any value nil if it isn't.
local function cleanValue(value, wanted)
    local kind = type(value)
    if kind ~= wanted then return nil end
    if kind == "string" and #value > MAX_STRING then return nil end
    local isBadNumber = kind == "number" and (value ~= value or value > MAX_NUMBER or value < -MAX_NUMBER)
    if isBadNumber then return nil end
    return value
end

--- The items of a list (1..n, up to MAX_LIST), each checked.
---@param value any
---@param clean fun(item: table): table? Checks one item; nil skips it.
---@return table[]? items nil if it isn't a table.
local function cleanList(value, clean)
    if type(value) ~= "table" then return nil end
    local result = {}
    for index = 1, MAX_LIST do
        local item = value[index]
        if item == nil then break end
        local cleaned = type(item) == "table" and clean(item) or nil
        if cleaned ~= nil then result[#result + 1] = cleaned end
    end
    return result
end

--- The fields of a table that a field list names, each of the right type.
---@param value table
---@param fields table<string, string> Field to Lua type; "table" fields are left for the caller.
---@return table
local function cleanFields(value, fields)
    local result = {}
    for key, wanted in pairs(fields) do
        if wanted ~= "table" then result[key] = cleanValue(value[key], wanted) end
    end
    return result
end

---@param value table
---@return Check? check nil for an unknown kind.
local function cleanCheck(value)
    if not CHECK_KINDS[value.kind] then return nil end
    local result = {
        kind = value.kind,
        op = OPERATORS[value.op] and value.op or nil,
        source = cleanValue(value.source, "string"),
        sourceType = cleanValue(value.sourceType, "string"),
    }
    local checkValue = value.value
    if type(checkValue) == "boolean" or conditions.IsUsableValue(checkValue) or cleanValue(checkValue, "number") ~= nil then
        result.value = checkValue
    end
    return result
end

---@param value table
---@return Change? change nil for an unknown property or a wrong-typed value.
local function cleanChange(value)
    local property = conditions.Property(value.property)
    if property == nil then return nil end
    local wanted = KIND_TYPES[property.kind]
    if wanted == nil or cleanValue(value.value, wanted) == nil then return nil end
    return { property = value.property, value = value.value, text = cleanValue(value.text, "number") }
end

---@param value table
---@return Condition
local function cleanCondition(value)
    return {
        match = MATCHES[value.match] and value.match or nil,
        key = cleanValue(value.key, "number"),
        checks = cleanList(value.checks, cleanCheck) or {},
        changes = cleanList(value.changes, cleanChange) or {},
    }
end

--- A time format as imported: a known one as it is, nil as nil, and
--- anything else the default rather than nil, so a record from after time
--- formats is never taken for an older one (see KEPT_AT_DEFAULT).
---@param format any
---@return TimeFormatID?
local function knownFormat(format)
    if format == nil or textTemplate.IsTimeFormat(format) then return format end
    return textTemplate.DEFAULT_TIME_FORMAT
end

---@param value table
---@return TextNode
local function cleanTextNode(value)
    local result = cleanFields(value, TEXT_FIELDS)
    result.timeFormat = knownFormat(value.timeFormat)
    return result
end

--- A load setting's hands as imported: one of loadOptions.HANDS_CHOICES,
--- else nil (any).
---@param hands any
---@return HandsChoice?
local function knownHands(hands)
    for _, choice in ipairs(loadOptions.HANDS_CHOICES) do
        if choice.id == hands then return hands end
    end
    return nil
end

---@param value table
---@return AuraLoad
local function cleanLoad(value)
    local result = { checks = cleanList(value.checks, cleanCheck) }
    if type(value.options) == "table" then
        result.options = {}
        local count = 0
        for optionID, setting in pairs(value.options) do
            count = count + 1
            if count > MAX_LIST then break end
            if cleanValue(optionID, "string") ~= nil and type(setting) == "table" then
                local settingValue = setting.value
                if type(settingValue) ~= "boolean" then settingValue = cleanValue(settingValue, "string") end
                local itemID = math.tointeger(cleanValue(setting.item, "number"))
                result.options[optionID] = { enabled = setting.enabled == true, value = settingValue, item = itemID,
                    hands = knownHands(setting.hands), op = OPERATORS[setting.op] and setting.op or nil,
                    number = cleanValue(setting.number, "number"), unlocked = cleanValue(setting.unlocked, "boolean") }
            end
        end
    end
    return result
end

--- Drops an Icon's chosen sprite or item unless the icon catalogue offers
--- it: the display draws it, and some sprites crash the client when drawn.
--- Loading gives a dropped one the source's icon.
---@param record table A cleaned record; changed in place.
local function dropUnofferedIcon(record)
    if record.iconSprite ~= nil and not iconCatalogue.OffersSprite(record.iconSprite) then record.iconSprite = nil end
    if record.iconItem ~= nil and not iconCatalogue.OffersItem(record.iconItem) then record.iconItem = nil end
end

--- A record with only what's expected in it.
---@param value any
---@return table? record nil if it can't be one (no id).
local function cleanRecord(value)
    if type(value) ~= "table" or cleanValue(value.id, "number") == nil then return nil end
    local result = cleanFields(value, FIELDS)
    if result.display ~= nil and displayTypes.Get(result.display) == nil then result.display = nil end
    result.timeFormat = knownFormat(value.timeFormat)
    result.conditions = cleanList(value.conditions, cleanCondition)
    result.texts = cleanList(value.texts, cleanTextNode)
    result.load = type(value.load) == "table" and cleanLoad(value.load) or nil
    result.sourceOptions = auraStore.CopySourceOptions(value.sourceOptions)
    dropUnofferedIcon(result)
    return result
end

--- A short checksum of a whole export, naming its parts.
---@param text string
---@return string checksum 4 hex digits.
local function checksum(text)
    local hash = CHECKSUM_SEED
    for index = 1, #text do hash = (hash * CHECKSUM_MULTIPLIER + text:byte(index)) & CHECKSUM_BITS end
    return string.format("%04X", hash)
end

--- Base64 split into parts that each fit an input field, each with a
--- header naming the whole by its checksum.
---@param text string
---@return string[] parts
local function splitParts(text)
    local count = (#text + PART_LENGTH - 1) // PART_LENGTH
    local wholeChecksum = checksum(text)
    local parts = {}
    for index = 1, count do
        local slice = text:sub((index - 1) * PART_LENGTH + 1, index * PART_LENGTH)
        parts[index] = PART_PREFIX .. wholeChecksum .. ":" .. index .. "/" .. count .. ":" .. slice
    end
    return parts
end

--- An aura or group and everything in it as text to copy: JSON if it fits
--- in one input field, else base64 (in parts if it's too long for one).
---@param auraID integer
---@param areaWidth number? Game area width, to keep its place on screen if it's in a group.
---@param areaHeight number?
---@return string[]? texts One string, or the parts of one too long for an input field; nil if there's no such aura.
function auraShare.Export(auraID, areaWidth, areaHeight)
    local records = auraStore.ExportRecords(auraID, areaWidth, areaHeight)
    if records == nil then return nil end
    for _, record in ipairs(records) do
        resetCustomTexts(record)
        dropDefaults(record)
        dropUntickedLoadOptions(record)
        dropGroupTexts(record)
    end
    local payload = { [VERSION_KEY] = FORMAT_VERSION, records = records }
    local readable = json.Encode(payload, KEY_RANKS)
    if #readable <= auraShare.BOX_LIMIT then return { readable } end
    local packed = lzw.Compress(json.EncodeCompact(renameKeys(payload, SHORT, 0)))
    local text = PREFIX .. base64.Encode(packed)
    if #text <= PART_LENGTH then return { text } end
    return splitParts(text)
end

--- Text without the whitespace at either end.
---@param text string
---@return string
local function trimmed(text)
    local first = text:find("%S")
    if first == nil then return "" end
    local last = #text
    while text:find("^%s", last) do last = last - 1 end
    return text:sub(first, last)
end

--- What's pasted in the boxes, trimmed, leaving out empty boxes.
---@param texts any[]
---@return string[]? pasted nil if one is too long.
---@return string? problem
local function pastedTexts(texts)
    local pasted = {}
    for _, text in ipairs(texts) do
        if type(text) == "string" then
            if #text > MAX_TEXT then return nil, "Too long to be an export." end
            text = trimmed(text)
            if text ~= "" then pasted[#pasted + 1] = text end
        end
    end
    return pasted
end

--- Puts a multi-part export back together, from its parts in any order.
---@param pasted string[] Each a part, without whitespace.
---@return string? text The whole export; nil if it can't be.
---@return string? problem Why not.
---@return integer? partsNeeded How many parts it has, once known.
local function joinParts(pasted)
    local wholeChecksum, count = nil, nil
    local slices = {}
    for _, text in ipairs(pasted) do
        local partChecksum, index, total, slice = text:match(PART_PATTERN)
        index, total = tonumber(index), tonumber(total)
        local isPart = partChecksum ~= nil and index ~= nil and total ~= nil and total >= 1 and total <= MAX_PARTS
            and index >= 1 and index <= total
        if not isPart then return nil, "One box isn't an export part." end
        if wholeChecksum ~= nil and (partChecksum ~= wholeChecksum or total ~= count) then
            return nil, "Those parts are from different exports.", count
        end
        wholeChecksum, count = partChecksum, total
        slices[index] = slice
    end
    local missing = {}
    for index = 1, count do
        if slices[index] == nil then missing[#missing + 1] = tostring(index) end
    end
    if #missing > 0 then
        local label = #missing == 1 and "Missing part: " or "Missing parts: "
        return nil, label .. table.concat(missing, ", ") .. ".", count
    end
    local text = table.concat(slices, "", 1, count)
    if checksum(text) ~= wholeChecksum then return nil, "Those parts are damaged or incomplete.", count end
    return text
end

--- The whole export from the pasted boxes: JSON or base64 in one box, or
--- every part of a base64 export in any order. Base64 comes back without
--- whitespace (pasting can bring spaces and line breaks with it); JSON
--- keeps its own, as its strings can hold spaces.
---@param texts any[]
---@return string? text nil if it can't be put together.
---@return string? problem Why not.
---@return integer? partsNeeded For parts, how many there are (so the player can be given that many boxes).
local function joinPasted(texts)
    local pasted, problem = pastedTexts(texts)
    if pasted == nil then return nil, problem end
    if #pasted == 0 then return nil, "Paste an export first." end
    local isMultiPart = pasted[1]:sub(1, #PART_PREFIX) == PART_PREFIX
    if not isMultiPart then
        if #pasted > 1 then return nil, "Paste one export at a time." end
        local isJSON = pasted[1]:sub(1, 1) == "{"
        if isJSON then return pasted[1] end
        return (pasted[1]:gsub("%s", ""))
    end
    for index, text in ipairs(pasted) do pasted[index] = text:gsub("%s", "") end
    return joinParts(pasted)
end

--- Readable JSON's payload. Says what's wrong with it, and where, as it may
--- have been edited by hand.
---@param text string
---@return table? payload nil if it can't be read.
---@return string? problem
local function readJSON(text)
    local payload, problem = json.Decode(text)
    if payload == nil then
        return nil, "Bad JSON: " .. problem .. "."
    end
    if type(payload) ~= "table" or payload[VERSION_KEY] == nil then return nil, "Not a RuneAuras export." end
    return payload
end

--- The payload in a base64 export: JSON or, from older versions, serialized.
---@param text string Without whitespace.
---@return table? payload nil if it isn't one.
---@return string? problem
local function readBase64(text)
    local isSerialized = text:sub(1, #SERIALIZED_PREFIX) == SERIALIZED_PREFIX
    if text:sub(1, #PREFIX) ~= PREFIX and not isSerialized then
        if text:match("^RA%d+:") then return nil, "Made by a newer RuneAuras." end
        return nil, "Not a RuneAuras export."
    end
    local prefixLength = isSerialized and #SERIALIZED_PREFIX or #PREFIX
    local packed = base64.Decode(text:sub(prefixLength + 1))
    local decoded = packed and lzw.Decompress(packed)
    if decoded == nil then return nil, "That export is damaged or incomplete." end
    local decode = isSerialized and serializer.Decode or json.Decode
    local payload = renameKeys(decode(decoded), LONG, 0)
    if type(payload) ~= "table" then return nil, "That export is damaged or incomplete." end
    if isSerialized then
        payload[VERSION_KEY] = type(payload.version) == "number" and payload.version or FIRST_FORMAT_VERSION
    end
    return payload
end

--- The checked records in pasted text.
---@param texts string|string[]
---@return table[]? records nil if there are none to import.
---@return string? problem Why not, for the player.
---@return integer? partsNeeded For a multi-part export, how many parts it has.
local function readRecords(texts)
    if type(texts) == "string" then texts = { texts } end
    if type(texts) ~= "table" then return nil, "Nothing to import." end
    local text, problem, partsNeeded = joinPasted(texts)
    if text == nil then return nil, problem, partsNeeded end
    local payload
    if text:sub(1, 1) == "{" then
        payload, problem = readJSON(text)
    else
        payload, problem = readBase64(text)
    end
    if payload == nil then return nil, problem end
    local version = payload[VERSION_KEY]
    if type(version) ~= "number" or type(payload.records) ~= "table" then
        return nil, "That export is damaged or incomplete."
    end
    if version > FORMAT_VERSION then return nil, "Made by a newer RuneAuras." end
    local hasTypedTexts = version < FIELD_TEXTS_VERSION
    local hasInwardOffsets = version < RIGHT_UP_OFFSETS_VERSION
    local records = {}
    for index = 1, MAX_RECORDS do
        local value = payload.records[index]
        if value == nil then break end
        local cleaned = cleanRecord(value)
        if cleaned ~= nil then
            -- Typed texts become fields first, keeping what they showed.
            if hasTypedTexts then auraStore.MigrateTexts(cleaned) end
            if hasInwardOffsets then auraStore.MigrateOffsets(cleaned) end
            resetCustomTexts(cleaned)
            records[#records + 1] = cleaned
        end
    end
    if #records == 0 then return nil, "That export has no auras." end
    return records
end

--- Adds the auras in pasted text as new ones at the top level, where they
--- were on screen. Never errors: anything unexpected is caught and reported
--- as a failed import.
---@param texts string|string[] What's in each box, or one string.
---@return Aura[]? made The auras made, the exported one first; nil if nothing was imported.
---@return string? problem A message for the player.
---@return integer? partsNeeded For a multi-part export, how many parts it has.
function auraShare.Import(texts)
    local ok, records, problem, partsNeeded = pcall(readRecords, texts)
    if not ok then return nil, "Couldn't read that export." end
    if records == nil then return nil, problem, partsNeeded end
    local added, made = pcall(auraStore.AddImported, records)
    if not added then return nil, "Couldn't read that export." end
    if #made == 0 then return nil, "That export has no auras." end
    return made
end

return auraShare
