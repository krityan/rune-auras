-- The aura editor's Display tab: what the aura is and how it's drawn, in
-- sections (General, Size, Appearance, Text or text nodes, Layout,
-- Position). Display types add their own controls through their TypeEditor.

local anchors = require("Auras/Helpers/anchors")
local auraStore = require("Auras/Store/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")
local textPicker = require("UI/Controls/text-picker")
local textTemplate = require("Auras/Helpers/text-template")
local fastTypeahead = require("UI/PrettyUI/fast-typeahead")
local sectionButtons = require("UI/Editor/section-buttons")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local displayTab = {}

local SECTION_GAP = uiConstants.SECTION_GAP
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

local comboEntries = choiceCombo.Entries

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

--- Whether a text's time options show: its source's values are times and
--- it shows one of them.
---@param template string?
---@param timed boolean
---@return boolean
local function showsTimeOptions(template, timed)
    return timed and (textTemplate.HasField(template, "value") or textTemplate.HasField(template, "max"))
end

--- Adds a text's time format and the options its format has: seconds
--- alone under a minute (hh:mm:ss), only whole ticks (ticks), or where
--- decimals stop (ss.ms).
---@param view EditorView
---@param textHolder Aura|TextNode
---@param update fun(key: string, value: any)
---@param context EditorTabContext
local function buildTimeOptions(view, textHolder, update, context)
    choiceCombo.Add(view, {
        label = "Time format",
        choices = textTemplate.TIME_FORMATS,
        value = textHolder.timeFormat,
        onChange = function(formatID)
            update("timeFormat", formatID)
            -- The options below depend on the format.
            context.requestRebuild()
        end,
    })
    if textTemplate.OffersBareSeconds(textHolder.timeFormat) then
        view:AddCheckboxButton({
            {
                text = "Just seconds under a minute",
                value = "bareSeconds",
                selected = textHolder.bareSeconds == true,
                tooltip = "59, not 0:59",
            },
        }, {
            onChange = function(_, _, _, selected) update("bareSeconds", selected == true) end,
        })
    end
    if textTemplate.OffersFullTicks(textHolder.timeFormat) then
        view:AddCheckboxButton({
            {
                text = "Only full ticks",
                value = "fullTicks",
                selected = textHolder.fullTicks ~= false,
                tooltip = "4.8 ticks shows 4, not 5",
            },
        }, {
            onChange = function(_, _, _, selected) update("fullTicks", selected == true) end,
        })
    end
    if not textTemplate.HasDecimals(textHolder.timeFormat) then return end
    numberInput.Add(view, {
        label = "Show decimals below (seconds)",
        value = textHolder.decimalsBelow,
        min = 0,
        max = textTemplate.MAX_DECIMALS_BELOW,
        step = 1,
        slider = true,
        onChange = function(value) update("decimalsBelow", value) end,
    })
end

