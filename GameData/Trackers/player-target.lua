-- The NPC the player is targeting, by its NPC uid, the latest one they had,
-- and that one's name, followed from NPCTARGET.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local varChanges = require("GameData/Trackers/var-changes")

local playerTarget = {}

local EVENT_ID = "runeAuras_playerTarget"
-- The NPC the player is targeting, by its NPC uid; NONE with none.
local TARGET_VAR = "NPCTARGET"
-- What NPC uid vars hold with no NPC.
local NONE = -1
playerTarget.NONE = NONE
-- The target info panel's name text, the current target's name.
local NAME_COMPONENT = "TOPLEVEL_V2_TARGET_INFO__NAME"

---@type integer? The current target's NPC uid (NONE with none); nil until read.
local current = nil
---@type integer? The latest target the player had.
local latest = nil
---@type string|false|nil The latest target's name; false when the NPC list had none and the panel hasn't named it yet; nil until looked up.
local latestName = nil
---@type boolean Whether the target info panel has named the latest target.
local isPanelNamed = false
---@type integer? gameClock.ServerTicks() when the latest target was targeted, so the panel's name is read once it has caught up.
local targetedTick = nil
---@type fun(lost: integer)? Called with the NPC uid the player stopped targeting, as the target goes to NONE.
local onLost = nil

--- Notes the player's target. A new one (or the same one targeted again,
--- as a uid can be reused) is named afresh.
---@param uid integer
local function setTarget(uid)
    local isNewTarget = uid ~= NONE and uid ~= current
    current = uid
    if not isNewTarget then return end
    latest, latestName, isPanelNamed = uid, nil, false
    targetedTick = gameClock.ServerTicks()
end

--- Names the current target from the target info panel, once a server tick
--- has passed since it was targeted so the panel shows it. The panel names
--- any target, where the NPC list can't find some.
local function readPanelName()
    if current == NONE or isPanelNamed then return end
    if targetedTick ~= nil and gameClock.ServerTicks() <= targetedTick then return end
    local combinedID = gameApi.Cached(gameApi.ComponentID, NAME_COMPONENT)
    local component = combinedID and gameApi.ComponentByID(combinedID)
    local text = component and gameApi.TextContent(component)
    if text == nil then return end
    -- Without any colour tags.
    local name = text:gsub("<[^>]*>", "")
    if name == "" then return end
    latestName, isPanelNamed = name, true
end

--- Reads the target var the first time (only in game, as server ticks are),
--- then the panel's name.
local function onServerTick()
    if current == nil then
        local uid = tonumber(gameApi.CachedVarPlayer(TARGET_VAR))
        if uid == nil then return end
        setTarget(uid)
    end
    readPanelName()
end

--- Follows the target var. This runs for every var change in the game.
---@param name string
---@param value any
local function onVarChanged(name, value)
    if name ~= TARGET_VAR then return end
    local uid = tonumber(value)
    if uid == nil then return end
    local hadTarget = current ~= nil and current ~= NONE
    if uid == NONE and hadTarget and onLost ~= nil then onLost(current) end
    setTarget(uid)
end

--- The current target.
---@return integer? uid An NPC uid, or NONE with no target; nil until known.
function playerTarget.Current()
    return current
end

--- The current target, else the latest one the player had.
---@return integer? uid An NPC uid; nil if the player hasn't had a target.
function playerTarget.Latest()
    return latest
end

--- The latest target's name, from the target info panel, else the NPC
--- list. Kept once the NPC is gone.
---@return string? name nil if the player hasn't had a target, or it hasn't been named.
function playerTarget.Name()
    if latest == nil then return nil end
    if latestName == nil then latestName = gameApi.NPCName(latest) or false end
    return latestName or nil
end

--- Sets what's called when the player loses their target (the target goes
--- to NONE), which is mostly the target dying.
---@param callback fun(lost: integer)? nil for nothing.
function playerTarget.SetOnLost(callback)
    onLost = callback
end

--- Forgets the target and its name, e.g. on leaving the game.
function playerTarget.Reset()
    current, latest, latestName, isPanelNamed, targetedTick = nil, nil, nil, false, nil
end

--- Starts following the target var and reading the panel's name each
--- server tick. Call once, at load.
function playerTarget.Start()
    varChanges.Listen(EVENT_ID, onVarChanged)
    Event.ServerLogic.Subscribe(EVENT_ID, onServerTick)
end

--- Stops following events.
function playerTarget.Stop()
    varChanges.Unlisten(EVENT_ID)
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

return playerTarget
