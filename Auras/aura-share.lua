-- Sharing auras as text: Export turns an aura or group (with everything in
-- it) into a string to copy, Import turns one back into new auras.
-- The string is "RA1:" then base64 (Auras/Helpers/base64) of the saved
-- records (aura-store's ExportRecords) written by Auras/Helpers/serializer
-- and compressed (Auras/Helpers/lzw). The game's input fields take 9,999
-- characters at most, so exports are kept short: fields at the value
-- loading would give them anyway are left out (loading fills them back
-- in), field names are swapped for short codes (KEYS), and the rest is
-- compressed.
-- The prefix says what it is and which format, so a later format can still
-- read this one.
-- Import treats the text as untrusted: it's only ever parsed, never run,
-- and every record is checked field by field before the store sees it (a
-- wrong-typed value would otherwise reach a display that does maths with
-- it every frame). Anything unexpected is dropped, a record that can't be
-- made sense of is skipped, and garbage is refused with a message rather
-- than an error.
-- An export too long for one input field is split into parts, each
-- "RAP1:<check>:<i>/<n>:" then its slice of the whole: <check> is a
-- checksum of the whole export, so parts of different exports can't be
-- mixed, and they can be pasted in any order.
-- Usage: local auraShare = require("Auras/aura-share")
--        local parts = auraShare.Export(auraID, areaWidth, areaHeight)
--        local made, problem, partsNeeded = auraShare.Import(texts, groupID, areaWidth, areaHeight)

local auraStore = require("Auras/aura-store")
local base64 = require("Auras/Helpers/base64")
local lzw = require("Auras/Helpers/lzw")
local conditions = require("Auras/Helpers/conditions")
local serializer = require("Auras/Helpers/serializer")
local displayTypes = require("Auras/Registries/display-types")

local auraShare = {}

local PREFIX = "RA1:"
-- An export is broken into chunks this long by spaces, so a text box can
-- wrap it (base64 has no spaces). Not line breaks: the game's input field
-- is single-line, and a paste stops at the first one. Import ignores
-- whitespace.
local CHUNK_LENGTH = 64
local FORMAT_VERSION = 1
local PART_PREFIX = "RAP1:"
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

-- Field -> the Lua type it must have, for an aura record. Colours are hex
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
local function isColourKey(key)
    return key == "colour" or (type(key) == "string" and key:match("Colour$") ~= nil)
end
for _, displayType in ipairs(displayTypes.List()) do
    for key, default in pairs(displayType.module.defaults or {}) do
        if FIELDS[key] == nil then FIELDS[key] = isColourKey(key) and "string" or type(default) end
    end
end

-- A text node's fields (see Auras/Displays/text-nodes).
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
}
local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local SHORT, LONG = {}, {}
for index, name in ipairs(KEYS) do
    -- A, B, ... Z, then AA, AB, ...
    local first, second = (index - 1) // 26, (index - 1) % 26 + 1
    local code = (first > 0 and LETTERS:sub(first, first) or "") .. LETTERS:sub(second, second)
    SHORT[name], LONG[code] = code, name
end

-- A copy of `value` with every table key renamed through `names`.
local function renameKeys(value, names, depth)
    if type(value) ~= "table" or depth > 16 then return value end
    local result = {}
    for key, item in pairs(value) do
        result[names[key] or key] = renameKeys(item, names, depth + 1)
    end
    return result
end

-- Fields with no default that sharing keeps whenever they're set.
local ALWAYS_KEPT = { id = true, group = true, source = true, conditions = true, texts = true, load = true }

-- Leaves out of `record` (and its text nodes) whatever loading would give
-- it anyway. Text node defaults follow the aura's own text fields, so
-- they're worked out first.
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
        if key ~= "id" and key ~= "display" and type(value) ~= "table" and record[key] == value then
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

-- A property kind -> the type its changes' values must have.
local KIND_TYPES = { colour = "string", bool = "boolean", number = "number", text = "string" }

