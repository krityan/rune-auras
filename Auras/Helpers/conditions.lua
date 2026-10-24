-- Conditions: display changes an aura makes while its checks pass.
-- An aura's `conditions` is a list, each one:
--   key      a number unique among the aura's conditions, kept when it's
--            moved, so the editor can remember it's collapsed
--   match    "all" (every check must pass) or "any" (one will do)
--   checks   list of { sourceType, source, kind, op, value }:
--              sourceType  data type id the source was picked from, or
--                      nil for the aura's own source
--              source  data source id; nil with a sourceType means none
--                      picked yet, and the check fails
--              kind    a CHECKS id: what's tested
--              op      an OPERATORS id, for kinds that compare a number
--              value   the number compared against, or for "active" true
--                      (active) or false (not active)
--   changes  list of { property, value }: a PROPERTIES id and the value it
--            takes while the condition passes. Later conditions win when
--            two change the same property.
-- A condition with no checks never passes, so a new one changes nothing.
-- Usage: local conditions = require("Auras/Helpers/conditions")

local conditions = {}

conditions.CHECKS = {
    { id = "active", label = "State", tooltip = "Whether a buff is up, a channel is running, a cooldown is running, or a value is above 0." },
    { id = "value", label = "Value", tooltip = "The value shown: seconds left for timers, the amount for resources." },
    { id = "percent", label = "Percent", tooltip = "The value as a percentage of its maximum." },
    -- Stacks and charges are both a source's fourth value: buffs have
    -- stacks, abilities charges.
    { id = "stacks", label = "Stacks", tooltip = "A stacking buff's stack count.", types = { buff = true } },
    { id = "charges", label = "Charges", types = { cooldown = true },
        tooltip = "How many charges of the ability are ready: 0 or 1, or up to 2 for one with a second charge (Surge, Escape, Barge)." },
}

