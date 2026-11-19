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
local wornEquipment = require("GameData/Trackers/worn-equipment")
local conditionsTab = require("UI/Editor/conditions-tab")
local uiConstants = require("UI/ui-constants")

local loadTab = {}

local ADD_BUTTON_WIDTH = 200
-- Passed to edit for a change that adds or removes controls, so the tab is rebuilt.
local REBUILD = true
local ITEM_GAP = uiConstants.ITEM_GAP
local HINT_HEIGHT, HINT_LINES = 40, 2
local HALF = splitRow.HALF

--- The aura's setting for an option, made (off, at its default) if missing.
---@param aura Aura Changed in place.
---@param option LoadOption
---@return LoadSetting
local function settingFor(aura, option)
    aura.load = aura.load or {}
    aura.load.options = aura.load.options or {}
    local setting = aura.load.options[option.id]
    if setting == nil then
        setting = { enabled = false, value = loadOptions.DefaultValue(option) }
        aura.load.options[option.id] = setting
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
            if not row.option.picksItem then
                setField(row, "value", choiceID)
                return
            end

            -- A new slot clears the item, and the item picker is rebuilt for it.
            row.edit(function()
                local setting = settingFor(row.aura, row.option)
                setting.value, setting.item = choiceID, nil
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

--- Adds Ability unlocked's Unlocked/Not unlocked dropdown.
---@param row OptionRow
local function addUnlockedCombo(row)
    choiceCombo.Add(row.view, inRightHalf(row, {
        choices = loadOptions.UNLOCKED_CHOICES,
        value = row.saved.unlocked ~= false,
        onChange = function(unlocked) setField(row, "unlocked", unlocked) end,
    }))
end

--- Adds the operator and number a comparing option (Skill level) tests against.
---@param row OptionRow
local function addComparison(row)
    comparisonInput.Add(row.view, {
        x = row.rightX,
        xAnchor = HALF,
        op = row.saved.op or loadOptions.DEFAULT_OP,
        value = row.saved.number or loadOptions.DEFAULT_NUMBER,
        onOperator = function(operatorID) setField(row, "op", operatorID) end,
        onValue = function(number) setField(row, "number", number) end,
    })
end

--- Adds Item equipped's item picker for the chosen slot, if it's a known one.
---@param row OptionRow
local function addItemPicker(row)
    local slot = wornEquipment.SLOTS[row.value]
    if slot == nil then
        return
    end

    itemPicker.Add(row.view, inRightHalf(row, {
        slot = slot,
        itemID = row.saved.item,
        onPick = function(itemID) setField(row, "item", itemID, REBUILD) end,
    }))
end

--- Adds a fixed option's checkbox and, once ticked, its value's dropdown, with
--- what the option also needs beside it (the hands, an item, or "is" and what
--- it must be).
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

    local hasIs = option.picksUnlocked or option.readNumber ~= nil
    local isSplit = hasIs or option.picksHands or option.picksItem
    row.value = saved.value
    row.halfWidth, row.rightX = splitRow.Halves(view, hasIs)
    addValueCombo(row, choices, isSplit)

    if option.picksHands then
        addHandsCombo(row)
    end

    if hasIs then
        splitRow.AddIs(view)
    end

    if option.picksUnlocked then
        addUnlockedCombo(row)
    end

    if option.readNumber ~= nil then
        addComparison(row)
    end

    if option.picksItem then
        addItemPicker(row)
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
