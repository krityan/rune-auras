-- Text templates: an aura's text, one field of the source's values or two
-- with a separator ("$value / $max"), so a text shows only what the game
-- gives. Owns the fields, the separators and filling a template in.

local textTemplate = {}

---@alias TextFieldID "value"|"max"|"percent"|"stacks"|"charges"|"name"|"ammo"|"target"|"level"|"hitChance"|"weakness"

---@class TextField
---@field id TextFieldID
---@field label string As the editor shows it.
---@field isNumber boolean? Two numbers are separated by " / " by default.

--- Every field, in the order the editor lists them. $percent is the value
--- as a percentage of the max, rounded to the text's percent decimals.
--- $stacks is a buff's
--- stack count and $charges an ability's charges ready (the same value,
--- named for each), both empty for sources without one. $name is the
--- source's name (for "Any channel", what's being channelled). $ammo is
--- the quiver's ammo ("Ful" for Ful arrows or bolts). $target, $level,
--- $hitChance and $weakness are about the player's target (its name, combat
--- level, the player's chance to hit it and its weakness), for target
--- sources. Each is empty for sources without one.
---@type TextField[]
textTemplate.FIELDS = {
    { id = "value", label = "Value", isNumber = true },
    { id = "max", label = "Max", isNumber = true },
    { id = "percent", label = "Percent", isNumber = true },
    { id = "stacks", label = "Stacks" },
    { id = "charges", label = "Charges" },
    { id = "name", label = "Name" },
    { id = "ammo", label = "Ammo" },
    { id = "target", label = "Target" },
    { id = "level", label = "Target level" },
    { id = "hitChance", label = "Hit chance" },
    { id = "weakness", label = "Weakness" },
}

--- Every separator, in the order the editor lists them.
---@type Choice[]
textTemplate.SEPARATORS = {
    { id = " / ", label = "/" },
    { id = " - ", label = "-" },
    { id = ": ", label = ":" },
}
local SLASH, DASH, COLON = textTemplate.SEPARATORS[1].id, textTemplate.SEPARATORS[2].id,
    textTemplate.SEPARATORS[3].id

textTemplate.DEFAULT = "$value"
-- Shown instead while a display has no data (e.g. at the login screen).
textTemplate.NO_DATA = "No data"

-- The most decimals $percent can show.
textTemplate.MAX_PERCENT_DECIMALS = 3
-- $percent's format for each number of decimals, from 0.
local PERCENT_FORMATS = { "%.0f%%", "%.1f%%", "%.2f%%", "%.3f%%" }

-- Taken off before rounding up, so a value a float's error above a whole
-- number doesn't round up to the next one.
local ROUNDING_SLACK = 1e-9

---@type table<string, TextField>
local FIELDS_BY_ID = {}
for _, field in ipairs(textTemplate.FIELDS) do FIELDS_BY_ID[field.id] = field end

--- The separator a second field gets by default: " / " between two
--- numbers, ": " after a name, else " - ".
---@param first TextFieldID
---@param second TextFieldID
---@return string
function textTemplate.DefaultSeparator(first, second)
    if FIELDS_BY_ID[first].isNumber and FIELDS_BY_ID[second].isNumber then return SLASH end
    if first == "name" then return COLON end
    return DASH
end

--- A template from its fields and separator.
---@param first TextFieldID
---@param separator string? Ignored without a second field.
---@param second TextFieldID?
---@return string
function textTemplate.Join(first, separator, second)
    if second == nil then return "$" .. first end
    return "$" .. first .. separator .. "$" .. second
end

---@class TemplateParts
---@field first TextFieldID
---@field separator string?
---@field second TextFieldID?

---@type table<string, TemplateParts> Every valid template to its parts.
local PARTS = {}
for _, first in ipairs(textTemplate.FIELDS) do
    PARTS[textTemplate.Join(first.id)] = { first = first.id }
    for _, second in ipairs(textTemplate.FIELDS) do
        for _, separator in ipairs(textTemplate.SEPARATORS) do
            PARTS[textTemplate.Join(first.id, separator.id, second.id)] =
                { first = first.id, separator = separator.id, second = second.id }
        end
    end