-- Short words, read after "Which is" (Which is: Below 15). Symbols can't
-- work: game text reads "<" as the start of a tag (<col=ff0000>), so a bare one
-- shows blank in the dropdown's list, while the box above it shows the
-- escape "<lt>" as typed (its label is read-only, so the two can't differ),
-- and look-alikes outside the game's character set (‹ ≤ ≥ ≠) show as "?".
conditions.OPERATORS = {
    { id = "lt", label = "Below" },
    { id = "le", label = "At most" },
    { id = "gt", label = "Above" },
    { id = "ge", label = "At least" },
    { id = "eq", label = "Exactly" },
    { id = "ne", label = "Not" },
}

conditions.MATCHES = {
    { id = "all", label = "All checks pass" },
    { id = "any", label = "Any check passes" },
}

-- What a condition can change. `kind` picks the editor control and how
-- the value is saved: colour (0xRRGGBBAA), bool, number (with min/max),
-- text. `types` limits one to those display types; without it, every
-- display has it. "hidden" isn't an aura field: the manager hides the
-- display (see placement's SetConditionHidden).
conditions.PROPERTIES = {
    { id = "hidden", label = "Hide", kind = "bool" },
    { id = "colour", label = "Fill colour", kind = "colour", types = { bar = true } },
    { id = "backgroundColour", label = "Background colour", kind = "colour", types = { bar = true } },
    { id = "borderColour", label = "Border colour", kind = "colour", types = { bar = true, icon = true } },
    { id = "tickColour", label = "Tick colour", kind = "colour", types = { bar = true } },
    { id = "iconColour", label = "Icon tint", kind = "colour", types = { icon = true } },
    { id = "swipeColour", label = "Swipe colour", kind = "colour", types = { icon = true } },
    -- Not a display option: only a condition sets it (see the Icon display).
    { id = "desaturate", label = "Desaturate", kind = "bool", types = { icon = true } },
    { id = "showIcon", label = "Show icon", kind = "bool", types = { bar = true, text = true } },
    { id = "showText", label = "Show value text", kind = "bool", types = { bar = true, icon = true } },
    { id = "textColour", label = "Text colour", kind = "colour" },
    { id = "textTemplate", label = "Text", kind = "text" },
}

local PROPERTIES_BY_ID = {}
for _, property in ipairs(conditions.PROPERTIES) do PROPERTIES_BY_ID[property.id] = property end

function conditions.Property(propertyID)
    return PROPERTIES_BY_ID[propertyID]
end

-- The properties a display type's conditions can change, in list order.
function conditions.PropertiesFor(displayID)
    local list = {}
    for _, property in ipairs(conditions.PROPERTIES) do
        if property.types == nil or property.types[displayID] then list[#list + 1] = property end
    end
    return list
end

-- The check kinds that apply to a data type (nil: unknown, so all).
function conditions.ChecksFor(dataTypeID)
    local list = {}
    for _, kind in ipairs(conditions.CHECKS) do
        if dataTypeID == nil or kind.types == nil or kind.types[dataTypeID] then list[#list + 1] = kind end
    end
    return list
end

-- Whether a check kind compares a number (and so has an operator).
function conditions.Compares(kind)
    return kind ~= "active"
end

local function compare(left, op, right)
    if op == "lt" then return left < right end
    if op == "le" then return left <= right end
    if op == "gt" then return left > right end
    if op == "ge" then return left >= right end
    if op == "eq" then return left == right end
    if op == "ne" then return left ~= right end
    return false
end

-- read(sourceID) -> curr, max, stacks for this frame.
local function passes(check, ownSource, read)
    local sourceID = check.source
    if sourceID == nil and check.sourceType == nil then sourceID = ownSource end
    if sourceID == nil then return false end
    local curr, max, stacks = read(sourceID)
    local kind = check.kind
    if kind == "active" then
        return (curr ~= nil and curr > 0) == (check.value ~= false)
    end
    local right = tonumber(check.value) or 0
    if kind == "stacks" or kind == "charges" then return compare(stacks or 0, check.op, right) end
    if curr == nil then return false end
    if kind == "percent" then
        if max == nil or max <= 0 then return false end
        return compare(curr * 100 / max, check.op, right)
    end
    return compare(curr, check.op, right)
end

-- Whether one check passes (see passes above).
function conditions.CheckPasses(check, ownSource, read)
    return passes(check, ownSource, read)
end

-- Whether a check has what it needs: a data type picked with no source yet
-- (or, saved before types were kept, neither) isn't.
function conditions.IsComplete(check)
    return not (check.sourceType ~= nil and check.source == nil)
end

-- Whether a list of checks passes: all of them, or any one for match
-- "any". Stops reading once the answer is known. No checks never pass.
function conditions.ChecksPass(checks, match, ownSource, read)
    if checks == nil or #checks == 0 then return false end
    local any = match == "any"
    for _, check in ipairs(checks) do
        if passes(check, ownSource, read) == any then return any end
    end
    return not any
end

local function conditionPasses(condition, ownSource, read)
    return conditions.ChecksPass(condition.checks, condition.match, ownSource, read)
end

-- Whether any of `checks` reads a value that moves between server ticks,
-- so it has to be tested every frame; other values only change once a
-- tick. isSmooth(sourceID) says whether a source's value is extrapolated
-- between ticks (timers). A stack count only changes on a tick, whatever
-- its source.
function conditions.ChecksNeedEveryFrame(checks, ownSource, isSmooth)
    for _, check in ipairs(checks or {}) do
        local sourceID = check.source
        if sourceID == nil and check.sourceType == nil then sourceID = ownSource end
        if sourceID ~= nil and check.kind ~= "stacks" and isSmooth(sourceID) then return true end
    end
    return false
end

-- The same over every condition in `list`.
function conditions.NeedEveryFrame(list, ownSource, isSmooth)
    for _, condition in ipairs(list or {}) do
        if conditions.ChecksNeedEveryFrame(condition.checks, ownSource, isSmooth) then return true end
    end
    return false
end

-- Which of `list`'s conditions pass, as a bit mask (condition i is bit
-- i - 1), so the aura manager can tell cheaply whether anything changed.
function conditions.Mask(list, ownSource, read)
    local mask = 0
    for index, condition in ipairs(list) do
        if conditionPasses(condition, ownSource, read) then mask = mask | (1 << (index - 1)) end
    end
    return mask
end

-- The aura as its passing conditions (`mask`) change it, and whether they
-- hide it: true or false when a passing condition sets Hide (the last one
-- wins), nil when none does. Returns the aura itself when nothing changes.
function conditions.Apply(aura, mask)
    if mask == 0 or aura.conditions == nil then return aura, nil end
    local changed, hidden = nil, nil
    for index, condition in ipairs(aura.conditions) do
        if mask & (1 << (index - 1)) ~= 0 then
            for _, change in ipairs(condition.changes or {}) do
                local property = PROPERTIES_BY_ID[change.property]
                -- A change left over from another display type (e.g. Fill
                -- colour after a bar became an icon) is skipped.
                if change.property == "hidden" then
                    hidden = change.value == true
                elseif property ~= nil and change.value ~= nil
                    and (property.types == nil or property.types[aura.display]) then
                    if changed == nil then
                        changed = {}
                        for key, value in pairs(aura) do changed[key] = value end
                    end
                    changed[change.property] = change.value
                end
            end
        end
    end
    return changed or aura, hidden
end

-- A new check, condition or change, with defaults filled in.
function conditions.NewCheck(kind)
    kind = kind or "active"
    return { kind = kind, op = "lt", value = kind == "active" or 0 }
end

-- A key not yet used by any condition in `list`.
function conditions.NextKey(list)
    local highest = 0
    for _, condition in ipairs(list or {}) do
        local key = tonumber(condition.key)
        if key ~= nil and key > highest then highest = key end
    end
    return highest + 1
end

-- A new condition for `list` (the aura's conditions, for its key).
function conditions.NewCondition(list)
    return { key = conditions.NextKey(list), match = "all", checks = { conditions.NewCheck() }, changes = {} }
end

-- A deep copy, for duplicating conditions and saving them.
function conditions.Copy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = conditions.Copy(item) end
    return copy
end

return conditions
