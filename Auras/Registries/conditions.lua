-- Conditions: display changes an aura makes while its checks pass. Owns the
-- Condition, Check and Change records, what they can test and change, and
-- evaluating them. The aura manager decides when to evaluate.

local conditions = {}

--- A test of one data source.
---@class Check
---@field sourceType string? Data type the source was picked from; nil for the aura's own source.
---@field source string? Data source id; nil with a sourceType means none picked yet, and the check fails.
---@field kind string A CHECKS id: what's tested.
---@field op string? An OPERATORS id, for kinds that compare a number.
---@field value number|boolean The number compared against; for "active", true (active) or false (not active).
---@field join string? Old saves only: "and"/"or" with the check before (see convertConditions in Auras/Store/aura-record).

--- A display option a passing condition sets.
---@class Change
---@field property string A PROPERTIES id.
---@field value any The value it takes while the condition passes.
---@field text integer? For a `perText` property on a display with text nodes, the key of the node it changes.

--- Display changes made while checks pass. A condition with no checks never
--- passes, so a new one changes nothing. Later conditions win when two
--- change the same property.
---@class Condition
---@field key integer Unique among the aura's conditions and kept when moved, so the editor can remember it's collapsed.
---@field match "all"|"any" Whether every check must pass, or one will do.
---@field checks Check[]
---@field changes Change[]

---@class CheckKind
---@field id string
---@field label string
---@field types table<string, boolean>? Data types that have it; nil: every type.

