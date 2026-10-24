-- Saves and loads the player's auras in PersistentDB.
-- An aura is a table:
--   id        unique integer
--   name      shown in the aura list
--   display   display type id (see Auras/Registries/display-types)
--   source    data source id (see Auras/Registries/data-sources), nil until chosen
--   enabled   whether it is drawn
--   colour    0xRRGGBBAA
--   showText  whether to draw the value text
--   unlocked  whether it can be dragged on screen
--   anchor    anchor point id (see Auras/Helpers/anchors). At the top level,
--             the point of the screen x/y is measured from; in a group, the
--             point of the aura that attaches to the group's point
--   x, y      offset from the anchor point, inwards from the screen's edges;
--             in a group, a plain offset (right and down) from its point
--   textColour, textFont, textSize  value text style (see Auras/Helpers/fonts)
--   textTemplate  value text with placeholders (see Auras/Helpers/text-template)
--   limitDecimals, decimalsBelow  show values at or above decimalsBelow
--                 without decimals
--   conditions  display changes made while checks pass (see
--             Auras/Helpers/conditions), or nil
--   group     id of the group it sits in, or nil at the top level. A group is
--             itself an aura with display "group" and no size: its anchor
--             and x/y place its point (see ScreenPoint), which everything
--             in it is placed from, so the group moves as one. Groups can
--             nest; a group inside one has no anchor of its own, only an
--             offset from its parent's point. A dynamic group (display
--             "dynamicGroup") is a group whose auras grow from its point: it
--             lays out what's showing itself (see
--             Auras/Displays/dynamic-group), so their own anchors and x/y
--             are unused while they're in it. It holds auras only, no groups
--             of either kind.
-- plus any option the display type adds through its `defaults`.
-- Usage: local auraStore = require("Auras/aura-store")

local anchors = require("Auras/Helpers/anchors")
local conditions = require("Auras/Helpers/conditions")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local fonts = require("Auras/Helpers/fonts")
local textTemplate = require("Auras/Helpers/text-template")

local auraStore = {}

local STORAGE_KEY = "auras"
-- Saved with the auras. Before 2, a group's x/y shifted its contents, which
-- kept anchors measured from the screen; see MigratePositions.
local POSITIONS_VERSION = 2
local DEFAULT_COLOUR = 0xFFFFFFFF
auraStore.DEFAULT_COLOUR = DEFAULT_COLOUR
local DEFAULT_DISPLAY = "bar"
local GROUP_DISPLAY = "group"
auraStore.GROUP_DISPLAY = GROUP_DISPLAY
local DYNAMIC_GROUP_DISPLAY = "dynamicGroup"
auraStore.DYNAMIC_GROUP_DISPLAY = DYNAMIC_GROUP_DISPLAY
local DEFAULT_TEXT_COLOUR = 0xFFFFFFFF
-- With limitDecimals on, values at or above this many seconds show whole.
local DEFAULT_DECIMALS_BELOW = 10
-- New auras sit just below the middle of the screen.
local NEW_AURA_ANCHOR = "centre"
local NEW_AURA_X, NEW_AURA_Y = 0, 150

-- Fields holding 0xRRGGBBAA colours are named "colour" or end in "Colour".
-- PersistentDB rounds large numbers off (losing the alpha byte), so these
-- are saved as hex strings instead.
local function isColourKey(key)
    return key == "colour" or (type(key) == "string" and key:match("Colour$") ~= nil)
end

local auras = {}
local nextID = 1
-- Whether the loaded auras still use the old group positions, waiting for
-- MigratePositions.
local positionsPending = false

-- Numbers can come back from storage as floats; the UI wants integers.
local function toInteger(value)
    local number = tonumber(value)
    if number == nil then return nil end
    return math.floor(number)
end

local function encodeColour(colour)
    return string.format("%08X", colour & 0xFFFFFFFF)
end

-- Older saves stored colours as numbers whose alpha byte was rounded away;
-- treat those as fully opaque.
local function decodeColour(value)
    if type(value) == "string" then
        return tonumber(value, 16)
    end
    local number = toInteger(value)
    if number == nil then return nil end
    return (number & 0xFFFFFF00) | 0xFF
end

