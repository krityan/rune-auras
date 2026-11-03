-- The worn equipment: the item in each worn slot. Read from the worn
-- inventory when the server says it changed, so a read every frame asks the
-- game nothing.

local gameApi = require("GameData/game-api")

local wornEquipment = {}

local EVENT_ID = "runeAuras_wornEquipment"
-- The worn equipment's inventory id.
local WORN_INVENTORY = 94
-- Its number of slots.
local SLOT_COUNT = 19

--- The worn slots, 1-indexed (see itemSlots for each slot's items).
wornEquipment.SLOTS = {
    HEAD = 1,
    CAPE = 2,
    NECK = 3,
    MAIN_HAND = 4,
    BODY = 5,
    OFF_HAND = 6,
    LEGS = 8,
    HANDS = 10,
    FEET = 11,
    RING = 13,
    AMMO = 14,
    AURA = 15,
    POCKET = 18,
    WINGS = 19,
}

--- Each worn slot's name as players know it, by its SLOTS key.
wornEquipment.SLOT_LABELS = {
    HEAD = "Head",
    CAPE = "Cape",
    NECK = "Neck",
    MAIN_HAND = "Main hand",
    BODY = "Body",
    OFF_HAND = "Off-hand",
    LEGS = "Legs",
    HANDS = "Hands",
    FEET = "Feet",
    RING = "Ring",
    AMMO = "Ammo",
    AURA = "Aura",
    POCKET = "Pocket",
    WINGS = "Wings",
}

-- Whether the worn inventory changed since it was last read. True at load,
-- for a reload in game, where it arrived before the events were followed.
local stale = true
---@type table<integer, integer> Slot to the item in it; empty slots are missing.
local items = {}

--- Reads every slot. If the inventory hasn't arrived, nothing is worn
--- until InventoryAdded says it has, so it isn't asked for again each read.
local function refresh()
    stale = false
    items = {}
    local inv = gameApi.Inventory(WORN_INVENTORY)
    if inv == nil then return end
    for slot = 1, SLOT_COUNT do
        local item = gameApi.InventoryItem(inv, slot)
        local itemID = item and gameApi.ID(item)
        if itemID ~= nil and itemID >= 0 then items[slot] = itemID end
    end
end

--- The item worn in a slot.
---@param slot integer One of SLOTS.
---@return integer? itemID nil when the slot is empty or nothing is known yet.
function wornEquipment.Item(slot)
    if stale then refresh() end
    return items[slot]
end

local function inventoryID(event) return event.inv.id end

--- Marks the slots to be read again when the worn inventory changes.
---@param event table An InventoryAdded or InventoryUpdated payload.
local function onInventoryChanged(event)
    if gameApi.Read("an inventory update", inventoryID, event) == WORN_INVENTORY then stale = true end
end

--- Forgets the worn items, e.g. on leaving the game. They're read again
--- once the server sends the inventory (InventoryAdded).
function wornEquipment.Reset()
    stale = false
    items = {}
end

--- Starts following the worn inventory.
function wornEquipment.Start()
    Event.InventoryAdded.Subscribe(EVENT_ID, onInventoryChanged)
    Event.InventoryUpdated.Subscribe(EVENT_ID, onInventoryChanged)
end

--- Stops following it.
function wornEquipment.Stop()
    Event.InventoryAdded.Unsubscribe(EVENT_ID)
    Event.InventoryUpdated.Unsubscribe(EVENT_ID)
end

return wornEquipment
