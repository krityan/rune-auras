-- The aura editor's Load tab (see UI/Windows/aura-editor): what decides
-- whether the aura loads (see Auras/Registries/load-options). Each fixed
-- option is a checkbox that turns it on, with its value below (only tested
-- while ticked); then custom checks, built as a condition's are (see
-- UI/Windows/conditions-tab), all of which must pass.
-- Usage (from the editor, which owns the sections and rebuilding):
--   loadTab.Build(aura, {
--       view = fn() -> a section view, for the options above the sections,
--       section = fn(id, title, build),
--       onChanged = fn(),        -- after any edit
--       requestRebuild = fn(),   -- after one that adds or removes controls
--   })

local auraStore = require("Auras/aura-store")
local conditions = require("Auras/Helpers/conditions")
local dataSources = require("Auras/Registries/data-sources")
local loadOptions = require("Auras/Registries/load-options")
local choiceCombo = require("UI/Controls/choice-combo")
local conditionsTab = require("UI/Windows/conditions-tab")
local uiConstants = require("UI/ui-constants")

local loadTab = {}

local ADD_BUTTON_WIDTH = 200
-- Space above each option after the first, as between checks.
local ITEM_GAP = uiConstants.GAP + 6

-- The aura's setting for an option, made (off, at its default) if missing.
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

-- Drops empty lists, so an aura with no options set and no checks saves no
-- load table. Unticked options keep their value, so ticking one again brings
-- back what was picked; they just aren't tested.
local function tidy(aura)
    local load = aura.load
    if load == nil then return end
    if load.options ~= nil and next(load.options) == nil then load.options = nil end
    if load.checks ~= nil and #load.checks == 0 then load.checks = nil end
    if load.options == nil and load.checks == nil then aura.load = nil end
end

local function buildOption(view, aura, option, first, edit)
    local load = aura.load
    local saved = load and load.options and load.options[option.id]
    local enabled = saved ~= nil and saved.enabled == true
    local value = saved ~= nil and saved.value
    if value == nil then value = option.default end
    view:AddCheckboxButton({
        {
            text = option.label,
            value = option.id,
            selected = enabled,
            tooltip = option.tooltip,
        },
    }, {
        marginTop = not first and ITEM_GAP or nil,
        onChange = function(_, _, _, selected)
            edit(function() settingFor(aura, option).enabled = selected == true end, true)
        end,
    })
    -- Its checkbox names it, so no label; it's greyed out until ticked.
    choiceCombo.Add(view, {
        choices = option.choices,
        value = value,
        disabled = not enabled,
        onChange = function(id) edit(function() settingFor(aura, option).value = id end) end,
    })
end

-- A new check starts with a data type but no source, so it doesn't count
-- (and unload the aura while it's being set up) until one is picked. The
-- type list also has "This aura's data source" for auras with one.
local function newCheck()
    local check = conditions.NewCheck()
    check.sourceType = dataSources.Types()[1].id
    return check
end

function loadTab.Build(aura, context)
    local auraID = aura.id
    local function edit(change, rebuild)
        change()
        tidy(aura)
        auraStore.Touch(auraID)
        auraStore.Save()
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
                height = 40,
                maxLines = 2,
                colour = uiConstants.MUTED_RGBA,
            })
        end
        conditionsTab.AddChecks(view, aura, holder, editChecks)
        view:AddFancyButton("Add check", function()
            editChecks(function() holder.checks[#holder.checks + 1] = newCheck() end, true)
        end, { width = ADD_BUTTON_WIDTH, marginTop = #holder.checks > 0 and ITEM_GAP or nil })
    end)
end

return loadTab
