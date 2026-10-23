-- Fills an aura's text template with its values.
-- Placeholders: $current (current value), $max (maximum value), $stacks
-- (a buff's stack count; empty for sources without one) and $name (the
-- source's name; for "Any channel", what's being channelled).
-- Usage: local textTemplate = require("Auras/Helpers/text-template")
--        textTemplate.Format("$current / $max", 57, 100) --> "57 / 100"
--        textTemplate.Format("$current", 12.4, 30, 10)   --> "13"
-- The optional decimalsBelow drops the decimals from values at or above
-- it, rounding up, so a cooldown reads "13" then "9.9" below 10 seconds.

local textTemplate = {}

textTemplate.DEFAULT = "$current / $max"

local PLACEHOLDERS = { "current", "max", "stacks", "name" }
-- Compiled templates are cached; typing a template in the editor makes a
-- new one per keystroke, so the cache is cleared once it gets this big.
local MAX_COMPILED = 64

-- Template string -> its parts: literal strings, and placeholder indexes
-- into PLACEHOLDERS. Compiled once so formatting (several times a second
-- per aura) doesn't re-parse it.
local compiled = {}
local compiledCount = 0
-- Reused between calls to build the text without a new table each time.
local buffer = {}

local function compile(template)
    local parts = {}
    local position = 1
    -- A placeholder may run into letters ("$maxHP"); unknown ones such as
    -- "$foo" are left as written.
    for start, word in string.gmatch(template, "()%$(%a+)") do
        for index, name in ipairs(PLACEHOLDERS) do
            if string.sub(word, 1, #name) == name then
                parts[#parts + 1] = string.sub(template, position, start - 1)
                parts[#parts + 1] = index
                position = start + 1 + #name
                break
            end
        end
    end
    parts[#parts + 1] = string.sub(template, position)
    return parts
end

-- Rounding up means a value only reads 0 once it really is 0.
local function formatValue(value, decimalsBelow)
    if decimalsBelow ~= nil and type(value) == "number" and value >= decimalsBelow then
        value = math.ceil(value - 1e-9)
    end
    return tostring(math.tointeger(value) or value)
end

function textTemplate.Format(template, curr, max, decimalsBelow, stacks, name)
    template = template or textTemplate.DEFAULT
    local parts = compiled[template]
    if parts == nil then
        if compiledCount >= MAX_COMPILED then
            compiled, compiledCount = {}, 0
        end
        parts = compile(template)
        compiled[template] = parts
        compiledCount = compiledCount + 1
    end
    local current = formatValue(curr, decimalsBelow)
    local maximum = formatValue(max, decimalsBelow)
    for index, part in ipairs(parts) do
        if part == 1 then
            buffer[index] = current
        elseif part == 2 then
            buffer[index] = maximum
        elseif part == 3 then
            buffer[index] = stacks ~= nil and formatValue(stacks) or ""
        elseif part == 4 then
            buffer[index] = name or ""
        else
            buffer[index] = part
        end
    end
    return table.concat(buffer, "", 1, #parts)
end

return textTemplate
