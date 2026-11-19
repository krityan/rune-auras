-- The aura editor's Load tab: what decides whether the aura loads (see
-- AuraLoad). Each fixed option is a checkbox that turns it on, with its
-- value below (and for Item equipped, the item); then custom checks, built as a
-- condition's are.

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

--- Adds a fixed option: its checkbox, and once ticked (which rebuilds the
--- tab), its value's dropdown under it, with on the same row: the hands
--- (Weapon style), the item picker's typeahead, its "Use worn item" below
--- (Item equipped; changing the slot clears the item), or "is" and an
--- operator and number (Skill level) or Unlocked/Not unlocked (Ability
--- unlocked).
---@param view EditorView
---@param aura Aura
---@param option LoadOption
---@param isFirst boolean Whether it's the first, with no gap above.
---@param edit fun(change: fun(), rebuild: boolean?)
local function buildOption(view, aura, option, isFirst, edit)
    local load = aura.load
    local saved = load and load.options and load.options[option.id]
    local enabled = saved ~= nil and saved.enabled == true
    local choices = loadOptions.Choices(option)
    local value = nil
    if saved ~= nil then
        value = saved.value
    end

    -- What the dropdown shows for a value it doesn't list: nothing picked
    -- (ticked before a list read from the game had loaded), or a choice it
    -- no longer has. Either is what's tested, so it isn't shown as another.
    local missingLabel = value == nil and "Choose one..." or "Not listed"

    view:AddCheckboxButton({
        {
            text = option.label,
            value = option.id,
            selected = enabled,
        },
    }, {
        marginTop = not isFirst and ITEM_GAP or nil,
        onChange = function(_, _, _, selected)
            edit(function() settingFor(aura, option).enabled = selected == true end, REBUILD)
        end,
    })

    -- A list read from the game is empty until its config can be read.
    if not enabled or #choices == 0 then
        return
    end

    -- With something beside it (the hands, the item, or "is" and what it must
    -- be: Unlocked/Not unlocked, or a comparison), it's the row's left half.
    local hasIs = option.picksUnlocked or option.readNumber ~= nil
    local isSplit = hasIs or option.picksHands or option.picksItem
    local halfWidth, rightX = splitRow.Halves(view, hasIs)

    -- Its checkbox names it, so no label.
    choiceCombo.Add(view, {
        x = isSplit and view.contentPadding or nil,
        width = isSplit and halfWidth or nil,
        widthAnchor = isSplit and HALF or nil,
        choices = choices,
        value = value,
        missingLabel = missingLabel,
        onChange = function(choiceID)
            if not option.picksItem then
                edit(function() settingFor(aura, option).value = choiceID end)
                return
            end

            edit(function()
                local setting = settingFor(aura, option)
                setting.value, setting.item = choiceID, nil
            end, REBUILD)
        end,
    })

    if option.picksHands then
        local hands = saved ~= nil and saved.hands or nil
        if not isChoice(loadOptions.HANDS_CHOICES, hands) then
            hands = loadOptions.DEFAULT_HANDS
        end

        choiceCombo.Add(view, {
            inline = true,
            x = rightX,
            xAnchor = HALF,
            width = halfWidth,
            widthAnchor = HALF,
            choices = loadOptions.HANDS_CHOICES,
            value = hands,
            onChange = function(choiceID) edit(function() settingFor(aura, option).hands = choiceID end) end,
        })
    end

    if hasIs then
        splitRow.AddIs(view)
    end

    if option.picksUnlocked then
        choiceCombo.Add(view, {
            inline = true,
            x = rightX,
            xAnchor = HALF,
            width = halfWidth,
            widthAnchor = HALF,
            choices = loadOptions.UNLOCKED_CHOICES,
            value = saved.unlocked ~= false,
            onChange = function(unlocked) edit(function() settingFor(aura, option).unlocked = unlocked end) end,
        })
    end

    if option.readNumber ~= nil then
        comparisonInput.Add(view, {
            x = rightX,
            xAnchor = HALF,
            op = saved.op or loadOptions.DEFAULT_OP,
            value = saved.number or loadOptions.DEFAULT_NUMBER,
            onOperator = function(operatorID) edit(function() settingFor(aura, option).op = operatorID end) end,
            onValue = function(number) edit(function() settingFor(aura, option).number = number end) end,
        })
    end

    local slot = option.picksItem and wornEquipment.SLOTS[value] or nil
    if slot == nil then
        return
    end

    itemPicker.Add(view, {
        inline = true,
        x = rightX,
        xAnchor = HALF,
        width = halfWidth,
        widthAnchor = HALF,
        slot = slot,
        itemID = saved.item,
        onPick = function(itemID) edit(function() settingFor(aura, option).item = itemID end, REBUILD) end,
    })
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
    -- own list.
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
