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

local gameApi = require("GameData/game-api")
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
-- Whether this scan is the first since loading or a pause: the buffs it
-- finds may have been there a while, rather than having just started.
local resumed = true
-- Struct id -> the longest a buff has started at this session, in seconds:
-- the initial tick's estimate when config gives no duration. Only the first
-- number of an instance seen from its start counts. A jump up while it's
-- running can be an extension as easily as a refresh (Galeshot can add more
-- than a step), and one found on resuming may already be extended; either
-- would make the next instance start at the extended length.
local knownDuration = {}
local wantedTick = { buff = nil, debuff = nil }
-- Struct id -> true for buffs whose number is a stack count, noted by Read
-- (update only knows the struct id). Their number isn't a time, so update
-- doesn't track a countdown for them.
local stacking = {}
local componentIDs = {}
local structParam, visibleParam = nil, nil
-- Struct id -> what its slot showed: { text, value, unit, percent, seconds
-- (the number in seconds), lo/hi (the range the time left is in as of the
-- last scan) and remaining (its midpoint), holding (being extended), max,
-- seenTick }. Only entries seen on the current tick count:
-- the rest are left over from before scanning paused.
local active = {}

local function paramID(name, fallback)
    local param = gameApi.Param(name)
    return param ~= nil and gameApi.ID(param) or fallback
end

local function slotComponentID(bar, slot)
    componentIDs[bar] = componentIDs[bar] or {}
    local ids = componentIDs[bar]
    if ids[slot] == nil then
        ids[slot] = gameApi.ComponentID(bar .. "__BUFF_" .. slot) or false
    end
    return ids[slot] or nil
end

-- The first non-empty text among a slot's children. Every slot is read
-- every tick, so this makes no closures: the visitor is shared and leaves
-- what it finds in foundText. Children that aren't text read nil for
-- .content, which the type check skips.
local foundText = nil

local function visitChild(child)
    local content = child.content
    if type(content) == "string" and content ~= "" then
        foundText = content
        return true
    end
    return false
end

-- Called from readSlot, inside its guard.
local function slotText(component)
    foundText = nil
    component:IterateStaticComponents(visitChild)
    if foundText == nil then component:IterateDynamicComponents(visitChild) end
    return foundText
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

-- Narrows a state's range of possible time left to lo..hi, falling back to
-- the given range if they don't overlap. Its midpoint is the estimate.
local function narrow(state, lo, hi, fallbackLo, fallbackHi)
    lo, hi = math.max(state.lo or lo, lo), math.min(state.hi or hi, hi)
    if lo > hi then lo, hi = fallbackLo, fallbackHi end
    state.lo, state.hi = lo, hi
    state.remaining = (lo + hi) / 2
end

