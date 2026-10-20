-- Keeps an on-screen display for every enabled aura and feeds it values.
-- Call Refresh() after changing an aura, and Draw() every frame.
-- Usage: local auraManager = require("Auras/aura-manager")

local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/data-sources")
local displayTypes = require("Auras/display-types")

local auraManager = {}

-- auraID -> { display = ..., displayID = ..., aura = ... }
local mounted = {}
local gameArea = nil
local gameAreaWidth, gameAreaHeight = nil, nil
local dirty = true
local onAuraMoved = nil
-- Source id -> { frame = n, [1] = curr, [2] = max, [3] = unrounded }, kept
-- between frames so reading every source each frame allocates nothing.
local sourceValues = {}
local frame = 0

local function currentGameArea()
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
end

local function destroyAll()
    -- The components are already gone if the game area was rebuilt.
    local alive = gameArea ~= nil and currentGameArea() == gameArea
    for _, entry in pairs(mounted) do
        if alive then entry.display:Destroy() end
    end
    mounted = {}
end

local function unmount(auraID)
    local entry = mounted[auraID]
    if entry == nil then return end
    entry.display:Destroy()
    mounted[auraID] = nil
end

local function mount(aura)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil then return end
    local display = displayType.module.new(gameArea, aura)
    local auraID = aura.id
    display:SetOnMoved(function(x, y)
        local stored = auraStore.Get(auraID)
        if stored == nil then return end
        stored.x, stored.y = x, y
        auraStore.Save()
        if onAuraMoved ~= nil then onAuraMoved(auraID) end
    end)
    mounted[auraID] = { display = display, displayID = aura.display, aura = aura }
end

local function sync()
    local wanted = {}
    for _, aura in ipairs(auraStore.List()) do
        if aura.enabled then
            wanted[aura.id] = true
            local entry = mounted[aura.id]
            if entry ~= nil and entry.displayID ~= aura.display then
                unmount(aura.id)
                entry = nil
            end
            if entry == nil then
                mount(aura)
            else
                entry.aura = aura
                entry.display:Apply(aura)
            end
        end
    end
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
        local curr, max, unrounded = nil, nil, nil
        if sourceID ~= nil and available then
            local value = sourceValues[sourceID]
            if value == nil then
                value = {}
                sourceValues[sourceID] = value
            end
            if value.frame ~= frame then
                value.frame = frame
                value[1], value[2], value[3] = dataSources.ReadAvailable(sourceID)
            end
            curr, max, unrounded = value[1], value[2], value[3]
        end
        -- A smooth source's unrounded value is only for drawing; text keeps
        -- the rounded one. Each display decides whether to use it.
        entry.display:SetValue(curr, max, unrounded)
    end
end

function auraManager.Destroy()
    destroyAll()
    gameArea = nil
    dirty = true
end

return auraManager
