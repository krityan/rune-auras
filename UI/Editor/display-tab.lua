-- The aura editor's Display tab: what the aura is and how it's drawn, in
-- sections (General, Size, Appearance, Text or text nodes, Layout,
-- Position). Display types add their own controls through their TypeEditor.

local anchors = require("Auras/Helpers/anchors")
local auraManager = require("Auras/aura-manager")
local auraStore = require("Auras/Store/aura-store")
local displayTypes = require("Auras/Registries/display-types")
local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")
local sectionButtons = require("UI/Editor/section-buttons")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local displayTab = {}

local SECTION_GAP = uiConstants.SECTION_GAP
local NAME_LENGTH = 32
local TEMPLATE_LENGTH = 64
local MAX_DECIMALS_BELOW = 120
-- How far a text node can sit from its anchor, either way.
local TEXT_OFFSET_RANGE = 200
local BUTTON_WIDTH = 150
local ADD_BUTTON_WIDTH = 200
-- Passed to edit for a change that adds or removes controls, so the tab is rebuilt.
local REBUILD = true
local HINT_HEIGHT, HINT_LINES = 40, 2

---@type { x: NumberInput, y: NumberInput }? The X/Y inputs while the Position section is open, so dragging the aura can update them.
local positionInputs = nil

--- The game area's size, which every position is inside (group layers cover
--- it too).
local parentSize = gameApi.GameAreaSize

--- Trims spaces from both ends.
---@param value any
---@return string
local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local comboEntries = choiceCombo.Entries

--- An aura's size on screen: its width/height, or for a display that sizes
--- itself (Text), the size it has now.
---@param aura Aura
---@return number width
---@return number height
local function auraSize(aura)
    local displayType = displayTypes.Get(aura.display)
    if displayType ~= nil and displayType.module.sizesItself then
        local width, height = auraManager.DisplaySize(aura.id)
        if width ~= nil then return width, height end
    end
    return aura.width or 0, aura.height or 0
end

-- The Text section's usual checkbox.
local SHOW_TEXT = { field = "showText", label = "Show text" }

--- Whether a type editor has a Text section for an aura.
---@param typeEditor TypeEditor
---@param aura Aura
---@return boolean
local function usesText(typeEditor, aura)
    local option = typeEditor.usesText
    if type(option) == "function" then return option(aura) end
    return option ~= false
end

