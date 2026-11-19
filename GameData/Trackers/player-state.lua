-- The player's state for load options: combat, their weapons' style and how
-- they're held, skill levels, and the magic master cape's perk. Read when
-- asked, through var-cache.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local varCache = require("GameData/Trackers/var-cache")
local wornEquipment = require("GameData/Trackers/worn-equipment")
local itemSlots = require("GameData/Catalogues/item-slots")

local playerState = {}

---@alias WeaponStyle "melee"|"ranged"|"magic"|"necromancy"

-- COMBATV2_MAINHAND_STYLE / _OFFHAND_STYLE value to style, the same for
-- one- and two-handed, plain and augmented weapons. They may be weapon
-- categories rather than styles, so other weapon types could use other
-- values: unknown ones are logged once. 9 is Malachi's tooth, a crossbow;
-- 5 an off-hand melee weapon or defender (Dark Sliver of Leng, Kalphite defender).
---@type table<integer, WeaponStyle>
local STYLES = { [6] = "melee", [5] = "melee", [8] = "ranged", [9] = "ranged", [1] = "magic", [37] = "necromancy" }
-- 7 is nothing equipped and -1 an empty off hand. 0 is taken as no weapon
-- rather than an unknown style.
local NO_WEAPON = { [7] = true, [-1] = true, [0] = true }

local readVarPlayer = varCache.VarPlayer

--- Whether the player is in combat.
---@return boolean? inCombat nil out of game.
function playerState.InCombat()
    local value = readVarPlayer("COMBATV2_PLAYER_IS_IN_COMBAT")
    if value == nil then
        return nil
    end

    return value ~= 0
end

---@alias WeaponHands
---| "twoHanded" # a two-handed weapon
---| "dualWield" # a weapon in each hand
---| "oneHanded" # a weapon in one hand only, or none

-- Style values already logged as unknown.
local reported = {}

--- The style a hand's style value means.
---@param value integer?
---@return WeaponStyle? style nil for no weapon or an unknown value.
local function styleOf(value)
    if value == nil or NO_WEAPON[value] then
        return nil
    end

    local style = STYLES[value]
    if style == nil and not reported[value] then
        reported[value] = true
        log(formatStr("Unknown weapon style value {}", tostring(value)))
    end

    return style
end

--- The equipped weapon's combat style: the main hand weapon's style, or the
--- off-hand weapon's when the main hand is empty (e.g. only an off-hand weapon equipped).
---@return WeaponStyle? style nil with no weapon, or out of game.
function playerState.WeaponStyle()
    return styleOf(readVarPlayer("COMBATV2_MAINHAND_STYLE")) or styleOf(readVarPlayer("COMBATV2_OFFHAND_STYLE"))
end

