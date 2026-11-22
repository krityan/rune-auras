-- The aura editor's Load tab: what decides whether the aura loads (see
-- AuraLoad). Each fixed option is a checkbox with its value below, then come
-- custom checks, built as a condition's are.

local auraStore = require("Auras/Store/aura-store")
local conditions = require("Auras/Registries/conditions")
local dataSources = require("Auras/Registries/data-sources")
local loadOptions = require("Auras/Registries/load-options")
local choiceCombo = require("UI/Controls/choice-combo")
local comparisonInput = require("UI/Controls/comparison-input")
local splitRow = require("UI/Controls/split-row")
local itemPicker = require("UI/Controls/item-picker")
local heroIcons = require("UI/Controls/hero-icons")
local wornEquipment = require("GameData/Trackers/worn-equipment")
local conditionsTab = require("UI/Editor/conditions-tab")
local uiConstants = require("UI/ui-constants")

local loadTab = {}

local ADD_BUTTON_WIDTH = 200
-- Passed to edit for a change that adds or removes controls, so the tab is rebuilt.
local REBUILD = true
local ITEM_GAP = uiConstants.ITEM_GAP
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local GAP = uiConstants.GAP
-- The room a delete button takes at the end of a row.
local DELETE_SPACE = BUTTON_SIZE + GAP
local HINT_HEIGHT, HINT_LINES = 40, 2
local HALF = splitRow.HALF

--- The aura's setting for an option, made (off, at its default, or with no
--- lines) if missing.
---@param aura Aura Changed in place.
---@param option LoadOption
---@return LoadSetting
local function settingFor(aura, option)
    aura.load = aura.load or {}
    aura.load.options = aura.load.options or {}
    local setting = aura.load.options[option.id]
    if setting == nil then
        setting = { enabled = false }
        aura.load.options[option.id] = setting

        if not option.hasLines then
            setting.value = loadOptions.DefaultValue(option)
        end
    end

    return setting
end

--- Whether a value is one of a dropdown's choices. An imported aura can hold
--- any string.
---@param choices { id: any, label: string }[]
---@param value any
---@return boolean
local function isChoice(choices, value)
    for _, choice in ipairs(choices) do
        if choice.id == value then
            return true
        end
    end

    return false
end

--- A fixed option's controls as they're built: what each one reads and changes.
---@class OptionRow
---@field view EditorView
---@field aura Aura
---@field option LoadOption
---@field saved LoadSetting? nil until the option is first ticked.
---@field edit fun(change: fun(), rebuild: boolean?)
---@field value any? The saved value.
---@field halfWidth number? Set once the option is ticked.
---@field rightX number? Where the right half starts.
---@field middleX number? Where "is" goes, for an option with lines (see splitRow.Halves).

--- Saves one field of an option's setting.
---@param row OptionRow
---@param field string A LoadSetting field.
---@param value any
---@param rebuild boolean? REBUILD for a change that adds or removes controls.
local function setField(row, field, value, rebuild)
    row.edit(function() settingFor(row.aura, row.option)[field] = value end, rebuild)
end

--- Places a control in the right half of the row, on the same line.
---@param row OptionRow
---@param fields table The control's other options; changed in place.
---@return table fields
local function inRightHalf(row, fields)
    fields.inline = true
    fields.x = row.rightX
    fields.xAnchor = HALF
    fields.width = row.halfWidth
    fields.widthAnchor = HALF
    return fields
end

--- Adds the checkbox that turns an option on, which rebuilds the tab.
---@param row OptionRow
---@param enabled boolean
---@param isFirst boolean Whether it's the first, with no gap above.
local function addCheckbox(row, enabled, isFirst)
    row.view:AddCheckboxButton({
        {
            text = row.option.label,
            value = row.option.id,
            selected = enabled,
        },
    }, {
        marginTop = not isFirst and ITEM_GAP or nil,
        onChange = function(_, _, _, selected)
            setField(row, "enabled", selected == true, REBUILD)
        end,
    })
end

