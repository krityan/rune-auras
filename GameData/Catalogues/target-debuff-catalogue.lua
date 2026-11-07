-- The damage over time and debuffs a player puts on their target, from
-- abilities and spells, for the Target debuff sources. Written by hand: no
-- config links a debuff to what applies it, or says how long it lasts.

local targetDebuffCatalogue = {}

--- A debuff the player can put on their target, applied by an ability
--- (startVar) or a spell (spell).
---@class TargetDebuffEntry
---@field key string Stable: part of the source id.
---@field name string What applies it, which players search for.
---@field icon integer The debuff's sprite (its struct's COMBATV2_ABILITY_ICON), which the target info panel shows while it's on.
---@field startVar string? An ability's cooldown var, without _START: _START holds the server tick it was used on.
---@field spell string? A spell's struct name. A cast shows as COMBATV2_JUST_USED_ABILITY holding the struct's id, and lands when its projectile arrives.
---@field style WeaponStyle? The weapon style it's used with, for an ability whose _START is also set by another style's ability (Corruption Shot and Blast share a cooldown): a use counts only with that style's weapon.
---@field earlierStartVar string? For a recast stage, the startVar of the stage before it. Using that stage sets this one's _START too, so a _START the same as that one's came from the earlier stage.
---@field isHex boolean? A hex spell: the magic master cape's perk doubles its length.
---@field isBind boolean? A bind spell: a cast on a target one of ours already binds does nothing, rather than refreshing it.
---@field durationTicks integer Server ticks the panel shows it for: from an ability's use, or from a spell landing.
---@field flagVar string? A varbit that's 1 while the current target has it. Training dummies never set it.
---@field spreadTicks integer? For a DoT that spreads to nearby enemies when its target dies: server ticks from the death until it ends on them.

-- The target info panel's icon for every bind, whichever spell or ability applied it.
local BOUND_ICON = 14392

---@type TargetDebuffEntry[]
targetDebuffCatalogue.ENTRIES = {
    -- Dismember, Slaughter and Massacre are one ability's three stages, each
    -- with its own bleed, and all three can be on a target at once.
    {
        key = "dismember",
        name = "Dismember",
        icon = 21239,
        startVar = "COMBATV2_COOLDOWN_MELEE_DISMEMBER",
        durationTicks = 19,
    },
    {
        key = "slaughter",
        name = "Slaughter",
        icon = 21362,
        startVar = "COMBATV2_COOLDOWN_MELEE_DISMEMBER_RECAST_1",
        earlierStartVar = "COMBATV2_COOLDOWN_MELEE_DISMEMBER",
        durationTicks = 21,
    },
    {
        key = "massacre",
        name = "Massacre",
        icon = 21296,
        startVar = "COMBATV2_COOLDOWN_MELEE_DISMEMBER_RECAST_2",
        earlierStartVar = "COMBATV2_COOLDOWN_MELEE_DISMEMBER_RECAST_1",
        durationTicks = 28,
    },
    -- Corruption Shot and Blast also go on enemies near the target, which
    -- aren't followed.
    {
        key = "corruption_shot",
        name = "Corruption Shot",
        icon = 17255,
        startVar = "COMBATV2_COOLDOWN_RANGED_CORRUPTION",
        style = "ranged",
        durationTicks = 14,
    },
    {
        key = "combust",
        name = "Combust",
        icon = 23401,
        startVar = "COMBATV2_COOLDOWN_MAGIC_COMBUST",
        durationTicks = 35,
    },
    {
        key = "corruption_blast",
        name = "Corruption Blast",
        icon = 19226,
        startVar = "COMBATV2_COOLDOWN_MAGIC_CORRUPTION",
        style = "magic",
        durationTicks = 14,
    },
    {
        key = "bloat",
        name = "Bloat",
        icon = 30098,
        startVar = "COMBATV2_COOLDOWN_NECROMANCY_BLOAT",
        durationTicks = 35,
        flagVar = "COMBATV2_TARGET_SIDE_PANEL_TARGET_NECROMANCY_BLOATED",
        spreadTicks = 14,
    },
    {
        key = "soulfire",
        name = "Soulfire",
        icon = 30372,
        startVar = "COMBATV2_ABILITY_WEAPON_COOLDOWN_SOULFIRE",
        durationTicks = 22,
    },
    -- These hexes last a minute and a recast refreshes them. TODO: check each
    -- length in game.
    {
        key = "confuse",
        name = "Confuse",
        icon = 14389,
        spell = "MAGIC_CONFUSE",
        isHex = true,
        durationTicks = 100,
    },
    {
        key = "weaken",
        name = "Weaken",
        icon = 14390,
        spell = "MAGIC_WEAKEN",
        isHex = true,
        durationTicks = 100,
    },
    {
        key = "curse",
        name = "Curse",
        icon = 14391,
        spell = "MAGIC_CURSE",
        isHex = true,
        durationTicks = 100,
    },
    {
        key = "vulnerability",
        name = "Vulnerability",
        icon = 14395,
        spell = "MAGIC_VULNERABILITY",
        isHex = true,
        durationTicks = 100,
    },
    {
        key = "enfeeble",
        name = "Enfeeble",
        icon = 14371,
        spell = "MAGIC_ENFEEBLE",
        isHex = true,
        durationTicks = 100,
    },
    {
        key = "stagger",
        name = "Stagger",
        icon = 14377,
        spell = "MAGIC_STAGGER",
        isHex = true,
        durationTicks = 100,
    },
    -- The binds' lengths are on NPCs; one praying against magic is bound for
    -- half as long. TODO: check each length in game, and Bind's and Snare's
    -- struct names.
    {
        key = "bind",
        name = "Bind",
        icon = BOUND_ICON,
        spell = "MAGIC_BIND",
        isHex = true,
        isBind = true,
        durationTicks = 20,
    },
    {
        key = "snare",
        name = "Snare",
        icon = BOUND_ICON,
        spell = "MAGIC_SNARE",
        isHex = true,
        isBind = true,
        durationTicks = 30,
    },
    {
        key = "entangle",
        name = "Entangle",
        icon = BOUND_ICON,
        spell = "MAGIC_ENTANGLE",
        isHex = true,
        isBind = true,
        durationTicks = 40,
    },
    {
        key = "smoke_cloud",
        name = "Smoke Cloud",
        icon = 14771,
        spell = "MAGIC_SMOKE_CLOUD",
        isHex = true,
        -- TODO: check in game.
        durationTicks = 200,
    },
}

return targetDebuffCatalogue
