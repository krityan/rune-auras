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
local BUTTON_WIDTH = 200
local ITEM_GAP = uiConstants.ITEM_GAP

---@class ItemPickerOptions
---@field slot integer One of wornEquipment.SLOTS.
---@field itemID integer? The item picked now; nil shows "Choose an item...".
---@field onPick fun(itemID: integer) Called when a different item is picked.
---@field width number? The typeahead's width, on a row of its own.
---@field widthAnchor number?

---@type table<integer, string[]> Slot to its items' labels as shown, made once: every edit in the Load tab rebuilds the picker.
local labelsBySlot = {}

--- A slot's items' labels as shown, by their places in `items`.
---@param slot integer
---@param items NamedItem[] The slot's items.
---@return string[]
local function slotLabels(slot, items)
    local labels = labelsBySlot[slot]
    if labels == nil then
        labels = {}

        for index, item in ipairs(items) do
            labels[index] = gameText.Plain(item.label)
        end

        labelsBySlot[slot] = labels
    end

    return labels
end

--- Typeahead entries for a slot's items, by name. They're new tables each
--- time, as the combo box changes its entries.
---@param labels string[] The slot's labels (see slotLabels).
---@return table[] entries Entry ids are places in the slot's items.
local function itemEntries(labels)
    local entries = {}
    for index, label in ipairs(labels) do
        entries[index] = { label = label, id = index, order = ITEM_ORDER }
    end

    return entries
end

--- Adds the typeahead to a view. It's given the slot's whole list only when
--- it's first opened, as the Load tab can show many of them, each of
--- thousands of items.
---@param view EditorView
---@param options ItemPickerOptions
function itemPicker.Add(view, options)
    local items = itemSlots.Named(options.slot)
    local labels = slotLabels(options.slot, items)
    local selected = nil
    for index, item in ipairs(items) do
        if item.id == options.itemID then
            selected = index
        end
    end

    -- An entry the slot's list doesn't have: a worn item added to the game
    -- since the list was made, picked with "Use worn item", or "Choose an
    -- item..." until one is picked.
    local extra = nil
    if selected == nil and options.itemID ~= nil then
        selected = #items + 1
        local name = gameApi.ItemName(options.itemID) or ("Item " .. options.itemID)
        extra = { label = gameText.Plain(name), id = selected, order = ITEM_ORDER }
    elseif selected == nil then
        selected = PLACEHOLDER_ENTRY_ID
        extra = { label = "Choose an item...", id = selected, order = PLACEHOLDER_ORDER }
    end

    local shown = extra or { label = labels[selected], id = selected, order = ITEM_ORDER }

    --- Every entry, the extra one last.
    ---@return table[]
    local function makeEntries()
        local entries = itemEntries(labels)
        if extra ~= nil then
            entries[#entries + 1] = extra
        end

        return entries
    end

    -- Under the slot it's for, so no label.
    fastTypeahead.AddDeferred(view, {
        width = options.width,
        widthAnchor = options.widthAnchor,
        entries = { shown },
        selectedID = selected,
        tooltip = "Type part of its name",
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then
                return
            end

            local item = items[entryID]
            if item == nil or item.id == options.itemID then
                return
            end

            options.onPick(item.id)
        end,
    }, makeEntries)
end

--- Adds "Use worn item", which picks whatever is worn in the slot now: the
--- way to pick an item the typeahead's list doesn't have yet (one added to
--- the game since the list was made).
---@param view EditorView
---@param slot integer One of wornEquipment.SLOTS.
---@param onPick fun(itemID: integer) Called with the worn item, if there is one.
function itemPicker.AddWornButton(view, slot, onPick)
    view:AddFancyButton("Use worn item", function()
        local worn = wornEquipment.Item(slot)
        if worn ~= nil then
            onPick(worn)
        end
    end, { width = BUTTON_WIDTH, marginTop = ITEM_GAP })
end

return itemPicker
