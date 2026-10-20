-- Reads which buffs are active, and for how long, from the game's own buff
-- and debuff bars (interfaces BUFF_BAR and DEBUFF_BAR). Each bar has 50
-- static slots (BUFF_BAR__BUFF_1..50); a slot showing a buff carries the
-- buff's struct id in its COMBATV2_BUFF_STRUCT component param and
-- COMBATV2_BUFF_VISIBLE = 1, and its children hold the icon and a text with
-- the time left ("15", "5m", ...) or the stack count.
-- So a buff only reads as active while the game's bar shows it: one hidden
-- by the player's buff bar settings never does.
-- The bars are only scanned on server ticks while something has asked for
-- a buff recently. The text only says whole seconds (or minutes), so the
-- time left counts down between changes using server ticks and the tick
-- fraction (GameData/Trackers/game-clock).
-- Usage:
--   local buffBar = require("GameData/Trackers/buff-bar")
--   buffBar.Start() / buffBar.Stop() / buffBar.Reset()
--   buffBar.Read(entry) --> curr, max, unrounded curr, untimed
--     (entry from GameData/Catalogues/buff-catalogue)

local gameClock = require("GameData/Trackers/game-clock")

local buffBar = {}

local EVENT_ID = "runeAuras_buffBar"
local SLOTS = 50
local SECONDS_PER_TICK = 0.6
-- Keep scanning this many server ticks after the last Read.
local WANTED_TICKS = 3
local BARS = { buff = "BUFF_BAR", debuff = "DEBUFF_BAR" }
-- Fallback param ids, as found in game; looked up by name first.
local STRUCT_PARAM_FALLBACK = 8106
local VISIBLE_PARAM_FALLBACK = 8107
-- A new slot can show up a tick or so before its text. Until it does (for
-- up to this many ticks), a buff that should have a number (timed or
-- stacking) is "initial": it reads its estimated full duration counting
-- down, flagged so displays can choose to treat it as inactive instead.
local TEXT_GRACE_TICKS = 3
-- Text units: "15" or "15s" seconds, "5m" minutes, "1h"/"1hr" hours.
local UNITS = { [""] = 1, s = 1, m = 60, h = 3600, hr = 3600 }

local tick = 0
-- The last tick the bars were scanned on.
local lastScanTick = nil
-- Struct id -> the longest a buff has lasted this session, in seconds: the
-- initial tick's estimate when config gives no duration.
local knownDuration = {}
local wantedTick = { buff = nil, debuff = nil }
local componentIDs = {}
local structParam, visibleParam = nil, nil
-- Struct id -> what its slot showed: { text, value, unit, percent,
-- changedTick, max, seenTick }. Only entries seen on the current tick count:
-- the rest are left over from before scanning paused.
local active = {}

local function paramID(name, fallback)
    local ok, param = pcall(function() return config.Param[name].id end)
    return ok and param or fallback
end

local function slotComponentID(bar, slot)
    componentIDs[bar] = componentIDs[bar] or {}
    local ids = componentIDs[bar]
    if ids[slot] == nil then
        local ok, componentID = pcall(function() return id.Component[bar .. "__BUFF_" .. slot] end)
        ids[slot] = ok and componentID or false
    end
    return ids[slot] or nil
end

-- The first non-empty text among a slot's children.
local function slotText(component)
    local text = nil
    local function visit(child)
        local ok, content = pcall(function() return child.content end)
        if ok and type(content) == "string" and content ~= "" then
            text = content
            return true
        end
        return false
    end
    pcall(function() component:IterateStaticComponents(visit) end)
    if text == nil then pcall(function() component:IterateDynamicComponents(visit) end) end
    return text
end

-- "15" -> 15, 1; "5m" -> 5, 60; "40%" -> 40, nil, true; else nil.
local function parse(text)
    if text == nil then return nil end
    local number, suffix = text:match("^%s*(%d+%.?%d*)%s*(%a*%%?)%s*$")
    number = tonumber(number)
    if number == nil then return nil end
    if suffix == "%" then return number, nil, true end
    local unit = UNITS[suffix:lower()]
    if unit == nil then return nil end
    return number, unit, false
end