--- Adds the dropdown for an option's value, in the row's left half when
--- something sits beside it. Its checkbox names it, so it has no label.
---@param row OptionRow
---@param choices Choice[]
---@param isSplit boolean
local function addValueCombo(row, choices, isSplit)
    -- What the dropdown shows for a value it doesn't list: nothing picked
    -- (ticked before a list read from the game had loaded), or a choice it
    -- no longer has. Either is what's tested, so it isn't shown as another.
    local missingLabel = row.value == nil and "Choose one..." or "Not listed"

    choiceCombo.Add(row.view, {
        x = isSplit and row.view.contentPadding or nil,
        width = isSplit and row.halfWidth or nil,
        widthAnchor = isSplit and HALF or nil,
        choices = choices,
        value = row.value,
        missingLabel = missingLabel,
        onChange = function(choiceID)
            if not row.option.picksItems then
                setField(row, "value", choiceID)
                return
            end

            -- A new slot clears the items, none of which can be worn there,
            -- and the item pickers are rebuilt for it.
            row.edit(function()
                local setting = settingFor(row.aura, row.option)
                setting.value, setting.items = choiceID, nil
            end, REBUILD)
        end,
    })
end

--- Adds Weapon style's hands dropdown. A saved value it doesn't list shows as
--- the default.
---@param row OptionRow
local function addHandsCombo(row)
    local hands = row.saved.hands
    if not isChoice(loadOptions.HANDS_CHOICES, hands) then
        hands = loadOptions.DEFAULT_HANDS
    end

    choiceCombo.Add(row.view, inRightHalf(row, {
        choices = loadOptions.HANDS_CHOICES,
        value = hands,
        onChange = function(choiceID) setField(row, "hands", choiceID) end,
    }))
end

--- Adds a delete button (the red Heroicon trash, as the section headers'
--- is) pinned at the right of the row before it.
---@param view EditorView
---@param onClick fun()
local function addDeleteButton(view, onClick)
    heroIcons.AddInline(view, "trash", onClick, {
        x = -(view.contentPadding + BUTTON_SIZE),
        xAnchor = 1,
        rowHeight = uiConstants.FIELD_HEIGHT,
        tooltip = "Remove",
        colour = uiConstants.DANGER_RGBA,
    })
end

--- Adds Item equipped's Is/Is not dropdown.
---@param row OptionRow
local function addWornCombo(row)
    choiceCombo.Add(row.view, inRightHalf(row, {
        choices = loadOptions.WORN_CHOICES,
        value = row.saved.worn ~= false,
        onChange = function(worn) setField(row, "worn", worn) end,
    }))
end

--- Changes Item equipped's list of items, then rebuilds the tab to show it.
---@param row OptionRow
---@param change fun(items: integer[]) Changes the saved list in place.
local function editItems(row, change)
    row.edit(function()
        local setting = settingFor(row.aura, row.option)
        setting.items = setting.items or {}
        change(setting.items)
    end, REBUILD)
end

---@param items integer[]
---@param itemID integer
---@return boolean
local function isListed(items, itemID)
    for _, listed in ipairs(items) do
        if listed == itemID then
            return true
        end
    end

    return false
end

