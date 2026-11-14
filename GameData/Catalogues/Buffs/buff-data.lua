-- Everything hand-written about particular buffs, for what game config and
-- the rules (buff-naming, buff-vars, buff-builder) don't say: names and
-- icons, vars the name rules don't find, how the game's buff bar shows
-- them, and the buffs the game no longer gives. Keyed by struct name, as
-- source ids are, so changing one here keeps the auras that show it.

local buffData = {}

-- Struct name to its name, for buffs the game doesn't name usably: it gives
-- a sentence, nothing, an internal name, or the same name as another buff
-- with nothing short saying what tells them apart. Where buffs share a name,
-- each says in brackets what tells it apart: what it does, or where it's from.
buffData.NAMES = {
    -- Sets whose tooltips share a name.
    COMBATV2_DSF_REWARD_BOOST_1_DUMMY_ABILITY = "Deep Sea Fishing (Catch rate)",
    COMBATV2_DSF_REWARD_BOOST_2_DUMMY_ABILITY = "Deep Sea Fishing (Additional catch)",
    COMBATV2_DSF_REWARD_BOOST_3_DUMMY_ABILITY = "Deep Sea Fishing (XP boost)",
    COMBATV2_IDOLS_BUFF_1_DUMMY_ABILITY = "Overgrown idol (Cut rate)",
    COMBATV2_IDOLS_BUFF_2_DUMMY_ABILITY = "Overgrown idol (Success rate)",
    COMBATV2_IDOLS_BUFF_3_DUMMY_ABILITY = "Overgrown idol (Additional log)",
    COMBATV2_IDOLS_BUFF_4_DUMMY_ABILITY = "Overgrown idol (XP boost)",
    COMBATV2_IDOLS_BUFF_5_DUMMY_ABILITY = "Overgrown idol (Log banking)",
    COMBATV2_EGWD_BIK_CRITICAL_ARROW_ADRENALINE_BUFF = "Feasting Spores (Adrenaline)",
    COMBATV2_EGWD_BIK_CRITICAL_ARROW_BUFF_STACKING = "Feasting Spores (Stacks)",
    COMBATV2_DUNGEON_ULTHVEN_2H_RANGED_SPECIAL_DUMMY_ABILITY = "Split Soul (ECB)",
    COMBATV2_BUFF_NECROMANCY_SPLIT_SOUL = "Split Soul (Necromancy)",
    COMBATV2_ABILITY_DEFENCE_UNSULLIED = "Unsullied (Defence)",
    COMBATV2_MENAPHOS_UNSULLIED_DUMMY_ABILITY = "Unsullied (Menaphos)",
    COMBATV2_PRAYER_PROTECT_ITEM = "Protect Item (Prayer)",
    COMBATV2_CURSE_PROTECT_ITEM = "Protect Item (Curse)",
    -- TODO: check the RAND_OVERLOAD item is Dungeoneering's.
    COMBATV2_RAND_OVERLOAD_DUMMY_ABILITY = "Overloaded (Dungeoneering)",

    -- Tooltips that are sentences or empty.
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_ANIMA_FLOW = "Anima Flow (Zamorak)",
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_BALANCE_OF_POWER = "Balance of Power (Zamorak)",
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_GUARDIANS_TRIUMPH = "Guardian's Triumph (Zamorak)",
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_HASTE = "Haste (Zamorak)",
    COMBATV2_FIGHTKILN_INVULN = "Fight Kiln crystal (Invulnerability)",
    COMBATV2_FIGHTKILN_MAGIC = "Fight Kiln crystal (Magic)",
    COMBATV2_FIGHTKILN_RANGED = "Fight Kiln crystal (Ranged)",
    COMBATV2_FIGHTKILN_STRENGTH = "Fight Kiln crystal (Strength)",
    COMBATV2_FIGHTKILN_HITPOINTS = "Fight Kiln crystal (Constitution)",
    ELR2_CYCLOSIS_CAUGHT = "Caught thieving (Cyclosis)",
    ELR2_WAIKO_CAUGHT = "Caught thieving (Waiko)",
    SWORLDS_MUTATOR_FEELING_PUMPED = "Feeling Pumped (Shattered Worlds)",
    SWORLDS_OBJECTIVE_FOUNTAIN = "Fountain objective (Shattered Worlds)",
    COMBATV2_STAFF_OF_LIGHT = "Power of Light",
    COMBATV2_STAFF_OF_DARKNESS = "Power of Darkness",
    COMBATV2_BUFF_MELEE_SUNFALL_SLAM = "Lesser Purifying Light",
    COMBATV2_DMBH_WEAPON_RANGED_SPECIAL_DUMMY_ABILITY = "Locate (Decimation)",
    COMBATV2_DMBH_WEAPON_MELEE_SPECIAL_DUMMY_ABILITY = "Gravitate (Annihilation)",
    COMBATV2_BUFF_MELEE_GREATER_FURY_GUARANTEED_CRITICAL_STRIKE = "Greater Fury (Guaranteed crit)",
    COMBATV2_CHARGE_OVERRIDE_BUFF_DUMMY_ABILITY = "Greater Barge",
    DIVINATION_PORTER_ACTIVE = "Sign of the Porter",
    FMC_REWARD_BOOK_ACTIVE = "Book of Char",
    COMBATV2_STUN_IMMUNE_ACTIVE = "Stun immunity",
    COMBATV2_MOLE2_MUDSTUN_DUMMY_ABILITY = "Trapped in mud (Giant Mole)",
    COMBATV2_NEX2_RAGE_DEBUFF = "Rage (Nex: Angel of Death)",
    COMBATV2_PRAYER_DEBUFF = "Protection prayers disabled",
    COMBATV2_REVIVE_LIFE_EFFECT = "Sign of Life cooldown",
}

