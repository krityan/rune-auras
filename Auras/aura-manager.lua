-- Keeps an on-screen display for every enabled aura and feeds it values.
-- Call RefreshChanged() after changing auras (only those whose store
-- version moved are re-applied), Refresh() when everything must be
-- re-applied (sources or icons changed), and Draw() every frame.
-- Usage: local auraManager = require("Auras/aura-manager")

local auraStore = require("Auras/aura-store")
local conditions = require("Auras/Helpers/conditions")
local loadOptions = require("Auras/Registries/load-options")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")

local auraManager = {}

-- auraID -> { display, displayID, aura, parent = component, version (the
-- store version last applied), conditionMask (which of its conditions
-- passed when it was last applied; see Auras/Helpers/conditions) }
local mounted = {}
local gameArea = nil
-- Our own full-size layer in the game area, holding the top-level auras.
-- Displays made straight in the game area land behind what's there and
-- don't reliably come to the front, so stacking them by list order (see
-- syncLevel) needs a parent of our own, as groups are for their contents.
local container = nil
local gameAreaWidth, gameAreaHeight = nil, nil
local dirty = true
-- Whether the next sync re-applies every aura, not just changed ones.
local applyAll = true
-- The display roots in the order they were last stacked, so a sync only
-- re-stacks when that order changes.
local stackOrder = {}
-- The mounted dynamic groups and their contents, in list order, found by
-- the last sync: { entry, children = { entries } }. Laid out every frame
-- (see layoutDynamicGroups), as their contents hide and show themselves.
local dynamicGroups = {}
-- Reused each frame for the contents showing in one dynamic group.
local showing = {}
local onAuraMoved = nil
-- Source id -> { frame = n, [1] = curr, [2] = max, [3] = unrounded, [4] = stacks }, kept
-- between frames so reading every source each frame allocates nothing.
local sourceValues = {}
local frame = 0

local function currentGameArea()
    return gameApi.Component("TOPLEVEL_V2__GAME_AREA")
end

-- An aura inside a group is a child of the group's layer, so destroying the
-- group has already destroyed it natively; destroying it again may fail.
local function destroyDisplay(display)
    pcall(display.Destroy, display)
end

-- A native component's method is called with `:`, never read as a field
-- (see AGENTS.md).
local function destroyComponent(component)
    component:Destroy()
end

local function destroyAll()
    -- The components are already gone if the game area was rebuilt.
    local alive = gameArea ~= nil and currentGameArea() == gameArea
    for _, entry in pairs(mounted) do
        if alive then destroyDisplay(entry.display) end
    end
    mounted = {}
    stackOrder = {}
    dynamicGroups = {}
    if alive and container ~= nil then pcall(destroyComponent, container) end
    container = nil
end

-- The container, made the first time and kept the game area's size.
local function ensureContainer()
    if container == nil then
        container = ui.Layer.new(gameArea)
        -- It covers the whole game area, so it must never catch clicks.
        container.enabled = true
        container.clickthrough = true
        container:SetPos(0, 0)
    end
    container:SetSize(gameArea.width, gameArea.height)
end

-- Applies an aura to its display as its passing conditions change it.
local function applyEntry(entry)
    local aura, hidden = conditions.Apply(entry.aura, entry.conditionMask)
    entry.display:Apply(aura)
    if entry.display.SetConditionHidden ~= nil then
        -- Like the displays' own hide options, ignored while it's unlocked
        -- so it can be found and moved.
        -- (Not `and/or`: a condition's false, "show", must get through.)
        if entry.aura.unlocked then hidden = nil end
        entry.display:SetConditionHidden(hidden)
    end
end

-- Conditions and load checks are tested once a server tick, as that's
-- when game values change, unless one reads a value extrapolated between
-- ticks (a `smooth` source: timers), which is tested every frame. The
-- server tick this frame is in (gameClock.ServerTicks):
local serverTick = 0

local function isExtrapolated(sourceID)
    local source = dataSources.Get(sourceID)
    return source ~= nil and source.smooth == true
end

-- Works out how often an entry's conditions need testing, and has them
-- tested on the next frame, for an entry that's new or whose aura (or the
-- sources) changed.
local function scheduleConditions(entry)
    entry.conditionsEveryFrame = conditions.NeedEveryFrame(entry.aura.conditions, entry.aura.source, isExtrapolated)
    entry.conditionsTick = nil
