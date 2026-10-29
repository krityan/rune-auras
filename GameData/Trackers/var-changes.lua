-- Var changes from VarTransmit, for every module that follows them. The
-- event fires for every var in the game, so one subscription reads each
-- change's name once and hands it to the listeners.

local gameApi = require("GameData/game-api")

local varChanges = {}

local EVENT_ID = "runeAuras_varChanges"

---@alias VarListener fun(name: string, newValue: any, oldValue: any)

---@type table<string, VarListener> Listener id to listener.
local listeners = {}
local subscribed = false

--- Passes a var change to every listener.
---@param event table A VarTransmit event.
local function onVarTransmit(event)
    local name = event.var and gameApi.EventVarName(event)
    if name == nil then return end
    local newValue, oldValue = event.newValue, event.oldValue
    for _, listener in pairs(listeners) do listener(name, newValue, oldValue) end
end

--- Calls a function with every var change until Unlisten. Listening again
--- with the same id replaces it.
---@param listenerID string
---@param listener VarListener
function varChanges.Listen(listenerID, listener)
    listeners[listenerID] = listener
    if subscribed then return end
    Event.VarTransmit.Subscribe(EVENT_ID, onVarTransmit)
    subscribed = true
end

--- Stops calling a listener, and stops following the event once none is left.
---@param listenerID string
function varChanges.Unlisten(listenerID)
    listeners[listenerID] = nil
    if not subscribed or next(listeners) ~= nil then return end
    Event.VarTransmit.Unsubscribe(EVENT_ID)
    subscribed = false
end

return varChanges
