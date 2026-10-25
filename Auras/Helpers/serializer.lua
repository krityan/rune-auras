-- Turns plain data (tables of strings, numbers and booleans, nested) into a
-- compact string and back, for sharing auras. Decode only parses: nothing
-- in the text is ever run, and anything malformed, too deep or too big is
-- refused with a reason rather than an error.
-- Format: a string is s<length>:<bytes> (so it needs no escaping), a number
-- n<number>; , true t, false f, and a table { key value ... }.

local serializer = {}

local MAX_DEPTH = 32
-- Values in one text, all told: far more than any real export.
local MAX_VALUES = 200000
-- A string length longer than this many digits is refused rather than read.
local MAX_LENGTH_DIGITS = 9
-- Enough significant digits to read back the same float.
local FLOAT_FORMAT = "%.17g"

--- Where a decode is up to.
---@class DecodeState
---@field text string
---@field position integer Index of the next character to read.
---@field values integer How many values have been read, for MAX_VALUES.

--- Whether a number is neither NaN nor infinite.
---@param number number
---@return boolean
local function isFinite(number)
    return number == number and number ~= math.huge and number ~= -math.huge
end

--- Appends a value's encoding to `out`. Errors on what can't be encoded.
---@param value any
---@param out string[]
---@param depth integer Tables it's inside.
local function encodeValue(value, out, depth)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = "s" .. #value .. ":" .. value
    elseif kind == "number" then
        if not isFinite(value) then error("can't encode a non-finite number") end
        local integer = math.tointeger(value)
        out[#out + 1] = "n" .. (integer and tostring(integer) or string.format(FLOAT_FORMAT, value)) .. ";"
    elseif kind == "boolean" then
        out[#out + 1] = value and "t" or "f"
    elseif kind == "table" then
        if depth >= MAX_DEPTH then error("too deeply nested to encode") end
        out[#out + 1] = "{"
        for key, item in pairs(value) do
            local keyKind = type(key)
            -- Other keys (tables, functions) can't come back, so they're left out.
            if keyKind == "string" or keyKind == "number" then
                encodeValue(key, out, depth + 1)
                encodeValue(item, out, depth + 1)
            end
        end
        out[#out + 1] = "}"
    else
        error("can't encode a " .. kind)
    end
end

--- Encodes a value. It's our own data only, so a value it can't encode is a
--- bug: it errors.
---@param value any
---@return string
function serializer.Encode(value)
    local out = {}
    encodeValue(value, out, 0)
    return table.concat(out)
end

local decodeValue

--- Reads a string (s<length>:<bytes>) at the state's position.
---@param state DecodeState
---@return string? value
---@return string? problem
local function decodeString(state)
    local text, position = state.text, state.position
    local digits = text:match("^%d+", position + 1)
    if digits == nil or #digits > MAX_LENGTH_DIGITS then return nil, "bad string length" end
    local length = tonumber(digits)
    local colon = position + 1 + #digits
    if text:sub(colon, colon) ~= ":" then return nil, "bad string" end
    local finish = colon + length
    if finish > #text then return nil, "string runs past the end" end
    state.position = finish + 1
    return text:sub(colon + 1, finish)
end

--- Reads a number (n<number>;) at the state's position.
---@param state DecodeState
---@return number? value
---@return string? problem
local function decodeNumber(state)
    local text, position = state.text, state.position
    local digits = text:match("^[%-%+%d%.eE]+", position + 1)
    if digits == nil then return nil, "bad number" end
    local number = tonumber(digits)
    local semicolon = position + 1 + #digits
    if number == nil or not isFinite(number) or text:sub(semicolon, semicolon) ~= ";" then
        return nil, "bad number"
    end
    state.position = semicolon + 1
    return math.tointeger(number) or number
end

--- Reads a table ({ key value ... }) at the state's position.
---@param state DecodeState
---@param depth integer
---@return table? value
---@return string? problem
local function decodeTable(state, depth)
    if depth >= MAX_DEPTH then return nil, "nested too deeply" end
    local text = state.text
    state.position = state.position + 1
    local result = {}
    while true do
        if state.position > #text then return nil, "table runs past the end" end
        if text:sub(state.position, state.position) == "}" then
            state.position = state.position + 1
            return result
        end
        local key, problem = decodeValue(state, depth + 1)
        if key == nil then return nil, problem end
        local keyKind = type(key)
        if keyKind ~= "string" and keyKind ~= "number" then return nil, "bad table key" end
        local item
        item, problem = decodeValue(state, depth + 1)
        if item == nil then return nil, problem end
        result[key] = item
    end
end

--- Reads any value at the state's position.
---@param state DecodeState
---@param depth integer Tables it's inside.
---@return any value nil on failure.
---@return string? problem Why it failed.
function decodeValue(state, depth)
    state.values = state.values + 1
    if state.values > MAX_VALUES then return nil, "too much data" end
    local position = state.position
    local tag = state.text:sub(position, position)
    if tag == "s" then return decodeString(state) end
    if tag == "n" then return decodeNumber(state) end
    if tag == "t" or tag == "f" then
        state.position = position + 1
        return tag == "t"
    end
    if tag == "{" then return decodeTable(state, depth) end
    return nil, "unexpected data"
end

--- The value encoded in a string. Trailing data is refused too.
---@param text any
---@return any value nil if it can't be read.
---@return string? problem Why not.
function serializer.Decode(text)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local state = { text = text, position = 1, values = 0 }
    local value, problem = decodeValue(state, 0)
    if value == nil then return nil, problem end
    if state.position <= #text then return nil, "unexpected data after the end" end
    return value
end

return serializer
