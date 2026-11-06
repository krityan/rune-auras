-- The damage-over-time effects a player puts on their target, for the
-- Target debuff sources. Written by hand: no config links a DoT to what
-- applies it, or says how long it lasts.

local targetDebuffCatalogue = {}

--- A DoT the player can put on their target.
---@class TargetDebuffEntry
---@field key string Stable: part of the source id.
---@field name string What applies it, which players search for.
---@field icon integer The debuff's sprite (its struct's COMBATV2_ABILITY_ICON), which the target info panel shows while it's on.
---@field startVar string The cooldown var, without _START, of what applies it: _START holds the server tick it was used on.
---@field style WeaponStyle? The weapon style it's used with, for an ability whose _START is also set by another style's ability (Corruption Shot and Blast share a cooldown): a use counts only with that style's weapon.
---@field earlierStartVar string? For a recast stage, the startVar of the stage before it. Using that stage sets this one's _START too, so a _START the same as that one's came from the earlier stage.
---@field durationTicks integer Server ticks from that use until the panel stops showing it, which is longer than the DoT's hits last.
---@field flagVar string? A varbit that's 1 while the current target has it. Training dummies never set it.
---@field spreadTicks integer? For a DoT that spreads to nearby enemies when its target dies: server ticks from the death until it ends on them.
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
}

return targetDebuffCatalogue
