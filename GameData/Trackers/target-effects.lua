-- Debuffs on the player's current target that aren't timed from a use (the
-- target debuff catalogue's OTHER): whether each shows on the target info
-- panel. Who applied one, or when, can't be seen.

local playerTarget = require("GameData/Trackers/player-target")
local targetDebuffCatalogue = require("GameData/Catalogues/target-debuff-catalogue")
local targetPanel = require("GameData/Trackers/target-panel")

local targetEffects = {}

local EVENT_ID = "runeAuras_targetEffects"
local NO_TARGET = playerTarget.NONE
-- Reads in a row without an effect's icon before it counts as gone.
local ABSENT_READS = 2

--- An effect showing on the current target.
---@class ShownEffect
---@field target integer The target's NPC uid.
---@field absentReads integer Reads in a row without its icon.

---@type table<string, ShownEffect> Entry key to the effect, while it shows.
local shown = {}

--- Follows the panel once a server tick: an effect starts when its icon
--- first shows on the current target, and ends after enough reads without
--- it, or when the target changes or the panel unloads.
local function onServerTick()
    local current = playerTarget.Current()
    local icons, filled = nil, 0
    if current ~= nil and current ~= NO_TARGET then
        icons, filled = targetPanel.Icons()
    end

    if icons == nil then
        shown = {}
        return
    end

    -- With every slot full, an effect may be on the target but not shown, so it isn't ended.
    local isPanelFull = filled >= targetPanel.SLOT_COUNT
    for _, entry in ipairs(targetDebuffCatalogue.OTHER) do
        local effect = shown[entry.key]
        if effect ~= nil and effect.target ~= current then
            effect = nil
        end

        if icons[entry.icon] then
            effect = effect or { target = current, absentReads = 0 }
            effect.absentReads = 0
        elseif effect ~= nil and not isPanelFull then
            effect.absentReads = effect.absentReads + 1

            if effect.absentReads >= ABSENT_READS then
                effect = nil
            end
        end

        shown[entry.key] = effect
    end
end

--- An effect showing on the current target: one seen on a target the
--- player has since swapped from doesn't count, though it's only dropped on
--- the next server tick.
---@param entry TargetEffectEntry
---@return ShownEffect? effect
local function shownOnCurrent(entry)
    local effect = shown[entry.key]
    if effect == nil or effect.target ~= playerTarget.Current() then
        return nil
    end

    return effect
end

--- Whether an effect shows on the current target, as 1 of 1 or 0 of 1.
---@param entry TargetEffectEntry
---@return number curr
---@return number max
function targetEffects.Read(entry)
    local isShown = shownOnCurrent(entry) ~= nil
    return isShown and 1 or 0, 1
end

--- Forgets the effects, e.g. on leaving the game.
function targetEffects.Reset()
    shown = {}
end

--- Starts reading the panel each server tick. Call once, at load.
function targetEffects.Start()
    Event.ServerLogic.Subscribe(EVENT_ID, onServerTick)
end

--- Stops following events.
function targetEffects.Stop()
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

return targetEffects