--- Adds the text options for an aura's own text fields (the Text display),
--- or one of a Bar's or Icon's text nodes, which share its field names.
---@param view EditorView
---@param textHolder Aura|TextNode
---@param update fun(key: string, value: any)
---@param showOption { field: string, label: string }? The checkbox that switches the text on; nil for none.
---@param context EditorTabContext
local function buildTextOptions(view, textHolder, update, showOption, context)
    if showOption ~= nil then
        local field = showOption.field
        view:AddCheckboxButton({
            { text = showOption.label, value = field, selected = textHolder[field] == true },
        }, {
            onChange = function(_, _, _, selected) update(field, selected == true) end,
        })
    end

    view:AddText("Text template")
    view:AddTextField({
        text = textHolder.textTemplate,
        placeholder = "e.g. $current / $max",
        maxLength = TEMPLATE_LENGTH,
        tooltip = "$current, $max, $stacks, $charges, $name",
        onChange = function(_, _, content) update("textTemplate", content) end,
    })

    view:AddCheckboxButton({
        {
            text = "Limit decimals",
            value = "limitDecimals",
            selected = textHolder.limitDecimals == true,
            tooltip = "Decimals only below a value",
        },
    }, {
        onChange = function(_, _, _, selected) update("limitDecimals", selected == true) end,
    })
    numberInput.Add(view, {
        label = "Show decimals below (seconds)",
        value = textHolder.decimalsBelow,
        min = 0,
        max = MAX_DECIMALS_BELOW,
        step = 1,
        slider = true,
        onChange = function(value) update("decimalsBelow", value) end,
    })

    colourInput.Add(view, {
        label = "Text colour",
        value = textHolder.textColour,
        windowTitle = "Text colour",
        onChange = function(colour) update("textColour", colour) end,
    })

    local fontList = fontCatalogue.List()
    local fontEntries, fontIndexByID = comboEntries(fontList)
    view:AddText("Font")
    view:AddComboBox({
        entries = fontEntries,
        selectedID = fontIndexByID[textHolder.textFont],
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local font = fontList[entryID]
            if font == nil or font.id == textHolder.textFont then return end
            -- Fonts come in different sizes, so keep the closest one.
            update("textSize", fontCatalogue.NearestSize(font.id, textHolder.textSize))
            update("textFont", font.id)
            -- The size range below depends on the font.
            context.requestRebuild()
        end,
    })

    local font = fontCatalogue.Get(textHolder.textFont)
    if font == nil then return end
    local sizeInput
    sizeInput = numberInput.Add(view, {
        label = "Text size",
        value = fontCatalogue.NearestSize(font.id, textHolder.textSize),
        min = font.sizes[1],
        max = font.sizes[#font.sizes],
        step = 1,
        slider = true,
        tooltip = "Snaps to the font's sizes",
        onChange = function(value)
            local size = fontCatalogue.NearestSize(font.id, value)
            if size ~= value then sizeInput:SetValue(size) end
            update("textSize", size)
        end,
    })
end

--- The X/Y offsets' ranges: what keeps the aura on screen at the top level,
--- or up to a screen's width or height either way from its group's point.
---@param aura Aura
---@return number? minX nil if the game area's size is unknown.
---@return number? maxX
---@return number? minY
---@return number? maxY
local function positionRange(aura)
    local parentWidth, parentHeight = parentSize()
    if parentWidth == nil then return nil end
    if aura.group ~= nil then return -parentWidth, parentWidth, -parentHeight, parentHeight end
    local width, height = auraSize(aura)
    return anchors.OffsetRange(aura.anchor, width, height, parentWidth, parentHeight)
end

--- Adds where a text node sits on its display: an anchor point of the
--- display's box and an offset inwards from it.
---@param view EditorView
---@param node TextNode
---@param update fun(key: string, value: any)
local function buildTextPosition(view, node, update)
    local anchorList = anchors.List()
    local anchorEntries, anchorIndexByID = comboEntries(anchorList)
    view:AddText("Anchor point")
    view:AddComboBox({
        entries = anchorEntries,
        selectedID = anchorIndexByID[anchors.Get(node.anchor).id],
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local anchor = anchorList[entryID]
            if anchor ~= nil and anchor.id ~= node.anchor then update("anchor", anchor.id) end
        end,
    })
    local tooltip = "Positive is inwards"
    numberInput.Add(view, {
        label = "X offset", value = node.x or 0, negative = true, tooltip = tooltip,
        min = -TEXT_OFFSET_RANGE, max = TEXT_OFFSET_RANGE, slider = true,
        onChange = function(value) update("x", value) end,
    })
    numberInput.Add(view, {
        label = "Y offset", value = node.y or 0, negative = true, tooltip = tooltip,
        min = -TEXT_OFFSET_RANGE, max = TEXT_OFFSET_RANGE, slider = true,
        onChange = function(value) update("y", value) end,
    })
end

--- The buttons in a text node's header (see sectionButtons.ForListItem).
---@param aura Aura
---@param index integer
---@param editTexts fun(change: fun(), rebuild: boolean?)
---@return table[] buttons As the editor's section takes them.
local function textNodeButtons(aura, index, editTexts)
    return sectionButtons.ForListItem(aura.texts, index, editTexts, function(node)
        local copy = {}
        for key, value in pairs(node) do copy[key] = value end
        copy.key = auraStore.NextTextKey(aura)
        return copy
    end)
end

--- Adds a Bar's or Icon's texts: a section each (in list order, the last
--- drawn on top), then Add text.
---@param aura Aura
---@param context EditorTabContext
local function buildTextNodes(aura, context)
    local texts = aura.texts
    local function editTexts(change, rebuild)
        auraStore.Edit(aura.id, change)
        context.changed("texts")
        if rebuild then context.requestRebuild() end
    end
    for index, node in ipairs(texts) do
        local function nodeUpdate(key, value)
            editTexts(function() node[key] = value end)
        end
        -- Keyed by aura and the node's key, so collapsing one follows it
        -- when it moves.
        context.section("text:" .. tostring(aura.id) .. ":" .. tostring(node.key), "Text " .. index, function(view)
            buildTextOptions(view, node, nodeUpdate, SHOW_TEXT, context)
            buildTextPosition(view, node, nodeUpdate)
        end, textNodeButtons(aura, index, editTexts))
    end
    local view = context.view()
    view:AddFancyButton("Add text", function()
        editTexts(function() texts[#texts + 1] = auraStore.NewText(aura) end, REBUILD)
    end, { width = ADD_BUTTON_WIDTH, marginTop = #texts > 0 and SECTION_GAP or nil })
end

--- Adds the anchor (or, in a group, attach point) picker. A group in a
--- group has neither: only an offset from its parent's point.
---@param view EditorView
---@param aura Aura
---@param context EditorTabContext
local function addAnchorPicker(view, aura, context)
    local isGroup = auraStore.IsGroup(aura)
    local inGroup = aura.group ~= nil
    local anchorList = anchors.List()
    local anchorEntries, anchorIndexByID = comboEntries(anchorList)
    view:AddText(inGroup and "Attach point" or "Anchor point")
    view:AddComboBox({
        entries = anchorEntries,
        selectedID = anchorIndexByID[anchors.Get(aura.anchor).id],
        tooltip = inGroup and "The point that sits on the group's point" or "Screen point the offsets start from",
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local anchor = anchorList[entryID]
            if anchor == nil or anchor.id == aura.anchor then return end
            -- Keep it where it is on screen; only the offset changes.
            local width, height = auraSize(aura)
            local areaWidth, areaHeight = parentSize()
            auraStore.SetAnchor(aura.id, anchor.id, width, height, areaWidth, areaHeight)
            context.changed("anchor")
            -- The X/Y ranges below depend on the anchor.
            context.requestRebuild()
        end,
    })
end

--- Adds the Position section's controls: anchor, X/Y offsets, Reset offset
--- for a plain group, and Unlock to drag.
---@param view EditorView
---@param aura Aura
---@param update fun(key: string, value: any)
---@param context EditorTabContext
local function buildPositionOptions(view, aura, update, context)
    local isGroup = auraStore.IsGroup(aura)
    local inGroup = aura.group ~= nil
    if not (isGroup and inGroup) then addAnchorPicker(view, aura, context) end

    -- Without a known parent size the ranges are unknown, so fall back to
    -- plain fields.
    local minX, maxX, minY, maxY = positionRange(aura)
    local sizeKnown = minX ~= nil
    local offsetTooltip = inGroup and "Right and down from the group's point" or "Positive is inwards"
    positionInputs = {
        x = numberInput.Add(view, {
            label = "X offset",
            value = aura.x,
            min = minX,
            max = maxX,
            slider = sizeKnown,
            negative = minX == nil or minX < 0,
            tooltip = offsetTooltip,
            onChange = function(value) update("x", value) end,
        }),
        y = numberInput.Add(view, {
            label = "Y offset",
            value = aura.y,
            min = minY,
            max = maxY,
            slider = sizeKnown,
            negative = minY == nil or minY < 0,
            tooltip = offsetTooltip,
            onChange = function(value) update("y", value) end,
        }),
    }

    -- Moving a plain group's point keeps its contents in place, so it can
    -- be put back on its anchor without moving anything.
    if isGroup and not auraStore.IsDynamicGroup(aura) then
        view:AddFancyButton("Reset offset", function()
            local width, height = parentSize()
            if width == nil or not auraStore.ResetGroupOffset(aura.id, width, height) then return end
            context.changed("x")
            context.requestRebuild()
        end, {
            width = BUTTON_WIDTH,
            tooltip = "Its auras stay put",
        })
    end

    view:AddCheckboxButton({
        {
            text = "Unlock to drag on screen",
            value = "unlocked",
            selected = aura.unlocked,
            tooltip = isGroup and "Drag the box around its auras" or nil,
        },
    }, {
        onChange = function(_, _, _, selected) update("unlocked", selected == true) end,
    })
end

--- Pulls the offsets back inside their ranges after a resize (the ranges
--- depend on the aura's size), matching where the display clamps itself.
---@param aura Aura
---@param update fun(key: string, value: any)
local function refreshPositionRange(aura, update)
    local minX, maxX, minY, maxY = positionRange(aura)
    if minX == nil then return end
    local x = math.max(minX, math.min(maxX, aura.x))
    local y = math.max(minY, math.min(maxY, aura.y))
    if x ~= aura.x then update("x", x) end
    if y ~= aura.y then update("y", y) end
    if positionInputs == nil then return end
    positionInputs.x:SetRange(minX, maxX)
    positionInputs.y:SetRange(minY, maxY)
    positionInputs.x:SetValue(x)
    positionInputs.y:SetValue(y)
end

--- Adds the General section: name, Export, and the display type.
---@param aura Aura
---@param context EditorTabContext
local function buildGeneral(aura, context)
    local update, typeEditor = context.update, context.typeEditor
    context.section("general", "General", function(view)
        view:AddText("Name")
        local nameField
        nameField = view:AddTextField({
            text = aura.name,
            placeholder = auraStore.IsGroup(aura) and "Group name" or "Aura name",
            maxLength = NAME_LENGTH,
            onChange = function()
                local name = trim(nameField:GetText())
                if name ~= "" then update("name", name) end
            end,
        })
        if context.onExport ~= nil then
            view:AddFancyButton("Export", function() context.onExport(aura.id) end, {
                width = BUTTON_WIDTH,
            })
        end

        -- Groups have no display type of their own.
        if typeEditor.usesSource ~= false then
            local types = displayTypes.Selectable()
            local typeEntries, typeIndexByID = comboEntries(types)
            view:AddText("Display type")
            view:AddComboBox({
                entries = typeEntries,
                selectedID = typeIndexByID[aura.display],
                onChange = function(_, entryID, _, eventType)
                    if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
                    local displayType = types[entryID]
                    if displayType == nil or displayType.id == aura.display then return end
                    update("display", displayType.id)
                    -- Type-specific options below depend on the display type.
                    context.requestRebuild()
                end,
            })
        end
    end)
end

--- Builds the tab for an aura.
---@param aura Aura
---@param context EditorTabContext Needs update, changed and typeEditor.
function displayTab.Build(aura, context)
    local update, typeEditor = context.update, context.typeEditor
    local function updateSize(key, value)
        update(key, value)
        refreshPositionRange(aura, update)
    end

    buildGeneral(aura, context)

    if typeEditor.size ~= nil then
        context.section("size", "Size", function(view)
            typeEditor.size(view, aura, updateSize)
        end)
    end

    if typeEditor.usesAppearance ~= false then
        context.section("appearance", "Appearance", function(view)
            if typeEditor.usesFillColour ~= false then
                colourInput.Add(view, {
                    label = "Fill colour",
                    value = aura.colour,
                    windowTitle = "Aura colour",
                    onChange = function(colour) update("colour", colour) end,
                })
            end
            if typeEditor.appearance ~= nil then typeEditor.appearance(view, aura, update) end
        end)
    end

    -- An aura switched to a type without nodes (Text) keeps its old ones,
    -- unused, so the type decides.
    local displayType = displayTypes.Get(aura.display)
    local drawsTextNodes = displayType ~= nil and displayType.module.usesTextNodes
    if aura.texts ~= nil and drawsTextNodes then
        buildTextNodes(aura, context)
    elseif usesText(typeEditor, aura) then
        context.section("text", "Text", function(view)
            local showOption = typeEditor.usesShowText ~= false and (typeEditor.showTextOption or SHOW_TEXT) or nil
            buildTextOptions(view, aura, update, showOption, context)
        end)
    end

    if typeEditor.layout ~= nil then
        context.section("layout", "Layout", function(view)
            typeEditor.layout(view, aura, update)
        end)
    end

    context.section("position", "Position", function(view)
        if auraStore.IsDynamicGroup(auraStore.Get(aura.group)) then
            -- Its own position comes back if it's moved out.
            view:AddText({
                text = "Its dynamic group positions it. Move the group, or change its Layout, to move it.",
                height = HINT_HEIGHT,
                maxLines = HINT_LINES,
                colour = uiConstants.MUTED_RGBA,
            })
        else
            buildPositionOptions(view, aura, update, context)
        end
    end)
end

--- Shows a dragged aura's new offset, if the Position section is open.
---@param aura Aura
function displayTab.OnAuraMoved(aura)
    if positionInputs == nil then return end
    positionInputs.x:SetValue(aura.x)
    positionInputs.y:SetValue(aura.y)
end

--- Forgets the tab's controls, when the editor is rebuilt or closed.
function displayTab.Forget()
    positionInputs = nil
end

return displayTab
