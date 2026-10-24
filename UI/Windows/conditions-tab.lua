-- The aura editor's Conditions tab (see UI/Windows/aura-editor): each of the
-- aura's conditions (see Auras/Helpers/conditions) is a collapsible section
-- with buttons in its header to move it up or down, duplicate it or remove
-- it. Inside are whether all its checks must pass or any one, the checks,
-- then the property changes it makes while it passes. (They're "checks" in
-- the UI so they aren't confused with the conditions they make up.)
-- Usage (from the editor, which owns the sections and rebuilding):
--   conditionsTab.Build(aura, {
--       section = fn(id, title, build, buttons),  -- the editor's sections
--       view = fn() -> a section view,
--       onChanged = fn(),                        -- after any edit
--       requestRebuild = fn(),                   -- after one that adds or removes controls
--   })

local auraStore = require("Auras/aura-store")
local gameApi = require("GameData/game-api")
local conditions = require("Auras/Helpers/conditions")
local dataSources = require("Auras/Registries/data-sources")
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local fastTypeahead = require("UI/Controls/fast-typeahead")
local uiConstants = require("UI/ui-constants")

local conditionsTab = {}

local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local GAP = uiConstants.GAP
local ADD_BUTTON_WIDTH = 200
local OPERATOR_WIDTH = 100
-- The line between a condition's checks and its changes: a small white
-- image (resources/Shapes/pixel.png, 8x8) stretched across the row and
-- tinted faint.
-- PrettyUI's own divider is 60px tall.
local DIVIDER_RGBA = 0xF2C66D80
local DIVIDER_HEIGHT = 1

-- Space above each check and change (and the Add buttons after them), a
-- little more than between rows, so each reads as a block.
local ITEM_GAP = GAP + 6

local ACTIVE_CHOICES = {
    { id = true, label = "Active" },
    { id = false, label = "Not active" },
}
local BOOL_CHOICES = {
    { id = true, label = "Yes" },
    { id = false, label = "No" },
}

-- The data type picker's choices: the aura's own source, then each type.
local OWN_SOURCE = "own"
-- A group has no source of its own, so it only gets the types.
local function typeChoices(hasOwnSource)
    local list = {}
    if hasOwnSource then list[1] = { id = OWN_SOURCE, label = "This aura's data source" } end
    for _, dataType in ipairs(dataSources.Types()) do
        list[#list + 1] = { id = dataType.id, label = dataType.label }
    end
    return list
end

-- The type a check's source was picked from. Checks saved before types
-- were kept only have their source, so it's found from that.
local function checkType(check)
    if check.sourceType ~= nil then return check.sourceType end
    local source = check.source ~= nil and dataSources.Get(check.source) or nil
    return source and source.type or nil
end

-- The number typed into a check's value field, allowing decimals (e.g.
-- 0.2 seconds), which the number input doesn't. It sits just after the
-- operator box and fills the rest of the row.
local function addNumberField(view, value, onChange)
    local padding = view.contentPadding
    local x = padding + OPERATOR_WIDTH + GAP
    view:AddTextField({
        inline = true,
        x = x,
        width = -(x + padding),
        widthAnchor = 1,
        text = tostring(value or 0),
        maxLength = 8,
        filterMode = ui.InputFieldFilterMode.NONE,
        tooltip = "The number to compare with. Decimals are fine, e.g. 0.6 for a tick.",
        onChange = function(_, _, content)
            local number = tonumber(content)
            if number ~= nil then onChange(number) end
        end,
    })
end

-- A combo box over { id, label } choices, narrowed to leave room for a
-- button pinned at the right of its row. A value that isn't among the
-- choices shows as `missingLabel` rather than as the first choice, which
-- would look picked when it isn't.
local function addComboBeside(view, choices, value, tooltip, onChange, missingLabel)
    local entries, selected = {}, nil
    for index, choice in ipairs(choices) do
        entries[index] = { label = choice.label, id = index }
        if choice.id == value then selected = index end
    end
    if selected == nil then
        entries[#entries + 1] = { label = missingLabel or "Choose...", id = 0 }
        selected = 0
    end
    view:AddComboBox({
        width = -(view.contentPadding * 2 + BUTTON_SIZE + GAP),
        widthAnchor = 1,
        entries = entries,
        selectedID = selected,
        tooltip = tooltip,
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local choice = choices[entryID]
            if choice ~= nil and choice.id ~= value then onChange(choice.id) end
        end,
    })
end

local function addRemoveButton(view, tooltip, onClick)
    view:AddSpriteButton("TRASH", onClick, {
        inline = true,
        x = -(view.contentPadding + BUTTON_SIZE),
        xAnchor = 1,
        size = BUTTON_SIZE,
        tooltip = tooltip,
    })
end

-- A check reads: data type (or the aura's own source), then the source of
-- that type, then what it has (active, value, ...), then what that is.
local function buildCheck(view, aura, condition, index, edit)
    local check = condition.checks[index]

    local dataTypeID = checkType(check)
    view:AddText({ text = "Check " .. index, marginTop = ITEM_GAP })
    addComboBeside(view, typeChoices(not auraStore.IsGroup(aura)), dataTypeID or OWN_SOURCE,
        "Which data the check reads: the aura's own, or a data source of another type.",
        function(id)
            edit(function()
                check.sourceType = id ~= OWN_SOURCE and id or nil
                check.source = nil
            end, true)
        end, "Unknown data type")
    addRemoveButton(view, "Remove", function()
        edit(function() table.remove(condition.checks, index) end, true)
    end)

    if dataTypeID ~= nil then
        local sources = dataSources.ListByType(dataTypeID)
        local entries, selected = {}, nil
        for sourceIndex, source in ipairs(sources) do
            entries[sourceIndex] = { label = source.label, id = sourceIndex, order = 1 }
            if source.id == check.source then selected = sourceIndex end
        end
        if selected == nil then
            entries[#entries + 1] = { label = "Choose a source...", id = 0, order = 0 }
            selected = 0
        end
        view:AddText("Data source")
        fastTypeahead.Add(view, {
            entries = entries,
            selectedID = selected,
            tooltip = "Which data source the check reads. Type to filter the list.",
            onChange = function(_, entryID, _, eventType)
                if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
                local source = sources[entryID]
                if source == nil or source.id == check.source then return end
                edit(function()
                    check.sourceType = dataTypeID
                    check.source = source.id
                end)
            end,
        })
    end

    -- What can be tested depends on the source's type (only buffs have
    -- stacks). A kind saved before it was limited stays listed.
    local readType = dataTypeID
    if readType == nil then
        local own = dataSources.Get(aura.source)
        readType = own and own.type or nil
    end
    local kinds = conditions.ChecksFor(readType)
    local listed = false
    for _, kind in ipairs(kinds) do listed = listed or kind.id == check.kind end
    if not listed then
        for _, kind in ipairs(conditions.CHECKS) do
            if kind.id == check.kind then kinds[#kinds + 1] = kind end
        end
    end
    choiceCombo.Add(view, {
        label = "Has",
        choices = kinds,
        value = check.kind,
        tooltip = "What to test about it.",
        onChange = function(id)
            edit(function()
                local fresh = conditions.NewCheck(id)
                check.kind, check.value = fresh.kind, fresh.value
            end, true)
        end,
    })

    if not conditions.Compares(check.kind) then
        choiceCombo.Add(view, {
            label = "Which is",
            choices = ACTIVE_CHOICES,
            value = check.value ~= false,
            onChange = function(id) edit(function() check.value = id end) end,
        })
        return
    end
    choiceCombo.Add(view, {
        label = "Which is",
        choices = conditions.OPERATORS,
        value = check.op,
        width = OPERATOR_WIDTH,
        tooltip = "How it compares with the number.",
        onChange = function(id) edit(function() check.op = id end) end,
    })
    addNumberField(view, check.value, function(number) edit(function() check.value = number end) end)
end

-- The value a new change starts with: what the aura has now.
local function currentValue(aura, property)
    if property.id == "hidden" then return true end
    local value = aura[property.id]
    if property.kind == "bool" then return value == true end
    if property.kind == "colour" then return value or 0xFFFFFFFF end
    return value or ""
end

local function buildChange(view, aura, condition, index, edit)
    local change = condition.changes[index]
    local current = conditions.Property(change.property)
    view:AddText({ text = "Change " .. index, marginTop = ITEM_GAP })
    addComboBeside(view, conditions.PropertiesFor(aura.display), change.property,
        "Which display option to change while the checks pass.",
        function(id)
            edit(function()
                change.property = id
                change.value = currentValue(aura, conditions.Property(id))
            end, true)
        end, (current and current.label or "Unknown option") .. " (not used by this display)")
    addRemoveButton(view, "Remove", function()
        edit(function() table.remove(condition.changes, index) end, true)
    end)

    local property = conditions.Property(change.property)
    if property == nil then return end
    if property.kind == "colour" then
        colourInput.Add(view, {
            label = "To",
            value = change.value,
            windowTitle = property.label,
            onChange = function(colour) edit(function() change.value = colour end) end,
        })
    elseif property.kind == "bool" then
        choiceCombo.Add(view, {
            label = "To",
            choices = BOOL_CHOICES,
            value = change.value == true,
            onChange = function(id) edit(function() change.value = id end) end,
        })
    elseif property.kind == "text" then
        view:AddText("To")
        view:AddTextField({
            text = tostring(change.value or ""),
            maxLength = 64,
            tooltip = "Placeholders work as in the Display tab's text: $current, $max, $stacks, $charges, $name.",
            onChange = function(_, _, content) edit(function() change.value = content end) end,
        })
    end
end

local function pixelImage()
    return Plugin.resources.Shapes.pixel
end

-- PrettyUI is another plugin, so an image it assigns is looked up in its
-- own folder and fails to load ("unable to read data from disk"). So the
-- line is made with a game sprite id (a sprite takes an id or an image, not
-- nothing; this is the one PrettyUI's own divider uses) and the image is
-- assigned here.
local PLACEHOLDER_SPRITE = "RS3_PARENT_FRAME_TOP_TILE"

local function addLine(view, spriteID)
    return view:AddSprite(spriteID, { height = DIVIDER_HEIGHT, colour = DIVIDER_RGBA, marginTop = ITEM_GAP })
end

local function setImage(sprite, image)
    sprite.sprite = image
end

-- New resources only load on a plugin refresh (prf) or client restart, so
-- each step is guarded: without the line, the gap alone separates them.
local function addDivider(view)
    local image = gameApi.Try(pixelImage)
    local spriteID = gameApi.Sprite(PLACEHOLDER_SPRITE)
    if image == nil or spriteID == nil then return end
    local ok, line = pcall(addLine, view, spriteID)
    if not ok or line == nil or line.root == nil then return end
    if not pcall(setImage, line.root, image) then
        -- Better no line than PrettyUI's sprite squashed into one.
        line.root.hidden = true
    end
end

-- Builds the checks of `holder` (anything with a `checks` list: a
-- condition, or an aura's load), each with its remove button. The Load tab
-- uses it too (see UI/Windows/load-tab).
function conditionsTab.AddChecks(view, aura, holder, edit)
    for index = 1, #holder.checks do
        buildCheck(view, aura, holder, index, edit)
    end
end

local function buildCondition(view, aura, condition, edit)
    choiceCombo.Add(view, {
        label = "Passes when",
        choices = conditions.MATCHES,
        value = condition.match == "any" and "any" or "all",
        tooltip = "Whether every check below must pass, or any one of them.",
        onChange = function(id) edit(function() condition.match = id end) end,
    })
    conditionsTab.AddChecks(view, aura, condition, edit)
    view:AddFancyButton("Add check", function()
        edit(function() condition.checks[#condition.checks + 1] = conditions.NewCheck() end, true)
    end, { width = ADD_BUTTON_WIDTH, marginTop = ITEM_GAP })

    addDivider(view)
    for index = 1, #condition.changes do
        buildChange(view, aura, condition, index, edit)
    end
    view:AddFancyButton("Add change", function()
        edit(function()
            local property = conditions.PropertiesFor(aura.display)[1]
            condition.changes[#condition.changes + 1] = { property = property.id, value = currentValue(aura, property) }
        end, true)
    end, {
        width = ADD_BUTTON_WIDTH,
        marginTop = #condition.changes > 0 and ITEM_GAP or nil,
    })
end

function conditionsTab.Build(aura, context)
    local auraID = aura.id
    -- Runs a change to the aura's conditions, saves it, and rebuilds the
    -- tab if it added or removed controls.
    local function edit(change, rebuild)
        change()
        if aura.conditions ~= nil and #aura.conditions == 0 then aura.conditions = nil end
        auraStore.Touch(auraID)
        auraStore.Save()
        context.onChanged()
        if rebuild then context.requestRebuild() end
    end

    local list = aura.conditions or {}
    for index, condition in ipairs(list) do
        local function move(by)
            edit(function()
                table.remove(list, index)
                table.insert(list, index + by, condition)
            end, true)
        end
        local buttons = {
            {
                sprite = "TRASH",
                tooltip = "Remove",
                onClick = function() edit(function() table.remove(list, index) end, true) end,
            },
            {
                sprite = "PLUS",
                tooltip = "Duplicate",
                onClick = function()
                    edit(function()
                        local copy = conditions.Copy(condition)
                        copy.key = conditions.NextKey(list)
                        table.insert(list, index + 1, copy)
                    end, true)
                end,
            },
        }
        if index < #list then
            buttons[#buttons + 1] = { sprite = "ARROW_DOWN", tooltip = "Move down", onClick = function() move(1) end }
        end
        if index > 1 then
            buttons[#buttons + 1] = { sprite = "ARROW_UP", tooltip = "Move up", onClick = function() move(-1) end }
        end
        -- Keyed by aura and the condition's own key, so collapsing one
        -- follows it when it moves and doesn't touch other auras'.
        local sectionID = "condition:" .. tostring(auraID) .. ":" .. tostring(condition.key or index)
        context.section(sectionID, "Condition " .. index, function(view)
            buildCondition(view, aura, condition, edit)
        end, buttons)
    end

    local view = context.view()
    if #list == 0 then
        view:AddText({
            text = "Conditions change how the aura looks while their checks pass, e.g. turn a bar red when a buff has under 5 seconds left.",
            height = 40,
            maxLines = 2,
            colour = uiConstants.MUTED_RGBA,
        })
    end
    view:AddFancyButton("Add condition", function()
        edit(function()
            aura.conditions = aura.conditions or {}
            aura.conditions[#aura.conditions + 1] = conditions.NewCondition(aura.conditions)
        end, true)
    end, {
        width = ADD_BUTTON_WIDTH,
        variant = "positive",
        marginTop = #list > 0 and GAP * 2 or nil,
    })
end

return conditionsTab
