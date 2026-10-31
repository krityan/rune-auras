-- Sharing auras as text: Export turns an aura or group (with everything in
-- it) into a string to copy, Import turns one back into new auras. Owns the
-- export format and checking imported text, which is untrusted: it's only
-- ever parsed, never run, and every record is checked field by field
-- before the store sees it (a wrong-typed value would otherwise reach a
-- display that does maths with it every frame).
--
-- Format: "RA1:" then base64 of the saved records (auraStore.ExportRecords,
-- see Auras/Store/shared-records), serialized and LZW-compressed. The game's input fields
-- take 9,999 characters at most, so exports are kept short: fields at the
-- value loading would give them anyway are left out, field names are
-- swapped for short codes (KEYS), and the rest is compressed. One still too
-- long for a field is split into parts, "RAP1:<checksum>:<i>/<n>:" then its
-- slice of the whole, which can be pasted in any order.

local auraStore = require("Auras/Store/aura-store")
local base64 = require("Auras/Sharing/base64")
local lzw = require("Auras/Sharing/lzw")
local conditions = require("Auras/Registries/conditions")
local serializer = require("Auras/Helpers/serializer")
local displayTypes = require("Auras/Registries/display-types")

local auraShare = {}

-- Says what it is and which format, so a later format can still read this one.
local PREFIX = "RA1:"
local FORMAT_VERSION = 1
-- An export is broken into chunks this long by spaces, so a text box can
-- wrap it (base64 has no spaces). Not line breaks: the game's input field
-- is single-line, and a paste stops at the first one. Import ignores
-- whitespace.
local CHUNK_LENGTH = 64
local PART_PREFIX = "RAP1:"
local PART_PATTERN = "^RAP1:(%x%x%x%x):(%d+)/(%d+):(.*)$"
-- The most of the export one part carries. The game's input fields take
-- 9,999 characters; this leaves room for the part's header and the spaces
-- it's broken up with.
local PART_LENGTH = 9600
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
    limitDecimals = "boolean", decimalsBelow = "number",
    conditions = "table", texts = "table", load = "table",
}
for _, displayType in ipairs(displayTypes.List()) do
    for key, default in pairs(displayType.module.defaults or {}) do
        if FIELDS[key] == nil then FIELDS[key] = isColourKey(key) and "string" or type(default) end
    end
end

-- A text node's fields (see TextNode).
local TEXT_FIELDS = {
    key = "number", showText = "boolean", textTemplate = "string", textColour = "string",
    textFont = "string", textSize = "number", limitDecimals = "boolean", decimalsBelow = "number",
    anchor = "string", x = "number", y = "number",
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
    "swipeAnticlockwise", "showProgressText", "fillStyle", "fillAnticlockwise",
}
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
-- Field name to its code, and code to its name.
local SHORT, LONG = {}, {}
for index, name in ipairs(KEYS) do
    -- A, B, ... Z, then AA, AB, ...
    local firstLetter, secondLetter = (index - 1) // #LETTERS, (index - 1) % #LETTERS + 1
    local code = (firstLetter > 0 and LETTERS:sub(firstLetter, firstLetter) or "")
        .. LETTERS:sub(secondLetter, secondLetter)
    SHORT[name], LONG[code] = code, name
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
local ALWAYS_KEPT = { id = true, group = true, source = true, conditions = true, texts = true, load = true }

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
        -- Its id and display are always kept: they say what it is.
        local saysWhatItIs = key == "id" or key == "display"
        if not saysWhatItIs and type(value) ~= "table" and record[key] == value then
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
    if type(checkValue) == "boolean" or cleanValue(checkValue, "number") ~= nil then result.value = checkValue end
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

---@param value table
---@return TextNode
local function cleanTextNode(value)
    return cleanFields(value, TEXT_FIELDS)
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
                result.options[optionID] = { enabled = setting.enabled == true, value = settingValue }
            end
        end
    end
    return result
end

--- A record with only what's expected in it.
---@param value any
---@return table? record nil if it can't be one (no id).
local function cleanRecord(value)
    if type(value) ~= "table" or cleanValue(value.id, "number") == nil then return nil end
    local result = cleanFields(value, FIELDS)
    if result.display ~= nil and displayTypes.Get(result.display) == nil then result.display = nil end
    result.conditions = cleanList(value.conditions, cleanCondition)
    result.texts = cleanList(value.texts, cleanTextNode)
    result.load = type(value.load) == "table" and cleanLoad(value.load) or nil
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