local function ids(list)
    local set = {}
    for _, item in ipairs(list) do set[item.id] = true end
    return set
end
local CHECK_KINDS = ids(conditions.CHECKS)
local OPERATORS = ids(conditions.OPERATORS)
local MATCHES = ids(conditions.MATCHES)

-- A value that's the right type and within the limits, or nil.
local function plain(value, wanted)
    local kind = type(value)
    if kind ~= wanted then return nil end
    if kind == "string" and #value > MAX_STRING then return nil end
    if kind == "number" and (value ~= value or value > MAX_NUMBER or value < -MAX_NUMBER) then return nil end
    return value
end

-- The items of a list (1..n, up to MAX_LIST), each made by `make`, which
-- returns nil for one to skip.
local function list(value, make)
    if type(value) ~= "table" then return nil end
    local result = {}
    for index = 1, MAX_LIST do
        local item = value[index]
        if item == nil then break end
        local made = type(item) == "table" and make(item) or nil
        if made ~= nil then result[#result + 1] = made end
    end
    return result
end

-- The fields of `value` that `fields` lists, with the right types.
local function fieldsOf(value, fields)
    local result = {}
    for key, wanted in pairs(fields) do
        if wanted ~= "table" then result[key] = plain(value[key], wanted) end
    end
    return result
end

local function check(value)
    if not CHECK_KINDS[value.kind] then return nil end
    local result = {
        kind = value.kind,
        op = OPERATORS[value.op] and value.op or nil,
        source = plain(value.source, "string"),
        sourceType = plain(value.sourceType, "string"),
    }
    local checkValue = value.value
    if type(checkValue) == "boolean" or plain(checkValue, "number") ~= nil then result.value = checkValue end
    return result
end

local function change(value)
    local property = conditions.Property(value.property)
    if property == nil then return nil end
    local wanted = KIND_TYPES[property.kind]
    if wanted == nil or plain(value.value, wanted) == nil then return nil end
    return { property = value.property, value = value.value, text = plain(value.text, "number") }
end

local function condition(value)
    return {
        match = MATCHES[value.match] and value.match or nil,
        key = plain(value.key, "number"),
        checks = list(value.checks, check) or {},
        changes = list(value.changes, change) or {},
    }
end

local function textNode(value)
    return fieldsOf(value, TEXT_FIELDS)
end

local function load(value)
    local result = { checks = list(value.checks, check) }
    if type(value.options) == "table" then
        result.options = {}
        local count = 0
        for id, setting in pairs(value.options) do
            count = count + 1
            if count > MAX_LIST then break end
            if plain(id, "string") ~= nil and type(setting) == "table" then
                local settingValue = setting.value
                if type(settingValue) ~= "boolean" then settingValue = plain(settingValue, "string") end
                result.options[id] = { enabled = setting.enabled == true, value = settingValue }
            end
        end
    end
    return result
end

-- A record with only what's expected in it, or nil if it can't be one.
local function record(value)
    if type(value) ~= "table" or plain(value.id, "number") == nil then return nil end
    local result = fieldsOf(value, FIELDS)
    if result.display ~= nil and displayTypes.Get(result.display) == nil then result.display = nil end
    result.conditions = list(value.conditions, condition)
    result.texts = list(value.texts, textNode)
    result.load = type(value.load) == "table" and load(value.load) or nil
    return result
end

-- A short checksum of a whole export, as 4 hex digits, naming its parts.
local function checksum(text)
    local hash = 5381
    for index = 1, #text do hash = (hash * 33 + text:byte(index)) & 0xFFFF end
    return string.format("%04X", hash)
end

-- `text` broken into chunks by spaces, so a text box can wrap it.
local function spaced(text)
    local chunks = {}
    for index = 1, #text, CHUNK_LENGTH do chunks[#chunks + 1] = text:sub(index, index + CHUNK_LENGTH - 1) end
    return table.concat(chunks, " ")
end

-- The aura or group `auraID` and everything in it as text to copy: a list
-- of one string, or of parts (see above) if it's too long for one input
-- field. nil if there's no such aura. areaWidth/areaHeight (the game
-- area's size) keep its place on screen if it's in a group.
function auraShare.Export(auraID, areaWidth, areaHeight)
    local records = auraStore.ExportRecords(auraID, areaWidth, areaHeight)
    if records == nil then return nil end
    for _, record in ipairs(records) do dropDefaults(record) end
    local payload = renameKeys({ version = FORMAT_VERSION, records = records }, SHORT, 0)
    local packed = lzw.Compress(serializer.Encode(payload))
    local text = PREFIX .. base64.Encode(packed)
    if #text <= PART_LENGTH then return { spaced(text) } end
    local count = (#text + PART_LENGTH - 1) // PART_LENGTH
    local check = checksum(text)
    local parts = {}
    for index = 1, count do
        local slice = text:sub((index - 1) * PART_LENGTH + 1, index * PART_LENGTH)
        parts[index] = spaced(PART_PREFIX .. check .. ":" .. index .. "/" .. count .. ":" .. slice)
    end
    return parts
end

-- The whole export from the pasted boxes: one export in one box, or every
-- part of one in any order. Returns it, or nil, why not and, for parts,
-- how many there are (so the player can be given that many boxes).
local function join(texts)
    local pasted = {}
    for _, text in ipairs(texts) do
        if type(text) == "string" then
            if #text > MAX_TEXT then return nil, "That's too long to be an aura." end
            -- Pasting can bring spaces and line breaks with it.
            text = text:gsub("%s", "")
            if text ~= "" then pasted[#pasted + 1] = text end
        end
    end
    if #pasted == 0 then return nil, "Paste an aura's export string first." end
    if pasted[1]:sub(1, #PART_PREFIX) ~= PART_PREFIX then
        if #pasted > 1 then return nil, "Paste one export at a time: each box should hold a part of the same one." end
        return pasted[1]
    end
    local check, count = nil, nil
    local slices = {}
    for _, text in ipairs(pasted) do
        local partCheck, index, total, slice = text:match("^RAP1:(%x%x%x%x):(%d+)/(%d+):(.*)$")
        index, total = tonumber(index), tonumber(total)
        if partCheck == nil or index == nil or total == nil or total < 1 or total > MAX_PARTS
            or index < 1 or index > total then
            return nil, "One of the boxes isn't a part of a Rune Auras export."
        end
        if check ~= nil and (partCheck ~= check or total ~= count) then
            return nil, "Those parts are from different exports.", count
        end
        check, count = partCheck, total
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
    if checksum(text) ~= check then return nil, "Those parts are incomplete or damaged.", count end
    return text
end

-- The checked records in a pasted string, or nil and why not.
local function read(texts)
    if type(texts) == "string" then texts = { texts } end
    if type(texts) ~= "table" then return nil, "Nothing to import." end
    local text, problem, partsNeeded = join(texts)
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
        local checked = record(value)
        if checked ~= nil then records[#records + 1] = checked end
    end
    if #records == 0 then return nil, "That export has no auras in it." end
    return records
end

-- Adds the auras in the pasted text as new ones, in `groupID` (nil: the top
-- level) where they were on screen. `texts` is what's in each box (or one
-- string). Returns the auras made (the first is the one that was
-- exported), or nil, a message for the player and, for a multi-part
-- export, how many parts it has. Never errors: anything unexpected is
-- caught and reported as a failed import.
function auraShare.Import(texts, groupID, areaWidth, areaHeight)
    local ok, records, problem, partsNeeded = pcall(read, texts)
    if not ok then return nil, "That export couldn't be read." end
    if records == nil then return nil, problem, partsNeeded end
    local added, made = pcall(auraStore.AddImported, records, groupID, areaWidth, areaHeight)
    if not added then return nil, "That export couldn't be read." end
    if #made == 0 then return nil, "That export has no auras in it." end
    return made
end

return auraShare
