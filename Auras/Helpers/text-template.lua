-- Text templates: an aura's text, one field of the source's values or two
-- with a separator ("$value / $max"), so a text shows only what the game
-- gives. Owns the fields, the separators and filling a template in.

local textTemplate = {}

---@alias TextFieldID "value"|"max"|"percent"|"stacks"|"charges"|"name"|"ammo"|"keybind"|"eofKeybind"|"target"|"level"|"hitChance"|"weakness"

--- Text fields a source gives besides its values, name and ammo: its
--- target's details (see TargetInfo), or its ability's keybind; or how its
--- values are written.
---@class TextInfo
---@field name string? The target's name, for $target.
---@field level integer? Its combat level, for $level.
---@field hitChance number? The player's chance to hit it, in percent, for $hitChance.
---@field weakness string? Its weakness, for $weakness.
---@field keybind string? The ability's keybind on the action bars, for $keybind.
---@field eofKeybind string? A special attack's Essence of Finality keybind, for $eofKeybind.
---@field compactValues boolean? $value and $max of 1000 or more are written as the buff bar writes counts (1.5K).

---@class TextField
---@field id TextFieldID
---@field label string As the editor shows it.
---@field isNumber boolean? Two numbers are separated by " / " by default.

--- Every field, in the order the editor lists them. Each is empty for a source
--- without it.
---@type TextField[]
textTemplate.FIELDS = {
    { id = "value", label = "Value", isNumber = true },
    { id = "max", label = "Max", isNumber = true },
    -- The value as a percentage of the max, to the text's percent decimals.
    { id = "percent", label = "Percent", isNumber = true },
    -- A buff's stack count.
    { id = "stacks", label = "Stacks" },
    -- An ability's charges ready: the same value as $stacks, named for abilities.
    { id = "charges", label = "Charges" },
    -- The source's name; for "Any channel", what's being channelled.
    { id = "name", label = "Name" },
    -- The quiver's ammo ("Ful" for Ful arrows or bolts).
    { id = "ammo", label = "Ammo" },
    -- An ability's keybind from its first action bar slot; for a special
    -- attack, the Weapon special attack's.
    { id = "keybind", label = "Keybind" },
    -- The Essence of Finality special attack's keybind.
    { id = "eofKeybind", label = "EOF Keybind" },
    -- For target sources: the target's name, combat level, the player's
    -- chance to hit it, and its weakness.
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

---@alias TimeFormatID "clock"|"seconds"|"tenths"|"units"|"ticks"

---@class TimeFormat : Choice
---@field id TimeFormatID
---@field hasDecimals boolean? Shows tenths below the text's decimalsBelow.
---@field offersBareSeconds boolean? Can show seconds alone under a minute (see TextStyle.bareSeconds).
---@field offersFullTicks boolean? Can count only whole ticks (see TextStyle.fullTicks).

-- The time formats' ids, as saved.
local CLOCK, SECONDS, TENTHS, UNITS, TICKS = "clock", "seconds", "tenths", "units", "ticks"

--- How a text writes $value and $max when they're times, in the order the
--- editor lists them, each labelled with an example. Every format but ticks
--- rounds up to whole seconds first (except ss.ms below decimalsBelow), so a
--- running timer never reads 0 and they all move on at the same moment.
---@type TimeFormat[]
textTemplate.TIME_FORMATS = {
    -- Without hours under an hour ("5:59"), and with bareSeconds, without
    -- minutes under a minute ("59").
    { id = CLOCK, label = "11:22:33", offersBareSeconds = true },
    { id = SECONDS, label = "360" },
    { id = TENTHS, label = "360.2", hasDecimals = true },
    -- The largest unit that fits, rounded down within it, as the buff bar
    -- writes them: 5:00 to 5:59 is "5m".
    { id = UNITS, label = "6m" },
    -- 0.6 second server ticks: with fullTicks the whole ticks left (2.9
    -- seconds is 4), otherwise every tick begun (5). Labelled by name, as
    -- an example would read as seconds.
    { id = TICKS, label = "Ticks", offersFullTicks = true },
}
textTemplate.DEFAULT_TIME_FORMAT = TENTHS
-- ss.ms's id.
textTemplate.TENTHS_FORMAT = TENTHS

---@type table<string, TimeFormat>
local TIME_FORMATS_BY_ID = {}
for _, format in ipairs(textTemplate.TIME_FORMATS) do
    TIME_FORMATS_BY_ID[format.id] = format
end

-- The most seconds a text's decimalsBelow can be.
textTemplate.MAX_DECIMALS_BELOW = 120
-- The most decimals $percent can show.
textTemplate.MAX_PERCENT_DECIMALS = 3
-- $percent's format for each number of decimals, from 0.
local PERCENT_FORMATS = { "%.0f%%", "%.1f%%", "%.2f%%", "%.3f%%" }

-- Taken off before rounding up, so a value a float's error above a whole
-- number doesn't round up to the next one.
local ROUNDING_SLACK = 1e-9
-- A compact value's letters, largest first, with what each stands for.
local COMPACT_UNITS = { { letter = "M", size = 1000000 }, { letter = "K", size = 1000 } }
local SECONDS_PER_MINUTE, SECONDS_PER_HOUR, SECONDS_PER_DAY = 60, 3600, 86400
local SECONDS_PER_TICK = 0.6
-- The units mm[unit] writes above seconds, largest first.
local TIME_UNITS = {
    { letter = "d", seconds = SECONDS_PER_DAY },
    { letter = "h", seconds = SECONDS_PER_HOUR },
    { letter = "m", seconds = SECONDS_PER_MINUTE },
}
local SECONDS_LETTER = "s"

---@type table<string, TextField>
local FIELDS_BY_ID = {}
for _, field in ipairs(textTemplate.FIELDS) do
    FIELDS_BY_ID[field.id] = field
end

--- The separator a second field gets by default: " / " between two
--- numbers, ": " after a name, otherwise " - ".
---@param first TextFieldID
---@param second TextFieldID
---@return string
function textTemplate.DefaultSeparator(first, second)
    if FIELDS_BY_ID[first].isNumber and FIELDS_BY_ID[second].isNumber then
        return SLASH
    end

    if first == "name" then
        return COLON
    end

    return DASH
end

--- A template from its fields and separator.
---@param first TextFieldID
---@param separator string? Ignored without a second field.
---@param second TextFieldID?
---@return string
function textTemplate.Join(first, separator, second)
    if second == nil then
        return "$" .. first
    end

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

--- How a text is written: what it shows and how its numbers look.
---@class TextStyle
---@field template string? nil for DEFAULT.
---@field timeFormat TimeFormatID? How $value and $max are written for a source whose values are times (see DataSource.timed); nil writes them as plain numbers.
---@field decimalsBelow number? For a format with decimals, values at or above this show whole, rounded up; nil for decimals at any value.
---@field bareSeconds boolean? For a format that offers it (hh:mm:ss), seconds alone under a minute: "59", not "0:59".
---@field fullTicks boolean? For a format that offers it (ticks), false counts the tick under way too; nil or true, only whole ticks.
---@field percentDecimals integer? Decimals for $percent; nil for none.

--- Whether a format is one of TIME_FORMATS.
---@param formatID any
---@return boolean
function textTemplate.IsTimeFormat(formatID)
    return TIME_FORMATS_BY_ID[formatID] ~= nil
end

--- Whether a format shows decimals, so a text's decimalsBelow matters.
---@param formatID any
---@return boolean
function textTemplate.HasDecimals(formatID)
    local format = TIME_FORMATS_BY_ID[formatID]
    return format ~= nil and format.hasDecimals == true
end

--- Whether a format can show seconds alone under a minute, so a text's
--- bareSeconds matters.
---@param formatID any
---@return boolean
function textTemplate.OffersBareSeconds(formatID)
    local format = TIME_FORMATS_BY_ID[formatID]
    return format ~= nil and format.offersBareSeconds == true
end

--- Whether a format can count only whole ticks, so a text's fullTicks
--- matters.
---@param formatID any
---@return boolean
function textTemplate.OffersFullTicks(formatID)
    local format = TIME_FORMATS_BY_ID[formatID]
    return format ~= nil and format.offersFullTicks == true
end

--- A value as text, whole numbers without ".0".
---@param value any
---@return string
local function plainText(value)
    return tostring(math.tointeger(value) or value)
end

--- Seconds rounded up to whole, so a running timer only reads 0 once it
--- really is 0.
---@param seconds number
---@return number whole An integer for any finite time.
local function wholeSeconds(seconds)
    return math.ceil(seconds - ROUNDING_SLACK)
end

--- hh:mm:ss, leaving off the hours under an hour ("5:59"), and with
--- `bareSeconds` the minutes under a minute ("59").
---@param seconds integer
---@param bareSeconds boolean?
---@return string
local function clockText(seconds, bareSeconds)
    local hours = seconds // SECONDS_PER_HOUR
    local minutes = (seconds % SECONDS_PER_HOUR) // SECONDS_PER_MINUTE
    local secondsPart = seconds % SECONDS_PER_MINUTE
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secondsPart)
    end

    if minutes == 0 and bareSeconds then
        return tostring(secondsPart)
    end

    return string.format("%d:%02d", minutes, secondsPart)