end

local function unmount(auraID)
    local entry = mounted[auraID]
    if entry == nil then return end
    destroyDisplay(entry.display)
    mounted[auraID] = nil
end

-- Whether a display was made this frame: it doesn't come to the front yet
-- (the others are brought in front of it instead), so the stack is put in
-- order again on the next frame. The same goes for a display that hid
-- itself and shows again (a buff gained, a bar no longer empty), which it
-- reports with `needsRestack`.
local madeThisFrame = false
local restackPending = false

-- `point` is the point of the group it's in (see Auras/Displays/group), or
-- nil at the top level.
local function mount(aura, parent, point)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    madeThisFrame = true
    local display = displayType.module.new(parent, aura, point)
    local auraID = aura.id
    display:SetOnMoved(function(x, y)
        local stored = auraStore.Get(auraID)
        if stored == nil then return end
        stored.x, stored.y = x, y
        -- A dragged aura is already where it belongs, but a dragged group's
        -- layer goes back to 0, 0 around its new point.
        if auraStore.IsGroup(stored) then auraStore.Touch(auraID) end
        auraStore.Save()
        -- A group's box around its contents follows them, so resync; and
        -- dragging raised it, so it goes back to its place in the stack.
        dirty = true
        restackPending = true
        if onAuraMoved ~= nil then onAuraMoved(auraID) end
    end)
    mounted[auraID] = { display = display, displayID = aura.display, aura = aura, parent = parent,
        version = auraStore.Version(auraID), conditionMask = 0 }
    scheduleConditions(mounted[auraID])
end

-- The box around a group's mounted contents, in the group's coordinates;
-- nested groups count their own contents. nil if nothing in it is shown.
local function contentBounds(groupID)
    local left, top, right, bottom
    for _, child in ipairs(auraStore.Children(groupID)) do
        local entry = mounted[child.id]
        if entry ~= nil and entry.display.root ~= nil then
            local childLeft, childTop, childRight, childBottom
            if auraStore.IsGroup(child) then
                childLeft, childTop, childRight, childBottom = entry.display:GetBounds()
            else
                local root = entry.display.root
                childLeft, childTop = root.x or 0, root.y or 0
                childRight, childBottom = childLeft + (root.width or 0), childTop + (root.height or 0)
            end
            if childLeft ~= nil then
                left = left and math.min(left, childLeft) or childLeft
                top = top and math.min(top, childTop) or childTop
                right = right and math.max(right, childRight) or childRight
                bottom = bottom and math.max(bottom, childBottom) or childBottom
            end
        end
    end
    return left, top, right, bottom
end

-- Aura id -> false while its load options (see Auras/Registries/
-- load-options) keep it from loading; worked out each frame by
-- updateLoaded, which resyncs when one changes.
local loadedStates = {}

-- Whether an aura is loaded. One that isn't isn't mounted, so a dynamic
-- group closes up around it.
local function isLoaded(aura)
    return aura ~= nil and loadedStates[aura.id] ~= false
end