-- Struct name to the sprite shown for it, for buffs whose struct's icon is a
-- dull "inactive" version the game swaps by script (their structs have
-- COMBATV2_BUFF_ICON_OVERRIDE): the coloured one (the same sprite name
-- without _INACTIVE), which the Icon display greys itself while inactive.
-- These are every BUFF_ICON_..._INACTIVE sprite.
buffData.ICONS = {
    -- Bloodlust: BUFF_ICON_MELEE_BLOODLUST(_INACTIVE).
    COMBATV2_BUFF_MELEE_BLOODLUST = 23875,
    -- Death Spark: BUFF_ICON_NECROMANCY_NECRO_RASIAL_ARMGUARD_T95(_INACTIVE).
    COMBATV2_BUFF_NECRO_RASIAL_ARMGUARD_T95_PASSIVE = 30127,
    -- Soul Reave: BUFF_ICON_NECROMANCY_NECRO_DEVOURER_ARMGUARD_T95(_INACTIVE).
    COMBATV2_BUFF_NECRO_DEVOURER_ARMGUARD_T95_PASSIVE = 35068,
}

-- Buffs with no name or icon of their own, to the ability struct whose they
-- show. The game links them only through a var that's empty while the buff
-- is off (<struct>_ABILITY_STRUCT), so they're listed here.
buffData.DETAILS_FROM = {
    -- Living Death's Death form.
    COMBATV2_BUFF_NECROMANCY_UNDEAD_INSTINCT = "COMBATV2_ABILITY_NECROMANCY_LIVING_DEATH",
}

-- Buffs whose struct is still in config though the game no longer gives
-- them, where their names don't say so (see RETIRED_PATTERNS).
buffData.RETIRED = {
    -- A temporary experience boost from Menaphos' launch.
    COMBATV2_MENAPHOS_XPBOOST = true,
    -- Only from a time-limited event's skilling cauldrons.
    COMBATV2_AGILITY_POTION_EFFECT = true,
    COMBATV2_CRAFTING_POTION_EFFECT = true,
    -- One-off rewards for returning players.
    COMBATV2_CHALLENGE_RETURNER_DXP_CHANCE_ABILITY = true,
    COMBATV2_CHALLENGE_RETURNER_FREE_DEATHS_ABILITY = true,
    COMBATV2_RETURNER_PACK_XP_BOOST_DUMMY_ABILITY = true,
    -- The Bonanza event's buff.
    BUFF_SELECT_EVENT_CENTRAL_BUFF_BAR_STRUCT = true,
    -- Removed with Chronicle cards.
    COMBATV2_CHRONICLE_CARD_DUMMY_ABILITY = true,
    -- The Battle of the Monolith world event, and its prerelease boost.
    COMBATV2_ABILITY_CONSTITUTION_6AWE2_BLESSING = true,
    COMBATV2_MINIQUEST_EGWD_PRERELEASE_XP_BUFF_DUMMY_ABILITY = true,
    -- The Raid on Port Sarim event.
    COMBATV2_PORTSARIM_CONCH_DUMMY_ABILITY = true,
    -- Golden Security, a Jagex account reward.
    COMBATV2_JAGEX_ACCOUNT_DAMAGE_REDUCTION = true,
    COMBATV2_MINING_BANKING = true,
    COMBATV2_MTX_TRADER_DURATION_DUMMY_ABILITY = true,
    COMBATV2_BUFF_RANGED_CRITICAL_STRIKE_ADRENALINE_EFFECT = true,
    -- Rock of Resilience, from a 2021 event.
    COMBATV2_MHAW_MAY21_STONE_DUMMY_ABILITY = true,
    -- Splintering Arrows' buff on the player: the arrows now only puncture the target.
    COMBATV2_EGWD_BIK_PUNCTURE_ARROW_BUFF = true,
    -- The laceration boots' empowered Barge and its cooldown: the boots now
    -- give Bladed Dive instead.
    COMBATV2_BLADED_DIVE_BOOTS_UPGRADE_BUFF_DUMMY_ABILITY = true,
    COMBATV2_BLADED_DIVE_BOOTS_UPGRADE_BUFF_DUMMY_ABILITY_COOLDOWN = true,
}

