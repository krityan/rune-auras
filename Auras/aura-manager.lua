-- The aura manager: keeps an on-screen display for every enabled, loaded
-- aura, feeds it values every frame, and works out its conditions, load
-- state, stacking and dynamic group layout.

local auraStore = require("Auras/Store/aura-store")
local conditions = require("Auras/Registries/conditions")
local loadOptions = require("Auras/Registries/load-options")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")

local auraManager = {}

--- A mounted aura.
---@class MountedEntry
---@field display Placed
---@field displayID DisplayID The type it was made as.
---@field aura Aura
---@field parent userdata The layer it's in.
---@field version integer The store version last applied.
---@field conditionMask integer Which of its conditions passed when it was last applied (see conditions.Mask).
---@field conditionsEveryFrame boolean Whether its conditions read a value extrapolated between ticks.
---@field conditionsTick integer? The server tick its conditions were last tested on; nil to test next frame.

--- A mounted dynamic group and its contents, in list order.
---@class DynamicGroupEntry
---@field entry MountedEntry
---@field children MountedEntry[]

--- A source's values this frame, kept between frames so reading every
--- source each frame allocates nothing.
---@class SourceValue
---@field frame integer The frame they were read on.
---@field curr number?
---@field max number?
---@field unrounded number?
---@field stacks number?
---@field detailsFrame integer? The frame the details were read on.
---@field name string?
---@field icon integer?
---@field object integer?

---@type table<integer, MountedEntry>
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
---@type table<integer, boolean> Aura ids the next sync re-applies though their version didn't move: a source they read changed (see Refresh).
local staleIDs = {}
-- The display roots in the order they were last stacked, so a sync only
-- re-stacks when that order changes.
local stackOrder = {}
---@type table<userdata, integer> Each root's place in stackOrder.
local stackIndex = {}
---@type table<Display, boolean> Displays whose parts are put back in order next frame (see raiseParts).
local partsToRaise = {}
---@type DynamicGroupEntry[] Found by the last sync. Laid out every frame (see layoutDynamicGroups), as their contents hide and show themselves.
local dynamicGroups = {}
-- Reused each frame for the contents showing in one dynamic group.
local showing = {}
local onAuraMoved = nil
---@type table<string, SourceValue>
local sourceValues = {}
local frame = 0
local currentGameArea = gameApi.GameArea

--- Destroys a display, quietly. An aura inside a group is a child of the
--- group's layer, so destroying the group has already destroyed it natively;
--- destroying it again may fail.
---@param display Display
local function destroyDisplay(display)
    pcall(display.Destroy, display)
end

--- Destroys a native component, for pcall. Its method is called with `:`,
--- never read as a field (see AGENTS.md).
---@param component userdata
local function destroyComponent(component)
    component:Destroy()
end

--- Destroys every display and the container.
local function destroyAll()
    -- The components are already gone if the game area was rebuilt.
    local alive = gameArea ~= nil and currentGameArea() == gameArea
    for _, entry in pairs(mounted) do
        if alive then destroyDisplay(entry.display) end
    end
    mounted = {}
    stackOrder = {}
    stackIndex = {}
    partsToRaise = {}
    dynamicGroups = {}
    if alive and container ~= nil then pcall(destroyComponent, container) end
    container = nil
end

--- Makes the container the first time, and keeps it the game area's size.
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

local warnedComponentLimit = false
local loggedErrors = {}

--- Reports a display that failed to be made or drawn. The game has 4,096
--- interface parts (components) for everything we draw, auras and the main
--- window together; past that, making one errors, and the display that hit
--- it is skipped (or left as it was). That's said once, rather than an
--- error every frame. Any other error is a bug: it's logged as one, once
--- per message.
---@param problem any The error.
local function reportDrawFailure(problem)
    problem = tostring(problem)
    if not gameApi.IsComponentLimitError(problem) then
        if not loggedErrors[problem] then
            loggedErrors[problem] = true
            log("[ERROR] Rune Auras: an aura couldn't be drawn: " .. problem)
        end
        return
    end
    if warnedComponentLimit then return end
    warnedComponentLimit = true
    log("Rune Auras: some auras can't be shown: the game's limit on interface parts was reached. "
        .. "Disabling or deleting auras you don't use makes room.")