-- Follows one slot's text, once per scan (so once a server tick). The time
-- left is tracked as a range, lo..hi, that drops by a tick each scan and is
-- narrowed by what the text says: a number N means the time left is within
-- a step below N, and a step down to N seen this tick means it crossed N
-- during the last tick, so it's within a tick below N. Over a few steps the
-- range closes in on the real countdown, and its midpoint is the estimate.
-- Text that should have stepped down by now but hasn't (with a tick's
-- slack, in case the text updates just after the tick it's read on) means
-- the buff was extended that tick (e.g. Galeshot during Rapid Fire), so the
-- range moves back up a tick and the max grows by a tick.
local function update(structID, text)
    local state = active[structID]
    if state == nil then
        state = { firstTick = tick }
        active[structID] = state
    end
    state.seenTick = tick
    if stacking[structID] then
        if text ~= state.text then
            state.text = text
            state.value, state.unit, state.percent = parse(text)
        end
        return
    end
    if text == state.text then
        if state.lo == nil then return end
        local floor = state.seconds - state.unit
        local lo, hi = state.lo - SECONDS_PER_TICK, state.hi - SECONDS_PER_TICK
        state.holding = hi < floor - SECONDS_PER_TICK
        if state.holding then
            lo, hi = lo + SECONDS_PER_TICK, hi + SECONDS_PER_TICK
            state.max = state.max + SECONDS_PER_TICK
        end
        -- hi may sit up to the slack below what the text allows (that's how
        -- a hold is spotted), so only lo is held to it; Read clamps the
        -- estimate.
        lo = math.min(math.max(lo, floor), hi)
        state.lo, state.hi = lo, hi
        state.remaining = (lo + hi) / 2
        return
    end
    local value, unit, percent = parse(text)
    local previousSeconds = state.seconds
    local previousRemaining = state.remaining
    state.text, state.value, state.unit, state.percent = text, value, unit, percent
    state.holding = false
    if value == nil or unit == nil then
        state.remaining, state.seconds, state.lo, state.hi = nil, nil, nil, nil
        return
    end
    local seconds = value * unit
    state.seconds = seconds
    -- What the text alone allows.
    local floor = seconds - unit
    -- The instance's first number. A number coming back after a blank or
    -- non-numeric text (the slot redrawing, e.g. when extended) belongs to
    -- the same instance, so it isn't a fresh start.
    local firstNumber = not state.numbered
    state.numbered = true
    if previousSeconds == nil and not firstNumber then
        state.max = math.max(state.max or 0, seconds)
        state.lo, state.hi = nil, nil
        narrow(state, floor, seconds, floor, seconds)
    elseif previousSeconds == nil or state.max == nil or seconds > previousSeconds + unit then
        -- A first sighting, or a jump up of more than a step: a new or
        -- refreshed buff, which starts full again. An initial tick's
        -- estimate stays the max if it was longer, so the bar doesn't jump
        -- when the first number arrives, and also narrows the range: it was
        -- timed from when the slot appeared.
        -- The estimate only stays the max if the number agrees with it (what
        -- it predicts by now is within a tick of the number); a longer one
        -- was wrong, e.g. remembered from an extended instance.
        local estimate = previousSeconds == nil and state.estimate or nil
        if estimate ~= nil then
            local predicted = estimate - (tick - state.firstTick) * SECONDS_PER_TICK
            if predicted > seconds + SECONDS_PER_TICK then
                estimate = nil
                state.estimate = nil
            end
        end
        state.max = math.max(seconds, estimate or 0)
        -- Remembered only from a number seen within a few ticks of the slot
        -- appearing, i.e. from the instance's start.
        if firstNumber and not resumed and tick - state.firstTick <= TEXT_GRACE_TICKS then
            knownDuration[structID] = math.max(knownDuration[structID] or 0, seconds)
        end
        state.lo, state.hi = nil, nil
        -- One that's just started is within a tick of its number; one found
        -- on resuming could be anywhere in its step.
        local lo = (resumed and previousSeconds == nil) and floor or math.max(floor, seconds - SECONDS_PER_TICK)
        narrow(state, lo, seconds, floor, seconds)
        if previousSeconds == nil and state.estimate ~= nil then
            local estimated = state.estimate - (tick - state.firstTick) * SECONDS_PER_TICK
            narrow(state, estimated - SECONDS_PER_TICK, estimated, state.lo, state.hi)
        end
    elseif seconds > previousSeconds then
        -- Up a step: extended by more than it ran down, so the max grows by
        -- what was added.
        state.lo, state.hi = nil, nil
        narrow(state, floor, seconds, floor, seconds)
        state.max = state.max + math.max(state.remaining - (previousRemaining or previousSeconds) + SECONDS_PER_TICK, 0)
    else
        -- Down a step: it crossed the new number during the last tick.
        local lo, hi = state.lo - SECONDS_PER_TICK, state.hi - SECONDS_PER_TICK
        state.lo, state.hi = nil, nil
        local crossed = math.max(floor, seconds - SECONDS_PER_TICK)
        narrow(state, math.max(lo, crossed), math.min(hi, seconds), crossed, seconds)
    end
end

-- The game side of reading one slot, run through gameApi.Read: the struct
-- id of the buff it shows (false if none), with its text left in foundText.
local function readSlot(componentID)
    foundText = nil
    local component = ui.Interfaces:GetComponent(componentID)
    if component == nil then return false end
    local slotParams = component.paramsConfig
    local structID, visible = slotParams:Get(structParam), slotParams:Get(visibleParam)
    if type(structID) ~= "number" or structID < 0 or visible ~= 1 then return false end
    slotText(component)
    return structID
end

-- Reads every slot of one bar, each on its own so one that can't be read
-- doesn't stop the rest. Returns whether every slot could be read.
local function scan(kind)
    local bar = BARS[kind]
    structParam = structParam or paramID("COMBATV2_BUFF_STRUCT", STRUCT_PARAM_FALLBACK)
    visibleParam = visibleParam or paramID("COMBATV2_BUFF_VISIBLE", VISIBLE_PARAM_FALLBACK)
    local complete = true
    for slot = 1, SLOTS do
        local componentID = slotComponentID(bar, slot)
        if componentID ~= nil then
            local structID, ok = gameApi.Read("a buff bar slot", readSlot, componentID)
            if not ok then
                complete = false
            elseif structID then
                update(structID, foundText)
            end
        end
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
    resumed = lastScanTick ~= tick - 1
    if resumed then active = {} end
    lastScanTick = tick
    local complete = true
    for kind in pairs(BARS) do
        if wantedNow(kind) then
            if not scan(kind) then complete = false end
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
    if entry.stacks then stacking[entry.structID] = true end
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
    if state.remaining == nil then return 1, 1, nil, true end
    -- Between scans it runs down through the tick, unless it's being held
    -- up by extensions; never below what the text allows.
    local remaining = state.remaining
    if not state.holding then remaining = remaining - gameClock.TickFraction() * SECONDS_PER_TICK end
    remaining = math.max(remaining, state.seconds - state.unit, 0)
    local rounded = math.ceil(remaining * 10 - 1e-9) / 10
    return rounded, state.max or state.seconds, remaining
end

return buffBar