-- Conditions are saved as nested tables; colours in their changes are hex
-- strings like the aura's own. `decode` turns a saved list back into one
-- the plugin uses (dropping anything malformed), or the reverse.
local function convertConditions(list, decode)
    if type(list) ~= "table" then return nil end
    local converted = {}
    for _, condition in ipairs(list) do
        if type(condition) == "table" then
            local copy = {
                match = condition.match == "any" and "any" or "all",
                key = tonumber(condition.key),
                checks = {},
                changes = {},
            }
            local joinedByOr = false
            for _, check in ipairs(type(condition.checks) == "table" and condition.checks or {}) do
                if type(check) == "table" then
                    check = conditions.Copy(check)
                    -- Checks used to be joined one by one with AND/OR;
                    -- ORs make the closest match "any".
                    if check.join == "or" then joinedByOr = true end
                    check.join = nil
                    copy.checks[#copy.checks + 1] = check
                end
            end
            if condition.match == nil and joinedByOr then copy.match = "any" end
            for _, change in ipairs(type(condition.changes) == "table" and condition.changes or {}) do
                -- Conditions briefly offered "Dim while active"; it became
                -- Desaturate, which is what it was used for.
                if type(change) == "table" and change.property == "dimWhileActive" then
                    change = { property = "desaturate", value = change.value }
                end
                local property = type(change) == "table" and conditions.Property(change.property) or nil
                if property ~= nil then
                    local value, keep = change.value, true
                    if property.kind == "colour" then
                        -- A colour that doesn't decode is dropped with its
                        -- change: encoding it back would error on load.
                        if decode then
                            value = decodeColour(value)
                            keep = value ~= nil
                        elseif value ~= nil then
                            value = encodeColour(value)
                        end
                    end
                    if keep then
                        copy.changes[#copy.changes + 1] = { property = change.property, value = value }
                    end
                end
            end
            converted[#converted + 1] = copy
        end
    end
    -- Conditions saved before keys existed get one (see conditions.NextKey).
    for _, condition in ipairs(converted) do
        if condition.key == nil then condition.key = conditions.NextKey(converted) end
    end
    return #converted > 0 and converted or nil
end

local function applyDisplayDefaults(aura)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    for key, value in pairs(displayType.module.defaults or {}) do
        if aura[key] == nil then aura[key] = value end
    end
end

-- Options that no longer exist, dropped on load so they stop being saved:
-- showInitialTick went with reading buffs off the buff bar.
local RETIRED_FIELDS = { showInitialTick = true }

local function normalize(saved)
    if type(saved) ~= "table" or toInteger(saved.id) == nil then return nil end
    -- Every other numeric aura field (id, position, sizes) is an integer.
    local aura = {}
    for key, value in pairs(saved) do
        if RETIRED_FIELDS[key] then
            -- Dropped.
        elseif key == "conditions" then
            aura.conditions = convertConditions(value, true)
        elseif isColourKey(key) then
            aura[key] = decodeColour(value)
        else
            aura[key] = type(value) == "number" and toInteger(value) or value
        end
    end
    aura.name = tostring(saved.name or "Aura")
    aura.display = displayTypes.Get(saved.display) ~= nil and saved.display or DEFAULT_DISPLAY
    aura.enabled = saved.enabled ~= false
    -- Source ids can be renamed (e.g. cooldowns now follow their var name).
    if aura.source ~= nil then aura.source = dataSources.CurrentID(aura.source) end
    aura.colour = aura.colour or DEFAULT_COLOUR
    aura.showText = saved.showText ~= false
    aura.unlocked = saved.unlocked == true
    -- Auras saved before anchors existed were positioned from the top left.
    aura.anchor = aura.anchor or anchors.DEFAULT
    aura.x = aura.x or 0
    aura.y = aura.y or 0
    aura.textColour = aura.textColour or DEFAULT_TEXT_COLOUR
    aura.textFont = aura.textFont or fonts.DEFAULT_FONT
    aura.textSize = aura.textSize or fonts.DEFAULT_SIZE
    aura.textTemplate = aura.textTemplate or textTemplate.DEFAULT
    aura.limitDecimals = saved.limitDecimals == true
    aura.decimalsBelow = aura.decimalsBelow or DEFAULT_DECIMALS_BELOW
    applyDisplayDefaults(aura)
    return aura
end

function auraStore.Load()
    auras = {}
    nextID = 1
    local saved = PersistentDB:Get(STORAGE_KEY)
    if type(saved) ~= "table" then return end
    for _, savedAura in ipairs(saved.auras or {}) do
        local aura = normalize(savedAura)
        if aura ~= nil then
            auras[#auras + 1] = aura
            nextID = math.max(nextID, aura.id + 1)
        end
    end
    nextID = math.max(nextID, toInteger(saved.nextID) or 1)
    -- A group that no longer exists (or isn't a group) can't hold auras.
    for _, aura in ipairs(auras) do
        if aura.group ~= nil and not auraStore.IsGroup(auraStore.Get(aura.group)) then
            aura.group = nil
        end
    end
    positionsPending = false
    if (toInteger(saved.positionsVersion) or 1) < POSITIONS_VERSION then
        for _, aura in ipairs(auras) do
            if aura.group ~= nil then positionsPending = true end
        end
    end
end

function auraStore.Save()
    local saved = {}
    for index, aura in ipairs(auras) do
        local copy = {}
        for key, value in pairs(aura) do
            if key == "conditions" then
                copy[key] = convertConditions(value, false)
            else
                copy[key] = isColourKey(key) and encodeColour(value) or value
            end
        end
        saved[index] = copy
    end
    PersistentDB:Set(STORAGE_KEY, {
        nextID = nextID,
        positionsVersion = positionsPending and 1 or POSITIONS_VERSION,
        auras = saved,
    })
end

function auraStore.List()
    return auras
end

-- An aura's place in the list (its order), or nil.
local function indexOf(auraID)
    for index, aura in ipairs(auras) do
        if aura.id == auraID then return index end
    end
    return nil
end

function auraStore.Get(auraID)
    local index = indexOf(auraID)
    return index and auras[index] or nil
end

-- Whether an aura holds others: a group or a dynamic group.
function auraStore.IsGroup(aura)
    return aura ~= nil and (aura.display == GROUP_DISPLAY or aura.display == DYNAMIC_GROUP_DISPLAY)
end

-- The auras and groups directly inside a group (nil: the top level), in
-- list order.
function auraStore.Children(groupID)
    local children = {}
    for _, aura in ipairs(auras) do
        if aura.group == groupID then children[#children + 1] = aura end
    end
    return children
end

-- Whether `auraID` is `groupID` or one of the groups `groupID` sits in;
-- moving it there would put a group inside itself.
local function containsGroup(auraID, groupID)
    local visited = {}
    while groupID ~= nil and not visited[groupID] do
        if groupID == auraID then return true end
        visited[groupID] = true
        local group = auraStore.Get(groupID)
        groupID = group and group.group or nil
    end
    return false
end

-- Aura id -> a count bumped whenever the aura changes, so the aura manager
-- re-applies only auras that changed (see Version). Not saved.
local versions = {}

local function touch(aura)
    versions[aura.id] = (versions[aura.id] or 0) + 1
end

-- How many times an aura has changed this session; anything that writes an
-- aura's fields itself calls Touch.
function auraStore.Version(auraID)
    return versions[auraID] or 0
end

function auraStore.Touch(auraID)
    versions[auraID] = (versions[auraID] or 0) + 1
end

function auraStore.IsDynamicGroup(aura)
    return aura ~= nil and aura.display == DYNAMIC_GROUP_DISPLAY
end

-- Whether an aura can go in a group: anything in a group, but only
-- auras (no groups) in a dynamic group.
function auraStore.CanHold(group, aura)
    if not auraStore.IsGroup(group) then return false end
    return not (auraStore.IsDynamicGroup(group) and auraStore.IsGroup(aura))
end

-- Where an aura's point is on screen, in a game area areaWidth by
-- areaHeight: for a group, the point its contents are placed from; for an
-- aura, the point of it that its anchor attaches. At the top level that's
-- its offset from the screen's anchor point (sizes cancel out), and in a
-- group its offset from the group's point.
function auraStore.ScreenPoint(aura, areaWidth, areaHeight)
    local x, y, visited = 0, 0, {}
    while aura ~= nil and not visited[aura.id] do
        visited[aura.id] = true
        local group = aura.group ~= nil and auraStore.Get(aura.group) or nil
        if group == nil then
            local left, top = anchors.ToScreen(aura.anchor, aura.x or 0, aura.y or 0, 0, 0, areaWidth, areaHeight)
            return x + left, y + top
        end
        x, y = x + (aura.x or 0), y + (aura.y or 0)
        aura = group
    end
    return x, y
end

-- Sets an aura's x/y so its point (see ScreenPoint) is at px, py.
local function placeAt(aura, px, py, areaWidth, areaHeight)
    local group = aura.group ~= nil and auraStore.Get(aura.group) or nil
    if group ~= nil then
        local gx, gy = auraStore.ScreenPoint(group, areaWidth, areaHeight)
        aura.x, aura.y = px - gx, py - gy
    else
        aura.x, aura.y = anchors.FromScreen(aura.anchor, px, py, 0, 0, areaWidth, areaHeight)
    end
    touch(aura)
end

-- Puts an aura in another group (nil: the top level), keeping it where it
-- is on screen if the game area's size is known.
local function regroup(aura, groupID, areaWidth, areaHeight)
    if areaWidth == nil or areaHeight == nil then
        aura.group = groupID
        touch(aura)
        return
    end
    local px, py = auraStore.ScreenPoint(aura, areaWidth, areaHeight)
    aura.group = groupID
    placeAt(aura, px, py, areaWidth, areaHeight)
end

-- Puts a group's point back on its anchor (or its parent's point) with no
-- offset, moving what's in it the other way so it all stays where it is on
-- screen. A dynamic group's contents grow from its point, so they move
-- with it; only a plain group keeps them in place. Returns whether
-- anything changed.
function auraStore.ResetGroupOffset(groupID, areaWidth, areaHeight)
    local group = auraStore.Get(groupID)
    if not auraStore.IsGroup(group) or ((group.x or 0) == 0 and (group.y or 0) == 0) then return false end
    local oldX, oldY = auraStore.ScreenPoint(group, areaWidth, areaHeight)
    group.x, group.y = 0, 0
    touch(group)
    if not auraStore.IsDynamicGroup(group) then
        local newX, newY = auraStore.ScreenPoint(group, areaWidth, areaHeight)
        for _, child in ipairs(auras) do
            if child.group == groupID then
                child.x, child.y = (child.x or 0) + oldX - newX, (child.y or 0) + oldY - newY
                touch(child)
            end
        end
    end
    auraStore.Save()
    return true
end

-- Converts saves from before group points (see POSITIONS_VERSION), once the
-- game area's size is known. A group's x/y used to shift its contents
-- (summed up nested groups), and everything else measured from the
-- screen's anchors. Groups had the top-left anchor, so a group's x/y
-- already places its point where its shift was, and a nested group's
-- offset adds up the same way; what was in a group measured from the
-- screen's anchor, so it now measures that anchor's spot from the group's
-- point. Returns whether anything was converted.
function auraStore.MigratePositions(areaWidth, areaHeight)
    if not positionsPending then return false end
    positionsPending = false
    for _, aura in ipairs(auras) do
        local group = aura.group ~= nil and auraStore.Get(aura.group) or nil
        if group ~= nil and not (auraStore.IsGroup(aura) and not auraStore.IsDynamicGroup(aura)) then
            aura.x, aura.y = anchors.ToScreen(aura.anchor, aura.x or 0, aura.y or 0, 0, 0, areaWidth, areaHeight)
            touch(aura)
        end
    end
    auraStore.Save()
    return true
end

-- Moves an aura or group into a group (nil: the top level), before one of
-- that group's contents (`beforeID`) or after them all (nil). Order is the
-- order of the store's list, which Children follows. Changing group keeps
-- it where it is on screen. Refuses a group that doesn't exist, moving a
-- group into itself or its own contents, and a `beforeID` that isn't in
-- the group. areaWidth/areaHeight, the game area's size if known, are
-- needed to keep it in place. Returns whether anything changed.
function auraStore.Move(auraID, groupID, beforeID, areaWidth, areaHeight)
    local from = indexOf(auraID)
    if from == nil or beforeID == auraID then return false end
    local aura = auras[from]
    if groupID ~= nil then
        if not auraStore.CanHold(auraStore.Get(groupID), aura) then return false end
        if containsGroup(auraID, groupID) then return false end
    end
    local before = beforeID ~= nil and auraStore.Get(beforeID) or nil
    if beforeID ~= nil and (before == nil or before.group ~= groupID) then return false end

    table.remove(auras, from)
    local to
    if before ~= nil then
        to = indexOf(beforeID)
    else
        -- After the group's last item (or at the very end if it's empty).
        to = #auras + 1
        for index = #auras, 1, -1 do
            if auras[index].group == groupID then to = index + 1 break end
        end
    end
    table.insert(auras, to, aura)

    local moved = to ~= from or aura.group ~= groupID
    -- In or out of a dynamic group, it's its own position (unused while
    -- it's in one) that's kept in place.
    if aura.group ~= groupID then regroup(aura, groupID, areaWidth, areaHeight) end
    if moved then auraStore.Save() end
    return moved
end

function auraStore.Create(groupID)
    local aura = {
        id = nextID,
        name = "New aura",
        display = DEFAULT_DISPLAY,
        source = nil,
        enabled = true,
        colour = DEFAULT_COLOUR,
        showText = true,
        unlocked = false,
        anchor = NEW_AURA_ANCHOR,
        x = NEW_AURA_X,
        y = NEW_AURA_Y,
        textColour = DEFAULT_TEXT_COLOUR,
        textFont = fonts.DEFAULT_FONT,
        textSize = fonts.DEFAULT_SIZE,
        textTemplate = textTemplate.DEFAULT,
        limitDecimals = false,
        decimalsBelow = DEFAULT_DECIMALS_BELOW,
        group = groupID,
    }
    -- The usual spot below the middle of the screen can be outside a group.
    if groupID ~= nil then aura.x, aura.y = 0, 0 end
    applyDisplayDefaults(aura)
    nextID = nextID + 1
    auras[#auras + 1] = aura
    auraStore.Save()
    return aura
end

-- A new, empty group, or with `dynamic` a dynamic group, inside `groupID`
-- (nil: the top level). Its point starts in the middle of the screen, or on
-- the point of the group it's in.
function auraStore.CreateGroup(groupID, dynamic)
    local group = {
        id = nextID,
        name = dynamic and "New dynamic group" or "New group",
        display = dynamic and DYNAMIC_GROUP_DISPLAY or GROUP_DISPLAY,
        enabled = true,
        unlocked = false,
        anchor = "centre",
        x = 0,
        y = 0,
        group = groupID,
    }
    applyDisplayDefaults(group)
    nextID = nextID + 1
    auras[#auras + 1] = group
    auraStore.Save()
    return group
end

-- How far a copy is nudged from its original, so it doesn't sit exactly on
-- top of it.
local DUPLICATE_OFFSET = 10

-- Nudges an offset by DUPLICATE_OFFSET, the other way if that would leave
-- the range that keeps the aura on screen.
local function nudge(offset, minimum, maximum)
    local nudged = offset + DUPLICATE_OFFSET
    if maximum ~= nil and nudged > maximum then nudged = offset - DUPLICATE_OFFSET end
    if minimum ~= nil then nudged = math.max(minimum, nudged) end
    if maximum ~= nil then nudged = math.min(maximum, nudged) end
    return nudged
end

-- Copies an aura with all its settings into a new one, listed right after
-- the original. areaWidth/areaHeight, the game area's size if known, keep
-- the copy's offset on screen. Returns the copy, or nil if the aura doesn't
-- exist.
function auraStore.Duplicate(auraID, areaWidth, areaHeight)
    local index = indexOf(auraID)
    if index == nil then return nil end
    local original = auras[index]
    -- Conditions are the only nested field.
    local copy = conditions.Copy(original)
    copy.id = nextID
    copy.name = original.name .. " copy"
    copy.unlocked = false
    -- In a group the offset is from the group's point, with no screen edge
    -- to keep inside.
    local minX, maxX, minY, maxY
    if areaWidth ~= nil and areaHeight ~= nil and original.group == nil then
        minX, maxX, minY, maxY = anchors.OffsetRange(original.anchor,
            original.width or 0, original.height or 0, areaWidth, areaHeight)
    end
    copy.x = nudge(original.x or 0, minX, maxX)
    copy.y = nudge(original.y or 0, minY, maxY)
    nextID = nextID + 1
    table.insert(auras, index + 1, copy)
    auraStore.Save()
    return copy
end

-- Deleting a group keeps what was in it, moving it up a level without
-- moving it on screen. areaWidth/areaHeight, the game area's size if known,
-- are needed for that.
function auraStore.Delete(auraID, areaWidth, areaHeight)
    local index = indexOf(auraID)
    if index == nil then return false end
    local aura = auras[index]
    if auraStore.IsGroup(aura) then
        for _, child in ipairs(auras) do
            if child.group == auraID then regroup(child, aura.group, areaWidth, areaHeight) end
        end
    end
    table.remove(auras, index)
    auraStore.Save()
    return true
end

-- Switching display type fills in the new type's option defaults.
function auraStore.Set(auraID, key, value)
    local aura = auraStore.Get(auraID)
    if aura == nil then return nil end
    if key == "display" and value ~= aura.display then
        -- Options mean different things per display type (a bar is wide, an
        -- icon square with a thinner border), so take all of the new type's
        -- defaults rather than keeping the old type's values.
        local displayType = displayTypes.Get(value)
        for option, default in pairs(displayType and displayType.module.defaults or {}) do
            aura[option] = default
        end
    end
    aura[key] = value
    if key == "display" then applyDisplayDefaults(aura) end
    touch(aura)
    auraStore.Save()
    return aura
end

return auraStore