--- What a condition can change.
---@class ConditionProperty
---@field id string The aura field it sets ("hidden" is handled by the manager instead; see placement's SetConditionHidden).
---@field label string
---@field kind "colour"|"bool"|"number"|"text" Picks the editor control and how the value is saved.
---@field types table<DisplayID, boolean>? Display types that have it; nil: every type.
---@field perText boolean? On a display with text nodes, a change names the node it changes.
---@field min number? For "number".
---@field max number? For "number".
---@field limit string? For "number": the display module's `limits` entry holding the max.

--- Reads a source's values for this frame.
---@alias ReadCheckValues fun(sourceID: string): curr: number?, max: number?, stacks: number?

-- Percent checks compare against the value as a percentage of its max.
local PERCENT = 100

---@type CheckKind[]
conditions.CHECKS = {
    { id = "active", label = "State" },
    { id = "value", label = "Value" },
    { id = "percent", label = "Percent" },
    -- Stacks and charges are both a source's fourth value: buffs have
    -- stacks, abilities charges.
    { id = "stacks", label = "Stacks", types = { buff = true } },
    { id = "charges", label = "Charges", types = { cooldown = true } },
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

---@type ConditionProperty[]
conditions.PROPERTIES = {
    { id = "hidden", label = "Hide", kind = "bool" },
    { id = "colour", label = "Fill colour", kind = "colour", types = { bar = true, segments = true } },
    { id = "backgroundColour", label = "Background colour", kind = "colour", types = { bar = true, segments = true } },
    { id = "borderColour", label = "Border colour", kind = "colour", types = { bar = true, icon = true, segments = true } },
    { id = "tickColour", label = "Tick colour", kind = "colour", types = { bar = true } },
    { id = "iconColour", label = "Icon tint", kind = "colour", types = { icon = true } },
    { id = "swipeColour", label = "Swipe colour", kind = "colour", types = { icon = true } },
    -- Not a display option: only a condition sets it (see the Icon display).
    { id = "desaturate", label = "Desaturate", kind = "bool", types = { icon = true } },
    { id = "showIcon", label = "Show icon", kind = "bool", types = { bar = true, text = true } },
    { id = "showText", label = "Show text", kind = "bool", perText = true, types = { bar = true, icon = true } },
    { id = "textColour", label = "Text colour", kind = "colour", perText = true, types = { bar = true, icon = true, text = true } },
    { id = "textTemplate", label = "Text", kind = "text", perText = true, types = { bar = true, icon = true, text = true } },
    { id = "segments", label = "Segments", kind = "number", min = 1, limit = "maxSegments", types = { segments = true } },
}

---@type table<string, ConditionProperty>
local PROPERTIES_BY_ID = {}
for _, property in ipairs(conditions.PROPERTIES) do PROPERTIES_BY_ID[property.id] = property end

--- A property by id.
---@param propertyID string?
---@return ConditionProperty? property nil if unknown.
function conditions.Property(propertyID)
    return PROPERTIES_BY_ID[propertyID]
end

--- Whether a property applies to a display type.
---@param property ConditionProperty
---@param displayID DisplayID?
---@return boolean
local function appliesTo(property, displayID)
    return property.types == nil or property.types[displayID] == true
end

--- The properties a display type's conditions can change, in list order.
---@param displayID DisplayID
---@return ConditionProperty[]
function conditions.PropertiesFor(displayID)
    local list = {}
    for _, property in ipairs(conditions.PROPERTIES) do
        if appliesTo(property, displayID) then list[#list + 1] = property end
    end
    return list
end

--- The check kinds that apply to a data type.
---@param dataTypeID string? nil: unknown, so every kind.
---@return CheckKind[]
function conditions.ChecksFor(dataTypeID)
    local list = {}
    for _, kind in ipairs(conditions.CHECKS) do
        if dataTypeID == nil or kind.types == nil or kind.types[dataTypeID] then list[#list + 1] = kind end
    end
    return list
end

--- Whether a check kind compares a number (and so has an operator).
---@param kind string A CHECKS id.
---@return boolean
function conditions.Compares(kind)
    return kind ~= "active"
end

--- Compares two numbers with an OPERATORS id.
---@param left number
---@param op string?
---@param right number
---@return boolean passes false for an unknown operator.
local function compare(left, op, right)
    if op == "lt" then return left < right end
    if op == "le" then return left <= right end
    if op == "gt" then return left > right end
    if op == "ge" then return left >= right end
    if op == "eq" then return left == right end
    if op == "ne" then return left ~= right end
    return false
end

--- The source a check reads: its own source, or the aura's when it names neither
--- a source nor a type.
---@param check Check
---@param ownSource string? The aura's source.
---@return string? sourceID nil if there's nothing to read.
local function checkedSource(check, ownSource)
    if check.source == nil and check.sourceType == nil then return ownSource end
    return check.source
end

--- Whether one check passes.
---@param check Check
---@param ownSource string? The aura's source.
---@param read ReadCheckValues
---@return boolean
function conditions.CheckPasses(check, ownSource, read)
    local sourceID = checkedSource(check, ownSource)
    if sourceID == nil then return false end
    local curr, max, stacks = read(sourceID)
    local kind = check.kind
    if kind == "active" then
        local isActive = curr ~= nil and curr > 0
        local wantsActive = check.value ~= false
        return isActive == wantsActive
    end
    local target = tonumber(check.value) or 0
    if kind == "stacks" or kind == "charges" then return compare(stacks or 0, check.op, target) end
    if curr == nil then return false end
    if kind == "percent" then
        if max == nil or max <= 0 then return false end
        return compare(curr * PERCENT / max, check.op, target)
    end
    return compare(curr, check.op, target)
end

--- Whether a check has what it needs: one with a data type picked but no
--- source yet doesn't. (A check saved before types were kept has neither,
--- and is complete: it reads the aura's own source.)
---@param check Check
---@return boolean
function conditions.IsComplete(check)
    return not (check.sourceType ~= nil and check.source == nil)
end

--- Whether a list of checks passes: all of them, or any one for "any".
--- Stops reading once the answer is known. No checks never pass.
---@param checks Check[]?
---@param match string? "any", or anything else for all.
---@param ownSource string? The aura's source.
---@param read ReadCheckValues
---@return boolean
function conditions.ChecksPass(checks, match, ownSource, read)
    if checks == nil or #checks == 0 then return false end
    local needsAny = match == "any"
    for _, check in ipairs(checks) do
        -- The first pass decides "any"; the first failure decides "all".
        if conditions.CheckPasses(check, ownSource, read) == needsAny then return needsAny end
    end
    return not needsAny
end

--- Whether any check reads a value that moves between server ticks, so it
--- has to be tested every Logic tick; other values only change once a server
--- tick. A stack count only changes on a server tick, whatever its source.
---@param checks Check[]?
---@param ownSource string? The aura's source.
---@param isSmooth fun(sourceID: string): boolean Whether a source's value is extrapolated between ticks (timers).
---@return boolean
function conditions.ChecksNeedEveryLogicTick(checks, ownSource, isSmooth)
    for _, check in ipairs(checks or {}) do
        local sourceID = checkedSource(check, ownSource)
        if sourceID ~= nil and check.kind ~= "stacks" and isSmooth(sourceID) then return true end
    end
    return false
end

--- ChecksNeedEveryLogicTick over every condition in a list.
---@param list Condition[]?
---@param ownSource string?
---@param isSmooth fun(sourceID: string): boolean
---@return boolean
function conditions.NeedEveryLogicTick(list, ownSource, isSmooth)
    for _, condition in ipairs(list or {}) do
        if conditions.ChecksNeedEveryLogicTick(condition.checks, ownSource, isSmooth) then return true end
    end
    return false
end

--- The mask bit for a condition's place in its list.
---@param index integer
---@return integer
local function maskBit(index)
    return 1 << (index - 1)
end

--- Which conditions pass, as a bit mask (condition i is bit i - 1), so the
--- aura manager can tell cheaply whether anything changed.
---@param list Condition[]
---@param ownSource string? The aura's source.
---@param read ReadCheckValues
---@return integer mask
function conditions.Mask(list, ownSource, read)
    local mask = 0
    for index, condition in ipairs(list) do
        if conditions.ChecksPass(condition.checks, condition.match, ownSource, read) then
            mask = mask | maskBit(index)
        end
    end
    return mask
end

--- A shallow copy of a table.
---@param source table
---@return table
local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

--- Sets a field on the text node a change names, in the changed aura. The
--- list and the node are copied the first time they're changed, so the
--- stored aura's are never touched.
---@param changed Aura The copy being changed.
---@param stored Aura The stored aura.
---@param change Change
local function changeTextNode(changed, stored, change)
    if changed.texts == stored.texts then changed.texts = shallowCopy(stored.texts) end
    for index, node in ipairs(changed.texts) do
        if node.key == change.text then
            if node == stored.texts[index] then
                node = shallowCopy(node)
                changed.texts[index] = node
            end
            node[change.property] = change.value
        end
    end
end

--- The aura as its passing conditions change it, and whether they hide it.
--- The stored aura is never changed. A change left over from another display
--- type (e.g. Fill colour after a bar became an icon) is skipped.
---@param aura Aura
---@param mask integer Which conditions pass (see Mask).
---@return Aura aura A changed copy, or the aura itself when nothing changes.
---@return boolean? hidden true or false when a passing condition sets Hide (the last one wins); nil when none does.
function conditions.Apply(aura, mask)
    if mask == 0 or aura.conditions == nil then return aura, nil end
    local changed, hidden = nil, nil
    for index, condition in ipairs(aura.conditions) do
        if mask & maskBit(index) ~= 0 then
            for _, change in ipairs(condition.changes or {}) do
                local property = PROPERTIES_BY_ID[change.property]
                if change.property == "hidden" then
                    hidden = change.value == true
                elseif property ~= nil and change.value ~= nil and appliesTo(property, aura.display) then
                    changed = changed or shallowCopy(aura)
                    if property.perText and aura.texts ~= nil and change.text ~= nil then
                        changeTextNode(changed, aura, change)
                    else
                        changed[change.property] = change.value
                    end
                end
            end
        end
    end
    return changed or aura, hidden
end

--- A new check with defaults filled in.
---@param kind string? A CHECKS id; nil for "active".
---@return Check
function conditions.NewCheck(kind)
    kind = kind or "active"
    local value
    if kind == "active" then value = true else value = 0 end
    return { kind = kind, op = "lt", value = value }
end

--- A key not yet used by any condition in a list.
---@param list Condition[]?
---@return integer
function conditions.NextKey(list)
    local highest = 0
    for _, condition in ipairs(list or {}) do
        local key = tonumber(condition.key)
        if key ~= nil and key > highest then highest = key end
    end
    return highest + 1
end

--- A new condition with one check and no changes.
---@param list Condition[]? The aura's conditions, so the key is new.
---@return Condition
function conditions.NewCondition(list)
    return { key = conditions.NextKey(list), match = "all", checks = { conditions.NewCheck() }, changes = {} }
end

--- A deep copy, for duplicating conditions and saving them.
---@generic T
---@param value T
---@return T
function conditions.Copy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = conditions.Copy(item) end
    return copy
end

return conditions
