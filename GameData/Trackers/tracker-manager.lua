-- Starts, resets and stops the trackers that follow game events or hold the
-- session's state, all together and in an order that works.

local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local activeBuffs = require("GameData/Trackers/active-buffs")
local channel = require("GameData/Trackers/channel")
local combatTimer = require("GameData/Trackers/combat-timer")
local extraAction = require("GameData/Trackers/extra-action")
local gameClock = require("GameData/Trackers/game-clock")
local playerTarget = require("GameData/Trackers/player-target")
local stalledAbility = require("GameData/Trackers/stalled-ability")
local targetDebuffs = require("GameData/Trackers/target-debuffs")
local targetEffects = require("GameData/Trackers/target-effects")
local targetInfo = require("GameData/Trackers/target-info")
local varCache = require("GameData/Trackers/var-cache")
local wornEquipment = require("GameData/Trackers/worn-equipment")

local trackerManager = {}

-- In start order: the game clock first, as the others read its tick count,
-- and target-debuffs after player-target (see targetDebuffs.Start). Every
-- one has Reset; active-buffs and channel follow no events of their own, so
-- they have no Start or Stop.
local TRACKERS = {
    gameClock,
    varCache,
    abilityCooldowns,
    extraAction,
    playerTarget,
    targetDebuffs,
    targetEffects,
    stalledAbility,
    combatTimer,
    wornEquipment,
    targetInfo,
    activeBuffs,
    channel,
}

--- Starts every tracker following its events. Call once, at load.
function trackerManager.Start()
    for _, tracker in ipairs(TRACKERS) do
        if tracker.Start then tracker.Start() end
    end
end

--- Makes every tracker forget the session, on leaving the game.
function trackerManager.Reset()
    for _, tracker in ipairs(TRACKERS) do tracker.Reset() end
end

--- Stops every tracker following events, in reverse start order, when the
--- plugin unloads.
function trackerManager.Stop()
    for index = #TRACKERS, 1, -1 do
        local tracker = TRACKERS[index]
        if tracker.Stop then tracker.Stop() end
    end
end

return trackerManager
