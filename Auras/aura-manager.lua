-- Keeps an on-screen display for every enabled aura and feeds it values.
-- Call RefreshChanged() after changing auras (only those whose store
-- version moved are re-applied), Refresh() when everything must be
-- re-applied (sources or icons changed), and Draw() every frame.
-- Usage: local auraManager = require("Auras/aura-manager")

local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local gameApi = require("GameData/game-api")

local auraManager = {}

-- auraID -> { display, displayID, aura, parent = component, version (the
-- store version last applied) }
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

local function mount(aura, parent)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    madeThisFrame = true
    local display = displayType.module.new(parent, aura)
    local auraID = aura.id
    display:SetOnMoved(function(x, y)
        local stored = auraStore.Get(auraID)
        if stored == nil then return end
        stored.x, stored.y = x, y
        auraStore.Save()
        -- A group's box around its contents follows them, so resync; and
        -- dragging raised it, so it goes back to its place in the stack.
        dirty = true
        restackPending = true
        if onAuraMoved ~= nil then onAuraMoved(auraID) end
    end)
    mounted[auraID] = { display = display, displayID = aura.display, aura = aura, parent = parent,
        version = auraStore.Version(auraID) }
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

-- Mounts the auras in a group (nil: the top level) under `parent`, then
-- each group's own contents under its layer. A hidden group's contents
-- aren't drawn. `order` collects the display roots in list order, for
-- stacking.
local function syncLevel(groupID, parent, wanted, order)
    for _, aura in ipairs(auraStore.Children(groupID)) do
        if aura.enabled and not wanted[aura.id] then
            wanted[aura.id] = true
            local entry = mounted[aura.id]
            if entry ~= nil and (entry.displayID ~= aura.display or entry.parent ~= parent) then
                unmount(aura.id)
                entry = nil
            end
            if entry == nil then
                mount(aura, parent)
            else
                entry.aura = aura
                local version = auraStore.Version(aura.id)
                if applyAll or entry.version ~= version then
                    entry.version = version
                    entry.display:Apply(aura)
                end
            end
            local mountedEntry = mounted[aura.id]
            if mountedEntry ~= nil and mountedEntry.display.root ~= nil then
                order[#order + 1] = mountedEntry.display.root
            end
            if auraStore.IsGroup(aura) and mountedEntry ~= nil then
                syncLevel(aura.id, mountedEntry.display.root, wanted, order)
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
    madeThisFrame = false
    ensureContainer()
    syncLevel(nil, container, wanted, order)
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
function auraManager.Refresh()
    dirty = true
    applyAll = true
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
    end

    if dirty then
        dirty = false
        sync()
    elseif restackPending then
        restackPending = false
        restack()
    end

    -- Shared per-frame state is looked up once, and auras sharing a data
    -- source read it once.
    frame = frame + 1
    local available = gameApi.PlayerAvailable()
    for _, entry in pairs(mounted) do
        local sourceID = entry.aura.source
        local curr, max, unrounded, stacks = nil, nil, nil, nil
        local name, icon, object = nil, nil, nil
        if sourceID ~= nil then
            local value = sourceValues[sourceID]
            if value == nil then
                value = {}
                sourceValues[sourceID] = value
            end
            if value.frame ~= frame then
                value.frame = frame
                value[1], value[2], value[3], value[4] = nil, nil, nil, nil
                if available then
                    value[1], value[2], value[3], value[4] = dataSources.ReadAvailable(sourceID)
                end
                -- Name and icon don't need a player: an unlocked bar still
                -- shows its icon at the login screen.
                value[5], value[6], value[7] = dataSources.Details(sourceID)
            end
            curr, max, unrounded, stacks = value[1], value[2], value[3], value[4]
            name, icon, object = value[5], value[6], value[7]
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
end

function auraManager.Destroy()
    destroyAll()
    gameArea = nil
    dirty = true
end

return auraManager
