-- The extra action button some fights show (Kerapac's Warp time): which
-- button it is, followed from VarTransmit, its cooldown, polled when read,
-- and each button's full cooldown, measured from VarTransmit when it's
-- used. The buttons themselves are listed by extra-action-catalogue.

local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local extraActionCatalogue = require("GameData/Catalogues/extra-action-catalogue")
local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local varChanges = require("GameData/Trackers/var-changes")

local extraAction = {}

local EVENT_ID = "runeAuras_extraAction"
-- The button showing (an ExtraActionButton id), 0 while there's none.
local BUTTON_VAR = "TOPLEVEL_V2_EXTRA_ACTION_BUTTON_ID"
local NO_BUTTON = 0
-- Its cooldown vars without _START/_END: server ticks, like an ability's.
local COOLDOWN_VAR = "TOPLEVEL_V2_EXTRA_ACTION_BUTTON_COOLDOWN"
local COOLDOWN_END_VAR = COOLDOWN_VAR .. "_END"
-- How many server ticks the clock can be off by when _END arrives.
local CLOCK_SLACK_TICKS = 1

---@type integer? The button showing, else the last one shown since entering the game.
local lastButtonID = nil
-- Whether a button is showing now, rather than only shown before.
local isShowing = false
---@type integer? The server tick the button last changed on.
local buttonChangedTick = nil
---@type table<integer, integer> Button id to its full cooldown in server ticks, as last measured.
local measuredTicks = {}
---@type { buttonID: integer, tick: integer, previousTicks: integer? }? The latest measurement, so one taken on the tick the button changed can be undone.
local lastMeasurement = nil

--- The id of the button showing, else of the last one shown since entering the game.
---@return integer? buttonID nil before any has shown.
function extraAction.ButtonID()
    return lastButtonID
end

--- The button showing, else the last one shown since entering the game.
---@return ExtraActionButton? button nil before any has shown, or while the catalogue is loading.
function extraAction.Button()
    if lastButtonID == nil then return nil end
    return extraActionCatalogue.Find(lastButtonID)
end

--- A button's full cooldown: as measured when last used since entering the
--- game, unless that was within a tick of the game's table's, else the table's.
---@param button ExtraActionButton
---@return number seconds 0 for a button without one.
function extraAction.CooldownSeconds(button)
    return gameClock.TicksToSeconds(measuredTicks[button.id] or button.cooldownTicks)
end

--- The button's cooldown. The game sets only its _END var (its _START stays
--- 0), so the full cooldown is the button's own (see CooldownSeconds). Every
--- button shares the one var. Ready while no button is showing: the game
--- ends the cooldown when the button goes, and sets _END a tick ahead now
--- and then while none shows, which isn't a cooldown.
---@return number? remaining Seconds, to a tenth; 0 when ready; nil when it can't be timed yet.
---@return number? total Seconds: the button's cooldown, or what's left if that's more (0 for neither).
---@return number? unrounded
function extraAction.Read()
    local button = extraAction.Button()
    local total = button and extraAction.CooldownSeconds(button) or 0
    if not isShowing then return 0, total, 0 end
    local remaining, _, unrounded = abilityCooldowns.GetCooldown(COOLDOWN_VAR)
    if remaining == nil then return nil end
    -- A button found late, or the last one after a switch, can be shorter than what's left.
    return remaining, math.max(total, remaining), unrounded
end

--- Notes a new button showing. A button can't be used on the tick it
--- appears, so a measurement taken on that tick wasn't a use and is undone.
---@param value any The button var's new value.
local function onButtonChanged(value)
    local buttonID = tonumber(value)
    isShowing = buttonID ~= nil and buttonID ~= NO_BUTTON
    if isShowing then lastButtonID = buttonID end
    buttonChangedTick = abilityCooldowns.ServerTick()
    local measuredThisTick = lastMeasurement ~= nil and lastMeasurement.tick == buttonChangedTick
    if not measuredThisTick then return end
    measuredTicks[lastMeasurement.buttonID] = lastMeasurement.previousTicks
    lastMeasurement = nil
end

--- Measures the showing button's full cooldown when it's used: the _END var
--- is set on the use's server tick, so it's that many ticks away. Only a
--- change made while a button shows and the cooldown was over counts as a
--- use; one made while it runs shortens or extends it, one on the tick the
--- button changed comes with the button, and one while none shows is the
--- tick-ahead value (see Read).
---@param value any The _END var's new value.
---@param oldValue any
local function onCooldownEndChanged(value, oldValue)
    if not abilityCooldowns.IsSettled() then return end
    local endTick, now = tonumber(value), abilityCooldowns.ServerTick()
    if endTick == nil or now == nil or not isShowing or endTick <= now then return end
    local wasReady = (tonumber(oldValue) or 0) <= now
    if not wasReady or buttonChangedTick == now then return end
    local ticks = endTick - now
    local button = extraAction.Button()
    -- The clock can be a tick either side of _END's when it arrives, so a
    -- measurement that close to the table's is the table's.
    local matchesTable = button ~= nil and math.abs(ticks - button.cooldownTicks) <= CLOCK_SLACK_TICKS
    lastMeasurement = { buttonID = lastButtonID, tick = now, previousTicks = measuredTicks[lastButtonID] }
    if matchesTable then
        measuredTicks[lastButtonID] = nil
    else
        measuredTicks[lastButtonID] = ticks
    end
end

--- Follows the button var and the cooldown's _END var.
---@param name string
---@param value any Its new value.
---@param oldValue any
local function onVarChanged(name, value, oldValue)
    if value == oldValue then return end
    if name == BUTTON_VAR then
        onButtonChanged(value)
    elseif name == COOLDOWN_END_VAR then
        onCooldownEndChanged(value, oldValue)
    end
end

--- Starts following the button and measuring cooldowns. Call once, at load.
--- Reads the button once, as a reload in game gets no var changes for it.
function extraAction.Start()
    onButtonChanged(gameApi.CachedVarPlayer(BUTTON_VAR))
    varChanges.Listen(EVENT_ID, onVarChanged)
end

--- Forgets the button and the measured cooldowns, on leaving the game: the
--- next character may never see them. Entering the game resends the
--- button var.
function extraAction.Reset()
    lastButtonID, isShowing, buttonChangedTick, lastMeasurement = nil, false, nil, nil
    measuredTicks = {}
end

--- Stops following events.
function extraAction.Stop()
    varChanges.Unlisten(EVENT_ID)
end

return extraAction
