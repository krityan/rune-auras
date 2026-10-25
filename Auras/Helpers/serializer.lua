-- Turns plain data (tables of strings, numbers and booleans, nested) into a
-- compact string and back, for sharing auras. Decode only parses: nothing
-- in the text is ever run, and anything malformed, too deep or too big is
-- refused with a reason rather than an error.
-- Format: a string is s<length>:<bytes> (so it needs no escaping), a
-- number n<number>; , true t, false f, and a table { key value ... }.
-- Usage: local serializer = require("Auras/Helpers/serializer")
--        local text = serializer.Encode({ a = 1, list = { "x" } })
--        local value, problem = serializer.Decode(text)

local serializer = {}

local MAX_DEPTH = 32
-- Values in one text, all told: far more than any real export.
local MAX_VALUES = 200000

local function isFinite(number)
    return number == number and number ~= math.huge and number ~= -math.huge
end

local function encodeValue(value, out, depth)
    local kind = type(value)
    if kind == "string" then
        out[#out + 1] = "s" .. #value .. ":" .. value
    elseif kind == "number" then
        if not isFinite(value) then error("can't encode a non-finite number") end
        local integer = math.tointeger(value)
        out[#out + 1] = "n" .. (integer and tostring(integer) or string.format("%.17g", value)) .. ";"
    elseif kind == "boolean" then
        out[#out + 1] = value and "t" or "f"
    elseif kind == "table" then
        if depth >= MAX_DEPTH then error("too deeply nested to encode") end
        out[#out + 1] = "{"
        for key, item in pairs(value) do
            local keyKind = type(key)
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

-- Our own data only, so a value it can't encode is a bug: it errors.
function serializer.Encode(value)
    local out = {}
    encodeValue(value, out, 0)
    return table.concat(out)
end

-- The parser's state: the text and where it's up to.
local function decodeValue(state, depth)
    state.values = state.values + 1
    if state.values > MAX_VALUES then return nil, "too much data" end
    local text, position = state.text, state.position
    local tag = text:sub(position, position)
    if tag == "s" then
        local digits = text:match("^%d+", position + 1)
        if digits == nil or #digits > 9 then return nil, "bad string length" end
        local length = tonumber(digits)
        local start = position + 1 + #digits
        if text:sub(start, start) ~= ":" then return nil, "bad string" end
        local finish = start + length
        if finish > #text then return nil, "string runs past the end" end
        state.position = finish + 1
        return text:sub(start + 1, finish)
    elseif tag == "n" then
        local digits = text:match("^[%-%+%d%.eE]+", position + 1)
        if digits == nil then return nil, "bad number" end
        local number = tonumber(digits)
        local finish = position + 1 + #digits
        if number == nil or not isFinite(number) or text:sub(finish, finish) ~= ";" then
            return nil, "bad number"
        end
        state.position = finish + 1
        return math.tointeger(number) or number
    elseif tag == "t" or tag == "f" then
        state.position = position + 1
        return tag == "t"
    elseif tag == "{" then
        if depth >= MAX_DEPTH then return nil, "nested too deeply" end
        state.position = position + 1
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
    return nil, "unexpected data"
end

-- The value in `text`, or nil and why not. Trailing data is refused too.
function serializer.Decode(text)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local state = { text = text, position = 1, values = 0 }
    local value, problem = decodeValue(state, 0)
    if value == nil then return nil, problem end
    if state.position <= #text then return nil, "unexpected data after the end" end
    return value
end

return serializer
