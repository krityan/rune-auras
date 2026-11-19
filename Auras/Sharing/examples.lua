-- The example auras Import's Examples tab lists, each with its export, a
-- name, a description and the data source whose icon shows beside it.

---@class AuraExample
---@field name string
---@field description string
---@field iconSource string A data source id, whose icon shows beside it.
---@field export string Its export, as Import reads it.

---@type AuraExample[]
local EXAMPLES = {
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
      "id": 803,
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
    {
        name = "Overload Reminder",
        description = "Show when your overload has expired, or is about to",
        iconSource = "buff_combatv2_overload_dummy_ability",
        export = [[
{
  "runeAuras": 3,
  "records": [
    {
      "id": 1232,
      "name": "Overload Reminder",
      "display": "icon",
      "source": "buff_combatv2_overload_dummy_ability",
      "colour": "27AE60FF",
      "anchor": "centre",
      "texts": [{ "key": 1 }],
      "invertSwipe": true,
      "hideWhileActive": true,
      "showActiveBelow": 15,
      "timeFormat": "tenths"
    }
  ]
}
]],
    },
}

return EXAMPLES
