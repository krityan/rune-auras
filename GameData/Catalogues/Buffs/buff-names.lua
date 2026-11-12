-- Hand-written names for the buffs the game doesn't name usably: it gives a
-- sentence, nothing, an internal name, or the same name as another buff
-- with nothing short saying what tells them apart. Buffs are keyed by
-- struct name, as their source ids are, so renaming one here keeps the
-- auras that show it.

local buffNames = {}

-- Struct name to its name. Where buffs share a name, each says in brackets
-- what tells it apart: what it does, or where it's from.
local NAMES = {
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

--- A buff's hand-written name.
---@param structName string
---@return string? name nil for a buff named from the game's config.
function buffNames.For(structName)
    return NAMES[structName]
end

return buffNames
