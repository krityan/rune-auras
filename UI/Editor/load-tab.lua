-- The aura editor's Load tab: what decides whether the aura loads (see
-- AuraLoad). Each fixed option is a checkbox that turns it on, with its
-- value below; then custom checks, built as a condition's are.

local auraStore = require("Auras/Store/aura-store")
local conditions = require("Auras/Registries/conditions")
local dataSources = require("Auras/Registries/data-sources")
local loadOptions = require("Auras/Registries/load-options")
local choiceCombo = require("UI/Controls/choice-combo")
local conditionsTab = require("UI/Editor/conditions-tab")
local uiConstants = require("UI/ui-constants")

local loadTab = {}

local ADD_BUTTON_WIDTH = 200
-- Passed to edit for a change that adds or removes controls, so the tab is rebuilt.
local REBUILD = true
local ITEM_GAP = uiConstants.ITEM_GAP
local HINT_HEIGHT, HINT_LINES = 40, 2

--- The aura's setting for an option, made (off, at its default) if missing.
---@param aura Aura Changed in place.
---@param option LoadOption
---@return LoadSetting
local function settingFor(aura, option)
    aura.load = aura.load or {}
    aura.load.options = aura.load.options or {}
    local setting = aura.load.options[option.id]
    if setting == nil then
        setting = { enabled = false, value = option.default }
        aura.load.options[option.id] = setting
    end
    return setting
end

--- Adds a fixed option: its checkbox, and its value's dropdown under it,
--- greyed out until ticked.
---@param view EditorView
---@param aura Aura
---@param option LoadOption
---@param isFirst boolean Whether it's the first, with no gap above.
---@param edit fun(change: fun(), rebuild: boolean?)
local function buildOption(view, aura, option, isFirst, edit)
    local load = aura.load
    local saved = load and load.options and load.options[option.id]
    local enabled = saved ~= nil and saved.enabled == true
    local value = nil
    if saved ~= nil then value = saved.value end
    if value == nil then value = option.default end
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
    -- Its checkbox names it, so no label.
    choiceCombo.Add(view, {
        choices = option.choices,
        value = value,
        disabled = not enabled,
        onChange = function(choiceID) edit(function() settingFor(aura, option).value = choiceID end) end,
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
        auraStore.Edit(auraID, change)
        context.onChanged()
        if rebuild then context.requestRebuild() end
    end

    -- The fixed options sit at the top for now; they'll be grouped into
    -- sections once there are more of them.
    local view = context.view()
    for index, option in ipairs(loadOptions.OPTIONS) do
        buildOption(view, aura, option, index == 1, edit)
    end

    -- Custom checks: the conditions tab's check controls, over the load's
    -- own list.
    context.section("loadChecks", "Custom checks", function(view)
        local holder = { checks = (aura.load and aura.load.checks) or {} }
        local function editChecks(change, rebuild)
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