--- How the player's weapons are held: the main hand's item from the worn
--- equipment (the shipped list says whether it's two-handed), and the off
--- hand's style and damage, as a defender has a melee style too.
--- TODO: check in game that a defender's COMBATV2_OFFHAND_STRENGTH is 0 and
--- an off-hand weapon's above 0.
---@return WeaponHands
function playerState.WeaponHands()
    local mainItem = wornEquipment.Item(wornEquipment.SLOTS.MAIN_HAND)
    if mainItem ~= nil and itemSlots.IsTwoHanded(mainItem) then
        return "twoHanded"
    end

    local hasMainWeapon = styleOf(readVarPlayer("COMBATV2_MAINHAND_STYLE")) ~= nil
    local hasOffWeapon = styleOf(readVarPlayer("COMBATV2_OFFHAND_STYLE")) ~= nil
        and (tonumber(readVarPlayer("COMBATV2_OFFHAND_STRENGTH")) or 0) > 0
    if hasMainWeapon and hasOffWeapon then
        return "dualWield"
    end

    return "oneHanded"
end

--- Every skill, by its SkillType key (which stays put if the game renumbers
--- skills), with its name as players know it, in alphabetical order.
---@type { id: string, label: string }[]
playerState.SKILLS = {
    { id = "AGILITY", label = "Agility" },
    { id = "ARCHAEOLOGY", label = "Archaeology" },
    { id = "ATTACK", label = "Attack" },
    { id = "HITPOINTS", label = "Constitution" },
    { id = "CONSTRUCTION", label = "Construction" },
    { id = "COOKING", label = "Cooking" },
    { id = "CRAFTING", label = "Crafting" },
    { id = "DEFENCE", label = "Defence" },
    { id = "DIVINATION", label = "Divination" },
    { id = "DUNGEONEERING", label = "Dungeoneering" },
    { id = "FARMING", label = "Farming" },
    { id = "FIREMAKING", label = "Firemaking" },
    { id = "FISHING", label = "Fishing" },
    { id = "FLETCHING", label = "Fletching" },
    { id = "HERBLORE", label = "Herblore" },
    { id = "HUNTER", label = "Hunter" },
    { id = "INVENTION", label = "Invention" },
    { id = "MAGIC", label = "Magic" },
    { id = "MINING", label = "Mining" },
    { id = "NECROMANCY", label = "Necromancy" },
    { id = "PRAYER", label = "Prayer" },
    { id = "RANGED", label = "Ranged" },
    { id = "RUNECRAFTING", label = "Runecrafting" },
    { id = "SLAYER", label = "Slayer" },
    { id = "SMITHING", label = "Smithing" },
    { id = "STRENGTH", label = "Strength" },
    { id = "SUMMONING", label = "Summoning" },
    { id = "THIEVING", label = "Thieving" },
    { id = "WOODCUTTING", label = "Woodcutting" },
}

--- A SKILLS id's SkillType value.
---@param skillKey any
---@return integer? skill nil for an unknown skill.
local function skillType(skillKey)
    if type(skillKey) ~= "string" or SkillType == nil then
        return nil
    end

    return SkillType[skillKey]
end

--- The player's level in a skill as it is now, boosts and drains included.
---@param skillKey any A SKILLS id.
---@return integer? level nil for an unknown skill, or out of game.
function playerState.SkillLevel(skillKey)
    local skill = skillType(skillKey)
    if skill == nil then
        return nil
    end

    return gameApi.SkillLevel(skill)
end

--- The player's level in a skill from their XP, without boosts or drains.
---@param skillKey any A SKILLS id.
---@return integer? level nil for an unknown skill, or out of game.
function playerState.BaseSkillLevel(skillKey)
    local skill = skillType(skillKey)
    if skill == nil then
        return nil
    end

    return gameApi.BaseSkillLevel(skill)
end

-- The Magic master cape's item id.
local MAGIC_MASTER_CAPE = 31273
-- The cape whose perks are in effect: the worn one (-1 with none).
local WORN_PERK_CAPE_VAR = "SKILLCAPE_PERKS_OBJ"
-- The cape on the Anachronia base camp's cape stand, whose perk is in effect while it's there.
local STAND_CAPE_VAR = "DINO_BASE_CAMP_PERK_SKILLCAPE"
-- A multi-perk cape's (max, completionist) stored perks, each a perk number
-- with a flag for the master version.
local STORED_PERKS = {
    { perk = "SKILLCAPE_PERKS_STORED1", master = "SKILLCAPE_PERKS_STORED1_MASTER" },
    { perk = "SKILLCAPE_PERKS_STORED2", master = "SKILLCAPE_PERKS_STORED2_MASTER" },
    { perk = "SKILLCAPE_PERKS_STORED3", master = "SKILLCAPE_PERKS_STORED3_MASTER" },
}
-- The magic perk's number among a multi-perk cape's stored perks.
local MAGIC_PERK = 4
-- What a multi-perk cape's name contains (lower case): "Max cape", "Completionist cape (t)".
local MULTI_PERK_NAMES = { "max cape", "completionist cape" }

--- Whether a multi-perk cape holds the magic master perk.
---@return boolean
local function storesMagicMasterPerk()
    for _, stored in ipairs(STORED_PERKS) do
        local isMaster = tonumber(readVarPlayer(stored.master)) == 1
        if isMaster and tonumber(readVarPlayer(stored.perk)) == MAGIC_PERK then
            return true
        end
    end

    return false
end

--- Whether an item is a cape that can hold several perks.
---@param itemID integer
---@return boolean
local function isMultiPerkCape(itemID)
    local name = string.lower(gameApi.ItemName(itemID) or "")
    for _, part in ipairs(MULTI_PERK_NAMES) do
        if string.find(name, part, 1, true) ~= nil then
            return true
        end
    end

    return false
end

--- Whether a cape var's cape gives the magic master perk: the master cape
--- itself, or a multi-perk cape holding it.
---@param name string An OBJ var.
---@return boolean
local function givesMagicMasterPerk(name)
    local itemID = gameApi.ItemID(readVarPlayer(name))
    if itemID == nil or itemID < 0 then
        return false
    end

    if itemID == MAGIC_MASTER_CAPE then
        return true
    end

    return isMultiPerkCape(itemID) and storesMagicMasterPerk()
end

---@type integer? The server tick (gameClock.ServerTicks) the perk was last checked on.
local perkCheckedTick = nil
-- Whether the perk was on at perkCheckedTick.
local hasPerk = false

--- Whether the magic master cape's perk is on, doubling hex spells'
--- lengths: from the worn cape, or the base camp's cape stand. Checked once
--- a server tick, as the vars it reads change no faster.
---@return boolean
function playerState.HasMagicMasterPerk()
    local tick = gameClock.ServerTicks()
    if tick ~= perkCheckedTick then
        perkCheckedTick = tick
        hasPerk = givesMagicMasterPerk(WORN_PERK_CAPE_VAR) or givesMagicMasterPerk(STAND_CAPE_VAR)
    end

    return hasPerk
end

return playerState