end

--- mm[unit]: the largest unit that fits, rounded down within it ("5m" for
--- 5:00 to 5:59), otherwise seconds ("10s").
---@param seconds integer
---@return string
local function unitsText(seconds)
    for _, unit in ipairs(TIME_UNITS) do
        if seconds >= unit.seconds then
            return (seconds // unit.seconds) .. unit.letter
        end
    end

    return seconds .. SECONDS_LETTER
end

--- Server ticks: with `fullTicks`, the whole ticks in a time, rounded down
--- ("4" for 2.9 seconds), otherwise rounded up to count the tick under way too
--- ("5").
---@param seconds number Finite.
---@param fullTicks boolean
---@return string
local function ticksText(seconds, fullTicks)
    local ticks = seconds / SECONDS_PER_TICK
    if fullTicks then
        return tostring(math.floor(ticks + ROUNDING_SLACK))
    end

    return tostring(math.ceil(ticks - ROUNDING_SLACK))
end

--- A time as text in its style's format (see TIME_FORMATS). ss.ms, or a
--- format not listed (from a newer version), shows tenths below the
--- style's decimalsBelow.
---@param seconds number
---@param style TextStyle With a timeFormat.
---@return string
local function timeText(seconds, style)
    local whole = wholeSeconds(seconds)

    -- A clock's digits need a whole number: a time from a bad read (infinite
    -- or not a number) shows as it is rather than erroring every frame.
    if math.type(whole) ~= "integer" then
        return plainText(seconds)
    end

    local formatID = style.timeFormat
    if formatID == CLOCK then
        return clockText(whole, style.bareSeconds)
    end

    if formatID == SECONDS then
        return tostring(whole)
    end

    if formatID == UNITS then
        return unitsText(whole)
    end

    if formatID == TICKS then
        return ticksText(seconds, style.fullTicks ~= false)
    end

    local decimalsBelow = style.decimalsBelow
    local isWhole = decimalsBelow ~= nil and seconds >= decimalsBelow
    if isWhole then
        return tostring(whole)
    end

    return plainText(seconds)
