-- JSON for sharing auras. Decode only parses pasted text, refusing anything
-- malformed, too deep or too big. Strings are the game's bytes: each one outside
-- printable ASCII, and "<" (a tag in game text), is written as \u00XX.

local json = {}

local MAX_DEPTH = 32
-- Values in one text, all told: far more than any real export.
local MAX_VALUES = 200000
-- The fewest significant digits tried for a float; more are added until it
-- reads back the same.
local MIN_FLOAT_DIGITS, MAX_FLOAT_DIGITS = 15, 17
-- The highest \u code that fits in one byte; any above it reads as this,
-- as the game shows characters outside its set.
local MAX_BYTE_CODE = 0xFF
local UNKNOWN_CHAR = "?"
-- Where a key with no rank goes: after the ranked ones, by name.
local UNRANKED = math.huge

--- How Encode lays text out.
---@class JsonStyle
---@field comma string Between items.
---@field colon string Between a key and its value.
---@field keyRanks table<string, integer> Object keys to their place: lower first.

-- Encode's separators: a space after each comma and colon, so it reads well.
local SPACED_COMMA, SPACED_COLON = ", ", ": "

-- A byte to how Encode writes it inside a string, for every byte that isn't
-- written as itself.
local ESCAPES = { [34] = '\\"', [92] = "\\\\", [8] = "\\b", [12] = "\\f", [10] = "\\n", [13] = "\\r", [9] = "\\t" }
local TAG_START = ("<"):byte()
for byte = 0, 255 do
    local isPlain = byte >= 32 and byte < 127 and byte ~= TAG_START
    if not isPlain and ESCAPES[byte] == nil then
        ESCAPES[byte] = string.format("\\u%04X", byte)
    end
end
local ESCAPED_CHARS = {}
for byte, escape in pairs(ESCAPES) do
    ESCAPED_CHARS[string.char(byte)] = escape
end
-- The bytes ESCAPES covers: quote, backslash, control bytes, "<", and 127 up.
local ESCAPED_PATTERN = '[\0-\31"\\<\127-\255]'

-- An escape's letter to the byte it stands for (\u is read apart).
local UNESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
-- What ends a run of plain characters in a string: its closing quote, an
-- escape, or a control byte (which must be escaped).
local STRING_STOP_PATTERN = '[\0-\31"\\]'
local NUMBER_PATTERN = "^-?%d+%.?%d*[eE]?[%-+]?%d*"
local NOT_SPACE_PATTERN = "[^ \t\r\n]"
local LITERALS = { ["true"] = true, ["false"] = false }

--- Where a decode is up to.
---@class JsonDecodeState
---@field text string
---@field position integer Index of the next character to read.
---@field values integer How many values have been read, for MAX_VALUES.

--- Whether a number is neither NaN nor infinite.
---@param number number
---@return boolean
local function isFinite(number)
    return number == number and number ~= math.huge and number ~= -math.huge
end

--- A number as JSON: an integer as itself, a float with the fewest digits
--- that read back the same.
---@param number number
---@return string
local function formatNumber(number)
    if not isFinite(number) then
        error("can't encode a non-finite number")
    end

    local integer = math.tointeger(number)
    if integer ~= nil then
        return tostring(integer)
    end

    local text
    for digits = MIN_FLOAT_DIGITS, MAX_FLOAT_DIGITS do
        text = string.format("%." .. digits .. "g", number)

        if tonumber(text) == number then
            break
        end
    end

    return text
end

--- Whether a table is a list: keys 1 to n and nothing else, at least one.
---@param value table
---@return boolean
local function isList(value)
    local length = #value
    if length == 0 then
        return false
    end

    local count = 0
    for key in pairs(value) do
        if math.type(key) ~= "integer" or key < 1 or key > length then
            return false
        end

        count = count + 1
    end

    return count == length
end