end

--- Whether a template shows a field.
---@param template string?
---@param field TextFieldID
---@return boolean
function textTemplate.HasField(template, field)
    local parts = textTemplate.Parts(template)
    return parts.first == field or parts.second == field
end

--- Whether a text is a template: one field, or two with one of SEPARATORS.
---@param text any
---@return boolean
function textTemplate.IsValid(text)
    return PARTS[text] ~= nil
end

--- A template's parts; one that isn't valid (a damaged save or a pasted
--- aura) has DEFAULT's.
---@param template string?
---@return TemplateParts
function textTemplate.Parts(template)
    return PARTS[template] or PARTS[textTemplate.DEFAULT]
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

--- The value as a percentage of the max, rounded to `decimals` (0 to
--- MAX_PERCENT_DECIMALS; anything else is brought within them). A max of 0
--- reads 0%.
---@param curr any
---@param max any
---@param decimals any
---@return string
local function percentText(curr, max, decimals)
    if type(curr) ~= "number" or type(max) ~= "number" then return "" end
    local percent = max > 0 and curr / max * 100 or 0
    decimals = math.floor(tonumber(decimals) or 0)
    decimals = math.max(0, math.min(textTemplate.MAX_PERCENT_DECIMALS, decimals))
    return string.format(PERCENT_FORMATS[decimals + 1], percent)
end

--- One of the target's fields' text.
---@param field TextFieldID
---@param target TargetInfo?
---@return string
local function targetFieldText(field, target)
    if target == nil then return "" end
    if field == "target" then return target.name or "" end
    if field == "level" then return target.level ~= nil and formatValue(target.level) or "" end
    if field == "hitChance" then return target.hitChance ~= nil and formatValue(target.hitChance) .. "%" or "" end
    return target.weakness or ""
end

--- One field's text.
---@param field TextFieldID
---@param curr any
---@param max any
---@param decimalsBelow number?
---@param stacks number?
---@param name string?
---@param ammo string?
---@param target TargetInfo?
---@param percentDecimals integer?
---@return string
local function fieldText(field, curr, max, decimalsBelow, stacks, name, ammo, target, percentDecimals)
    if field == "value" then return formatValue(curr, decimalsBelow) end
    if field == "max" then return formatValue(max, decimalsBelow) end
    if field == "percent" then return percentText(curr, max, percentDecimals) end
    if field == "stacks" or field == "charges" then return stacks ~= nil and formatValue(stacks) or "" end
    if field == "name" then return name or "" end
    if field == "ammo" then return ammo or "" end
    return targetFieldText(field, target)
end

--- Fills a template with values.
--- `Format("$value / $max", 57, 100)` gives "57 / 100";
--- `Format("$value", 12.4, 30, 10)` gives "13", since 12.4 is at or above 10.
---@param template string? nil for DEFAULT.
---@param curr any Current value.
---@param max any Maximum value.
---@param decimalsBelow number? Values at or above this show whole, rounded up.
---@param stacks number? Stacks or charges; nil leaves $stacks and $charges empty.
---@param name string? For $name.
---@param ammo string? For $ammo.
---@param target TargetInfo? For $target, $level, $hitChance and $weakness.
---@param percentDecimals integer? Decimals for $percent; nil for none.
---@return string
function textTemplate.Format(template, curr, max, decimalsBelow, stacks, name, ammo, target, percentDecimals)
    local parts = textTemplate.Parts(template or textTemplate.DEFAULT)
    local text = fieldText(parts.first, curr, max, decimalsBelow, stacks, name, ammo, target, percentDecimals)
    if parts.second == nil then return text end
    return text .. parts.separator
        .. fieldText(parts.second, curr, max, decimalsBelow, stacks, name, ammo, target, percentDecimals)
end

return textTemplate