end

--- A value written as the buff bar writes a count: 1000 or more as K and
--- 1000000 or more as M, to one decimal without ".0" (1500 is "1.5K"). A
--- value that rounds to 1000 of a letter takes the next one up (999,960 is
--- "1M", not "1000K").
---@param value any
---@return string? text nil for a value under 1000, or not a number.
local function compactValue(value)
    if type(value) ~= "number" then
        return nil
    end

    for index, unit in ipairs(COMPACT_UNITS) do
        if value >= unit.size then
            local rounded = string.format("%.1f", value / unit.size)
            local larger = COMPACT_UNITS[index - 1]
            if larger ~= nil and tonumber(rounded) >= larger.size / unit.size then
                return "1" .. larger.letter
            end

            return (rounded:gsub("%.0$", "")) .. unit.letter
        end
    end

    return nil
end

--- $value's or $max's text: a time in the text's format for a source whose
--- values are times, compact for a source that writes its values so (see
--- TextInfo.compactValues), otherwise the number as it is.
---@param value any
---@param style TextStyle
---@param info TextInfo?
---@return string
local function valueText(value, style, info)
    local isTime = style.timeFormat ~= nil and type(value) == "number"
    if isTime then
        return timeText(value, style)
    end

    local compact = info ~= nil and info.compactValues and compactValue(value)
    return compact or plainText(value)