--- Adds an item to Item equipped's list, unless it's there already or the
--- list is full.
---@param row OptionRow
---@param itemID integer
local function addItem(row, itemID)
    editItems(row, function(items)
        if not isListed(items, itemID) and #items < loadOptions.MAX_ROWS then
            items[#items + 1] = itemID
        end
    end)
end

--- Adds a row of Item equipped's list: an item's typeahead with a delete
--- button, or the empty row at the end, where picking an item adds it.
---@param row OptionRow
---@param slot integer
---@param items integer[] The saved list.
---@param index integer? The item's place in the list; nil for the empty row.
local function addItemRow(row, slot, items, index)
    -- Every row leaves room for the button, so the typeaheads line up.
    itemPicker.Add(row.view, {
        slot = slot,
        itemID = index ~= nil and items[index] or nil,
        width = -(row.view.contentPadding * 2 + DELETE_SPACE),
        widthAnchor = 1,
        onPick = function(itemID)
            if index == nil then
                addItem(row, itemID)
                return
            end

            editItems(row, function(saved)
                if not isListed(saved, itemID) then
                    saved[index] = itemID
                end
            end)
        end,
    })

    if index == nil then
        return
    end

    addDeleteButton(row.view, function()
        editItems(row, function(saved) table.remove(saved, index) end)
    end)
end

--- Adds Item equipped's items for the chosen slot, if it's a known one: a
--- row each, then an empty row and "Use worn item" to add another, until
--- the list is full.
---@param row OptionRow
local function addItemList(row)
    local slot = wornEquipment.SLOTS[row.value]
    if slot == nil then
        return
    end

    local items = row.saved.items or {}
    for index = 1, #items do
        addItemRow(row, slot, items, index)
    end

    if #items >= loadOptions.MAX_ROWS then
        return
    end

    addItemRow(row, slot, items, nil)
    itemPicker.AddWornButton(row.view, slot, function(itemID) addItem(row, itemID) end)
end

--- Changes an option's lines, then rebuilds the tab to show them.
---@param row OptionRow
---@param change fun(lines: LoadLine[]) Changes the saved lines in place.
local function editLines(row, change)
    row.edit(function()
        local setting = settingFor(row.aura, row.option)
        setting.lines = setting.lines or {}
        change(setting.lines)
    end, REBUILD)
end

--- Saves one field of an option's line, without rebuilding: the control
--- that changed it already shows it.
---@param row OptionRow
---@param index integer The line's place.
---@param field string A LoadLine field.
---@param value any
local function setLineField(row, index, field, value)
    row.edit(function() settingFor(row.aura, row.option).lines[index][field] = value end)
end

--- Adds a line of an option with lines: its choice, then "is" and what it
--- must be (Unlocked or Not unlocked, or a comparison), then a delete
--- button; or the empty row at the end, only a choice, where picking one
--- adds a line.
---@param row OptionRow
---@param choices Choice[]
---@param lines LoadLine[] The saved lines.
---@param index integer? The line's place; nil for the empty row.
local function addLineRow(row, choices, lines, index)
    local view, option = row.view, row.option
    local line = index ~= nil and lines[index] or nil

    -- A choice a line holds that the list doesn't (renamed, or imported)
    -- shows as missing, as it's what's tested.
    choiceCombo.Add(view, {
        x = view.contentPadding,
        width = row.halfWidth,
        widthAnchor = HALF,
        choices = choices,
        value = line and line.value,
        missingLabel = line == nil and "Choose one..." or "Not listed",
        onChange = function(choiceID)
            if index ~= nil then
                setLineField(row, index, "value", choiceID)
                return
            end

            editLines(row, function(saved)
                if #saved < loadOptions.MAX_ROWS then
                    saved[#saved + 1] = { value = choiceID }
                end
            end)
        end,
    })

    if line == nil then
        return
    end

    splitRow.AddIs(view, row.middleX)

    if option.picksUnlocked then
        choiceCombo.Add(view, inRightHalf(row, {
            choices = loadOptions.UNLOCKED_CHOICES,
            value = line.unlocked ~= false,
            onChange = function(unlocked) setLineField(row, index, "unlocked", unlocked) end,
        }))
    end

    if option.readNumber ~= nil then
        comparisonInput.Add(view, {
            x = row.rightX,
            xAnchor = HALF,
            endSpace = DELETE_SPACE,
            op = line.op or loadOptions.DEFAULT_OP,
            value = line.number or loadOptions.DEFAULT_NUMBER,
            onOperator = function(operatorID) setLineField(row, index, "op", operatorID) end,
            onValue = function(number) setLineField(row, index, "number", number) end,
        })
    end

    addDeleteButton(view, function()
        editLines(row, function(saved) table.remove(saved, index) end)
    end)
end

--- Adds an option's lines, a row each, then an empty row to add another,
--- until there are MAX_ROWS.
---@param row OptionRow
---@param choices Choice[]
local function addLines(row, choices)
    row.halfWidth, row.rightX, row.middleX = splitRow.Halves(row.view, true, DELETE_SPACE)
    local lines = row.saved.lines or {}
    for index = 1, #lines do
        addLineRow(row, choices, lines, index)
    end

    if #lines < loadOptions.MAX_ROWS then
        addLineRow(row, choices, lines, nil)
    end
end

--- Adds a fixed option's checkbox and, once ticked, its value's dropdown, with
--- what the option also needs beside it (the hands, or Is or Is not and the
--- items under them), or its lines.
---@param view EditorView
---@param aura Aura
---@param option LoadOption
---@param isFirst boolean Whether it's the first, with no gap above.
---@param edit fun(change: fun(), rebuild: boolean?)
local function buildOption(view, aura, option, isFirst, edit)
    local load = aura.load
    local saved = load and load.options and load.options[option.id]
    local enabled = saved ~= nil and saved.enabled == true
    ---@type OptionRow
    local row = { view = view, aura = aura, option = option, saved = saved, edit = edit }
    addCheckbox(row, enabled, isFirst)

    if not enabled then
        return
    end

    -- A list read from the game is empty until its config can be read.
    local choices = loadOptions.Choices(option)
    if #choices == 0 then
        return
    end

    if option.hasLines then
        addLines(row, choices)
        return
    end

    local isSplit = option.picksHands or option.picksItems
    row.value = saved.value
    row.halfWidth, row.rightX = splitRow.Halves(view, false)
    addValueCombo(row, choices, isSplit)

    if option.picksHands then
        addHandsCombo(row)
    end

    if option.picksItems then
        addWornCombo(row)
        addItemList(row)
    end
end

--- A new load check. It starts with a data type but no source, so it
--- doesn't count (and unload the aura while it's being set up) until one is
--- picked. The type list also has "This aura's data source" for auras with one.
---@return Check
local function newCheck()
    local check = conditions.NewCheck()
    check.sourceType = dataSources.Types()[1].id
    return check
end

--- Builds the tab for an aura.
---@param aura Aura
---@param context EditorTabContext
function loadTab.Build(aura, context)
    local auraID = aura.id

    --- Makes a change to the aura's load, then saves and reports it.
    ---@param change fun()
    ---@param rebuild boolean? Rebuild the tab after, for a change that adds or removes controls.
    local function edit(change, rebuild)
        if change ~= nil then
            auraStore.Edit(auraID, change)
            context.onChanged()
        end

        if rebuild then
            context.requestRebuild()
        end
    end

    -- The fixed options sit at the top for now; they'll be grouped into
    -- sections once there are more of them.
    local optionsView = context.view()
    for index, option in ipairs(loadOptions.OPTIONS) do
        buildOption(optionsView, aura, option, index == 1, edit)
    end

    -- Custom checks: the conditions tab's check controls, over the load's
    -- list of checks.
    context.section("loadChecks", "Custom checks", function(view)
        local holder = { checks = (aura.load and aura.load.checks) or {} }

        local function editChecks(change, rebuild)
            if change == nil then
                return edit(nil, rebuild)
            end

            edit(function()
                change()
                aura.load = aura.load or {}
                aura.load.checks = holder.checks
            end, rebuild)
        end

        if #holder.checks == 0 then
            view:AddText({
                text = "Checks here must all pass for the aura to load, e.g. a buff being active.",
                height = HINT_HEIGHT,
                maxLines = HINT_LINES,
                colour = uiConstants.MUTED_RGBA,
            })
        end

        conditionsTab.AddChecks(view, aura, holder, editChecks)

        view:AddFancyButton("Add check", function()
            editChecks(function() holder.checks[#holder.checks + 1] = newCheck() end, REBUILD)
        end, { width = ADD_BUTTON_WIDTH, marginTop = #holder.checks > 0 and ITEM_GAP or nil })
    end)
end

return loadTab
