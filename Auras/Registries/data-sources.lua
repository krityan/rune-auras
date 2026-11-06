-- Data sources: the game values an aura can show, grouped by data type
-- (resources, cooldowns, ...) for picking in the editor. Owns the
-- DataSource record and building the lists; the values themselves are read
-- by GameData/Trackers, and the sets of abilities and buffs come from
-- GameData/Catalogues.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local activeBuffs = require("GameData/Trackers/active-buffs")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local channel = require("GameData/Trackers/channel")
local extraAction = require("GameData/Trackers/extra-action")
local extraActionCatalogue = require("GameData/Catalogues/extra-action-catalogue")
local specialAttackCatalogue = require("GameData/Catalogues/special-attack-catalogue")
local targetDebuffCatalogue = require("GameData/Catalogues/target-debuff-catalogue")
local targetDebuffs = require("GameData/Trackers/target-debuffs")
local playerTarget = require("GameData/Trackers/player-target")
local playerResources = require("GameData/Trackers/player-resources")
local wornEquipment = require("GameData/Trackers/worn-equipment")
local gameApi = require("GameData/game-api")

local dataSources = {}

--- A game value an aura can show. Every source reads a current and max
--- value, so any display type can show it as a fraction.
---@class DataSource
---@field id string Stable: named after game config, so saved auras keep working.
---@field type string A data type id (see Types).
---@field label string Shown in the picker; may say more than `name` to tell sources apart.
---@field name string? What auras show as $name, when it differs from `label`.
---@field colour integer Default fill (0xRRGGBBAA) when an aura picks this source.
---@field icon integer? Sprite id, for the Icon display.
---@field iconObject integer? An item whose icon is shown instead.
---@field read fun(): number?, number?, number?, number? Returns curr, max, the unrounded curr (smooth sources), and stacks or charges.
---@field smooth boolean? `read` rounds its current value, and gives the unrounded one third, for a bar's Smooth fill.
---@field timed boolean? Values are times in seconds (cooldowns, timed buffs, channels), which bar ticks and the radial swipe need.
---@field state "cooldown"|"active"|nil Whether running means on cooldown or active (buffs, debuffs, channels), for the Icon display's dimming and hiding; nil for values with no on/off.
---@field onOff boolean? Only on or off (a toggled buff: 1 of 1), so a swipe has nothing to show.
---@field hasStacks boolean? A buff that reports its stack count, for $stacks.
---@field hasAmmo boolean? Reports its ammo from `details`, for $ammo.
---@field hasTarget boolean? Reports its target's name from `details`, for $target.
---@field details fun(): string?, integer?, integer?, string?, string? | nil Name, sprite icon, item icon, $ammo and $target right now, instead of the fields (see Details).
---@field movedFrom string[]? Ids it used to have, so auras saved with them follow it.
---@field ability AbilityEntry? Its ability, so a greater icon swap can be picked up (ApplyGreaterIcons).

---@class DataType
---@field id string
---@field label string

---@type DataType[]
local TYPES = {
    { id = "resource", label = "Resource" },
    { id = "cooldown", label = "Ability cooldown" },
    { id = "specialAttack", label = "Special attack cooldown" },
    { id = "buff", label = "Buff" },
    { id = "debuff", label = "Debuff" },
    { id = "targetDebuff", label = "Target debuff" },
    { id = "channel", label = "Channel" },
    { id = "extraAction", label = "Extra action button" },
}

---@type DataSource[]
local SOURCES = {
    {
        id = "lifepoints",
        type = "resource",
        label = "Lifepoints",
        colour = 0xC0392BFF,
        read = function()
            return playerResources.GetLifepoints(), playerResources.GetMaxLifepoints()
        end,
    },
    {
        id = "adrenaline",
        type = "resource",
        label = "Adrenaline",
        colour = 0xE8B923FF,
        read = function()
            return playerResources.GetAdrenaline(), playerResources.GetMaxAdrenaline()
        end,
    },
    {
        id = "prayer",
        type = "resource",
        label = "Prayer points",
        colour = 0x3FA9D6FF,
        read = function()
            return playerResources.GetPrayerPoints(), playerResources.GetMaxPrayerPoints()
        end,
    },
    {
        id = "summoning",
        type = "resource",
        label = "Summoning points",
        colour = 0x2FB79AFF,
        read = function()
            return playerResources.GetSummoningPoints(), playerResources.GetMaxSummoningPoints()
        end,
    },
}

