-- The example auras Import's Examples tab lists, each with its export, a
-- name, a description and the data source whose icon shows beside it. It's
-- regenerated whole from each example's export, so don't edit it by hand.

---@class AuraExample
---@field name string
---@field description string
---@field iconSource string A data source id, whose icon shows beside it.
---@field export string Its export, as Import reads it.

---@type AuraExample[]
local EXAMPLES = {
    {
        name = "Lifepoint Orb",
        description = "An orb that shows your lifepoints",
        iconSource = "lifepoints",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 1624,
      "name": "Lifepoints",
      "display": "orb",
      "source": "lifepoints",
      "colour": "C0392BFF",
      "anchor": "centre",
      "texts": [{ "textSize": 27, "key": 1 }],
      "width": 100,
      "height": 100,
      "borderThickness": 4,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
    {
        name = "Adrenaline Bar",
        description = "A clean bar showing your current adrenaline",
        iconSource = "adrenaline",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 1228,
      "name": "Adrenaline",
      "display": "bar",
      "source": "adrenaline",
      "colour": "E8B923FF",
      "anchor": "centre",
      "y": -130,
      "texts": [{ "key": 1 }],
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
    {
        name = "Necromancy Resource Bars",
        description = "Segmented bars for both your primary necromancy resources",
        iconSource = "buff_combatv2_buff_necromancy_necrosis",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 67,
      "name": "Necromancy Resource Bars",
      "display": "group",
      "anchor": "centre",
      "load": {
        "options": { "weaponStyle": { "enabled": true, "value": "necromancy" } }
      }
    },
    {
      "id": 69,
      "group": 67,
      "name": "Necrosis Stacks",
      "display": "segments",
      "source": "buff_combatv2_buff_necromancy_necrosis",
      "colour": "7C00FFFF",
      "anchor": "bottom",
      "y": -198,
      "textFont": "museo_sans_regular",
      "textSize": 11,
      "textTemplate": "$value / $max",
      "decimalsBelow": 120,
      "borderThickness": 2,
      "segmentWidth": 34,
      "sizeBy": "total",
      "totalLength": 420,
      "spacing": 1,
      "timeFormat": "tenths"
    },
    {
      "id": 70,
      "group": 67,
      "name": "Soul Stacks - 3",
      "display": "segments",
      "source": "buff_combatv2_buff_necromancy_residual_soul",
      "colour": "00D5FFFF",
      "anchor": "centre",
      "y": -205,
      "textFont": "museo_sans_regular",
      "textSize": 11,
      "textTemplate": "$value / $max",
      "decimalsBelow": 120,
      "load": {
        "options": {
          "wearing": { "enabled": true, "value": "OFF_HAND", "item": 55537 }
        }
      },
      "borderThickness": 2,
      "segments": 3,
      "segmentWidth": 139,
      "sizeBy": "total",
      "totalLength": 420,
      "spacing": 1,
      "timeFormat": "tenths"
    },
    {
      "id": 1229,
      "group": 67,
      "name": "Soul Stacks - 5",
      "display": "segments",
      "source": "buff_combatv2_buff_necromancy_residual_soul",
      "colour": "00D5FFFF",
      "anchor": "centre",
      "y": -205,
      "textFont": "museo_sans_regular",
      "textSize": 11,
      "textTemplate": "$value / $max",
      "decimalsBelow": 120,
      "load": {
        "options": {
          "wearing": { "enabled": true, "value": "OFF_HAND", "item": 55485 }
        }
      },
      "borderThickness": 2,
      "segments": 5,
      "segmentWidth": 139,
      "sizeBy": "total",
      "totalLength": 420,
      "spacing": 1,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
    {
        name = "Common Upkeeps",
        description = "Timers for common buffs such as overloads and prayer renewals",
        iconSource = "buff_combatv2_prayer_renew_dummy_ability",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 2140,
      "name": "Common Upkeeps",
      "display": "dynamicGroup",
      "anchor": "centre",
      "x": 411,
      "y": 114,
      "grow": "down",
      "spacing": 0
    },
    {
      "id": 2141,
      "group": 2140,
      "name": "Overloaded",
      "display": "bar",
      "source": "buff_combatv2_overload_dummy_ability",
      "colour": "29AE27FF",
      "anchor": "centre",
      "texts": [{ "key": 1, "timeFormat": "clock" }],
      "hideWhenEmpty": true,
      "showIcon": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2142,
      "group": 2140,
      "name": "Prayer Renew",
      "display": "bar",
      "source": "buff_combatv2_prayer_renew_dummy_ability",
      "colour": "AE2727FF",
      "anchor": "centre",
      "y": -30,
      "texts": [{ "key": 1, "timeFormat": "clock" }],
      "hideWhenEmpty": true,
      "showIcon": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2143,
      "group": 2140,
      "name": "Animate Dead",
      "display": "bar",
      "source": "buff_combatv2_buff_animate_dead",
      "colour": "272BAEFF",
      "anchor": "centre",
      "y": -60,
      "texts": [{ "key": 1, "timeFormat": "clock" }],
      "hideWhenEmpty": true,
      "showIcon": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2144,
      "group": 2140,
      "name": "Vampyrism",
      "display": "bar",
      "source": "buff_combatv2_buff_vampyrism",
      "colour": "F90E0EFF",
      "anchor": "centre",
      "y": -90,
      "texts": [{ "key": 1, "timeFormat": "clock" }],
      "hideWhenEmpty": true,
      "showIcon": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2145,
      "group": 2140,
      "name": "Penance",
      "display": "bar",
      "source": "buff_combatv2_buff_penance",
      "colour": "B7B628FF",
      "anchor": "centre",
      "y": -120,
      "texts": [{ "key": 1, "timeFormat": "clock" }],
      "hideWhenEmpty": true,
      "showIcon": true,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
    {
        name = "Overload Reminder",
        description = "Show when your overload has expired, or is about to",
        iconSource = "buff_combatv2_overload_dummy_ability",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 1625,
      "name": "Overload Reminder",
      "display": "icon",
      "source": "buff_combatv2_overload_dummy_ability",
      "colour": "27AE60FF",
      "anchor": "centre",
      "conditions": [
        {
          "key": 1,
          "match": "all",
          "checks": [{ "kind": "active", "op": "lt", "value": false }],
          "changes": [{ "value": "FFFD00FF", "property": "borderColour" }]
        }
      ],
      "texts": [{ "key": 1 }],
      "width": 60,
      "height": 60,
      "invertSwipe": true,
      "hideWhileActive": true,
      "showActiveBelow": 15,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
    {
        name = "Item Cooldowns",
        description = "Shows how long until Enhanced Excalibur and Ritual Shard are ready",
        iconSource = "buff_combatv2_excalibur_active",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 2146,
      "name": "Item Cooldowns",
      "display": "dynamicGroup",
      "anchor": "centre",
      "grow": "horizontal"
    },
    {
      "id": 2148,
      "group": 2146,
      "name": "Enhanced Excalibur",
      "display": "icon",
      "source": "buff_combatv2_excalibur_active",
      "colour": "E74C3CFF",
      "anchor": "centre",
      "x": 48,
      "conditions": [
        {
          "key": 1,
          "match": "all",
          "checks": [{ "kind": "active", "op": "lt", "value": false }],
          "changes": [{ "value": "798F64FF", "property": "backgroundColour" }]
        }
      ],
      "texts": [{ "key": 1, "timeFormat": "clock" }],
      "backgroundColour": "606060FF",
      "dimWhileActive": false,
      "timeFormat": "tenths"
    },
    {
      "id": 2147,
      "group": 2146,
      "name": "Ancient elven ritual shard",
      "display": "icon",
      "source": "buff_combatv2_nature_boss_prayer_restorer_active",
      "colour": "E74C3CFF",
      "anchor": "centre",
      "conditions": [
        {
          "key": 1,
          "match": "all",
          "checks": [{ "kind": "active", "op": "lt", "value": false }],
          "changes": [{ "value": "798F64FF", "property": "backgroundColour" }]
        }
      ],
      "texts": [{ "key": 1, "timeFormat": "clock" }],
      "backgroundColour": "606060FF",
      "dimWhileActive": false,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
    {
        name = "Defensive Buff Bar",
        description = "Your defensive buffs in a new buff bar",
        iconSource = "buff_combatv2_ability_defence_resonance",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 2026,
      "name": "Defensives Buff Bar",
      "display": "dynamicGroup",
      "anchor": "centre",
      "y": -1,
      "grow": "horizontal"
    },
    {
      "id": 2034,
      "group": 2026,
      "name": "Divert",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_divert",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": -75,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2035,
      "group": 2026,
      "name": "Resonance",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_resonance",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": -25,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2138,
      "group": 2026,
      "name": "Disruption Shield",
      "display": "icon",
      "source": "buff_magic_disruption_shield",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": 25,
      "y": -213,
      "texts": [
        {
          "showText": false,
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "backgroundColour": "2C2C2CFF",
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2027,
      "group": 2026,
      "name": "Anticipation",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_anticipation",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": -125,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2028,
      "group": 2026,
      "name": "Freedom",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_freedom",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": -75,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2032,
      "group": 2026,
      "name": "Devotion",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_devotion",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": -25,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2029,
      "group": 2026,
      "name": "Reflect",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_reflect",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": -25,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2030,
      "group": 2026,
      "name": "Barricade",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_barricade",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": 25,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2031,
      "group": 2026,
      "name": "Immortality",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_heroism",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": 75,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    },
    {
      "id": 2033,
      "group": 2026,
      "name": "Rejuvenate",
      "display": "icon",
      "source": "buff_combatv2_ability_defence_resurgence",
      "colour": "27AE60FF",
      "anchor": "centre",
      "x": -25,
      "y": -213,
      "texts": [
        {
          "y": -25,
          "textSize": 27,
          "decimalsBelow": 0,
          "key": 1,
          "timeFormat": "seconds"
        }
      ],
      "width": 50,
      "height": 50,
      "borderThickness": 2,
      "swipeStyle": "none",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
    {
        name = "Quiver Ammo",
        description = "Show the ammo currently selected in your Pernix quiver",
        iconSource = "buff_combatv2_buff_quiver_active_ammo",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 1230,
      "name": "Current Quiver Ammo",
      "display": "icon",
      "source": "buff_combatv2_buff_quiver_active_ammo",
      "colour": "27AE60FF",
      "anchor": "centre",
      "textColour": "FFE500FF",
      "textSize": 24,
      "decimalsBelow": 3,
      "texts": [{ "textSize": 13, "textTemplate": "$ammo", "key": 1 }],
      "load": {
        "options": {
          "weaponStyle": { "enabled": true, "value": "ranged" },
          "wearing": { "enabled": true, "value": "AMMO", "item": 52532 }
        }
      },
      "width": 60,
      "height": 60,
      "backgroundColour": "00000000",
      "borderColour": "FFFFFF00",
      "borderThickness": 0,
      "swipeStyle": "none",
      "swipeColour": "0A0A0A72",
      "invertSwipe": true,
      "hideWhileInactive": true,
      "showActiveBelow": 180,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
    {
        name = "Stalled Ability",
        description = "The ability you have stalled, with a timer until you drop combat",
        iconSource = "cooldown_magic_tsunami",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 1626,
      "name": "Stalled ability",
      "display": "icon",
      "source": "stalled_ability",
      "colour": "F39C12FF",
      "anchor": "centre",
      "textFont": "museo_sans_regular",
      "textSize": 11,
      "decimalsBelow": 120,
      "texts": [
        {
          "textFont": "museo_sans_bold",
          "textSize": 27,
          "decimalsBelow": 3,
          "key": 1
        }
      ],
      "width": 64,
      "height": 64,
      "invertSwipe": true,
      "hideWhileInactive": true,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
}

return EXAMPLES