end

---@param display Display
---@param aura Aura
local function applyDisplay(display, aura)
    display:Apply(aura)
end

--- Applies an aura to its display as its passing conditions change it,
--- including whether they hide it.
---@param entry MountedEntry
local function applyEntry(entry)
    local aura, hidden = conditions.Apply(entry.aura, entry.conditionMask)
    -- Applying can make parts (texts, ticks), so it can hit the limit.
    local ok, problem = pcall(applyDisplay, entry.display, aura)
    if not ok then reportDrawFailure(problem) end
    if entry.display.SetConditionHidden ~= nil then
        -- Like the displays' own hide options, ignored while it's unlocked
        -- so it can be found and moved. (Not `and/or`: a condition's false,
        -- "show", must get through.)
        if entry.aura.unlocked then hidden = nil end
        entry.display:SetConditionHidden(hidden)
    end
end

-- Conditions and load checks are tested once a server tick, as that's
-- when game values change, unless one reads a value extrapolated between
-- ticks (a `smooth` source: timers), which is tested every frame. The
-- server tick this frame is in (gameClock.ServerTicks):
local serverTick = 0

--- Whether a source's value is extrapolated between server ticks.
---@param sourceID string
---@return boolean
local function isExtrapolated(sourceID)
    local source = dataSources.Get(sourceID)
    return source ~= nil and source.smooth == true
end

--- Works out how often an entry's conditions need testing, and has them
--- tested on the next frame, for an entry that's new or whose aura (or the
--- sources) changed.
---@param entry MountedEntry
local function scheduleConditions(entry)
    entry.conditionsEveryFrame = conditions.NeedEveryFrame(entry.aura.conditions, entry.aura.source, isExtrapolated)
    entry.conditionsTick = nil
end

--- Destroys an aura's display, if it has one.
---@param auraID integer
local function unmount(auraID)
    local entry = mounted[auraID]
    if entry == nil then return end
    destroyDisplay(entry.display)
    mounted[auraID] = nil
end

-- Whether a sync made a display this frame (see restack).
local madeThisFrame = false
---@type integer? The place in stackOrder the next frame restacks from; nil for none.
local restackFrom = nil
-- restack's `from` for every display.
local EVERY_DISPLAY = 1

--- Restacks on the next frame from a place in stackOrder onwards.
---@param from integer
local function requestRestack(from)
    if restackFrom == nil or from < restackFrom then restackFrom = from end
end

--- Saves an aura's new offset after the player dragged it.
---@param auraID integer
---@param x number
---@param y number
local function onDisplayMoved(auraID, x, y)
    -- Edited (touched) so it's re-applied as well as saved. A dragged aura is
    -- already where it belongs (re-applying leaves it there), but a dragged
    -- group's layer goes back to 0, 0 around its new point.
    local stored = auraStore.Edit(auraID, function(aura) aura.x, aura.y = x, y end)
    if stored == nil then return end
    -- A group's box around its contents follows them, so resync; and
    -- dragging raised it, so it goes back to its place in the stack.
    dirty = true
    requestRestack(EVERY_DISPLAY)
    if onAuraMoved ~= nil then onAuraMoved(auraID) end
end

--- Makes an aura's display. Making it can hit the game's limit on interface
--- parts partway; the display then removes what it made, and it's skipped.
---@param aura Aura
---@param parent userdata The layer to make it in.
---@param point GroupPoint? Its group's point; nil at the top level.
local function mount(aura, parent, point)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    madeThisFrame = true
    local ok, display = pcall(displayType.module.new, parent, aura, point)
    if not ok or display == nil then
        reportDrawFailure(display)
        return
    end
    local auraID = aura.id
    display:SetOnMoved(function(x, y) onDisplayMoved(auraID, x, y) end)
    mounted[auraID] = { display = display, displayID = aura.display, aura = aura, parent = parent,
        version = auraStore.Version(auraID), conditionMask = 0 }
    scheduleConditions(mounted[auraID])
