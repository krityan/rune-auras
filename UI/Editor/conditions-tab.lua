-- The aura editor's Conditions tab: each of the aura's conditions is a
-- collapsible section with buttons in its header to move it up or down,
-- duplicate it or remove it. Inside are whether all its checks must pass or
-- any one, the checks, then the changes it makes while it passes. (They're
-- "checks" in the UI so they aren't confused with the conditions they make up.)

local auraStore = require("Auras/Store/aura-store")
local gameApi = require("GameData/game-api")
local conditions = require("Auras/Registries/conditions")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local choiceCombo = require("UI/Controls/choice-combo")
local numberInput = require("UI/Controls/number-input")
local colourInput = require("UI/Controls/colour-input")
local sourcePicker = require("UI/Controls/source-picker")
local sectionButtons = require("UI/Editor/section-buttons")
local uiConstants = require("UI/ui-constants")

local conditionsTab = {}

--- Makes a change to the aura, then saves and reports it.
---@alias EditFunction fun(change: fun(), rebuild: boolean?)

local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local GAP = uiConstants.GAP
local ITEM_GAP = uiConstants.ITEM_GAP
local ADD_BUTTON_WIDTH = 200
-- Passed to edit for a change that adds or removes controls, so the tab is rebuilt.
local REBUILD = true
local OPERATOR_WIDTH = 100
local VALUE_FIELD_LENGTH = 8
local CHANGE_TEXT_LENGTH = 64
local HINT_HEIGHT, HINT_LINES = 40, 2
-- The line between a condition's checks and its changes: a small white
-- image (resources/Shapes/pixel.png, 8x8) stretched across the row and
-- tinted faint, as PrettyUI's own divider is 60px tall.
local DIVIDER_RGBA = 0xF2C66D80
local DIVIDER_HEIGHT = 1
-- Combo entry id for a placeholder entry, not one of the choices.
local PLACEHOLDER_ENTRY_ID = 0

local ACTIVE_CHOICES = {
    { id = true, label = "Active" },
    { id = false, label = "Not active" },
}
local BOOL_CHOICES = {
    { id = true, label = "Yes" },
    { id = false, label = "No" },
}

-- The data type picker's choice for the aura's own source.
local OWN_SOURCE = "own"

--- The data type picker's choices: the aura's own source, then each type.
---@param hasOwnSource boolean false for a group, which has no source of its own.
---@return Choice[]
local function typeChoices(hasOwnSource)
    local list = {}
    if hasOwnSource then list[1] = { id = OWN_SOURCE, label = "This aura's data source" } end
    for _, dataType in ipairs(dataSources.Types()) do
        list[#list + 1] = { id = dataType.id, label = dataType.label }
    end
    return list
end

--- The type a check's source was picked from. Checks saved before types
--- were kept only have their source, so it's found from that.
---@param check Check
---@return string? dataTypeID nil for the aura's own source.
local function checkType(check)
    if check.sourceType ~= nil then return check.sourceType end
    local source = check.source ~= nil and dataSources.Get(check.source) or nil
    return source and source.type or nil
end

--- Adds the field a check's number is typed in, allowing decimals (e.g. 0.2
--- seconds), which the number input doesn't. It sits just after the
--- operator box and fills the rest of the row.
---@param view EditorView
---@param value number?
---@param onChange fun(number: number)
local function addNumberField(view, value, onChange)
    local padding = view.contentPadding
    local x = padding + OPERATOR_WIDTH + GAP
    view:AddTextField({
        inline = true,
        x = x,
        width = -(x + padding),
        widthAnchor = 1,
        text = tostring(value or 0),
        maxLength = VALUE_FIELD_LENGTH,
        filterMode = ui.InputFieldFilterMode.NONE,
        tooltip = "Decimals work, e.g. 0.6",
        onChange = function(_, _, content)
            local number = tonumber(content)
            if number ~= nil then onChange(number) end
        end,
    })
end

--- Adds a combo box narrowed to leave room for a button pinned at the right
--- of its row. A value that isn't among the choices shows as `missingLabel`
--- rather than as the first choice, which would look picked when it isn't.
---@param view EditorView
---@param choices Choice[]
---@param value any The id selected.
---@param tooltip string
---@param onChange fun(choiceID: any)
---@param missingLabel string?
local function addComboBeside(view, choices, value, tooltip, onChange, missingLabel)
    local entries, selected = {}, nil
    for index, choice in ipairs(choices) do
        entries[index] = { label = choice.label, id = index }
        if choice.id == value then selected = index end
    end
    if selected == nil then
        entries[#entries + 1] = { label = missingLabel or "Choose...", id = PLACEHOLDER_ENTRY_ID }
        selected = PLACEHOLDER_ENTRY_ID
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

--- Adds a remove button pinned at the right of the row before it.
---@param view EditorView
---@param tooltip string
---@param onClick fun()
local function addRemoveButton(view, tooltip, onClick)
    view:AddSpriteButton("TRASH", onClick, {
        inline = true,
        x = -(view.contentPadding + BUTTON_SIZE),
        xAnchor = 1,
        size = BUTTON_SIZE,
        tooltip = tooltip,
    })
end

--- Adds the typeahead picking a check's data source, of its data type.
---@param view EditorView
---@param check Check
---@param dataTypeID string
---@param edit EditFunction
local function addSourcePicker(view, check, dataTypeID, edit)
    sourcePicker.Add(view, {
        dataTypeID = dataTypeID,
        selectedID = check.source,
        tooltip = "Type to filter",
        onPick = function(source)
            edit(function()
                check.sourceType = dataTypeID
                check.source = source.id
            end)
        end,
    })
end

--- What a check can test: that depends on the source's type (only buffs
--- have stacks). A kind saved before it was limited stays listed.
---@param aura Aura
---@param check Check
---@param dataTypeID string? nil for the aura's own source.
---@return CheckKind[]
local function kindChoices(aura, check, dataTypeID)
    local readType = dataTypeID
    if readType == nil then
        local own = dataSources.Get(aura.source)
        readType = own and own.type or nil
    end
    local kinds = conditions.ChecksFor(readType)
    local isListed = false
    for _, kind in ipairs(kinds) do isListed = isListed or kind.id == check.kind end
    if not isListed then
        for _, kind in ipairs(conditions.CHECKS) do
            if kind.id == check.kind then kinds[#kinds + 1] = kind end
        end
    end
    return kinds
end

--- Adds one check. It reads top to bottom: data type (or the aura's own
--- source), then the source of that type, then what it has (Has), then
--- what that is (Which is).
---@param view EditorView
---@param aura Aura
---@param holder { checks: Check[] } A condition, or an aura's load.
---@param index integer
---@param edit EditFunction
local function buildCheck(view, aura, holder, index, edit)
    local check = holder.checks[index]

    local dataTypeID = checkType(check)
    view:AddText({ text = "Check " .. index, marginTop = ITEM_GAP })
    addComboBeside(view, typeChoices(not auraStore.IsGroup(aura)), dataTypeID or OWN_SOURCE,
        "What the check reads",
        function(typeID)
            edit(function()
                check.sourceType = typeID ~= OWN_SOURCE and typeID or nil
                check.source = nil
            end, REBUILD)
        end, "Unknown data type")
    addRemoveButton(view, "Remove", function()
        edit(function() table.remove(holder.checks, index) end, REBUILD)
    end)

    if dataTypeID ~= nil then addSourcePicker(view, check, dataTypeID, edit) end

    choiceCombo.Add(view, {
        label = "Has",
        choices = kindChoices(aura, check, dataTypeID),
        value = check.kind,
        onChange = function(kindID)
            edit(function()
                local fresh = conditions.NewCheck(kindID)
                check.kind, check.value = fresh.kind, fresh.value
            end, REBUILD)
        end,
    })

    if not conditions.Compares(check.kind) then
        choiceCombo.Add(view, {
            label = "Which is",
            choices = ACTIVE_CHOICES,
            value = check.value ~= false,
            onChange = function(wantsActive) edit(function() check.value = wantsActive end) end,
        })
        return
    end
    choiceCombo.Add(view, {
        label = "Which is",
        choices = conditions.OPERATORS,
        value = check.op,
        width = OPERATOR_WIDTH,
        onChange = function(operatorID) edit(function() check.op = operatorID end) end,
    })
    addNumberField(view, check.value, function(number) edit(function() check.value = number end) end)
end

--- The text nodes a per-text change can name.
---@param aura Aura
---@return TextNode[]? texts nil for a display without them.
local function textNodes(aura)
    local displayType = displayTypes.Get(aura.display)
    if displayType == nil or not displayType.module.usesTextNodes then return nil end
    return aura.texts
end

--- The node a change names.
---@param aura Aura
---@param change Change
---@return TextNode? node nil if none is named, or it's been removed.
local function namedTextNode(aura, change)
    for _, node in ipairs(textNodes(aura) or {}) do
        if node.key == change.text then return node end
    end
    return nil
end

--- The node a new value is taken from: the one named, or the first.
---@param aura Aura
---@param change Change
---@return TextNode?
local function textNodeFor(aura, change)
    local texts = textNodes(aura)
    if texts == nil then return nil end
    return namedTextNode(aura, change) or texts[1]
end

--- The value a new change starts with: what the aura (or, for a per-text
--- property, the change's text node) has now. Also points a per-text change
--- at a node if it has none.
---@param aura Aura
---@param property ConditionProperty
---@param change Change? Changed in place.
---@return any
local function currentValue(aura, property, change)
    if property.id == "hidden" then return true end
    local holder = aura
    if property.perText and change ~= nil then
        local node = textNodeFor(aura, change)
        if node ~= nil then
            change.text = node.key
            holder = node
        end
    end
    local value = holder[property.id]
    if property.kind == "bool" then return value == true end
    if property.kind == "colour" then return value or auraStore.DEFAULT_COLOUR end
    if property.kind == "number" then return value or property.min or 0 end
    return value or ""
end

--- Adds the "Of" picker naming which text node a per-text change changes,
--- on a display with text nodes.
---@param view EditorView
---@param aura Aura
---@param property ConditionProperty
---@param change Change
---@param edit EditFunction
local function addTextNodePicker(view, aura, property, change, edit)
    local texts = textNodes(aura)
    if texts == nil or #texts == 0 then return end
    local choices = {}
    for nodeIndex, node in ipairs(texts) do
        choices[nodeIndex] = { id = node.key, label = "Text " .. nodeIndex }
    end
    local node = namedTextNode(aura, change)
    -- Naming a text that's been removed changes nothing, so it shows as
    -- that rather than as Text 1.
    if node == nil and change.text ~= nil then
        choices[#choices + 1] = { id = change.text, label = "A removed text (changes nothing)" }
    end
    choiceCombo.Add(view, {
        label = "Of",
        choices = choices,
        value = node and node.key or change.text,
        tooltip = "Which of the aura's texts",
        onChange = function(nodeKey)
            edit(function()
                change.text = nodeKey
                change.value = currentValue(aura, property, change)
            end, REBUILD)
        end,
    })
end

--- The most a number property can be set to. A `limit` takes it from the
--- display's own limits, so the two can't drift apart.
---@param aura Aura
---@param property ConditionProperty
---@return number?
local function propertyMax(aura, property)
    if property.limit == nil then return property.max end
    local displayType = displayTypes.Get(aura.display)
    local limits = displayType and displayType.module.limits
    return limits and limits[property.limit] or property.max
end

--- Adds the control for a change's value ("To"), by the property's kind.
---@param view EditorView
---@param aura Aura
---@param property ConditionProperty
---@param change Change
---@param edit EditFunction
local function addValueControl(view, aura, property, change, edit)
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
            onChange = function(isOn) edit(function() change.value = isOn end) end,
        })
    elseif property.kind == "number" then
        local max = propertyMax(aura, property)
        numberInput.Add(view, {
            label = "To",
            value = tonumber(change.value) or property.min or 0,
            min = property.min,
            max = max,
            step = 1,
            slider = property.min ~= nil and max ~= nil,
            onChange = function(value) edit(function() change.value = value end) end,
        })
    elseif property.kind == "text" then
        view:AddText("To")
        view:AddTextField({
            text = tostring(change.value or ""),
            maxLength = CHANGE_TEXT_LENGTH,
            tooltip = "$current, $max, $stacks, $charges, $name",
            onChange = function(_, _, content) edit(function() change.value = content end) end,
        })
    end
end

--- Adds one change: which option, which text (for a per-text one), and its value.
---@param view EditorView
---@param aura Aura
---@param condition Condition
---@param index integer
---@param edit EditFunction
local function buildChange(view, aura, condition, index, edit)
    local change = condition.changes[index]
    local current = conditions.Property(change.property)
    view:AddText({ text = "Change " .. index, marginTop = ITEM_GAP })
    addComboBeside(view, conditions.PropertiesFor(aura.display), change.property,
        "What to change",
        function(propertyID)
            edit(function()
                change.property = propertyID
                change.value = currentValue(aura, conditions.Property(propertyID), change)
            end, REBUILD)
        end, (current and current.label or "Unknown option") .. " (not used by this display)")
    addRemoveButton(view, "Remove", function()
        edit(function() table.remove(condition.changes, index) end, REBUILD)
    end)

    local property = conditions.Property(change.property)
    if property == nil then return end
    if property.perText then addTextNodePicker(view, aura, property, change, edit) end
    addValueControl(view, aura, property, change, edit)
end

-- PrettyUI is another plugin, so an image it assigns is looked up in its
-- own folder and fails to load ("unable to read data from disk"). So the
-- line is made with a game sprite id (a sprite takes an id or an image, not
-- nothing; any thin frame tile works, as the image replaces it) and the image is
-- assigned here.
local PLACEHOLDER_SPRITE = "RS3_PARENT_FRAME_TOP_TILE"

---@param view EditorView
---@param spriteID integer
---@return table line
local function addLine(view, spriteID)
    return view:AddSprite(spriteID, { height = DIVIDER_HEIGHT, colour = DIVIDER_RGBA, marginTop = ITEM_GAP })
end

local function setImage(sprite, image)
    sprite.sprite = image
end

--- Adds the line between a condition's checks and its changes. New
--- resources only load on a plugin refresh (prf) or client restart, so each
--- step is guarded: without the line, the gap alone separates them.
---@param view EditorView
local function addDivider(view)
    local image = gameApi.ResourceImage("Shapes", "pixel")
    local spriteID = gameApi.Sprite(PLACEHOLDER_SPRITE)
    if image == nil or spriteID == nil then return end
    local ok, line = pcall(addLine, view, spriteID)
    if not ok or line == nil or line.root == nil then return end
    if not pcall(setImage, line.root, image) then
        -- Better no line than PrettyUI's sprite squashed into one.
        line.root.hidden = true
    end
end

--- Adds the checks of anything with a `checks` list (a condition, or an
--- aura's load), each with its remove button. The Load tab uses it too.
---@param view EditorView
---@param aura Aura
---@param holder { checks: Check[] }
---@param edit EditFunction
function conditionsTab.AddChecks(view, aura, holder, edit)
    for index = 1, #holder.checks do
        buildCheck(view, aura, holder, index, edit)
    end
end

--- Adds one condition's contents: its match, checks, divider and changes.
---@param view EditorView
---@param aura Aura
---@param condition Condition
---@param edit EditFunction
local function buildCondition(view, aura, condition, edit)
    choiceCombo.Add(view, {
        label = "Passes when",
        choices = conditions.MATCHES,
        value = condition.match == "any" and "any" or "all",
        onChange = function(matchID) edit(function() condition.match = matchID end) end,
    })
    conditionsTab.AddChecks(view, aura, condition, edit)
    view:AddFancyButton("Add check", function()
        edit(function() condition.checks[#condition.checks + 1] = conditions.NewCheck() end, REBUILD)
    end, { width = ADD_BUTTON_WIDTH, marginTop = ITEM_GAP })

    addDivider(view)
    for index = 1, #condition.changes do
        buildChange(view, aura, condition, index, edit)
    end
    view:AddFancyButton("Add change", function()
        edit(function()
            local property = conditions.PropertiesFor(aura.display)[1]
            local change = { property = property.id }
            change.value = currentValue(aura, property, change)
            condition.changes[#condition.changes + 1] = change
        end, REBUILD)
    end, {
        width = ADD_BUTTON_WIDTH,
        marginTop = #condition.changes > 0 and ITEM_GAP or nil,
    })
end

--- The buttons in a condition's header (see sectionButtons.ForListItem).
---@param list Condition[]
---@param index integer
---@param edit EditFunction
---@return table[] buttons As the editor's section takes them.
local function conditionButtons(list, index, edit)
    return sectionButtons.ForListItem(list, index, edit, function(condition)
        local copy = conditions.Copy(condition)
        copy.key = conditions.NextKey(list)
        return copy
    end)
end

--- Builds the tab for an aura.
---@param aura Aura
---@param context EditorTabContext
function conditionsTab.Build(aura, context)
    local auraID = aura.id
    --- Makes a change to the aura's conditions, saves it, and rebuilds the
    --- tab if it added or removed controls.
    local function edit(change, rebuild)
        auraStore.Edit(auraID, change)
        context.onChanged()
        if rebuild then context.requestRebuild() end
    end

    local list = aura.conditions or {}
    for index, condition in ipairs(list) do
        -- Keyed by aura and the condition's own key, so collapsing one
        -- follows it when it moves and doesn't touch other auras' sections.
        local sectionID = "condition:" .. tostring(auraID) .. ":" .. tostring(condition.key or index)
        context.section(sectionID, "Condition " .. index, function(view)
            buildCondition(view, aura, condition, edit)
        end, conditionButtons(list, index, edit))
    end

    local view = context.view()
    if #list == 0 then
        view:AddText({
            text = "Conditions change how the aura looks while their checks pass, e.g. turn a bar red when a buff has under 5 seconds left.",
            height = HINT_HEIGHT,
            maxLines = HINT_LINES,
            colour = uiConstants.MUTED_RGBA,
        })
    end
    view:AddFancyButton("Add condition", function()
        edit(function()
            aura.conditions = aura.conditions or {}
            aura.conditions[#aura.conditions + 1] = conditions.NewCondition(aura.conditions)
        end, REBUILD)
    end, {
        width = ADD_BUTTON_WIDTH,
        variant = "positive",
        marginTop = #list > 0 and GAP * 2 or nil,
    })
end

return conditionsTab