end

--- The value as a percentage of the max, rounded to `decimals` (0 to
--- MAX_PERCENT_DECIMALS; anything else is brought within them). A max of 0
--- reads 0%.
---@param curr any
---@param max any
---@param decimals any
---@return string
local function percentText(curr, max, decimals)
    if type(curr) ~= "number" or type(max) ~= "number" then
        return ""
    end

    local percent = max > 0 and curr / max * 100 or 0
    decimals = math.floor(tonumber(decimals) or 0)
    decimals = math.max(0, math.min(textTemplate.MAX_PERCENT_DECIMALS, decimals))
    return string.format(PERCENT_FORMATS[decimals + 1], percent)
end

--- One of a source's TextInfo fields' text.
---@param field TextFieldID
---@param info TextInfo?
---@return string
local function infoFieldText(field, info)
    if info == nil then
        return ""
    end

    if field == "keybind" then
        return info.keybind or ""
    end

    if field == "eofKeybind" then
        return info.eofKeybind or ""
    end

    if field == "target" then
        return info.name or ""
    end

    if field == "level" then
        return info.level ~= nil and plainText(info.level) or ""
    end

    if field == "hitChance" then
        return info.hitChance ~= nil and plainText(info.hitChance) .. "%" or ""
    end

    return info.weakness or ""
end

--- One field's text.
---@param field TextFieldID
---@param style TextStyle
---@param curr any
---@param max any
---@param stacks number?
---@param name string?
---@param ammo string?
---@param info TextInfo?
---@return string
local function fieldText(field, style, curr, max, stacks, name, ammo, info)
    if field == "value" then
        return valueText(curr, style, info)
    end

    if field == "max" then
        return valueText(max, style, info)
    end

    if field == "percent" then
        return percentText(curr, max, style.percentDecimals)
    end

    if field == "stacks" or field == "charges" then
        return stacks ~= nil and plainText(stacks) or ""
    end

    if field == "name" then
        return name or ""
    end

    if field == "ammo" then
        return ammo or ""
    end

    return infoFieldText(field, info)
end

--- Fills a text's template with values.
--- `Format({ template = "$value / $max" }, 57, 100)` gives "57 / 100";
--- `Format({ template = "$value", timeFormat = "tenths", decimalsBelow = 10 }, 12.4, 30)`
--- gives "13", since 12.4 is at or above 10.
---@param style TextStyle
---@param curr any Current value.
---@param max any Maximum value.
---@param stacks number? Stacks or charges; nil leaves $stacks and $charges empty.
---@param name string? For $name.
---@param ammo string? For $ammo.
---@param info TextInfo? For $keybind, $target, $level, $hitChance and $weakness.
---@return string
function textTemplate.Format(style, curr, max, stacks, name, ammo, info)
    local parts = textTemplate.Parts(style.template or textTemplate.DEFAULT)
    local text = fieldText(parts.first, style, curr, max, stacks, name, ammo, info)
    if parts.second == nil then
        return text
    end

    return text .. parts.separator .. fieldText(parts.second, style, curr, max, stacks, name, ammo, info)
end

--- Whether a template shows a field.
---@param template string?
---@param field TextFieldID
---@return boolean
function textTemplate.Uses(template, field)
    local parts = textTemplate.Parts(template or textTemplate.DEFAULT)
    return parts.first == field or parts.second == field
end

return textTemplate