--- Text broken into chunks by spaces, so a text box can wrap it.
---@param text string
---@return string
local function spaced(text)
    local chunks = {}
    for index = 1, #text, CHUNK_LENGTH do chunks[#chunks + 1] = text:sub(index, index + CHUNK_LENGTH - 1) end
    return table.concat(chunks, " ")
end

--- An aura or group and everything in it as text to copy.
---@param auraID integer
---@param areaWidth number? Game area width, to keep its place on screen if it's in a group.
---@param areaHeight number?
---@return string[]? texts One string, or the parts of one too long for an input field; nil if there's no such aura.
function auraShare.Export(auraID, areaWidth, areaHeight)
    local records = auraStore.ExportRecords(auraID, areaWidth, areaHeight)
    if records == nil then return nil end
    for _, record in ipairs(records) do dropDefaults(record) end
    local payload = renameKeys({ version = FORMAT_VERSION, records = records }, SHORT, 0)
    local packed = lzw.Compress(serializer.Encode(payload))
    local text = PREFIX .. base64.Encode(packed)
    if #text <= PART_LENGTH then return { spaced(text) } end
    local count = (#text + PART_LENGTH - 1) // PART_LENGTH
    local wholeChecksum = checksum(text)
    local parts = {}
    for index = 1, count do
        local slice = text:sub((index - 1) * PART_LENGTH + 1, index * PART_LENGTH)
        parts[index] = spaced(PART_PREFIX .. wholeChecksum .. ":" .. index .. "/" .. count .. ":" .. slice)
    end
    return parts
end

--- What's pasted in the boxes, without whitespace (pasting can bring spaces
--- and line breaks with it), leaving out empty boxes.
---@param texts any[]
---@return string[]? pasted nil if one is too long.
---@return string? problem
local function pastedTexts(texts)
    local pasted = {}
    for _, text in ipairs(texts) do
        if type(text) == "string" then
            if #text > MAX_TEXT then return nil, "That's too long to be an aura." end
            text = text:gsub("%s", "")
            if text ~= "" then pasted[#pasted + 1] = text end
        end
    end
    return pasted
end

--- Puts a multi-part export back together, from its parts in any order.
---@param pasted string[] Each a part.
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
        if not isPart then return nil, "One of the boxes isn't a part of a Rune Auras export." end
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
        return nil, "Paste the rest of the parts too: " .. table.concat(missing, ", ") .. " of "
            .. count .. " still missing.", count
    end
    local text = table.concat(slices, "", 1, count)
    if checksum(text) ~= wholeChecksum then return nil, "Those parts are incomplete or damaged.", count end
    return text
end

--- The whole export from the pasted boxes: one export in one box, or every
--- part of one in any order.
---@param texts any[]
---@return string? text nil if it can't be put together.
---@return string? problem Why not.
---@return integer? partsNeeded For parts, how many there are (so the player can be given that many boxes).
local function joinPasted(texts)
    local pasted, problem = pastedTexts(texts)
    if pasted == nil then return nil, problem end
    if #pasted == 0 then return nil, "Paste an aura's export string first." end
    local isMultiPart = pasted[1]:sub(1, #PART_PREFIX) == PART_PREFIX
    if not isMultiPart then
        if #pasted > 1 then return nil, "Paste one export at a time: each box should hold a part of the same one." end
        return pasted[1]
    end
    return joinParts(pasted)
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
    if text:sub(1, #PREFIX) ~= PREFIX then
        if text:match("^RA%d+:") then return nil, "That was exported by a newer Rune Auras." end
        return nil, "That isn't a Rune Auras export."
    end
    local packed = base64.Decode(text:sub(#PREFIX + 1))
    local decoded = packed and lzw.Decompress(packed)
    if decoded == nil then return nil, "That export is incomplete or damaged." end
    local payload = renameKeys(serializer.Decode(decoded), LONG, 0)
    if type(payload) ~= "table" or type(payload.records) ~= "table" then
        return nil, "That export is incomplete or damaged."
    end
    local records = {}
    for index = 1, MAX_RECORDS do
        local value = payload.records[index]
        if value == nil then break end
        local cleaned = cleanRecord(value)
        if cleaned ~= nil then records[#records + 1] = cleaned end
    end
    if #records == 0 then return nil, "That export has no auras in it." end
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
    if not ok then return nil, "That export couldn't be read." end
    if records == nil then return nil, problem, partsNeeded end
    local added, made = pcall(auraStore.AddImported, records)
    if not added then return nil, "That export couldn't be read." end
    if #made == 0 then return nil, "That export has no auras in it." end
    return made
end

return auraShare
