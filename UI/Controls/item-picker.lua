-- Picking an item worn in one slot: a typeahead of the slot's items, as the
-- data source picker's, and a button taking whatever is worn there now.

local gameApi = require("GameData/game-api")
local itemSlots = require("GameData/Catalogues/item-slots")
local wornEquipment = require("GameData/Trackers/worn-equipment")
local gameText = require("Auras/Helpers/game-text")
local fastTypeahead = require("UI/PrettyUI/fast-typeahead")
local uiConstants = require("UI/ui-constants")

local itemPicker = {}

-- Combo entry id and typeahead order for "Choose an item...", shown before
-- the items until one of this slot is picked (see sourcePicker).
local PLACEHOLDER_ENTRY_ID = 0
local PLACEHOLDER_ORDER, ITEM_ORDER = 0, 1
-- The most matches the dropdown shows at once. A slot has up to ~5,000
-- items, and every row shown is several components (see fastTypeahead).
local MAX_SHOWN = 100
local BUTTON_WIDTH = 200
local ITEM_GAP = uiConstants.ITEM_GAP

---@class ItemPickerOptions
---@field slot integer One of wornEquipment.SLOTS.
---@field itemID integer? The item picked now.
---@field onPick fun(itemID: integer) Called when a different item is picked.

---@type table<integer, string[]> Slot to its items' labels as shown, made once: every edit in the Load tab rebuilds the picker.
local labelsBySlot = {}

--- Typeahead entries for a slot's items, by name. They're new tables each
--- time, as the combo box changes its entries.
---@param slot integer
---@param items NamedItem[] The slot's items.
---@return table[] entries Entry ids are places in `items`.
local function itemEntries(slot, items)
    local labels = labelsBySlot[slot]
    if labels == nil then
        labels = {}
        for index, item in ipairs(items) do labels[index] = gameText.Plain(item.label) end
        labelsBySlot[slot] = labels
    end
    local entries = {}
    for index, label in ipairs(labels) do
        entries[index] = { label = label, id = index, order = ITEM_ORDER }
    end
    return entries
end

--- Adds the typeahead and "Use worn item" to a view.
---@param view EditorView
---@param options ItemPickerOptions
function itemPicker.Add(view, options)
    local items = itemSlots.Named(options.slot)
    local entries = itemEntries(options.slot, items)
    local selected = nil
    for index, item in ipairs(items) do
        if item.id == options.itemID then selected = index end
    end
    -- A worn item the list doesn't have (added to the game since it was made)
    -- can still be picked with "Use worn item", so it gets an entry of its own.
    if selected == nil and options.itemID ~= nil then
        selected = #items + 1
        local name = gameApi.ItemName(options.itemID) or ("Item " .. options.itemID)
        entries[selected] = { label = gameText.Plain(name), id = selected, order = ITEM_ORDER }
    end
    if selected == nil then
        entries[#entries + 1] = { label = "Choose an item...", id = PLACEHOLDER_ENTRY_ID, order = PLACEHOLDER_ORDER }
        selected = PLACEHOLDER_ENTRY_ID
    end
    -- Under the slot it's for, so no label.
    fastTypeahead.Add(view, {
        marginTop = ITEM_GAP,
        entries = entries,
        selectedID = selected,
        tooltip = "Type part of its name. Shows the first " .. MAX_SHOWN .. " matches.",
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local item = items[entryID]
            if item == nil or item.id == options.itemID then return end
            options.onPick(item.id)
        end,
    }, MAX_SHOWN)
    view:AddFancyButton("Use worn item", function()
        local worn = wornEquipment.Item(options.slot)
        if worn ~= nil and worn ~= options.itemID then options.onPick(worn) end
    end, { width = BUTTON_WIDTH, marginTop = ITEM_GAP })
end

return itemPicker