--- Adds the text options for an aura's own text fields (the Text display),
--- or one of a Bar's or Icon's text nodes, which share its field names.
---@param view EditorView
---@param textHolder Aura|TextNode
---@param update fun(key: string, value: any)
---@param showOption { field: string, label: string }? The checkbox that switches the text on; nil for none.
---@param context EditorTabContext
---@param sourceID string? The source the aura reads (see dataSources.AuraSourceID), which decides the text's fields.
---@param hideWhenReadyLabel string? A text node's Hide when ready checkbox's label; nil for none.
local function buildTextOptions(view, textHolder, update, showOption, context, sourceID, hideWhenReadyLabel)
    local checkboxes = {}
    if showOption ~= nil then
        checkboxes[#checkboxes + 1] = { text = showOption.label, value = showOption.field,
            selected = textHolder[showOption.field] == true }
    end
    if hideWhenReadyLabel ~= nil then
        checkboxes[#checkboxes + 1] = { text = hideWhenReadyLabel, value = "hideWhenReady",
            selected = textHolder.hideWhenReady == true }
    end
    if #checkboxes > 0 then
        view:AddCheckboxButton(checkboxes, {
            onChange = function(_, _, field, selected) update(field, selected == true) end,
        })
    end

    local source = dataSources.Get(sourceID)
    local timed = source ~= nil and source.timed == true
    textPicker.Add(view, {
        label = "Text",
        template = textHolder.textTemplate,
        sourceID = sourceID,
        onChange = function(template, rebuild)
            local oldTemplate = textHolder.textTemplate
            update("textTemplate", template)
            -- The percent decimals slider shows only with $percent, and
            -- the time options only with a time.
            local percentChanged = textTemplate.HasField(oldTemplate, "percent")
                ~= textTemplate.HasField(template, "percent")
            local timeChanged = showsTimeOptions(oldTemplate, timed) ~= showsTimeOptions(template, timed)
            if rebuild or percentChanged or timeChanged then context.requestRebuild() end
        end,
    })
    if textTemplate.HasField(textHolder.textTemplate, "percent") then
        numberInput.Add(view, {
            label = "Percent decimals",
            value = textHolder.percentDecimals or 0,
            min = 0,
            max = textTemplate.MAX_PERCENT_DECIMALS,
            step = 1,
            slider = true,
            onChange = function(value) update("percentDecimals", value) end,
        })
    end

    if showsTimeOptions(textHolder.textTemplate, timed) then buildTimeOptions(view, textHolder, update, context) end

    colourInput.Add(view, {
        label = "Text colour",
        value = textHolder.textColour,
        windowTitle = "Text colour",
        onChange = function(colour) update("textColour", colour) end,
    })

    local fontList = fontCatalogue.List()
    local fontEntries, fontIndexByID = comboEntries(fontList)
    view:AddText("Font")
    fastTypeahead.Add(view, {
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
        label = "Font size",
        value = fontCatalogue.NearestSize(font.id, textHolder.textSize),
        min = font.sizes[1],
        max = font.sizes[#font.sizes],
        step = 1,
        slider = true,
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
---@param screenSize ScreenSizeFunction
---@return number? minX nil if the game area's size is unknown.
---@return number? maxX
---@return number? minY
---@return number? maxY
local function positionRange(aura, screenSize)
    local parentWidth, parentHeight = parentSize()
    if parentWidth == nil then return nil end
    if aura.group ~= nil then return -parentWidth, parentWidth, -parentHeight, parentHeight end
    local width, height = screenSize(aura)
    return anchors.OffsetRange(aura.anchor, width, height, parentWidth, parentHeight)
end

--- Adds where a text node sits on its display: an anchor point of the
--- display's box and an offset from it (right and up).
---@param view EditorView
---@param node TextNode
---@param update fun(key: string, value: any)
local function buildTextPosition(view, node, update)
    local anchorList = anchors.List()
    local anchorEntries, anchorIndexByID = comboEntries(anchorList)
    view:AddText("Anchor point")
    fastTypeahead.Add(view, {
        entries = anchorEntries,
        selectedID = anchorIndexByID[anchors.Get(node.anchor).id],
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local anchor = anchorList[entryID]
            if anchor ~= nil and anchor.id ~= node.anchor then update("anchor", anchor.id) end
        end,
    })
    numberInput.Add(view, {
        label = "X offset", value = node.x or 0, negative = true,
        min = -TEXT_OFFSET_RANGE, max = TEXT_OFFSET_RANGE, slider = true,
        onChange = function(value) update("x", value) end,
    })
    numberInput.Add(view, {
        label = "Y offset", value = node.y or 0, negative = true,
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
---@param typeEditor TypeEditor
local function buildTextNodes(aura, context, typeEditor)
    local texts = aura.texts
    local hideWhenReadyLabel = typeEditor.hideWhenReadyLabel and typeEditor.hideWhenReadyLabel(aura) or nil
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
            buildTextOptions(view, node, nodeUpdate, SHOW_TEXT, context, dataSources.AuraSourceID(aura),
                hideWhenReadyLabel)
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
    fastTypeahead.Add(view, {
        entries = anchorEntries,
        selectedID = anchorIndexByID[anchors.Get(aura.anchor).id],
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local anchor = anchorList[entryID]
            if anchor == nil or anchor.id == aura.anchor then return end
            -- Keep it where it is on screen; only the offset changes.
            local width, height = context.screenSize(aura)
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
    local minX, maxX, minY, maxY = positionRange(aura, context.screenSize)
    local sizeKnown = minX ~= nil
    positionInputs = {
        x = numberInput.Add(view, {
            label = "X offset",
            value = aura.x,
            min = minX,
            max = maxX,
            slider = sizeKnown,
            negative = minX == nil or minX < 0,
            onChange = function(value) update("x", value) end,
        }),
        y = numberInput.Add(view, {
            label = "Y offset",
            value = aura.y,
            min = minY,
            max = maxY,
            slider = sizeKnown,
            negative = minY == nil or minY < 0,
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
---@param screenSize ScreenSizeFunction
local function refreshPositionRange(aura, update, screenSize)
    local minX, maxX, minY, maxY = positionRange(aura, screenSize)
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

--- Adds the display type above the display-specific options; groups have no choice.
---@param aura Aura
---@param context EditorTabContext
local function buildDisplayType(aura, context)
    local update, typeEditor = context.update, context.typeEditor
    if typeEditor.usesSource == false then return end
    local view = context.view()
    local types = displayTypes.Selectable()
    local typeEntries, typeIndexByID = comboEntries(types)
    view:AddText("Display type")
    fastTypeahead.Add(view, {
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

--- Builds the tab for an aura.
---@param aura Aura
---@param context EditorTabContext Needs update, changed, typeEditor and screenSize.
function displayTab.Build(aura, context)
    local update, typeEditor = context.update, context.typeEditor
    local function updateSize(key, value)
        update(key, value)
        refreshPositionRange(aura, update, context.screenSize)
    end

    buildDisplayType(aura, context)

    if typeEditor.size ~= nil then
        typeEditor.size(context.view(), aura, updateSize)
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
            if typeEditor.appearance ~= nil then typeEditor.appearance(view, aura, update, context) end
        end)
    end

    if typeEditor.state ~= nil then
        local source = dataSources.ForAura(aura)
        local state = source ~= nil and source.state or nil
        local title = state == "cooldown" and "Cooldown" or (state == "active" and "Duration" or "State")
        context.section("state", title, function(view)
            typeEditor.state(view, aura, update)
        end)
    end

    -- An aura switched to a type without nodes (Text) keeps its old ones,
    -- unused, so the type decides.
    local displayType = displayTypes.Get(aura.display)
    local drawsTextNodes = displayType ~= nil and displayType.options.usesTextNodes
    if aura.texts ~= nil and drawsTextNodes then
        buildTextNodes(aura, context, typeEditor)
    elseif usesText(typeEditor, aura) then
        context.section("text", "Text", function(view)
            local showOption = typeEditor.usesShowText ~= false and (typeEditor.showTextOption or SHOW_TEXT) or nil
            buildTextOptions(view, aura, update, showOption, context, dataSources.AuraSourceID(aura))
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