local function update(structID, text)
    local state = active[structID]
    if state == nil then
        state = { firstTick = tick }
        active[structID] = state
    end
    state.seenTick = tick
    if text == state.text then return end
    local value, unit, percent = parse(text)
    local previous, previousUnit = state.value, state.unit
    state.text, state.value, state.unit, state.percent = text, value, unit, percent
    state.changedTick = tick
    if value == nil then return end
    local seconds = unit and value * unit or value
    local previousSeconds = previous and (previousUnit and previous * previousUnit or previous) or nil
    -- A first sighting, or a jump up (more than the text's own step), is a
    -- new or refreshed buff: it starts full again.
    if previousSeconds == nil or state.max == nil or seconds > previousSeconds + (unit or 1) then
        -- Keep an initial tick's estimate as the max if it was longer, so
        -- the bar doesn't jump when the first number arrives.
        state.max = math.max(seconds, previousSeconds == nil and state.estimate or 0)
    elseif seconds > state.max then
        state.max = seconds
    end
    knownDuration[structID] = math.max(knownDuration[structID] or 0, state.max)
end

local function readSlot(bar, slot)
    local componentID = slotComponentID(bar, slot)
    local component = componentID and ui.Interfaces:GetComponent(componentID)
    if component == nil then return end
    local slotParams = component.paramsConfig
    local structID, visible = slotParams:Get(structParam), slotParams:Get(visibleParam)
    if type(structID) == "number" and structID >= 0 and visible == 1 then
        update(structID, slotText(component))
    end
end

-- Reads every slot of one bar, each on its own so one that errors doesn't
-- stop the rest. Returns whether every slot could be read.
local function scan(kind)
    local bar = BARS[kind]
    structParam = structParam or paramID("COMBATV2_BUFF_STRUCT", STRUCT_PARAM_FALLBACK)
    visibleParam = visibleParam or paramID("COMBATV2_BUFF_VISIBLE", VISIBLE_PARAM_FALLBACK)
    local complete = true
    for slot = 1, SLOTS do
        if not pcall(readSlot, bar, slot) then complete = false end
    end
    return complete
end

local function wantedNow(kind)
    local wanted = wantedTick[kind]
    return wanted ~= nil and tick - wanted <= WANTED_TICKS
end

local function onServerTick()
    tick = tick + 1
    if not (wantedNow("buff") or wantedNow("debuff")) then return end
    -- After a pause, what's left in active stopped being followed (a buff
    -- may have ended or been refreshed meanwhile), so start afresh.
    if lastScanTick ~= tick - 1 then active = {} end
    lastScanTick = tick
    local complete = true
    for kind in pairs(BARS) do
        if wantedNow(kind) then
            local ok, read = pcall(scan, kind)
            if not ok or not read then complete = false end
        end
    end
    for structID, state in pairs(active) do
        if state.seenTick ~= tick then
            if complete then
                -- Not seen on a full scan: it's gone from the bar.
                active[structID] = nil
            else
                -- A slot couldn't be read, so it may still be there: keep it
                -- as it was for this tick rather than drop it.
                state.seenTick = tick
            end
        end
    end
end

function buffBar.Start()
    Event.ServerLogic.Subscribe(EVENT_ID, onServerTick)
end

function buffBar.Stop()
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

-- Forgets everything, e.g. on leaving the game.
function buffBar.Reset()
    active = {}
    lastScanTick = nil
    wantedTick.buff, wantedTick.debuff = nil, nil
    componentIDs = {}
end

-- An inactive buff reads 0. A timed one reads its seconds left (rounded up
-- to a tenth, like cooldowns) over the longest it's been since it started,
-- plus the unrounded value. A stacking one reads its stacks over the most
-- seen (or a percentage over 100). One with no number on the bar reads
-- 1 / 1 with untimed = true, so displays can leave out the text.
-- The fifth value, initial, marks a buff that's on the bar but hasn't shown
-- its number yet: it reads its expected duration (config's, or the longest
-- seen) counting down from when it appeared, or reads inactive if that's
-- not known.
function buffBar.Read(entry)
    wantedTick[entry.kind] = tick
    local state = active[entry.structID]
    -- Not seen this tick: either gone, or scanning was paused and it's out of
    -- date until the next scan.
    if state == nil or state.seenTick ~= tick then return 0, 0 end
    local value = state.value
    if value == nil then
        if (entry.timed or entry.stacks) and tick - state.firstTick < TEXT_GRACE_TICKS then
            local duration = not entry.stacks and (entry.duration or knownDuration[entry.structID]) or nil
            -- No estimate: lighting up without a number would be jarring.
            if duration == nil then return 0, 0 end
            state.estimate = duration
            local elapsed = (tick - state.firstTick + gameClock.TickFraction()) * SECONDS_PER_TICK
            local remaining = math.max(duration - elapsed, 0)
            return math.ceil(remaining * 10 - 1e-9) / 10, duration, remaining, false, true
        end
        return 1, 1, nil, true
    end
    if state.percent then return value, 100 end
    if entry.stacks then
        state.maxStacks = math.max(state.maxStacks or 0, value)
        return value, state.maxStacks
    end
    local unit = state.unit or 1
    local shown = value * unit
    local elapsed = (tick - state.changedTick + gameClock.TickFraction()) * SECONDS_PER_TICK
    -- The text rounds, so the real time left lies within one step below it.
    local remaining = math.max(shown - unit, 0, math.min(shown, shown - elapsed))
    local rounded = math.ceil(remaining * 10 - 1e-9) / 10
    return rounded, state.max or shown, remaining
end

return buffBar
