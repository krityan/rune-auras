-- Keeps an on-screen display for every enabled aura and feeds it values.
-- Call Refresh() after changing an aura, and Draw() every frame.
-- Usage: local auraManager = require("Auras/aura-manager")

local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")

local auraManager = {}

-- auraID -> { display = ..., displayID = ..., aura = ..., parent = component }
local mounted = {}
local gameArea = nil
local gameAreaWidth, gameAreaHeight = nil, nil
local dirty = true
local onAuraMoved = nil
-- Source id -> { frame = n, [1] = curr, [2] = max, [3] = unrounded, [4] = untimed, [5] = initial }, kept
-- between frames so reading every source each frame allocates nothing.
local sourceValues = {}
local frame = 0

local function currentGameArea()
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
end

-- An aura inside a group is a child of the group's layer, so destroying the
-- group has already destroyed it natively; destroying it again may fail.
local function destroyDisplay(display)
    pcall(function() display:Destroy() end)
end

local function destroyAll()
    -- The components are already gone if the game area was rebuilt.
    local alive = gameArea ~= nil and currentGameArea() == gameArea
    for _, entry in pairs(mounted) do
        if alive then destroyDisplay(entry.display) end
    end
    mounted = {}
end

local function unmount(auraID)
    local entry = mounted[auraID]
    if entry == nil then return end
    destroyDisplay(entry.display)
    mounted[auraID] = nil
end

local function mount(aura, parent)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    local display = displayType.module.new(parent, aura)
    local auraID = aura.id
    display:SetOnMoved(function(x, y)
        local stored = auraStore.Get(auraID)
        if stored == nil then return end
        stored.x, stored.y = x, y
        auraStore.Save()
        -- A group's box around its contents follows them, so resync.
        dirty = true
        if onAuraMoved ~= nil then onAuraMoved(auraID) end
    end)
    mounted[auraID] = { display = display, displayID = aura.display, aura = aura, parent = parent }
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
-- aren't drawn.
local function syncLevel(groupID, parent, wanted)
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
                entry.display:Apply(aura)
            end
            local mountedGroup = mounted[aura.id]
            if auraStore.IsGroup(aura) and mountedGroup ~= nil then
                syncLevel(aura.id, mountedGroup.display.root, wanted)
                mountedGroup.display:SetBounds(contentBounds(aura.id))
            end
        end
    end
end

local function sync()
    local wanted = {}
    syncLevel(nil, gameArea, wanted)
    for auraID in pairs(mounted) do
        if not wanted[auraID] then unmount(auraID) end
    end
end

function auraManager.Refresh()
    dirty = true
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
    end

    if dirty then
        dirty = false
        sync()
    end

    -- Shared per-frame state is looked up once, and auras sharing a data
    -- source read it once.
    frame = frame + 1
    local available = Player.IsAvailable()
    for _, entry in pairs(mounted) do
        local sourceID = entry.aura.source
        local curr, max, unrounded, untimed, initial = nil, nil, nil, nil, nil
        if sourceID ~= nil and available then
            local value = sourceValues[sourceID]
            if value == nil then
                value = {}
                sourceValues[sourceID] = value
            end
            if value.frame ~= frame then
                value.frame = frame
                value[1], value[2], value[3], value[4], value[5] = dataSources.ReadAvailable(sourceID)
            end
            curr, max, unrounded, untimed, initial = value[1], value[2], value[3], value[4], value[5]
        end
        -- A smooth source's unrounded value is only for drawing; text keeps
        -- the rounded one. Each display decides whether to use it.
        entry.display:SetValue(curr, max, unrounded, untimed, initial)
    end
end

function auraManager.Destroy()
    destroyAll()
    gameArea = nil
    dirty = true
end

return auraManager