--- A table's keys in the order they're written: ranked ones by rank, then
--- the rest by name. Errors on a key that isn't a string.
---@param value table
---@param keyRanks table<string, integer>
---@return string[]
local function sortedKeys(value, keyRanks)
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "string" then
            error("can't encode a " .. type(key) .. " key outside a list")
        end

        keys[#keys + 1] = key
    end

    table.sort(keys, function(first, second)
        local firstRank, secondRank = keyRanks[first] or UNRANKED, keyRanks[second] or UNRANKED
        if firstRank ~= secondRank then
            return firstRank < secondRank
        end

        return first < second
    end)

    return keys
end

local encodeValue

--- Appends a table as a JSON array or object to `out`.
---@param value table
---@param out string[]
---@param depth integer
---@param style JsonStyle
local function encodeTable(value, out, depth, style)
    if depth >= MAX_DEPTH then
        error("too deeply nested to encode")
    end

    if isList(value) then
        out[#out + 1] = "["

        for index, item in ipairs(value) do
            if index > 1 then
                out[#out + 1] = style.comma
            end

            encodeValue(item, out, depth + 1, style)
        end

        out[#out + 1] = "]"
        return
    end

    out[#out + 1] = "{"

    for index, key in ipairs(sortedKeys(value, style.keyRanks)) do
        if index > 1 then
            out[#out + 1] = style.comma
        end

        encodeValue(key, out, depth + 1, style)
        out[#out + 1] = style.colon
        encodeValue(value[key], out, depth + 1, style)
    end

    out[#out + 1] = "}"
end

--- Appends a value's JSON to `out`. Errors on what can't be encoded.
---@param value any
---@param out string[]
---@param depth integer Tables it's inside.
---@param style JsonStyle
function encodeValue(value, out, depth, style)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = '"' .. value:gsub(ESCAPED_PATTERN, ESCAPED_CHARS) .. '"'
    elseif kind == "number" then
        out[#out + 1] = formatNumber(value)
    elseif kind == "boolean" then
        out[#out + 1] = tostring(value)
    elseif kind == "table" then
        encodeTable(value, out, depth, style)
    else
        error("can't encode a " .. kind)
    end
end

--- Encodes a value in a style.
---@param value any
---@param style JsonStyle
---@return string
local function encode(value, style)
    local out = {}
    encodeValue(value, out, 0, style)
    return table.concat(out)
end

--- Encodes a value as JSON to read: on one line, with a space after each
--- comma and colon. A table with keys 1 to n is an array, any other an
--- object, whose keys must be strings. It only encodes the plugin's data, so a value it
--- can't encode is a bug: it errors.
---@param value any
---@param keyRanks table<string, integer>? Object keys to their place: lower first, the rest after by name.
---@return string
function json.Encode(value, keyRanks)
    return encode(value, { comma = SPACED_COMMA, colon = SPACED_COLON, keyRanks = keyRanks or {} })
end

--- Encodes a value as JSON with no spaces, as Encode otherwise does, with
--- object keys by name.
---@param value any
---@return string
function json.EncodeCompact(value)
    return encode(value, { comma = ",", colon = ":", keyRanks = {} })
end

--- Moves past any whitespace.
---@param state JsonDecodeState
local function skipSpace(state)
    state.position = state.text:find(NOT_SPACE_PATTERN, state.position) or #state.text + 1
end

--- The character at the state's position.
---@param state JsonDecodeState
---@return string char "" at the end.
local function peek(state)
    return state.text:sub(state.position, state.position)
end

--- Reads a \u escape's code (the position is at its "u").
---@param state JsonDecodeState
---@return string? char The byte it stands for, or UNKNOWN_CHAR above MAX_BYTE_CODE.
---@return string? problem
local function decodeUnicode(state)
    local hex = state.text:match("^%x%x%x%x", state.position + 1)
    if hex == nil then
        return nil, "bad \\u escape"
    end

    state.position = state.position + 1 + #hex
    local code = tonumber(hex, 16)
    if code > MAX_BYTE_CODE then
        return UNKNOWN_CHAR
    end

    return string.char(code)
end

--- Reads an escape (the position is at its backslash).
---@param state JsonDecodeState
---@return string? char
---@return string? problem
local function decodeEscape(state)
    state.position = state.position + 1
    local letter = peek(state)
    if letter == "u" then
        return decodeUnicode(state)
    end

    local char = UNESCAPES[letter]
    if char == nil then
        return nil, "bad escape"
    end

    state.position = state.position + 1
    return char
end

--- Reads a string at the state's position (its opening quote).
---@param state JsonDecodeState
---@return string? value
---@return string? problem
local function decodeString(state)
    local text = state.text
    local pieces = {}
    state.position = state.position + 1

    while true do
        local stop = text:find(STRING_STOP_PATTERN, state.position)
        if stop == nil then
            return nil, "unclosed string"
        end

        pieces[#pieces + 1] = text:sub(state.position, stop - 1)
        state.position = stop
        local char = peek(state)
        if char == '"' then
            state.position = stop + 1
            return table.concat(pieces)
        end

        if char ~= "\\" then
            return nil, "unescaped control character in a string"
        end

        local unescaped, problem = decodeEscape(state)
        if unescaped == nil then
            return nil, problem
        end

        pieces[#pieces + 1] = unescaped
    end
end

--- Reads a number at the state's position.
---@param state JsonDecodeState
---@return number? value
---@return string? problem
local function decodeNumber(state)
    local digits = state.text:match(NUMBER_PATTERN, state.position)
    local number = digits and tonumber(digits)
    if number == nil or not isFinite(number) then
        return nil, "bad number"
    end

    state.position = state.position + #digits
    return math.tointeger(number) or number
end

--- Reads true, false or null at the state's position.
---@param state JsonDecodeState
---@return boolean? value nil for null.
---@return string? problem
---@return boolean? isNull
local function decodeLiteral(state)
    local word = state.text:match("^%a+", state.position)
    if word == nil then
        return nil, "expected a value"
    end

    if word == "null" then
        state.position = state.position + #word
        return nil, nil, true
    end

    local value = LITERALS[word]
    if value == nil then
        return nil, "unexpected word"
    end

    state.position = state.position + #word
    return value
end

local decodeValue

--- Reads the items of an array or the members of an object, separated by
--- commas, up to the closing bracket (the position is at the opening one).
---@param state JsonDecodeState
---@param closer string "]" or "}".
---@param readItem fun(): boolean, string? Reads one item; false and a problem on failure.
---@return boolean ok
---@return string? problem
local function decodeItems(state, closer, readItem)
    state.position = state.position + 1
    skipSpace(state)

    if peek(state) == closer then
        state.position = state.position + 1
        return true
    end

    while true do
        local ok, problem = readItem()
        if not ok then
            return false, problem
        end

        skipSpace(state)
        local char = peek(state)
        if char == closer then
            state.position = state.position + 1
            return true
        end

        if char ~= "," then
            return false, "expected , or " .. closer
        end

        state.position = state.position + 1
        skipSpace(state)
    end
end

--- Reads an array at the state's position. Nulls in it are left out.
---@param state JsonDecodeState
---@param depth integer
---@return table? value
---@return string? problem
local function decodeArray(state, depth)
    local result = {}
    local ok, problem = decodeItems(state, "]", function()
        local item, itemProblem, isNull = decodeValue(state, depth + 1)
        if item == nil and not isNull then
            return false, itemProblem
        end

        if item ~= nil then
            result[#result + 1] = item
        end

        return true
    end)
    if not ok then
        return nil, problem
    end

    return result
end

--- Reads an object at the state's position. A member that's null is left out.
---@param state JsonDecodeState
---@param depth integer
---@return table? value
---@return string? problem
local function decodeObject(state, depth)
    local result = {}
    local ok, problem = decodeItems(state, "}", function()
        if peek(state) ~= '"' then
            return false, "expected a key in quotes"
        end

        local key, keyProblem = decodeString(state)
        if key == nil then
            return false, keyProblem
        end

        skipSpace(state)

        if peek(state) ~= ":" then
            return false, "expected :"
        end

        state.position = state.position + 1
        skipSpace(state)
        local item, itemProblem, isNull = decodeValue(state, depth + 1)
        if item == nil and not isNull then
            return false, itemProblem
        end

        result[key] = item
        return true
    end)
    if not ok then
        return nil, problem
    end

    return result
end

--- Reads any value at the state's position.
---@param state JsonDecodeState
---@param depth integer Arrays and objects it's inside.
---@return any value nil for null or on failure.
---@return string? problem Why it failed; nil for null.
---@return boolean? isNull
function decodeValue(state, depth)
    state.values = state.values + 1

    if state.values > MAX_VALUES then
        return nil, "too much data"
    end

    local char = peek(state)
    if char == "{" or char == "[" then
        if depth >= MAX_DEPTH then
            return nil, "nested too deeply"
        end

        if char == "{" then
            return decodeObject(state, depth)
        end

        return decodeArray(state, depth)
    end

    if char == '"' then
        return decodeString(state)
    end

    if char == "-" or char:match("^%d$") then
        return decodeNumber(state)
    end

    return decodeLiteral(state)
end

--- The value in a JSON text, with whitespace allowed around it. Nulls in
--- objects and arrays are left out; trailing data is refused.
---@param text any
---@return any value nil if it can't be read (or is null).
---@return string? problem Why not, and where ("expected : at character 52", "expected , or ] at the end").
function json.Decode(text)
    if type(text) ~= "string" then
        return nil, "not text"
    end

    local state = { text = text, position = 1, values = 0 }
    skipSpace(state)
    local value, problem, isNull = decodeValue(state, 0)
    if isNull then
        return nil, "null"
    end

    if value ~= nil then
        skipSpace(state)

        if state.position > #text then
            return value
        end

        problem = "text after the end"
    end

    local isAtEnd = state.position > #text
    return nil, problem .. (isAtEnd and " at the end" or " at character " .. state.position)
end

return json
