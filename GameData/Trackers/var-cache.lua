-- VarPlayer values for reads every step (resources, buff stacks, toggles),
-- each kept until VarTransmit (through var-changes) says it changed. A
-- varbit's change comes through under its base var's name, never its own,
-- so each var is filed under the name its changes arrive as (its base var's
-- for a varbit). A re-send with the value unchanged drops nothing. Values
-- are also dropped every server tick, so a change that came some other way
-- shows a tick late at worst.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local varChanges = require("GameData/Trackers/var-changes")

local varCache = {}

local LISTENER_ID = "runeAuras_varCache"

---@type table<string, any> Var name to its last value read.
local values = {}
---@type table<string, boolean> Var name to true while its value is current.
local current = {}
-- The server tick `current` was started on.
local currentServerTick = nil
---@type table<string, string> Var name to the name its changes arrive under: its base var's for a varbit, else its own.
local changeNames = {}
---@type table<string, string[]> A name changes arrive under to the vars filed under it.
local varsByChangeName = {}
---@type table<string, boolean> Vars whose change name isn't known yet (their config isn't readable yet): dropped on every change.
local unfiled = {}

--- Files a var under the name its changes arrive as, once its config can be read.
---@param name string
local function fileUnderChangeName(name)
    local varConfig = gameApi.Cached(gameApi.VarPlayerConfig, name)
    local baseName, ok = nil, false
    if varConfig ~= nil then baseName, ok = gameApi.BaseVarName(varConfig) end
    if not ok then
        unfiled[name] = true
        return
    end
    unfiled[name] = nil
    local changeName = baseName or name
    changeNames[name] = changeName
    local filed = varsByChangeName[changeName] or {}
    filed[#filed + 1] = name
    varsByChangeName[changeName] = filed
end

--- Drops the values a var change affects.
---@param name string
---@param newValue any
---@param oldValue any
local function onVarChanged(name, newValue, oldValue)
    if newValue == oldValue then return end
    local filed = varsByChangeName[name]
    if filed ~= nil then
        for _, filedName in ipairs(filed) do current[filedName] = nil end
    end
    for unfiledName in pairs(unfiled) do current[unfiledName] = nil end
end

--- A VarPlayer's (or varbit's) value, read from the game only when it's
--- changed since the last read (or a server tick has passed).
---@param name string
---@return any value nil if it can't be read.
function varCache.VarPlayer(name)
    local serverTick = gameClock.ServerTicks()
    if serverTick ~= currentServerTick then
        currentServerTick = serverTick
        for known in pairs(current) do current[known] = nil end
    end
    if current[name] then return values[name] end
    if changeNames[name] == nil then fileUnderChangeName(name) end
    local value = gameApi.CachedVarPlayer(name)
    values[name], current[name] = value, true
    return value
end

--- Forgets every value, e.g. on leaving the game. Which name each var's
--- changes arrive under is kept: that doesn't change.
function varCache.Reset()
    values, current = {}, {}
end

--- Starts following var changes. Call once, at load.
function varCache.Start()
    varChanges.Listen(LISTENER_ID, onVarChanged)
end

--- Stops following them.
function varCache.Stop()
    varChanges.Unlisten(LISTENER_ID)
end

return varCache