-- Mounts the auras in a group (nil: the top level) under `parent`, placed
-- from the group's `point`, then each group's own contents under its layer.
-- A hidden group's contents aren't drawn. `order` collects the display roots
-- in list order, for stacking; `dynamic` is the dynamic group record being
-- filled, if the group is one.
local function syncLevel(groupID, parent, point, wanted, order, dynamic)
    for _, aura in ipairs(auraStore.Children(groupID)) do
        if aura.enabled and isLoaded(aura) and not wanted[aura.id] then
            wanted[aura.id] = true
            local entry = mounted[aura.id]
            if entry ~= nil and (entry.displayID ~= aura.display or entry.parent ~= parent) then
                unmount(aura.id)
                entry = nil
            end
            if entry == nil then
                mount(aura, parent, point)
            else
                entry.aura = aura
                local version = auraStore.Version(aura.id)
                -- A group makes a new point table when it moves, so this
                -- re-places everything in a group that moved.
                if applyAll or entry.version ~= version or entry.display.groupPoint ~= point then
                    entry.version = version
                    entry.display.groupPoint = point
                    scheduleConditions(entry)
                    applyEntry(entry)
                end
            end
            local mountedEntry = mounted[aura.id]
            if mountedEntry ~= nil and mountedEntry.display.root ~= nil then
                order[#order + 1] = mountedEntry.display.root
                if dynamic ~= nil then
                    -- The dynamic group places it (see placement).
                    mountedEntry.display.layoutManaged = true
                    dynamic.children[#dynamic.children + 1] = mountedEntry
                end
            end
            if auraStore.IsGroup(aura) and mountedEntry ~= nil then
                local inner = nil
                if auraStore.IsDynamicGroup(aura) then
                    inner = { entry = mountedEntry, children = {} }
                    dynamicGroups[#dynamicGroups + 1] = inner
                end
                syncLevel(aura.id, mountedEntry.display.root, mountedEntry.display.point, wanted, order, inner)
                mountedEntry.display:SetBounds(contentBounds(aura.id))
            end
        end
    end
end

-- Brings each display to the front in list order (within its parent), so
-- ones lower in the list draw over ones above them: a display is otherwise
-- stacked where it was made, and dragging raises it.
local function restack()
    for _, root in ipairs(stackOrder) do root:MoveToFront() end
end

local function sync()
    local wanted, order = {}, {}
    dynamicGroups = {}
    madeThisFrame = false
    ensureContainer()
    syncLevel(nil, container, nil, wanted, order)
    applyAll = false
    for auraID in pairs(mounted) do
        if not wanted[auraID] then unmount(auraID) end
    end
    -- Re-stack only when the order changed: most syncs (an edit to one
    -- aura) leave it as it was.
    local changed = #order ~= #stackOrder
    for index = 1, #order do
        if changed then break end
        changed = order[index] ~= stackOrder[index]
    end
    stackOrder = order
    if changed then restack() end
    restackPending = restackPending or madeThisFrame
end

-- Re-applies every aura on the next frame.
-- Aura id -> { version, everyFrame, tick }: the store version its load
-- timing was worked out for, whether its load checks need testing every
-- frame, and the server tick it was last tested on.
local loadTimings = {}

function auraManager.Refresh()
    dirty = true
    applyAll = true
    -- Sources may have changed, and with them which values are extrapolated.
    loadTimings = {}
end

-- Syncs on the next frame, re-applying only auras that changed.
function auraManager.RefreshChanged()
    dirty = true
end

-- The on-screen size of an aura's display, or nil if it isn't mounted. A
-- Text display sizes itself to its text, so its aura's width/height are
-- only nominal.
function auraManager.DisplaySize(auraID)
    local entry = mounted[auraID]
    if entry == nil or entry.display.width == nil then return nil end
    return entry.display.width, entry.display.height
end

-- callback(auraID) runs after the player drags an aura to a new spot.
function auraManager.SetOnAuraMoved(callback)
    onAuraMoved = callback
end

-- Lines up each dynamic group's contents that are showing (not hiding
-- themselves), after this frame's values have shown or hidden them, and
-- redraws its box when they moved.
local function layoutDynamicGroups()
    for _, dynamic in ipairs(dynamicGroups) do
        local count = 0
        for _, child in ipairs(dynamic.children) do
            local display = child.display
            if display.root ~= nil and not display.rootHidden then
                count = count + 1
                showing[count] = display
            end
        end
        local group = dynamic.entry.display
        if group.root ~= nil and group:Layout(showing, count) then
            group:SetBounds(contentBounds(dynamic.entry.aura.id))
        end
    end
end

local playerAvailable = false

-- A source's values this frame, read once however many auras use it:
-- { frame, curr, max, unrounded, stacks, name, icon, object }. The name and
-- icon (`withDetails`) are only fetched for sources a display shows, not
-- ones only a condition checks.
local function sourceValue(sourceID, withDetails)
    local value = sourceValues[sourceID]
    if value == nil then
        value = {}
        sourceValues[sourceID] = value
    end
    if value.frame ~= frame then
        value.frame = frame
        value[1], value[2], value[3], value[4] = nil, nil, nil, nil
        if playerAvailable then
            value[1], value[2], value[3], value[4] = dataSources.ReadAvailable(sourceID)
        end
    end
    if withDetails and value.detailsFrame ~= frame then
        value.detailsFrame = frame
        -- Name and icon don't need a player: an unlocked bar still shows
        -- its icon at the login screen.
        value[5], value[6], value[7] = dataSources.Details(sourceID)
    end
    return value
end

-- What a condition's check reads (see conditions.Mask).
local function readForConditions(sourceID)
    local value = sourceValue(sourceID, false)
    return value[1], value[2], value[4]
end

-- Works out which auras load this frame, resyncing if any changed. An
-- unlocked aura always loads, so it can be found and moved. A disabled one
-- isn't mounted anyway, so it isn't tested.
-- Each aura is tested once a server tick (its options are game vars too),
-- or every frame if a load check reads an extrapolated value, and again
-- whenever the aura changes.
local function updateLoaded()
    loadOptions.NewFrame()
    for _, aura in ipairs(auraStore.List()) do
        local loaded = true
        if aura.enabled and not aura.unlocked and loadOptions.HasAny(aura) then
            local version = auraStore.Version(aura.id)
            local timing = loadTimings[aura.id]
            if timing == nil or timing.version ~= version then
                timing = {
                    version = version,
                    everyFrame = conditions.ChecksNeedEveryFrame(aura.load.checks, aura.source, isExtrapolated),
                }
                loadTimings[aura.id] = timing
            end
            if timing.everyFrame or timing.tick ~= serverTick then
                timing.tick = serverTick
                loaded = loadOptions.Passes(aura, aura.source, readForConditions)
            else
                loaded = loadedStates[aura.id] ~= false
            end
        end
        if loaded ~= (loadedStates[aura.id] ~= false) then dirty = true end
        loadedStates[aura.id] = loaded
    end
end

function auraManager.Draw()
    local area = currentGameArea()
    if area ~= gameArea then
        destroyAll()
        gameArea = area
        dirty = true
    end
    if gameArea == nil then return end

    -- Anchored positions depend on the game area's size.
    if gameArea.width ~= gameAreaWidth or gameArea.height ~= gameAreaHeight then
        gameAreaWidth, gameAreaHeight = gameArea.width, gameArea.height
        dirty = true
        applyAll = true
        -- Old saves' group positions convert once the size is known.
        auraStore.MigratePositions(gameAreaWidth, gameAreaHeight)
    end

    -- Shared per-frame state is looked up once, and auras sharing a data
    -- source (or checking it in a condition or load check) read it once.
    frame = frame + 1
    serverTick = gameClock.ServerTicks()
    playerAvailable = gameApi.PlayerAvailable()
    updateLoaded()

    if dirty then
        dirty = false
        sync()
    elseif restackPending then
        restackPending = false
        restack()
    end

    for _, entry in pairs(mounted) do
        local sourceID = entry.aura.source
        local curr, max, unrounded, stacks = nil, nil, nil, nil
        local name, icon, object = nil, nil, nil
        if sourceID ~= nil then
            local value = sourceValue(sourceID, true)
            curr, max, unrounded, stacks = value[1], value[2], value[3], value[4]
            name, icon, object = value[5], value[6], value[7]
        end
        local auraConditions = entry.aura.conditions
        if auraConditions ~= nil and (entry.conditionsEveryFrame or entry.conditionsTick ~= serverTick) then
            entry.conditionsTick = serverTick
            local mask = conditions.Mask(auraConditions, sourceID, readForConditions)
            if mask ~= entry.conditionMask then
                entry.conditionMask = mask
                applyEntry(entry)
            end
        end
        -- A smooth source's unrounded value is only for drawing; text keeps
        -- the rounded one. Each display decides whether to use it.
        local display = entry.display
        if display.SetDetails ~= nil then display:SetDetails(name, icon, object) end
        display:SetValue(curr, max, unrounded, stacks)
        if display.needsRestack then
            display.needsRestack = nil
            restackPending = true
        end
    end
    layoutDynamicGroups()
end

function auraManager.Destroy()
    destroyAll()
    gameArea = nil
    dirty = true
end

return auraManager
