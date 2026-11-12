-- Finding a buff's vars: nothing in config links a buff struct to the vars
-- it's read from, so they're found by name, with these rules and alias
-- tables. Reading the vars is active-buffs' job.

local gameApi = require("GameData/game-api")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local wornEquipment = require("GameData/Trackers/worn-equipment")

local buffVars = {}

local STACKS_SUFFIX = "_STACKS"

local CORE_PREFIXES = { "COMBATV2_", "ABILITY_", "BUFF_", "DEBUFF_" }
local CORE_SUFFIXES = { "_DUMMY_ABILITY", "_DUMMY_EFFECT", "_DUMMY", "_ABILITY", "_COOLDOWN", "_EFFECT", "_STRUCT" }

--- A struct name without its prefixes and suffixes: the part its vars share.
--- "INVENT_PERK_RELENTLESS_COOLDOWN_DUMMY_ABILITY" gives "INVENT_PERK_RELENTLESS".
---@param name string
---@return string core
local function nameCore(name)
    local changed = true
    while changed do
        changed = false
        for _, prefix in ipairs(CORE_PREFIXES) do
            if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1); changed = true end
        end
        for _, suffix in ipairs(CORE_SUFFIXES) do
            if #name > #suffix and name:sub(-#suffix) == suffix then name = name:sub(1, -#suffix - 1); changed = true end
        end
    end
    return name
end