-- Seasonal events whose buffs are named with the event and its year
-- (HALLOWEEN23, MTXBEACH15, EVENT21): each year's event brings new ones.
local EVENT_WORDS = { "HALLOWEEN", "XMAS", "CHRISTMAS", "EASTER", "VALENTINES", "BEACH", "SUMMER", "WINTER", "EVENT" }

-- Config names (a buff's struct, or the item it shows) of things the game
-- no longer gives: Treasure Hunter (promotions are TRH<number>, older items
-- plain TRH), Leagues (a game mode only on its own worlds while it ran), the
-- retired Beach event, a crafting event's enhancers, the variety task
-- events, and an event word followed by a year of 2 or 4 digits.
buffData.RETIRED_PATTERNS = { "^TRH[%d_]", "_TRH[%d_]", "LEAGUE", "^COMBATV2_BEACH_", "^MTXBEACH",
    "^COMBATV2_EVENT_CRAFTING_", "^VARIETY_TASK_EVENTS_" }
for _, word in ipairs(EVENT_WORDS) do
    buffData.RETIRED_PATTERNS[#buffData.RETIRED_PATTERNS + 1] = word .. "_?%d%d%d?%d?%f[%D]"
end

-- Struct name to its end-time VarClient where the name rules (see buff-vars)
-- don't find it, or false for a buff with none: one whose end time by name
-- is never set, timed from its ability's use or read from its stacks or
-- toggle instead, or one whose var by name is something else's.
buffData.END_VARS = {
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
    -- buff-vars' END_VAR_NAMES): Kuradal's Favour respawns slayer creatures at once.
    -- TODO: check these in game; they may be the rewards' cooldowns instead.
    SWORLDS_REWARD_FEROCIOUS_DUMMY_ABILITY = "SWORLDS_REWARD_KURADEL_INSTA_RESPAWN_COOLDOWN",
    SWORLDS_REWARD_SLAYING_DUMMY_ABILITY = "SWORLDS_REWARD_SLAYER_XP_MULTIPLIER_COOLDOWN",
    -- Named like Devoted's end without the struct's _ACTIVE.
    COMBATV2_STUN_IMMUNE_ACTIVE = "COMBATV2_STUN_IMMUNE_COOLDOWN",
    -- Both Sonic Waves set Greater Sonic Wave's end time; each Flow's
    -- requirement (REQUIRES) says which one it was.
    COMBATV2_BUFF_MAGIC_FLOW_STACKS = "COMBATV2_MAGIC_GREATER_SONIC_WAVE_END_EFFECT_CLIENT",
    COMBATV2_BUFF_MAGIC_GREATER_FLOW_STACKS = "COMBATV2_MAGIC_GREATER_SONIC_WAVE_END_EFFECT_CLIENT",

    -- None: their end time by name is never set.
    -- Transfigure's bind, timed from its ability's use instead.
    COMBATV2_ABILITY_CONSTITUTION_TRANSFIGURE = false,
    -- Frostblades' stacks, until Icy Tempest spends them.
    COMBATV2_BUFF_PRIMORDIAL_ICE = false,
    -- Vengeance lasts until the next hit; COMBATV2_VENGEANCE_COOLDOWN is the
    -- Vengeance cooldown debuff's.
    COMBATV2_VENGEANCE = false,
}

-- A Lua pattern on the struct name and its replacement, for whole families
-- of end-time VarClients.
buffData.END_VAR_FAMILIES = {
    -- Incense sticks: COMBATV2_INCENSE_<HERB>_DUMMY.
    { pattern = "^COMBATV2_INCENSE_(.+)_DUMMY$", replacement = "COMBATV2_INCENSE_BURNER_%1_END_CLIENT" },
}

--- How a stacking buff's stacks are read, where the rules don't say.
---@class BuffStacksData
---@field var string? Its stacks VarPlayer, where the name rules (see buff-vars) don't find it.
---@field atFull integer? For a buff shown as a percentage, its var's value at 100% where it holds something else.
---@field whileUntimed boolean? Builds up stacks with no timer, then at the most stacks loses them and runs a timer instead: active while it has stacks, its value then the stacks.

---@type table<string, BuffStacksData>
buffData.STACKS = {
    COMBATV2_BUFF_ANIMATE_DEAD = { var = "COMBATV2_MAGIC_ANIMATE_DEAD_STACKS" },
    -- The damage dealt towards the Aftershock perk's next explosion, which
    -- comes at 50,000.
    COMBATV2_AFTERSHOCK_TRACKER = { var = "INVENT_PERK_AFTERSHOCK_COUNTER", atFull = 50000 },
    -- The Wise perk's bonus experience today, in tenths of experience: it
    -- stops at 50,000 a day, whatever its rank.
    INVENT_PERK_WISE = { var = "INVENT_PERK_WISE_DAILYCAP", atFull = 500000 },
    -- The stacks the buff bar shows for Nex's enrage.
    -- TODO: check it in game.
    COMBATV2_NEX2_RAGE_DEBUFF = { var = "NEX2_BUFF_BAR_ENRAGE" },
    -- Enervated's cut to adrenaline gain, as a percentage; also its on/off var.
    COMBATV2_ADRENALINE_DEBUFF_DUMMY_ABILITY = { var = "COMBATV2_ADRENALINE_DEBUFF" },
    -- The runic attuner's absorbed energy, named after the Elidinis off-hand.
    -- TODO: check it in game.
    COMBATV2_BUFF_SKILLING_OFFHAND_RUNECRAFTING = { var = "ELIDINIS_BOSS_SKILLING_OFFHAND_RUNECRAFTING_ATTUNED_ALTAR_STREAK" },
    -- Electrified (Deep Sea Fishing): at 10 stacks the player is stunned and
    -- its timer runs 150 seconds.
    COMBATV2_DSF_JELLYFISH_STUN_DUMMY_ABILITY = { whileUntimed = true },
    -- Matched by the words in their names.
    -- TODO: check these in game.
    COMBATV2_BSLAY_REAPER_NECKLACE_DUMMY_ABILITY = { var = "BSLAY_REAPER_NECKLACE_STACK_AMOUNT" },
    COMBATV2_EGWD_BIK_CRITICAL_ARROW_BUFF_STACKING = { var = "EGWD_BIK_CRITICAL_ARROW_STACKS" },
    COMBATV2_DINARROW_WEN_CHILL_DUMMY_ABILITY = { var = "DINARROW_WEN_BUFF_CHILL_STACKS" },
    COMBATV2_DMBH_WEAPON_MELEE_SPECIAL_DUMMY_ABILITY = { var = "DMBH_WEAPON_MELEE_STACKS" },
    COMBATV2_INVENT_PERK_RUTHLESS_DUMMY_ABILITY = { var = "INVENT_PERK_RUTHLESS_STACK_QUANTITY" },
    COMBATV2_BUFF_SKILLING_OFFHAND_ARCHAEOLOGY_EFFECT = { var = "SKILLING_OFFHAND_ARCHAEOLOGY_BUFF_EFFECT_STACKS" },
    COMBATV2_DUEL_ARENA_REMOVAL_SCARAB_STACK = { var = "DUEL_ARENA_REMOVAL_HUNTER_SCARAB_STACK" },
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_ANIMA_FLOW = { var = "EGWD_ZAMORAK_BOSS_EDICT_ANIMA_FLOW_STACKS" },
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_BALANCE_OF_POWER = { var = "EGWD_ZAMORAK_BOSS_EDICT_BALANCE_OF_POWER_STACKS" },
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_GUARDIANS_TRIUMPH = { var = "EGWD_ZAMORAK_BOSS_EDICT_GUARDIANS_TRIUMPH_STACKS" },
    COMBATV2_EGWD_ZAMORAK_BOSS_BUFF_RUNE_HASTE = { var = "EGWD_ZAMORAK_BOSS_EDICT_HASTE_STACKS" },
}

-- Stacks VarPlayers for whole families, as END_VAR_FAMILIES.
buffData.STACKS_VAR_FAMILIES = {
    -- Incense sticks: each herb's potency, 1 to 4, is its stacks.
    { pattern = "^COMBATV2_INCENSE_(.+)_DUMMY$", replacement = "INCENSE_%1_POTENCY" },
}

-- Struct name (or COMBATV2_ plus its core, so a _DUMMY copy finds them too)
-- to its toggle VarPlayer, where the name rules don't find it. The tiered
-- prayers (Thick/Rock/Steel Skin, the strength, eye and mystic tiers,
-- Charge, Hand of and Decay) are left out: each set shares one
-- COMBATV2_PRAYER_BOOST_* varbit that can't tell its tiers apart.
buffData.ACTIVE_VARS = {
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

-- Struct name to a VarPlayer that must also be non-zero for it to count as
-- active, for buffs whose own vars carry on after the game has dropped them
-- and the buff bar can't tell (they share an icon or an end time, or show
-- an item the game picks). Greater versions use their base's (see
-- buff-builder's shareAbilityVars).
buffData.REQUIRES = {
    -- Both Sonic Waves set one end time (see END_VARS); each sets its own flag.
    COMBATV2_BUFF_MAGIC_FLOW_STACKS = "COMBATV2_BUFF_MAGIC_FLOW_ACTIVE",
    COMBATV2_BUFF_MAGIC_GREATER_FLOW_STACKS = "COMBATV2_BUFF_MAGIC_GREATER_FLOW_ACTIVE",
    COMBATV2_ABILITY_MAGIC_GREATER_SONIC_WAVE = "COMBATV2_BUFF_MAGIC_GREATER_FLOW_ACTIVE",
    -- The scripture is switched on; taking it off switches it off. Its icon
    -- on the bar is the book worn, so the bar can't follow it.
    COMBATV2_GOD_BOOK_TIMER_DUMMY_ABILITY = "GOD_BOOK_ACTIVE",
    -- Each potion tier's own time left (in 15 second steps): a stronger tier
    -- clears a weaker one's, but not its end time, and all show one icon.
    COMBATV2_ANTI_DRAGONFIRE_DUMMY_ABILITY = "DRAGONRESIST_ORIGINAL",
    COMBATV2_SUPER_ANTI_DRAGONFIRE_DUMMY_ABILITY = "DRAGONRESIST_ALL",
    -- The two tiers share an end time; each has its own flag, and drinking
    -- one clears the other's.
    COMBATV2_PRAYER_RENEW_DUMMY_ABILITY = "COMBATV2_TARGET_SIDE_PANEL_PLAYER_PRAYER_RENEW",
    COMBATV2_SUPER_PRAYERRENEW_DUMMY_ABILITY = "COMBATV2_TARGET_SIDE_PANEL_PLAYER_SUPER_PRAYERRENEW",
    -- Greater Barge, bought from the Dungeoneering reward shop.
    COMBATV2_CHARGE_OVERRIDE_BUFF_DUMMY_ABILITY = "DUNGEON_REWARD_SHOP_BARGE_OVERRIDE_UNLOCK",
}

-- Buffs with no var of their own that come once the player has gone a while
-- without attacking, to how long in server ticks (see BuffEntry.quietTicks).
buffData.QUIET_TICKS = {
    -- Greater Barge makes the next melee channel instant after 8 ticks (4.8 s).
    COMBATV2_CHARGE_OVERRIDE_BUFF_DUMMY_ABILITY = 8,
}

-- Struct name to how the game's buff bar treats it, where the default (see
-- buff-builder's endsOffBuffBar) doesn't fit: "decides" for a buff the
-- default leaves out that's on only while the bar shows it all the same (a
-- toggled one follows the bar both ways), "never" for one the bar never
-- shows, which keeps to its vars.
buffData.BAR = {
    -- The porter's flag isn't set again on login, and stays set after its
    -- sign is taken off. The bar shows the porter VII sign, its struct's item,
    -- whichever sign or Grace of the Elves is worn.
    DIVINATION_PORTER_ACTIVE = "decides",
    -- Greater Barge's buff is timed from the attacks that change a var (see
    -- QUIET_TICKS); the bar catches the rest.
    -- TODO: check whether auto-attacks restart it.
    COMBATV2_CHARGE_OVERRIDE_BUFF_DUMMY_ABILITY = "decides",
    COMBATV2_INFINITE_RUN = "never",
}

-- Buffs that show the same icon on the buff bar, listed in the order kept
-- when the bar shows fewer of them than are running and its timers can't
-- say which (see BuffEntry.iconGroup): both Dominion mines show the mine.
buffData.SHARED_ICONS = {
    { "COMBATV2_DOM_MINE_1_DUMMY_ABILITY", "COMBATV2_DOM_MINE_2_DUMMY_ABILITY" },
}

return buffData