end

--- The box around a group's mounted contents, in the group's coordinates;
--- nested groups count their own contents.
---@param groupID integer
---@return number? left nil if nothing in it is shown.
---@return number? top
---@return number? right
---@return number? bottom
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

---@type table<integer, boolean> Aura id to false while its load options keep it from loading; worked out each frame by updateLoaded, which resyncs when one changes.
local loadedStates = {}

--- Whether an aura is loaded. One that isn't isn't mounted, so a dynamic
--- group closes up around it.
---@param aura Aura?
---@return boolean
local function isLoaded(aura)
    return aura ~= nil and loadedStates[aura.id] ~= false
end

--- Re-applies a mounted aura if it changed, its group moved, or everything
--- is being re-applied.
---@param entry MountedEntry
---@param aura Aura
---@param point GroupPoint?
local function updateEntry(entry, aura, point)
    entry.aura = aura
    local version = auraStore.Version(aura.id)
    -- A group makes a new point table when it moves, so this re-places
    -- everything in a group that moved.
    local groupMoved = entry.display.groupPoint ~= point
    if applyAll or staleIDs[aura.id] or entry.version ~= version or groupMoved then
        entry.version = version
        entry.display.groupPoint = point
        scheduleConditions(entry)
        applyEntry(entry)
    end
end

--- Mounts the auras in a group under its layer, placed from the group's
--- point, then each group's own contents under its layer. A hidden group's
--- contents aren't drawn.
---@param groupID integer? nil for the top level.
---@param parent userdata The group's layer (the container at the top level).
---@param point GroupPoint? The group's point.
---@param wanted table<integer, boolean> Collects every aura id mounted.
---@param order userdata[] Collects the display roots in list order, for stacking.
---@param dynamic DynamicGroupEntry? Filled with the contents if the group is a dynamic group.
local function syncLevel(groupID, parent, point, wanted, order, dynamic)
    for _, aura in ipairs(auraStore.Children(groupID)) do
        if aura.enabled and isLoaded(aura) and not wanted[aura.id] then
            wanted[aura.id] = true
            local entry = mounted[aura.id]
            local needsRemount = entry ~= nil and (entry.displayID ~= aura.display or entry.parent ~= parent)
            if needsRemount then
                unmount(aura.id)
                entry = nil
            end
            if entry == nil then
                mount(aura, parent, point)
            else
                updateEntry(entry, aura, point)
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

--- Brings each display from a place in stackOrder onwards to the front, so
--- later ones in the list draw over earlier ones (within their parent). A
--- display made this frame ignores MoveToFront, and one shown again loses
--- its place, so they're restacked next frame (`requestRestack`) from there.
---@param from integer A place in stackOrder.
local function restack(from)
    for index = from, #stackOrder do stackOrder[index]:MoveToFront() end
end

--- Calls `RaiseParts` on the displays that made or showed a part last frame
--- (see restack for why it waits).
local function raiseParts()
    if next(partsToRaise) == nil then return end
    for display in pairs(partsToRaise) do display:RaiseParts() end
    partsToRaise = {}
end

--- Whether two stacking orders differ.
---@param first userdata[]
---@param second userdata[]
---@return boolean
local function orderDiffers(first, second)
    if #first ~= #second then return true end
    for index = 1, #first do
        if first[index] ~= second[index] then return true end
    end
    return false
end

--- Mounts, re-applies and unmounts displays to match the store, and
--- restacks when the order changed (most syncs, an edit to one aura, leave
--- it as it was).
local function sync()
    local wanted, order = {}, {}
    dynamicGroups = {}
    madeThisFrame = false
    ensureContainer()
    syncLevel(nil, container, nil, wanted, order)
    applyAll = false
    if next(staleIDs) ~= nil then staleIDs = {} end
    for auraID in pairs(mounted) do
        if not wanted[auraID] then unmount(auraID) end
    end
    if orderDiffers(order, stackOrder) then
        stackOrder = order
        stackIndex = {}
        for index, root in ipairs(order) do stackIndex[root] = index end
        restack(EVERY_DISPLAY)
    end
    if madeThisFrame then requestRestack(EVERY_DISPLAY) end
