-- Text templates: an aura's text with placeholders, filled with its values.
-- Placeholders: $current, $max, $stacks (a buff's stack count; empty for
-- sources without one), $charges (an ability's charges ready: the same
-- value, named for abilities), $name (the source's name; for "Any
-- channel", what's being channelled) and $arrow (the quiver's ammo, "Ful"
-- for Ful arrows; empty for every other source).

local textTemplate = {}

textTemplate.DEFAULT = "$current / $max"
-- Shown instead while a display has no data (e.g. at the login screen).
textTemplate.NO_DATA = "No data"

-- A compiled template's parts are literal strings, or one of these.
local CURRENT, MAXIMUM, STACKS, NAME, CHARGES, ARROW = 1, 2, 3, 4, 5, 6
-- Placeholder names, indexed by their part.
local PLACEHOLDERS = { [CURRENT] = "current", [MAXIMUM] = "max", [STACKS] = "stacks", [NAME] = "name",
    [CHARGES] = "charges", [ARROW] = "arrow" }
-- Compiled templates are cached; typing a template in the editor makes a
-- new one per keystroke, so the cache is cleared once it gets this big.
local MAX_COMPILED = 64
-- Taken off before rounding up, so a value a float's error above a whole
-- number doesn't round up to the next one.
local ROUNDING_SLACK = 1e-9

---@type table<string, (string|integer)[]> Template to its parts, so formatting (several times a second per aura) doesn't re-parse it.
local compiled = {}
local compiledCount = 0
-- Reused between calls to build the text without a new table each time.
local buffer = {}

--- Splits a template into literal strings and placeholder parts. A
--- placeholder may run into letters ("$maxHP"); unknown ones such as "$foo"
--- are left as written.
---@param template string
---@return (string|integer)[] parts
local function compile(template)
    local parts = {}
    local position = 1
    for start, word in string.gmatch(template, "()%$(%a+)") do
        for part, placeholder in ipairs(PLACEHOLDERS) do
            if string.sub(word, 1, #placeholder) == placeholder then
                parts[#parts + 1] = string.sub(template, position, start - 1)
                parts[#parts + 1] = part
                position = start + 1 + #placeholder
                break
            end
        end
    end
    parts[#parts + 1] = string.sub(template, position)
    return parts
end

--- A value as text: whole numbers without ".0", and values at or above
--- `decimalsBelow` rounded up to whole, so a value only reads 0 once it
--- really is 0.
---@param value any
---@param decimalsBelow number?
---@return string
local function formatValue(value, decimalsBelow)
    if decimalsBelow ~= nil and type(value) == "number" and value >= decimalsBelow then
        value = math.ceil(value - ROUNDING_SLACK)
    end
    return tostring(math.tointeger(value) or value)
end

--- A template's compiled parts, compiling and caching it if needed.
---@param template string
---@return (string|integer)[]
local function partsOf(template)
    local parts = compiled[template]
    if parts ~= nil then return parts end
    if compiledCount >= MAX_COMPILED then
        compiled, compiledCount = {}, 0
    end
    parts = compile(template)
    compiled[template] = parts
    compiledCount = compiledCount + 1
    return parts
end

--- Fills a template with values.
--- `Format("$current / $max", 57, 100)` gives "57 / 100";
--- `Format("$current", 12.4, 30, 10)` gives "13", since 12.4 is at or above 10.
---@param template string? nil for DEFAULT.
---@param curr any Current value.
---@param max any Maximum value.
---@param decimalsBelow number? Values at or above this show whole, rounded up.
---@param stacks number? Stacks or charges; nil leaves $stacks and $charges empty.
---@param name string? For $name.
---@param arrow string? For $arrow.
---@return string
function textTemplate.Format(template, curr, max, decimalsBelow, stacks, name, arrow)
    local parts = partsOf(template or textTemplate.DEFAULT)
    local current = formatValue(curr, decimalsBelow)
    local maximum = formatValue(max, decimalsBelow)
    for index, part in ipairs(parts) do
        if part == CURRENT then
            buffer[index] = current
        elseif part == MAXIMUM then
            buffer[index] = maximum
        elseif part == STACKS or part == CHARGES then
            buffer[index] = stacks ~= nil and formatValue(stacks) or ""
        elseif part == NAME then
            buffer[index] = name or ""
        elseif part == ARROW then
            buffer[index] = arrow or ""
        else
            buffer[index] = part
        end
    end
    return table.concat(buffer, "", 1, #parts)
end

return textTemplate