-- Struct name to its end-time VarClient, where the names don't follow the
-- rules (see endVarName).
local END_VAR_ALIASES = {
    -- Named after the Zamorak fight, whose ranged weapons have it.
    COMBATV2_ABILITY_WEAPON_BALANCE_BY_FORCE = "COMBATV2_EGWD_ZAMORAK_BOSS_RANGED_WEAPON_SPECIAL_BUFF_END_CLIENT",
    -- "Renew" in the struct, "Renewal" in the var.
    COMBATV2_PRAYER_RENEW_DUMMY_ABILITY = "COMBATV2_COOLDOWN_PRAYER_RENEWAL_END_EFFECT_CLIENT",
    -- "Resurgence" in the struct (the ability is Rejuvenate), misspelt in the var.
    COMBATV2_ABILITY_DEFENCE_RESURGENCE = "COMBATV2_COOLDOWN_DEFENCE_REJUVINATE_END_EFFECT_CLIENT",
    COMBATV2_ANTI_DRAGONFIRE_DUMMY_ABILITY = "COMBATV2_COOLDOWN_DRAGONFIRE_END_EFFECT_CLIENT",
    COMBATV2_SUPER_ANTI_DRAGONFIRE_DUMMY_ABILITY = "COMBATV2_COOLDOWN_SUPER_DRAGONFIRE_END_EFFECT_CLIENT",
    COMBATV2_HARVEST_POTION_TIMER = "HERB120_HARVEST_POTION_END_EFFECT_CLIENT",
    COMBATV2_CHARMING_POTION_DUMMY_ABILITY = "HERB120_CHARMING_POTION_END_EFFECT_CLIENT",
    COMBATV2_ARCH_KHARIDET_PYLON_EFFECT_DUMMY_ABILITY = "COMBATV2_ARCH_KHARIDET_PYLON_EFFECT_END_CLIENT",
    -- The general stun (a jellyfish's at 10 Electrified stacks is 9 seconds).
    -- TODO: check other stuns set it too.
    COMBATV2_STUNNED_DUMMY_ABILITY = "COMBATV2_COOLDOWN_STUN_END_EFFECT_CLIENT",
    -- A VarClient without the usual suffix; its struct is named like an on/off var.
    -- TODO: check it holds the Logic tick the cooldown ends.
    COMBATV2_EXCALIBUR_ACTIVE = "COMBATV2_COOLDOWN_EXCALIBUR",
    MAGIC_SEREN_CRYSTAL_MASK = "COMBATV2_COOLDOWN_SEREN_CRYSTAL_MASK_END_EFFECT_CLIENT",
    COMBATV2_MTX_XP_BOMB_DUMMY_DXP_ABILITY = "COMBATV2_MTX_XP_BOMB_END_EFFECT_CLIENT",
    COMBATV2_ELR1_SPIRIT_DRAGON_CHARM_DUMMY_ABILITY = "COMBATV2_COOLDOWN_ELR1_SPIRIT_CHARM_END_EFFECT_CLIENT",
    -- The stronger tiers share the base potion's var.
    COMBATV2_SUPREME_OVERLOAD_DUMMY_ABILITY = "COMBATV2_COOLDOWN_OVERLOAD_END_EFFECT_CLIENT",
    COMBATV2_ELDER_OVERLOAD_DUMMY_ABILITY = "COMBATV2_COOLDOWN_OVERLOAD_END_EFFECT_CLIENT",
    COMBATV2_SUPER_PRAYERRENEW_DUMMY_ABILITY = "COMBATV2_COOLDOWN_PRAYER_RENEWAL_END_EFFECT_CLIENT",
    -- A spell, so its vars are under MAGIC_ rather than BUFF_.
    COMBATV2_BUFF_ANIMATE_DEAD = "COMBATV2_MAGIC_ANIMATE_DEAD_END_EFFECT_CLIENT",
    -- Same words as their var, in another order or wording, found offline
    -- by matching name words (Berserk's struct says STRENGTH, its var MELEE).
    COMBATV2_ABILITY_STRENGTH_BERSERK = "COMBATV2_BUFF_MELEE_BERSERK_END_CLIENT",
    COMBATV2_DINARROW_WEN_CHILL_DUMMY_ABILITY = "COMBATV2_DINARROW_WEN_BUFF_CHILL_END_CLIENT",
    COMBATV2_DINARROW_WEN_PRECISION_DUMMY_ABILITY = "COMBATV2_DINARROW_WEN_BUFF_PRECISION_END_CLIENT",
    COMBATV2_LUNAR_TUNE_BANE_ORE = "COMBATV2_LUNAR_TUNE_BANE_ORE_BUFF_END_CLIENT",
    COMBATV2_ARCH_ORTHEN_REX_EFFECT_DUMMY_ABILITY = "COMBATV2_ARCH_ORTHEN_REX_EFFECT_END_CLIENT",
    COMBATV2_EGWD_BIK_GOD_BOOK_EFFECT_BUFF = "COMBATV2_EGWD_BIK_GOD_BOOK_EFFECT_END_CLIENT",
    COMBATV2_BUFF_DRAGON_BATTLEAXE = "COMBATV2_BUFF_DRAGON_BATTLEAXE_EFFECT_END_CLIENT",
    COMBATV2_BUFF_DRAGON_SCIMITAR = "COMBATV2_BUFF_DRAGON_SCIMITAR_EFFECT_END_CLIENT",
    -- Also matched by the words in their names, more loosely: reordered
    -- (QUEST_DM_ARCH, ARCH_QUEST_DM), reworded (SPELL, MAGIC; RENEW, RENEWAL;
    -- an extra action ability's button), or ANTI dropped as for antifire.
    -- TODO: check these in game.
    COMBATV2_QUEST_DM_ARCH_FOCUS_BUFF = "COMBATV2_ARCH_QUEST_DM_FOCUS_BUFF_END_CLIENT",
    LUNAR_SPELL_IMBUE_BUFF = "COMBATV2_LUNAR_MAGIC_IMBUE_BUFF_END_CLIENT",
    COMBATV2_BUFF_EXTRA_ACTION_ABILITY_ZILYANA = "COMBATV2_EGWD_EXTRA_ACTION_BUTTON_ZILYANA_EFFECT_END_CLIENT",
    COMBATV2_BUFF_EXTRA_ACTION_ABILITY_KREEARRA = "COMBATV2_EGWD_EXTRA_ACTION_BUTTON_KREEARRA_EFFECT_END_CLIENT",
    DESERT_QUEST_FINALE_REWARDS_APMEKEN_BOON_GIFT = "QUEST_DESERT_FINALE_REWARDS_APMEKEN_BOON_END_CLIENT",
    COMBATV2_LORE_RENEW_DUMMY_ABILITY = "COMBATV2_COOLDOWN_LORE_RENEWAL_END_EFFECT_CLIENT",
    COMBATV2_ANTI_POISON_DUMMY_ABILITY = "COMBATV2_COOLDOWN_POISON_END_EFFECT_CLIENT",
    ARTISANS_REWARD_LUMINITE_INJECTOR_BUFF = "ARTISAN_LUMINITE_INJECTOR_END_TIME_BUFF",
    COMBATV2_RAID_REBIRTH1_AMASCUT_GOD_BOOK_EFFECT = "COMBATV2_BUFF_RAID_REBIRTH1_AMASCUT_BOOK_END_CLIENT",
    COMBATV2_EGWD_ZAMORAK_BOSS_REWARD_HAVOC_ADREN_BOOST_STRUCT = "COMBATV2_EGWD_ZAMORAK_REWARD_HAVOC_SET_BUFF_END_CLIENT",
    COMBATV2_DINARROW_BIK_DUMMY_ABILITY = "COMBATV2_DINARROW_BIK_DEBUFF_END_CLIENT",
    -- Named with _CLIENT and no END.
    -- TODO: check these in game.
    COMBATV2_CRUC_DM_APPLY_THERMAL_HEALTH_BOOST = "COMBATV2_CRUC_DM_APPLY_THERMAL_HEALTH_BOOST_CLIENT",
    COMBATV2_ANNIVERSARY_CAKE_DUMMY_ABILITY = "COMBATV2_COOLDOWN_ANNIVERSARY_CAKE_CLIENT",
    -- Named after what the reward does, and _COOLDOWN like Devoted's end (see
    -- endVarName): Kuradal's Favour respawns slayer creatures at once.
    -- TODO: check these in game; they may be the rewards' cooldowns instead.
    SWORLDS_REWARD_FEROCIOUS_DUMMY_ABILITY = "SWORLDS_REWARD_KURADEL_INSTA_RESPAWN_COOLDOWN",
    SWORLDS_REWARD_SLAYING_DUMMY_ABILITY = "SWORLDS_REWARD_SLAYER_XP_MULTIPLIER_COOLDOWN",
    -- Named like Devoted's end (see endVarName) without the struct's _ACTIVE.
    COMBATV2_STUN_IMMUNE_ACTIVE = "COMBATV2_STUN_IMMUNE_COOLDOWN",
    -- Both Sonic Waves set Greater Sonic Wave's end time; each Flow's
    -- requirement (ACTIVE_WHILE) says which one it was.
    COMBATV2_BUFF_MAGIC_FLOW_STACKS = "COMBATV2_MAGIC_GREATER_SONIC_WAVE_END_EFFECT_CLIENT",
    COMBATV2_BUFF_MAGIC_GREATER_FLOW_STACKS = "COMBATV2_MAGIC_GREATER_SONIC_WAVE_END_EFFECT_CLIENT",
}

-- Buffs whose end-time VarClient by name is never set: they're timed from
-- their ability's use if they can be (see startVarName), else read from
-- their stacks or toggle.
local UNSET_END_VARS = {
    -- Transfigure's bind.
    COMBATV2_ABILITY_CONSTITUTION_TRANSFIGURE = true,
    -- Frostblades' stacks, until Icy Tempest spends them.
    COMBATV2_BUFF_PRIMORDIAL_ICE = true,
}

-- Debuffs that build up stacks with no timer, then at the most stacks lose
-- them and run a timer instead.
local STACKS_WHILE_UNTIMED = {
    -- Electrified (Deep Sea Fishing): at 10 stacks the player is stunned
    -- and its timer runs 150 seconds.
    COMBATV2_DSF_JELLYFISH_STUN_DUMMY_ABILITY = true,
}

-- A Lua pattern on the struct name and its replacement, for whole families.
local END_VAR_PATTERNS = {
    -- Incense sticks: COMBATV2_INCENSE_<HERB>_DUMMY.
    { pattern = "^COMBATV2_INCENSE_(.+)_DUMMY$", replacement = "COMBATV2_INCENSE_BURNER_%1_END_CLIENT" },
}

--- A var name for a struct from the first of a family's patterns that
--- matches it and gives a var `isUsable` accepts.
---@param patterns { pattern: string, replacement: string }[]
---@param structName string
---@param isUsable fun(name: string): boolean
---@return string? varName nil if none does.
local function patternVarName(patterns, structName, isUsable)
    for _, rule in ipairs(patterns) do
        local varName, matched = structName:gsub(rule.pattern, rule.replacement)
        if matched > 0 and isUsable(varName) then return varName end
    end
    return nil
end

--- Whether a VarClient can be a buff's end time: it exists and holds an
--- integer (a Logic tick). Names found by a rule could match a var of
--- another type, which can't be read every tick (see gameApi.IsIntegerVar).
---@param name string
---@return boolean
local function isEndTimeVar(name)
    local varConfig = gameApi.VarClient(name)
    return varConfig ~= nil and gameApi.IsIntegerVar(varConfig)
end

-- Buffs whose <struct>_COOLDOWN VarClient is a cooldown that follows them,
-- not their end time: Vengeance lasts until the next hit, and its cooldown
-- is the Vengeance cooldown debuff's.
local COOLDOWN_NOT_END = {
    COMBATV2_VENGEANCE = true,
}

--- A buff's end-time VarClient: END_VAR_ALIASES and END_VAR_PATTERNS first,
--- then _END_EFFECT_CLIENT or _END_CLIENT under the struct's own name or its
--- core with a COMBATV2_BUFF_, COMBATV2_DEBUFF_, COMBATV2_ or no prefix, then
--- an ability's effect, COMBATV2_COOLDOWN_<core>_END_EFFECT_CLIENT, then a
--- special attack's effect, <core>_EFFECT_CLIENT with no END. Last come names
--- with no END at all: the struct's own, or <struct>_COOLDOWN and the like,
--- which despite the word hold the end of many perks and boosts (Devoted's
--- is COMBATV2_DEVOTED_PERK_COOLDOWN), except COOLDOWN_NOT_END's.
--- (COMBATV2_COOLDOWN_<core>_END_CLIENT is the ability's cooldown, so it's
--- never used.)
---@param structName string
---@param core string Its nameCore.
---@return string? varName nil if there's none, or it's in UNSET_END_VARS.
local function endVarName(structName, core)
    if UNSET_END_VARS[structName] then return nil end
    local alias = END_VAR_ALIASES[structName]
    if alias ~= nil and isEndTimeVar(alias) then return alias end
    local fromPattern = patternVarName(END_VAR_PATTERNS, structName, isEndTimeVar)
    if fromPattern ~= nil then return fromPattern end
    local candidates = { structName .. "_END_EFFECT_CLIENT", structName .. "_END_CLIENT" }
    for _, prefix in ipairs({ "COMBATV2_BUFF_", "COMBATV2_DEBUFF_", "COMBATV2_", "" }) do
        candidates[#candidates + 1] = prefix .. core .. "_END_EFFECT_CLIENT"
        candidates[#candidates + 1] = prefix .. core .. "_END_CLIENT"
    end
    candidates[#candidates + 1] = abilityCatalogue.COOLDOWN_VAR_PREFIX .. core .. "_END_EFFECT_CLIENT"
    -- Special attacks' effects (Instability, Split Soul, Gravitate) leave out the END.
    candidates[#candidates + 1] = abilityCatalogue.COOLDOWN_VAR_PREFIX .. core .. "_EFFECT_CLIENT"
    candidates[#candidates + 1] = "COMBATV2_" .. core .. "_EFFECT_CLIENT"
    if not COOLDOWN_NOT_END[structName] then
        candidates[#candidates + 1] = structName
        candidates[#candidates + 1] = structName .. "_COOLDOWN"
        candidates[#candidates + 1] = "COMBATV2_" .. core .. "_COOLDOWN"
        candidates[#candidates + 1] = abilityCatalogue.COOLDOWN_VAR_PREFIX .. core
    end
    for _, candidate in ipairs(candidates) do
        if isEndTimeVar(candidate) then return candidate end
    end
    return nil
end

--- Something that must hold for a buff to count as active: a VarPlayer
--- being non-zero, or a worn slot holding a certain item.
---@class BuffRequirement
---@field var string? The VarPlayer; nil for an item requirement.
---@field slot integer? For an item requirement, the worn slot (wornEquipment.SLOTS).
---@field item string? For an item requirement, a Lua pattern the item's config name must match.

local SLOTS = wornEquipment.SLOTS

-- Buffs whose own vars carry on after the game has dropped them, to what
-- must also hold for them to count as active: any one of their requirements.
-- Greater versions use their base's (see buff-list's shareAbilityVars).
---@type table<string, BuffRequirement[]>
local ACTIVE_WHILE = {
    -- Sunshine's end time belongs to its area, so it carries on after the
    -- player leaves; this varbit is 1 while they're in it. (Death's
    -- Swiftness has a TSD_ varbit too, but it's no longer a ground effect.)
    COMBATV2_ABILITY_MAGIC_SUNSHINE = { { var = "TSD_SUNSHINE_DAMAGE" } },
    -- Both Sonic Waves set one end time (see END_VAR_ALIASES).
    COMBATV2_BUFF_MAGIC_FLOW_STACKS = { { var = "COMBATV2_BUFF_MAGIC_FLOW_ACTIVE" } },
    COMBATV2_BUFF_MAGIC_GREATER_FLOW_STACKS = { { var = "COMBATV2_BUFF_MAGIC_GREATER_FLOW_ACTIVE" } },
    COMBATV2_ABILITY_MAGIC_GREATER_SONIC_WAVE = { { var = "COMBATV2_BUFF_MAGIC_GREATER_FLOW_ACTIVE" } },
    -- The scripture is switched on; taking it off switches it off.
    COMBATV2_GOD_BOOK_TIMER_DUMMY_ABILITY = { { var = "GOD_BOOK_ACTIVE" } },
    -- A scrimshaw only runs while it's worn (POP_VAMPIRISM_UNTRADEABLE and the like).
    COMBATV2_SCRIMSHAW_TIMER_DUMMY_ABILITY = { { slot = SLOTS.POCKET, item = "^POP_" } },
    -- The porter's flag stays set after its sign is taken off, so a sign
    -- (DIV_SIGN_PORTER7_ACTIVE) or Grace of the Elves must be worn.
    DIVINATION_PORTER_ACTIVE = {
        { slot = SLOTS.POCKET, item = "DIV_SIGN_PORTER%d" },
        { slot = SLOTS.NECK, item = "^ALCH_ONYX_SKILL_NECKLACE" },
    },
    -- Each potion tier's own time left (in 15 second steps): a stronger
    -- tier clears a weaker one's, but not its end time.
    COMBATV2_ANTI_DRAGONFIRE_DUMMY_ABILITY = { { var = "DRAGONRESIST_ORIGINAL" } },
    COMBATV2_SUPER_ANTI_DRAGONFIRE_DUMMY_ABILITY = { { var = "DRAGONRESIST_ALL" } },
    -- The two tiers share an end time; each has its own flag, and drinking
    -- one clears the other's.
    COMBATV2_PRAYER_RENEW_DUMMY_ABILITY = { { var = "COMBATV2_TARGET_SIDE_PANEL_PLAYER_PRAYER_RENEW" } },
    COMBATV2_SUPER_PRAYERRENEW_DUMMY_ABILITY = { { var = "COMBATV2_TARGET_SIDE_PANEL_PLAYER_SUPER_PRAYERRENEW" } },
    -- Greater Barge, bought from the Dungeoneering reward shop.
    COMBATV2_CHARGE_OVERRIDE_BUFF_DUMMY_ABILITY = { { var = "DUNGEON_REWARD_SHOP_BARGE_OVERRIDE_UNLOCK" } },
}

-- Buffs with no var of their own that come once the player has gone a
-- while without attacking, to how long in server ticks (see
-- BuffEntry.quietTicks).
local AFTER_NOT_ATTACKING = {
    -- Greater Barge makes the next melee channel instant after 8 ticks (4.8 s).
    COMBATV2_CHARGE_OVERRIDE_BUFF_DUMMY_ABILITY = 8,
}

-- Buffs whose vars can't say when they end early, so they also end once
-- the game's buff bar drops their icon; a toggled one follows the bar both
-- ways (see BuffEntry.endsOffBuffBar).
local ENDS_OFF_BUFF_BAR = {
    -- Switching a scrimshaw off changes no var: its time left just stops counting down.
    COMBATV2_SCRIMSHAW_TIMER_DUMMY_ABILITY = true,
    -- Picking a mine up changes no var. Both mines show the same item (see
    -- SHARED_ICON_GROUPS).
    COMBATV2_DOM_MINE_1_DUMMY_ABILITY = true,
    COMBATV2_DOM_MINE_2_DUMMY_ABILITY = true,
    -- A dreadnip can despawn before its time is up, which changes no var.
    COMBATV2_DREADNIP_DUMMY_ABILITY = true,
    -- Greater Fury's guaranteed critical strike is spent by the next melee
    -- attack, which changes no var and leaves its end time running.
    COMBATV2_BUFF_MELEE_GREATER_FURY_GUARANTEED_CRITICAL_STRIKE = true,
    -- Revenge ends early when the shield or defender comes off, which
    -- doesn't move its end time; the bar also catches anything else that
    -- ends it.
    COMBATV2_ABILITY_DEFENCE_REVENGE = true,
    COMBATV2_BUFF_DEFENCE_REVENGE = true,
    -- The porter's flag isn't set again on login, and stays set after its
    -- sign is taken off. The bar shows the porter VII sign, its struct's
    -- item, whichever sign or Grace of the Elves is worn.
    DIVINATION_PORTER_ACTIVE = true,
    -- Greater Barge's buff is timed from the attacks that change a var (see
    -- AFTER_NOT_ATTACKING); the bar catches the rest.
    -- TODO: check whether auto-attacks restart it.
    COMBATV2_CHARGE_OVERRIDE_BUFF_DUMMY_ABILITY = true,
}

-- Buffs that pause while switched off, to the VarPlayer holding their time
-- left in server ticks (see BuffEntry.timeLeftVar).
local TIME_LEFT_VARS = {
    -- Switching a scrimshaw off stops its time left counting down; its end
    -- time is only set again when it's switched back on.
    COMBATV2_SCRIMSHAW_TIMER_DUMMY_ABILITY = "POP_SCRIMSHAW_TIMELEFT",
}

--- A pausing buff's time-left VarPlayer (see TIME_LEFT_VARS).
---@param structName string
---@return string? varName nil for a buff that doesn't pause.
local function timeLeftVarName(structName)
    local varName = TIME_LEFT_VARS[structName]
    if varName ~= nil and gameApi.VarExists(varName) then return varName end
    return nil
end

--- Buffs in ENDS_OFF_BUFF_BAR that show the same icon there, so the bar
--- can't say which of them it still shows.
---@class BuffIconGroup
---@field key string The same for every member of the group.
---@field endVars (string|false)[] Each member's end-time VarClient, in the group's order; false for one without.
---@field index integer This buff's place in the group.

-- Buffs that show the same icon on the buff bar, listed in the order kept
-- when the bar shows fewer of them than are running and its timers can't
-- say which: both Dominion mines show the mine.
local SHARED_ICON_GROUPS = {
    { "COMBATV2_DOM_MINE_1_DUMMY_ABILITY", "COMBATV2_DOM_MINE_2_DUMMY_ABILITY" },
}

--- A buff's group of buffs sharing its icon on the bar (see SHARED_ICON_GROUPS).
---@param structName string
---@return BuffIconGroup? group nil for a buff not in one.
local function iconGroupFor(structName)
    for _, members in ipairs(SHARED_ICON_GROUPS) do
        for index, member in ipairs(members) do
            if member == structName then
                local endVars = {}
                for memberIndex, memberName in ipairs(members) do
                    endVars[memberIndex] = endVarName(memberName, nameCore(memberName)) or false
                end
                return { key = table.concat(members, "|"), endVars = endVars, index = index }
            end
        end
    end
    return nil
end

--- A buff's requirements (see ACTIVE_WHILE), leaving out any whose var doesn't exist.
---@param structName string
---@return BuffRequirement[]? requirements nil for a buff without any.
local function requirementsFor(structName)
    local listed = ACTIVE_WHILE[structName]
    if listed == nil then return nil end
    local requirements = {}
    for _, requirement in ipairs(listed) do
        local canRead = requirement.var == nil or gameApi.VarExists(requirement.var)
        if canRead then requirements[#requirements + 1] = requirement end
    end
    if #requirements == 0 then return nil end
    return requirements
end

-- Struct name (or COMBATV2_ plus its core, so a _DUMMY copy finds them too)
-- to its toggle VarPlayer, where the names don't follow the rules (see
-- activeVarName). The tiered prayers (Thick/Rock/Steel Skin, the strength,
-- eye and mystic tiers, Charge, Hand of and Decay) are left out: each set
-- shares one COMBATV2_PRAYER_BOOST_* varbit that can't tell its tiers apart.
local ACTIVE_VARS = {
    -- 0 while off, its ability's id (1 for Lesser) while on. (_ABILITY_STRUCT
    -- follows it too, but reads as a struct, never as a number.)
    COMBATV2_BUFF_NECROMANCY_BONE_SHIELD = "COMBATV2_BUFF_NECROMANCY_BONE_SHIELD_ABILITY_ID",
    COMBATV2_PRAYER_PROTECT_MAGIC = "COMBATV2_PRAYER_PROTECT_MAGE",
    COMBATV2_PRAYER_PROTECT_MISSILES = "COMBATV2_PRAYER_PROTECT_RANGE",
    COMBATV2_PRAYER_SUMMONING = "COMBATV2_PRAYER_PROTECT_SUMMONING",
    COMBATV2_PRAYER_RAPID_HEAL = "COMBATV2_PRAYER_HEAL",
    COMBATV2_CURSE_SAP_STRENGTH = "CURSE_SAP_MELEE_STR",
    COMBATV2_CURSE_SAP_RANGE_STRENGTH = "CURSE_SAP_RANGE_STR",
    COMBATV2_CURSE_SAP_MAGIC_STRENGTH = "CURSE_SAP_MAGIC_STR",
    COMBATV2_CURSE_DEFLECT_MISSILES = "CURSE_DEFLECT_RANGED",
    COMBATV2_CURSE_LEECH_RANGE_STRENGTH = "CURSE_LEECH_RANGED_STRENGTH",
    -- The target's id while it's debilitated, -1 once it isn't.
    COMBATV2_ABILITY_DEFENCE_DEBILITATE = "COMBATV2_DEBILITATE_NPC_UID",
    -- The runic attuner's attuned rune (an OBJ var, so its icon too: see
    -- BuffEntry.objectVar), named after the Elidinis off-hand.
    -- TODO: check it in game.
    COMBATV2_BUFF_SKILLING_OFFHAND_RUNECRAFTING = "ELIDINIS_BOSS_SKILLING_OFFHAND_RUNECRAFTING_ATTUNED_RUNE_OBJ",
    -- Golden Consignment, a Jagex account reward; its timer has no var by name.
    -- TODO: check it in game.
    COMBATV2_JAGEX_ACCOUNT_PORTER_EFFECT = "JAGEX_ACCOUNT_PORTER_BUFF_ACTIVE",
    -- Inner Chaos and Sword of Edicts, from standing by Zamorak's runes.
    -- TODO: check these in game.
    COMBATV2_EGWD_ZAMORAK_BOSS_RUNE_OFFENSIVE_ZONE_BUFF = "EGWD_ZAMORAK_BOSS_RUNE_OFFENSIVE_ZONE_ACTIVE",
    COMBATV2_EGWD_ZAMORAK_BOSS_RUNE_DEFENSIVE_ZONE_BUFF = "EGWD_ZAMORAK_BOSS_RUNE_DEFENSIVE_ZONE_ACTIVE",
}

--- A toggled buff's VarPlayer (prayers, curses, Bone Shield, Flow: no
--- timer, switched on and off): non-zero while on. It's ACTIVE_VARS, then
--- one ending _ACTIVE, then one named after the struct itself, with or
--- without COMBATV2_ (prayers are varbits COMBATV2_PRAYER_<name>, curses
--- CURSE_<name>).
---@param structName string
---@param core string Its nameCore.
---@return string? varName nil if there's none.
local function activeVarName(structName, core)
    local alias = ACTIVE_VARS[structName] or ACTIVE_VARS["COMBATV2_" .. core]
    if alias ~= nil and gameApi.VarExists(alias) then return alias end
    -- An _ACTIVE flag first: a same-named var can be a level or count
    -- (INVENT_PERK_WISE) where INVENT_PERK_WISE_ACTIVE is the flag.
    local candidates = { structName .. "_ACTIVE", "COMBATV2_" .. core .. "_ACTIVE", core .. "_ACTIVE" }
    -- Flow's struct is COMBATV2_BUFF_MAGIC_FLOW_STACKS, its flag _FLOW_ACTIVE.
    if structName:sub(-#STACKS_SUFFIX) == STACKS_SUFFIX then
        candidates[#candidates + 1] = structName:sub(1, -#STACKS_SUFFIX - 1) .. "_ACTIVE"
    end
    candidates[#candidates + 1] = structName
    candidates[#candidates + 1] = "COMBATV2_" .. core
    candidates[#candidates + 1] = core
    for _, candidate in ipairs(candidates) do
        if gameApi.VarExists(candidate) then return candidate end
    end
    return nil
end

--- The _START var a buff with no end time of its own is timed from
--- (Unsullied): it lasts COMBATV2_ABILITY_EFFECT_DURATION from the cast,
--- which is the ability's COMBATV2_COOLDOWN_<core>_START (the server tick it
--- was used; its _END is when the cooldown ends, not the effect).
---@param core string The buff's nameCore.
---@return string? varName nil if the ability has none.
local function startVarName(core)
    local varName = abilityCatalogue.COOLDOWN_VAR_PREFIX .. core .. "_START"
    if gameApi.VarExists(varName) then return varName end
    return nil
end

-- Struct name to its stacks VarPlayer, where the names differ.
local STACKS_VAR_ALIASES = {
    COMBATV2_BUFF_ANIMATE_DEAD = "COMBATV2_MAGIC_ANIMATE_DEAD_STACKS",
    -- The damage dealt towards the Aftershock perk's next explosion.
    COMBATV2_AFTERSHOCK_TRACKER = "INVENT_PERK_AFTERSHOCK_COUNTER",
    -- The Wise perk's bonus experience today, in tenths of experience.
    INVENT_PERK_WISE = "INVENT_PERK_WISE_DAILYCAP",
    -- The stacks the buff bar shows for Nex's enrage.
    -- TODO: check it in game.
    COMBATV2_NEX2_RAGE_DEBUFF = "NEX2_BUFF_BAR_ENRAGE",
    -- Enervated's cut to adrenaline gain, as a percentage; also its on/off var.
    COMBATV2_ADRENALINE_DEBUFF_DUMMY_ABILITY = "COMBATV2_ADRENALINE_DEBUFF",
    -- The runic attuner's absorbed energy, named after the Elidinis off-hand.
    -- TODO: check it in game.
    COMBATV2_BUFF_SKILLING_OFFHAND_RUNECRAFTING = "ELIDINIS_BOSS_SKILLING_OFFHAND_RUNECRAFTING_ATTUNED_ALTAR_STREAK",
    -- Matched by the words in their names.
    -- TODO: check these in game.
    COMBATV2_BSLAY_REAPER_NECKLACE_DUMMY_ABILITY = "BSLAY_REAPER_NECKLACE_STACK_AMOUNT",
    COMBATV2_EGWD_BIK_CRITICAL_ARROW_BUFF_STACKING = "EGWD_BIK_CRITICAL_ARROW_STACKS",
    COMBATV2_DINARROW_WEN_CHILL_DUMMY_ABILITY = "DINARROW_WEN_BUFF_CHILL_STACKS",
    COMBATV2_DMBH_WEAPON_MELEE_SPECIAL_DUMMY_ABILITY = "DMBH_WEAPON_MELEE_STACKS",
    COMBATV2_INVENT_PERK_RUTHLESS_DUMMY_ABILITY = "INVENT_PERK_RUTHLESS_STACK_QUANTITY",
    COMBATV2_BUFF_SKILLING_OFFHAND_ARCHAEOLOGY_EFFECT = "SKILLING_OFFHAND_ARCHAEOLOGY_BUFF_EFFECT_STACKS",
    COMBATV2_DUEL_ARENA_REMOVAL_SCARAB_STACK = "DUEL_ARENA_REMOVAL_HUNTER_SCARAB_STACK",
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_ANIMA_FLOW = "EGWD_ZAMORAK_BOSS_EDICT_ANIMA_FLOW_STACKS",
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_BALANCE_OF_POWER = "EGWD_ZAMORAK_BOSS_EDICT_BALANCE_OF_POWER_STACKS",
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_GUARDIANS_TRIUMPH = "EGWD_ZAMORAK_BOSS_EDICT_GUARDIANS_TRIUMPH_STACKS",
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_HASTE = "EGWD_ZAMORAK_BOSS_EDICT_HASTE_STACKS",
}

-- Struct name to its stacks var's value at 100%, for a buff shown as a
-- percentage whose var holds something else.
local STACKS_AT_FULL = {
    -- Aftershock explodes once 50,000 damage has been dealt.
    COMBATV2_AFTERSHOCK_TRACKER = 50000,
    -- Wise stops at 50,000 bonus experience a day, whatever its rank, and
    -- its var counts tenths of experience.
    INVENT_PERK_WISE = 500000,
}

-- Stacks VarPlayers for whole families, as END_VAR_PATTERNS.
local STACKS_VAR_PATTERNS = {
    -- Incense sticks: each herb's potency, 1 to 4, is its stacks.
    { pattern = "^COMBATV2_INCENSE_(.+)_DUMMY$", replacement = "INCENSE_%1_POTENCY" },
}

-- What a stacks var's name ends with, in the order they're tried: an amount
-- (Sprite focus's ARCH_EXCAVATION_FOCUS_COUNT) only where there's no _STACKS.
local STACKS_VAR_SUFFIXES = { STACKS_SUFFIX, "_COUNT", "_AMOUNT", "_PERCENT" }

--- A stacking buff's stacks VarPlayer: STACKS_VAR_ALIASES and
--- STACKS_VAR_PATTERNS first, then the struct name or its core with a suffix
--- from STACKS_VAR_SUFFIXES.
---@param structName string
---@param core string Its nameCore.
---@return string? varName nil if there's none.
local function stacksVarName(structName, core)
    local alias = STACKS_VAR_ALIASES[structName]
    if alias ~= nil and gameApi.VarExists(alias) then return alias end
    local fromPattern = patternVarName(STACKS_VAR_PATTERNS, structName, gameApi.VarExists)
    if fromPattern ~= nil then return fromPattern end
    local candidates = {}
    for _, suffix in ipairs(STACKS_VAR_SUFFIXES) do
        for _, stem in ipairs({ structName, "COMBATV2_BUFF_" .. core, "COMBATV2_" .. core, core }) do
            candidates[#candidates + 1] = stem .. suffix
        end
        -- A struct already ending _STACKS can be its own stacks var (Essence
        -- Corruption).
        if suffix == STACKS_SUFFIX and structName:sub(-#STACKS_SUFFIX) == STACKS_SUFFIX then
            candidates[#candidates + 1] = structName
        end
    end
    for _, candidate in ipairs(candidates) do
        if gameApi.VarExists(candidate) then return candidate end
    end
    return nil
end

--- Finds every var a buff is read from, setting its endVar, stacksVar,
--- stacksAtFull, stacksWhileUntimed, requirements, endsOffBuffBar,
--- iconGroup, timeLeftVar, quietTicks, startVar, activeVar and objectVar. Toggles and
--- start-timed buffs are only looked for without an end time, which is
--- looked for first.
---@param entry BuffEntry Changed in place; its structName, stacks, stacksPercent, duration and objectOverride must be set.
function buffVars.Resolve(entry)
    local structName = entry.structName
    local core = nameCore(structName)
    entry.endVar = endVarName(structName, core)
    entry.stacksVar = entry.stacks and stacksVarName(structName, core) or nil
    entry.stacksAtFull = entry.stacksPercent and STACKS_AT_FULL[structName] or nil
    entry.stacksWhileUntimed = STACKS_WHILE_UNTIMED[structName]
    entry.requirements = requirementsFor(structName)
    entry.endsOffBuffBar = ENDS_OFF_BUFF_BAR[structName] == true
    entry.iconGroup = entry.endsOffBuffBar and iconGroupFor(structName) or nil
    entry.timeLeftVar = timeLeftVarName(structName)
    entry.quietTicks = AFTER_NOT_ATTACKING[structName]
    local untimed = entry.endVar == nil
    -- Only buffs with a duration can be timed from their ability's use.
    entry.startVar = untimed and entry.duration ~= nil and startVarName(core) or nil
    entry.activeVar = untimed and activeVarName(structName, core) or nil
    -- The quiver's on/off var is the OBJ var holding its ammo.
    entry.objectVar = entry.objectOverride and entry.activeVar or nil
end

--- Whether a buff has any var to be read from (active-buffs reads it if so).
--- Buffs with none can't be tracked, so the data sources leave them out.
---@param entry BuffEntry
---@return boolean
function buffVars.HasAny(entry)
    return entry.endVar ~= nil or entry.startVar ~= nil or entry.stacksVar ~= nil or entry.activeVar ~= nil
        or entry.quietTicks ~= nil
end

--- Whether a buff has a timer: an end time or a start to time from.
---@param entry BuffEntry
---@return boolean
function buffVars.IsTimed(entry)
    return entry.endVar ~= nil or entry.startVar ~= nil
end

return buffVars