end

--- An aura's load-check timing.
---@class LoadTiming
---@field version integer The store version it was worked out for.
---@field everyFrame boolean Whether its load checks need testing every frame.
---@field tick integer? The server tick it was last tested on.

---@type table<integer, LoadTiming>
local loadTimings = {}

--- Re-applies auras on the next frame after sources or their icons changed
--- (so which values are extrapolated may have too): those reading a source
--- that passes `isAffected`, or every aura.
---@param isAffected (fun(sourceID: string): boolean)? Whether a source changed; nil for all of them.
function auraManager.Refresh(isAffected)
    dirty = true
    if isAffected == nil then
        applyAll = true
        loadTimings = {}
        return
    end
    for _, aura in ipairs(auraStore.List()) do
        if auraStore.ReadsSource(aura, isAffected) then
            staleIDs[aura.id] = true
            loadTimings[aura.id] = nil
        end
    end
end

--- Syncs on the next frame, re-applying only auras whose store version moved.
function auraManager.RefreshChanged()
    dirty = true
end

--- The on-screen size of an aura's display. A Text display sizes itself to
--- its text, so its aura's width/height are only nominal.
---@param auraID integer
---@return number? width nil if it isn't mounted.
---@return number? height
function auraManager.DisplaySize(auraID)
    local entry = mounted[auraID]
    if entry == nil or entry.display.width == nil then return nil end
    return entry.display.width, entry.display.height
end

--- Sets what runs after the player drags an aura to a new spot.
---@param callback fun(auraID: integer)
function auraManager.SetOnAuraMoved(callback)
    onAuraMoved = callback
end

--- Lines up each dynamic group's contents that are showing (not hiding
--- themselves), after this frame's values have shown or hidden them, and
--- redraws its box when they moved.
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
-- sourceValue's choices: also read the source's name and icon, or only its values.
local WITH_DETAILS, VALUES_ONLY = true, false

--- A source's values this frame, read once however many auras use it.
---@param sourceID string
---@param withDetails boolean WITH_DETAILS for a source a display shows, or VALUES_ONLY for one only a condition checks.
---@return SourceValue
local function sourceValue(sourceID, withDetails)
    local value = sourceValues[sourceID]
    if value == nil then
        value = {}
        sourceValues[sourceID] = value
    end
    if value.frame ~= frame then
        value.frame = frame
        value.curr, value.max, value.unrounded, value.stacks = nil, nil, nil, nil
        if playerAvailable then
            value.curr, value.max, value.unrounded, value.stacks = dataSources.ReadAvailable(sourceID)
        end
    end
    if withDetails and value.detailsFrame ~= frame then
        value.detailsFrame = frame
        -- Name and icon don't need a player: an unlocked bar still shows
        -- its icon at the login screen.
        value.name, value.icon, value.object = dataSources.Details(sourceID)
    end
    return value
end

--- What a condition's check reads (see ReadCheckValues).
---@param sourceID string
---@return number? curr
---@return number? max
---@return number? stacks
local function readForConditions(sourceID)
    local value = sourceValue(sourceID, VALUES_ONLY)
    return value.curr, value.max, value.stacks
end

--- Whether an aura loads this frame. Each is tested once a server tick (its
--- options are game vars too), or every frame if a load check reads an
--- extrapolated value, and again whenever the aura changes.
---@param aura Aura Enabled, locked, with load options.
---@return boolean
local function testLoaded(aura)
    local version = auraStore.Version(aura.id)
    local timing = loadTimings[aura.id]
    if timing == nil or timing.version ~= version then
        timing = {
            version = version,
            everyFrame = conditions.ChecksNeedEveryFrame(aura.load.checks, aura.source, isExtrapolated),
        }
        loadTimings[aura.id] = timing
    end
    if not timing.everyFrame and timing.tick == serverTick then return loadedStates[aura.id] ~= false end
    timing.tick = serverTick
    return loadOptions.Passes(aura, aura.source, readForConditions)