-- Ability cooldowns: current is the seconds left (0 when ready), max is the
-- full cooldown, so a bar drains as the ability comes back. The list comes
-- from game config (ability-catalogue), falling back to the hand-written
-- abilityCatalogue.FALLBACK if that can't be read yet (e.g. loading at the
-- login screen), until Refresh succeeds.
local COOLDOWN_COLOUR = 0x9B59B6FF
local COOLDOWN_VAR_PREFIX = abilityCatalogue.COOLDOWN_VAR_PREFIX
local COOLDOWN_ID_PREFIX = abilityCatalogue.SOURCE_ID_PREFIX

--- A cooldown source's id, named after its var so it stays stable.
---@param varBase string The cooldown var without _START/_END.
---@return string
local function cooldownID(varBase)
    return COOLDOWN_ID_PREFIX .. string.lower(varBase:sub(#COOLDOWN_VAR_PREFIX + 1))
end

---@type table<string, string> Old source id to current id, for auras saved before ids followed the var.
local RENAMED_IDS = {}
for _, ability in ipairs(abilityCatalogue.FALLBACK) do
    RENAMED_IDS[COOLDOWN_ID_PREFIX .. ability.legacyID] = cooldownID(ability.var)
end
---@type table<string, string> Every old id to its current one: RENAMED_IDS plus the sources' movedFrom (a buff's duplicates, a channel's old buff id). Rebuilt with the sources.
local MOVED_IDS = {}

-- SOURCES is the resources, then the ability cooldowns, the special attack
-- cooldowns, the buffs, the debuffs, the target debuffs, the channels and
-- the extra action buttons; all but the resources and target debuffs are
-- rebuilt from game config (rebuildSources).
local RESOURCES = { table.unpack(SOURCES) }
local cooldownSources = {}
local specialAttackSources = {}
local buffSources = {}
local debuffSources = {}
local targetDebuffSources = {}
local channelSources = {}
local extraActionSources = {}
---@type table<string, DataSource>
local SOURCES_BY_ID = {}
-- Whether the cooldowns came from the ability catalogue rather than FALLBACK.
local usingCatalogue = false

--- Rebuilds SOURCES, the id lookup and MOVED_IDS from the lists.
local function rebuildSources()
    for index = #SOURCES, 1, -1 do SOURCES[index] = nil end
    local lists = { RESOURCES, cooldownSources, specialAttackSources, buffSources, debuffSources,
        targetDebuffSources, channelSources, extraActionSources }
    for _, list in ipairs(lists) do
        for _, source in ipairs(list) do SOURCES[#SOURCES + 1] = source end
    end
    for key in pairs(SOURCES_BY_ID) do SOURCES_BY_ID[key] = nil end
    for _, source in ipairs(SOURCES) do
        SOURCES_BY_ID[source.id] = source
    end
    MOVED_IDS = {}
    for oldID, sourceID in pairs(RENAMED_IDS) do MOVED_IDS[oldID] = sourceID end
    for _, source in ipairs(SOURCES) do
        for _, oldID in ipairs(source.movedFrom or {}) do
            MOVED_IDS[oldID] = source.id
            -- Auras still saved with it read the source in its place.
            if SOURCES_BY_ID[oldID] == nil then SOURCES_BY_ID[oldID] = source end
        end
    end
end

--- A cooldown's values: the time to its next charge (see GetNextCharge),
--- and the charges ready as the fourth.
---@param varBase string
---@return number? remaining
---@return number? total
---@return number? unrounded
---@return integer? charges
local function readCooldown(varBase)
    local remaining, total, unrounded = abilityCooldowns.GetNextCharge(varBase)
    return remaining, total, unrounded, (abilityCooldowns.GetCharges(varBase))
end

--- The recast stage an ability is on, if any: the last whose flag is set.
---@param ability AbilityEntry
---@return AbilityStage? stage nil while it's the ability itself.
local function currentStage(ability)
    local stages = ability.stages
    if stages == nil then return nil end
    for index = #stages, 1, -1 do
        local stage = stages[index]
        if (abilityCooldowns.VarValue(stage.activeVar) or 0) ~= 0 then return stage end
    end
    return nil
end

--- A cooldown source's read: the ability's cooldown, or ready while it's on
--- a recast stage. A stage's own cooldown is only the global cooldown after
--- the stage before, so it isn't shown.
---@param ability AbilityEntry
---@return fun(): number?, number?, number?, integer?
local function cooldownReader(ability)
    local varBase = ability.var
    if ability.stages == nil then return function() return readCooldown(varBase) end end
    return function()
        if currentStage(ability) == nil then return readCooldown(varBase) end
        local _, total = abilityCooldowns.GetCooldown(varBase)
        -- One use ready: GetCharges would say 0, as the ability's cooldown runs.
        return 0, total, 0, 1
    end
end

--- A staged ability's details: its current stage's name and icon.
---@param ability AbilityEntry
---@return fun(): string?, integer?, integer?
local function stageDetails(ability)
    return function()
        local stage = currentStage(ability)
        if stage == nil then return ability.label, ability.icon, nil end
        return stage.label or ability.label, stage.icon or ability.icon, nil
    end
end

--- Builds a cooldown source per ability, from the catalogue or FALLBACK.
local function buildCooldownSources()
    local abilities = abilityCatalogue.List()
    usingCatalogue = #abilities > 0
    if not usingCatalogue then abilities = abilityCatalogue.FALLBACK end
    cooldownSources = {}
    for _, ability in ipairs(abilities) do
        local varBase = ability.var
        -- Every ability's last use helps show the others are ready before
        -- the cooldown clock is synced.
        abilityCooldowns.Watch(varBase)
        for _, stage in ipairs(ability.stages or {}) do
            abilityCooldowns.WatchFlag(stage.activeVar)
        end
        cooldownSources[#cooldownSources + 1] = {
            -- Abilities sharing a cooldown share a var, so the catalogue names
            -- each one; the hand-written fallback is named by its var.
            id = ability.id or cooldownID(varBase),
            type = "cooldown",
            label = ability.label,
            colour = COOLDOWN_COLOUR,
            icon = ability.icon,
            ability = ability,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = cooldownReader(ability),
            details = ability.stages and stageDetails(ability) or nil,
        }
    end
end

local SPECIAL_ATTACK_ID_PREFIX = "special_attack_"
local EQUIPPED_SPECIAL_NAME = "Equipped weapon"
dataSources.EQUIPPED_SPECIAL_ID = SPECIAL_ATTACK_ID_PREFIX .. "equipped"
---@type table<string, DataSource> A special's key (see SpecialAttackEntry.key) to its source.
local specialsByKey = {}
-- The main hand item equippedSpecial was found for (false: not found yet).
local equippedWeapon = false
---@type DataSource?
local equippedSpecial = nil
---@type string? The last special source found worn this session, for auras that remember it (see EquippedSpecialID).
local lastSpecialID = nil

--- The special source for a worn weapon (see specialAttackCatalogue.Find).
---@param itemID integer?
---@return DataSource?
local function specialFor(itemID)
    if itemID == nil then return nil end
    local key = specialAttackCatalogue.Find(itemID)
    return key and specialsByKey[key]
end

--- The special of the main hand weapon, where every special with a cooldown
--- is. Found again only when the weapon changes.
---@return DataSource?
local function findEquippedSpecial()
    local mainHand = wornEquipment.Item(wornEquipment.SLOTS.MAIN_HAND)
    if mainHand ~= equippedWeapon then
        equippedWeapon = mainHand
        equippedSpecial = specialFor(mainHand)
        if equippedSpecial ~= nil then lastSpecialID = equippedSpecial.id end
    end
    return equippedSpecial
end

--- The special source "Equipped weapon" stands for now: the worn weapon's,
--- else, when remembering, the last one worn this session.
---@param remember boolean
---@return string? sourceID nil if there's none.
function dataSources.EquippedSpecialID(remember)
    local special = findEquippedSpecial()
    if special ~= nil then return special.id end
    if remember and lastSpecialID ~= nil and SOURCES_BY_ID[lastSpecialID] ~= nil then return lastSpecialID end
    return nil
end

--- "Equipped weapon"'s values: its special's cooldown, else 0 of 0.
---@return number? remaining
---@return number? total
---@return number? unrounded
---@return integer? charges
local function readEquippedSpecial()
    local special = findEquippedSpecial()
    if special == nil then return 0, 0 end
    return special.read()
end

--- "Equipped weapon"'s details: its special's name and icon.
---@return string name
---@return integer? spriteID
---@return integer? objectID
local function equippedSpecialDetails()
    local special = findEquippedSpecial()
    if special == nil then return EQUIPPED_SPECIAL_NAME, nil, nil end
    return special.name or special.label, special.icon, special.iconObject
end

--- Builds "Equipped weapon", then a source per special attack with a
--- cooldown, found with the buffs (see specialAttackCatalogue.List).
local function buildSpecialAttackSources()
    specialAttackSources = {
        {
            id = dataSources.EQUIPPED_SPECIAL_ID,
            type = "specialAttack",
            label = EQUIPPED_SPECIAL_NAME,
            colour = COOLDOWN_COLOUR,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = readEquippedSpecial,
            details = equippedSpecialDetails,
        },
    }
    specialsByKey = {}
    equippedWeapon = false
    for _, special in ipairs(specialAttackCatalogue.List(buffCatalogue.List())) do
        local varBase = special.var
        abilityCooldowns.Watch(varBase, special.endClientVar)
        local source = {
            id = SPECIAL_ATTACK_ID_PREFIX .. string.lower(special.key),
            type = "specialAttack",
            -- Named after the weapon, which is what players search for;
            -- $name is the special's.
            label = special.weapon or special.name,
            name = special.name,
            colour = COOLDOWN_COLOUR,
            icon = special.icon,
            iconObject = special.icon == nil and special.object or nil,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = function() return readCooldown(varBase) end,
        }
        specialAttackSources[#specialAttackSources + 1] = source
        specialsByKey[special.key] = source
    end
end

-- Buffs and debuffs: current is the seconds left (or the stacks; 0 while
-- inactive) over the full duration, read from their own vars (active-buffs).
-- Only those with an icon and known vars are listed (see buff-catalogue).
-- Special attacks' cooldown debuffs are listed as special attacks instead.
local BUFF_COLOUR = 0x27AE60FF
local DEBUFF_COLOUR = 0xE74C3CFF

--- The ability a buff belongs to, when that ability has a greater version:
--- the buff's own struct is the ability's struct (COMBATV2_ABILITY_MAGIC_SUNSHINE),
--- or for a greater buff, its base buff's struct. The buff then shows the ability's
--- icon, which follows the greater unlock, so Sunshine and Greater Sunshine
--- both show the version the player has.
---@param entry BuffEntry
---@param cooldownsByID table<string, DataSource>
---@return AbilityEntry? ability nil if it has no greater version.
local function greaterAbility(entry, cooldownsByID)
    local structName = entry.baseStruct or entry.structName
    local abilityName = structName:gsub("^COMBATV2_ABILITY_", "")
    local cooldown = cooldownsByID[COOLDOWN_ID_PREFIX .. abilityName:lower()]
    local ability = cooldown and cooldown.ability
    if ability == nil or ability.greater == nil then return nil end
    return ability
end

-- The end of an ammo item's name that $ammo leaves off ("Ful arrows" is "Ful").
local AMMO_NAME_ENDINGS = { "%s+[Aa]rrows?$", "%s+[Bb]olts?$" }
---@type table<integer, string> Item id to its $ammo name, as names don't change.
local ammoNames = {}

--- An ammo item's name without "arrows" or "bolts", for $ammo.
---@param itemID integer?
---@return string?
local function ammoName(itemID)
    if itemID == nil then return nil end
    local cached = ammoNames[itemID]
    if cached ~= nil then return cached end
    local name = gameApi.ItemName(itemID)
    if name == nil then return nil end
    for _, ending in ipairs(AMMO_NAME_ENDINGS) do name = name:gsub(ending, "") end
    ammoNames[itemID] = name
    return name
end

--- Builds a buff or debuff source per listed catalogue entry (see
--- buffCatalogue.IsListed).
local function buildBuffSources()
    buffSources, debuffSources = {}, {}
    local cooldownsByID = {}
    for _, source in ipairs(cooldownSources) do cooldownsByID[source.id] = source end
    for _, entry in ipairs(buffCatalogue.List()) do
        if buffCatalogue.IsListed(entry) then
            local isBuff = entry.kind == "buff"
            local list = isBuff and buffSources or debuffSources
            local ability = greaterAbility(entry, cooldownsByID)
            -- Timed (so it can move every frame) unless all it has is stacks
            -- or an on/off var.
            local timed = entry.endVar ~= nil or entry.startVar ~= nil
            list[#list + 1] = {
                -- A debuff's id is "buff_<struct name>" too, as the catalogue names it.
                id = entry.id,
                type = entry.kind,
                -- The picker's label has the struct's name added when two
                -- clash, which only shows once every buff is loaded; what an
                -- aura shows ($name) is the buff's own name, which doesn't.
                label = entry.label,
                name = entry.name,
                colour = isBuff and BUFF_COLOUR or DEBUFF_COLOUR,
                icon = ability and ability.icon or entry.icon,
                iconObject = entry.icon == nil and entry.object or nil,
                ability = ability,
                smooth = timed,
                timed = timed,
                onOff = not timed and entry.stacksVar == nil,
                hasStacks = entry.stacksVar ~= nil,
                hasAmmo = entry.objectVar ~= nil,
                state = "active",
                -- Its duplicates' ids (see dropDuplicates in buff-catalogue).
                movedFrom = entry.duplicateIDs,
                read = function() return activeBuffs.Read(entry) end,
                -- The quiver's icon is its ammo (see BuffEntry.objectVar), and
                -- $ammo its name.
                details = entry.objectVar ~= nil and function()
                    local item = activeBuffs.Object(entry)
                    return entry.name, nil, item or entry.object, ammoName(item)
                end or nil,
            }
        end
    end
end

-- Target debuffs (target-debuffs tracker): current is the seconds left of a
-- DoT the player put on their target, max its length, and $target the
-- target's name.
local TARGET_DEBUFF_ID_PREFIX = "target_debuff_"

--- Builds a source per DoT in the target debuff catalogue.
local function buildTargetDebuffSources()
    for _, entry in ipairs(targetDebuffCatalogue.ENTRIES) do
        targetDebuffSources[#targetDebuffSources + 1] = {
            id = TARGET_DEBUFF_ID_PREFIX .. entry.key,
            type = "targetDebuff",
            label = entry.name,
            colour = DEBUFF_COLOUR,
            icon = entry.icon,
            smooth = true,
            timed = true,
            state = "active",
            read = function() return targetDebuffs.Read(entry) end,
            hasTarget = true,
            -- $target: the name of the target it shows the run of.
            details = function()
                local ammo = nil
                return entry.name, entry.icon, nil, ammo, playerTarget.Name()
            end,
        }
    end
end

-- Channels (channel tracker): current is the seconds left of the channel
-- (so far, for a cast like Snipe), max its length, so a bar is a channel or
-- cast bar. "Any channel" shows whatever is being channelled; the others
-- one channelled ability each (any version of it, e.g. Greater Flurry for
-- Flurry), from the ability catalogue.
local CHANNEL_COLOUR = 0x5DADE2FF
local ANY_CHANNEL_NAME = "Any channel"
---@type table<string, AbilityEntry> Ability key to its ability, so "Any channel" can name and show it.
local channelAbilities = {}

--- "Any channel"'s details: the name and icon of whatever is (or was last)
--- being channelled.
---@return string name
---@return integer? spriteID
---@return nil objectID
local function anyChannelDetails()
    local key = channel.Key()
    local ability = key ~= nil and channelAbilities[key] or nil
    if ability == nil then return ANY_CHANNEL_NAME, nil, nil end
    return ability.label, ability.icon, nil
end

--- A read for one ability's channel: the channel while this ability is channelled,
--- else 0 of its own last length.
---@param key string The ability's key (see abilityCatalogue.Key).
---@return fun(): number, number, number?
local function abilityChannelReader(key)
    local lastMax = 0
    return function()
        local curr, max, remaining = channel.Read()
        if channel.Key() ~= key then return 0, lastMax end
        lastMax = max
        return curr, max, remaining
    end
end

--- Builds "Any channel", plus a source per channelled ability once the
--- catalogue can be read.
local function buildChannelSources()
    channelSources = {
        {
            id = "channel_any",
            type = "channel",
            label = ANY_CHANNEL_NAME,
            colour = CHANNEL_COLOUR,
            smooth = true,
            timed = true,
            state = "active",
            read = channel.Read,
            details = anyChannelDetails,
        },
    }
    channelAbilities = {}
    if not usingCatalogue then return end
    for _, ability in ipairs(abilityCatalogue.List()) do
        if ability.channelled and ability.key ~= nil then
            channelAbilities[ability.key] = ability
            local abilityName = ability.id:gsub("^" .. COOLDOWN_ID_PREFIX, "")
            channelSources[#channelSources + 1] = {
                id = "channel_" .. abilityName,
                type = "channel",
                label = ability.label,
                colour = CHANNEL_COLOUR,
                icon = ability.icon,
                ability = ability,
                smooth = true,
                timed = true,
                state = "active",
                -- Channelled abilities were once listed as buffs.
                movedFrom = { buffCatalogue.SourceID(abilityCatalogue.STRUCT_PREFIX .. abilityName) },
                read = abilityChannelReader(ability.key),
            }
        end
    end
end

-- The generic extra action source's label in the picker, under the Extra action button type.
local ANY_EXTRA_ACTION_LABEL = "Any"
-- The generic extra action source's name before any button has shown.
local EXTRA_ACTION_NAME = "Extra action button"
-- The start of every extra action source's id.
local EXTRA_ACTION_ID_PREFIX = "extra_action_"

--- The "Any" extra action source's details: the name and icon of the button
--- showing, or the last one shown.
---@return string name
---@return integer? spriteID
---@return nil objectID
local function extraActionDetails()
    local button = extraAction.Button()
    if button == nil then return EXTRA_ACTION_NAME, nil, nil end
    return button.name, button.icon, nil
end

--- A read for one button: the cooldown while it's the button showing (or
--- the last one shown), else ready, out of its own cooldown.
---@param button ExtraActionButton
---@return fun(): number?, number?, number?
local function extraActionReader(button)
    return function()
        if extraAction.ButtonID() ~= button.id then return 0, extraAction.CooldownSeconds(button), 0 end
        return extraAction.Read()
    end
end

--- Builds the extra action button sources (extra-action tracker): current is
--- the seconds left of the cooldown, max the full cooldown. "Any" is
--- whichever button is showing, then one source per button from
--- the catalogue, once it has loaded. Every button shares one cooldown.
local function buildExtraActionSources()
    extraActionSources = {
        {
            id = EXTRA_ACTION_ID_PREFIX .. "button",
            type = "extraAction",
            label = ANY_EXTRA_ACTION_LABEL,
            name = EXTRA_ACTION_NAME,
            colour = COOLDOWN_COLOUR,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = extraAction.Read,
            details = extraActionDetails,
        },
    }
    for _, button in ipairs(extraActionCatalogue.List()) do
        extraActionSources[#extraActionSources + 1] = {
            id = EXTRA_ACTION_ID_PREFIX .. button.key:lower(),
            type = "extraAction",
            label = button.label,
            name = button.name,
            colour = COOLDOWN_COLOUR,
            icon = button.icon,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = extraActionReader(button),
        }
    end
end

-- Buffs and extra action buttons come in later: their catalogues load in
-- the background once in game (see Auras/source-sync), then RefreshBuffs
-- and RefreshExtraActions list them.
buildCooldownSources()
buildSpecialAttackSources()
buildBuffSources()
buildTargetDebuffSources()
buildChannelSources()
buildExtraActionSources()
rebuildSources()

--- Tries the ability catalogue again if it couldn't be read before, e.g. on
--- entering the game, rebuilding everything built from it.
---@return boolean changed Whether the sources changed, so displays showing them (names, icons) need refreshing.
function dataSources.Refresh()
    if usingCatalogue then return false end
    buildCooldownSources()
    if not usingCatalogue then return false end
    -- Buffs link to the cooldowns' abilities, and channels come from the
    -- ability catalogue too.
    buildBuffSources()
    buildChannelSources()
    rebuildSources()
    return true
end

--- Rebuilds the buff and debuff sources, and the special attacks found with
--- them, after the buff catalogue changed (its background scan found different
--- buffs).
function dataSources.RefreshBuffs()
    buildSpecialAttackSources()
    buildBuffSources()
    rebuildSources()
end

--- Rebuilds the extra action button sources, once their catalogue has loaded.
function dataSources.RefreshExtraActions()
    buildExtraActionSources()
    rebuildSources()
end

--- Copies each source's ability icon onto it, after greater unlocks changed.
local function syncAbilityIcons()
    for _, source in ipairs(SOURCES) do
        if source.ability ~= nil then source.icon = source.ability.icon end
    end
end

--- Switches unlocked greater abilities to their greater icons (see
--- ability-catalogue).
---@return boolean changed Whether any icon changed, so displays showing them need refreshing.
---@return boolean complete false while some unlock flags haven't arrived.
function dataSources.ApplyGreaterIcons()
    if not usingCatalogue then return false, false end
    local changed, complete = abilityCatalogue.ApplyGreaterUnlocks()
    if changed then syncAbilityIcons() end
    return changed, complete
end

--- Follows a var update that may be a greater unlock flag.
---@param name string The var's name.
---@param value any
---@return boolean changed Whether any icon changed.
function dataSources.OnVarChanged(name, value)
    if not usingCatalogue or not abilityCatalogue.OnVarChanged(name, value) then return false end
    syncAbilityIcons()
    return true
end

--- Lets the next login check greater unlocks again.
function dataSources.ResetGreaterIcons()
    abilityCatalogue.Reset()
end

--- Every data type, in the picker's order.
---@return DataType[]
function dataSources.Types()
    return TYPES
end

--- The sources of one data type, in registry order.
---@param typeID string
---@return DataSource[]
function dataSources.ListByType(typeID)
    local list = {}
    for _, source in ipairs(SOURCES) do
        if source.type == typeID then list[#list + 1] = source end
    end
    return list
end

--- Every source.
---@return DataSource[]
function dataSources.List()
    return SOURCES
end

--- The current id for a saved source id, which may predate a rename.
---@param sourceID string
---@return string
function dataSources.CurrentID(sourceID)
    return MOVED_IDS[sourceID] or sourceID
end

--- A source by id (or an old id it moved from).
---@param sourceID string?
---@return DataSource? source nil if unknown.
function dataSources.Get(sourceID)
    return SOURCES_BY_ID[sourceID]
end

--- A source's name, sprite icon and item icon as they are now: its own,
--- except "Any channel", which takes whatever is being channelled,
--- "Equipped weapon", which takes the worn weapon's special, an ability
--- with recast stages, which takes its current stage, the quiver, which
--- shows its ammo, and the "Any" extra action button, which takes the button's.
---@param sourceID string?
---@return string? name nil if the source is unknown.
---@return integer? spriteID
---@return integer? objectID
---@return string? ammo The quiver's ammo, for $ammo; nil for every other source.
---@return string? target A target debuff's target's name, for $target; nil for every other source.
function dataSources.Details(sourceID)
    local source = SOURCES_BY_ID[sourceID]
    if source == nil then return nil end
    if source.details ~= nil then return source.details() end
    return source.name or source.label, source.icon, source.iconObject
end

-- Text fields every source fills.
local COMMON_TEXT_FIELDS = { value = true, max = true, name = true }

--- Whether a source fills a text field: every source has $value, $max
--- and $name; $charges is an ability's, $stacks a stacking buff's and
--- $ammo the quiver's, and $target a target debuff's.
---@param sourceID string?
---@param field TextFieldID
---@return boolean
function dataSources.FillsTextField(sourceID, field)
    if COMMON_TEXT_FIELDS[field] then return true end
    local source = SOURCES_BY_ID[sourceID]
    if source == nil then return false end
    if field == "charges" then return source.type == "cooldown" end
    if field == "stacks" then return source.hasStacks == true end
    if field == "ammo" then return source.hasAmmo == true end
    return field == "target" and source.hasTarget == true
end

--- A source's values now (see DataSource.read).
---@param sourceID string?
---@return number? curr nil when the source is unknown or no player is logged in.
---@return number? max
---@return number? unroundedCurr
---@return number? stacks
function dataSources.Read(sourceID)
    if not gameApi.PlayerAvailable() then return nil end
    return dataSources.ReadAvailable(sourceID)
end

--- Read, for a caller that has already checked the player is available (the
--- aura manager checks once a frame rather than once per source).
---@param sourceID string?
---@return number? curr nil when the source is unknown.
---@return number? max
---@return number? unroundedCurr
---@return number? stacks
function dataSources.ReadAvailable(sourceID)
    local source = SOURCES_BY_ID[sourceID]
    if source == nil then return nil end
    return source.read()
end

return dataSources