end

--- Works out which auras load this frame, resyncing if any changed. An
--- unlocked aura always loads, so it can be found and moved. A disabled one
--- isn't mounted anyway, so it isn't tested.
local function updateLoaded()
    loadOptions.NewFrame()
    for _, aura in ipairs(auraStore.List()) do
        local loaded = true
        if aura.enabled and not aura.unlocked and loadOptions.HasAny(aura) then
            loaded = testLoaded(aura)
        end
        local wasLoaded = loadedStates[aura.id] ~= false
        if loaded ~= wasLoaded then dirty = true end
        loadedStates[aura.id] = loaded
    end
end

--- Tests an entry's conditions when they're due, re-applying it when which
--- ones pass changed.
---@param entry MountedEntry
local function updateConditions(entry)
    local auraConditions = entry.aura.conditions
    if auraConditions == nil then return end
    if not entry.conditionsEveryFrame and entry.conditionsTick == serverTick then return end
    entry.conditionsTick = serverTick
    local mask = conditions.Mask(auraConditions, entry.aura.source, readForConditions)
    if mask ~= entry.conditionMask then
        entry.conditionMask = mask
        applyEntry(entry)
    end
end

--- Feeds a display its source's values this frame. Drawing a value can make
--- parts (a bar's ticks), so it's guarded against the limit on them.
---@param entry MountedEntry
local function drawEntry(entry)
    local sourceID = entry.aura.source
    local curr, max, unrounded, stacks = nil, nil, nil, nil
    local name, icon, object = nil, nil, nil
    if sourceID ~= nil then
        local value = sourceValue(sourceID, WITH_DETAILS)
        curr, max, unrounded, stacks = value.curr, value.max, value.unrounded, value.stacks
        name, icon, object = value.name, value.icon, value.object
    end
    updateConditions(entry)
    -- A smooth source's unrounded value is only for drawing; text keeps the
    -- rounded one. Each display decides whether to use it.
    local display = entry.display
    if display.SetDetails ~= nil then
        local ok, problem = pcall(display.SetDetails, display, name, icon, object)
        if not ok then reportDrawFailure(problem) end
    end
    local ok, problem = pcall(display.SetValue, display, curr, max, unrounded, stacks)
    if not ok then reportDrawFailure(problem) end
    if display.needsRestack then
        display.needsRestack = nil
        requestRestack(stackIndex[display.root])
    end
    if display.partsMade then partsToRaise[display] = true end
end

--- Keeps the displays in step with the game area's size: anchored positions
--- depend on it. Old saves' group positions convert once it's known.
local function followGameAreaSize()
    if gameArea.width == gameAreaWidth and gameArea.height == gameAreaHeight then return end
    gameAreaWidth, gameAreaHeight = gameArea.width, gameArea.height
    dirty = true
    applyAll = true
    auraStore.MigratePositions(gameAreaWidth, gameAreaHeight)
end

--- Draws every aura. Call every frame.
function auraManager.Draw()
    -- Saves wait for edits to stop, and a big one is spread over frames
    -- (see auraStore.SavePending).
    auraStore.SavePending()
    local area = currentGameArea()
    if area ~= gameArea then
        destroyAll()
        gameArea = area
        dirty = true
    end
    if gameArea == nil then return end
    followGameAreaSize()

    -- Shared per-frame state is looked up once, and auras sharing a data
    -- source (or checking it in a condition or load check) read it once.
    frame = frame + 1
    serverTick = gameClock.ServerTicks()
    playerAvailable = gameApi.PlayerAvailable()
    updateLoaded()

    -- Before the sync, which may destroy a display waiting for it.
    raiseParts()
    if dirty then
        dirty = false
        sync()
    elseif restackFrom ~= nil then
        local from = restackFrom
        restackFrom = nil
        restack(from)
    end

    for _, entry in pairs(mounted) do drawEntry(entry) end
    layoutDynamicGroups()
end

--- Destroys every display; the next Draw makes them again.
function auraManager.Destroy()
    destroyAll()
    gameArea = nil
    dirty = true
end

return auraManager
