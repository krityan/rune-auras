-- Icon editor controls (see TypeEditor in UI/Editor/aura-editor).

local dataSources = require("Auras/Registries/data-sources")
local iconOptions = require("Auras/Displays/Options/icon")
local gameText = require("Auras/Helpers/game-text")
local iconCatalogue = require("GameData/Catalogues/icon-catalogue")
local choiceCombo = require("UI/Controls/choice-combo")
local colourInput = require("UI/Controls/colour-input")
local numberInput = require("UI/Controls/number-input")
local iconPicker = require("UI/Windows/icon-picker")
local uiConstants = require("UI/ui-constants")

---@type TypeEditor
local iconEditor = {}

-- The longest "Show below" a buff can be given, in seconds.
local MAX_SHOW_BELOW = 3600
-- The icon row's button widths (wide enough for their one word), the gap
-- between controls and the row's height.
local CHOOSE_WIDTH, RESET_WIDTH = 72, 64
local GAP = uiConstants.GAP
local ROW_HEIGHT = uiConstants.FIELD_HEIGHT
local SOURCE_ICON = iconOptions.SOURCE_ICON

-- Icons have their own swipe colour, so the editor's generic fill colour
-- doesn't apply.
iconEditor.usesFillColour = false
-- Swipe anticlockwise is only offered for the radial, Wipe direction for
-- the linear wipe, and Reset once an icon is chosen.
iconEditor.rebuildOn = { swipeStyle = true, iconSprite = true, iconItem = true }
iconEditor.choosesIcon = true

--- The label of a text node's checkbox to blank it while the source is
--- ready, or nil for a source that's never ready (neither a cooldown nor a
--- buff).
---@param aura Aura
---@return string?
function iconEditor.hideWhenReadyLabel(aura)
    local source = aura.source and dataSources.Get(aura.source)
    local state = source ~= nil and source.state or nil
    if state == "cooldown" then return "Hide when ready" end
    if state == "active" then return "Hide while inactive" end
    return nil
end

--- The Size section: one size, as icons are kept square.
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
function iconEditor.size(view, aura, update)
    numberInput.Add(view, {
        label = "Size",
        value = aura.width,
        min = iconOptions.limits.minSize,
        max = iconOptions.limits.maxSize,
        step = 2,
        slider = true,
        onChange = function(value)
            -- Kept square.
            update("height", value)
            update("width", value)
        end,
    })
end

--- Shows an icon chosen in place of the source's, or the source's again.
---@param update fun(key: string, value: any)
---@param spriteID integer
---@param itemID integer
local function setIcon(update, spriteID, itemID)
    update("iconItem", itemID)
    update("iconSprite", spriteID)
end

--- Adds the icon shown as one row: "Icon: default" or "Icon: <name>", then
--- Choose (the icon picker) and, once one is chosen, Reset for the source's
--- again, right-aligned.
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
---@param windowBounds fun(): Rect? Where the editor's window is, to open the picker beside it.
local function addIconChoice(view, aura, update, windowBounds)
    local spriteID, itemID = iconOptions.ChosenIcon(aura)
    local isChosen = spriteID ~= nil or itemID ~= nil
    local padding = view.contentPadding
    local buttonsWidth = CHOOSE_WIDTH + (isChosen and GAP + RESET_WIDTH or 0)
    local name = "default"
    if isChosen then name = gameText.Plain(iconCatalogue.Name(spriteID, itemID) or "chosen icon") end
    view:AddText({
        text = "Icon: " .. name,
        width = -(padding * 2 + buttonsWidth + GAP),
        widthAnchor = 1,
        height = ROW_HEIGHT,
        maxLines = 1,
        colour = uiConstants.MUTED_RGBA,
    })
    view:AddSimpleButton("Choose", function()
        iconPicker.Open({
            auraID = aura.id,
            title = "Icon: " .. aura.name,
            beside = windowBounds(),
            spriteID = spriteID,
            itemID = itemID,
            onPick = function(entry)
                setIcon(update, entry.sprite or SOURCE_ICON, entry.item or SOURCE_ICON)
            end,
        })
    end, {
        inline = true,
        x = -(padding + buttonsWidth),
        xAnchor = 1,
        width = CHOOSE_WIDTH,
        height = ROW_HEIGHT,
    })
    if not isChosen then return end
    view:AddSimpleButton("Reset", function()
        setIcon(update, SOURCE_ICON, SOURCE_ICON)
    end, {
        inline = true,
        x = -(padding + RESET_WIDTH),
        xAnchor = 1,
        width = RESET_WIDTH,
        height = ROW_HEIGHT,
    })
end

--- Adds the icon shown, and icon tint, background and border controls.
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
---@param context EditorTabContext
function iconEditor.appearance(view, aura, update, context)
    addIconChoice(view, aura, update, context.windowBounds)
    colourInput.Add(view, {
        label = "Icon tint",
        value = aura.iconColour or iconOptions.defaults.iconColour,
        windowTitle = "Icon tint",
        onChange = function(colour) update("iconColour", colour) end,
    })
    colourInput.Add(view, {
        label = "Background colour",
        value = aura.backgroundColour or iconOptions.defaults.backgroundColour,
        windowTitle = "Icon background colour",
        onChange = function(colour) update("backgroundColour", colour) end,
    })
    colourInput.Add(view, {
        label = "Border colour",
        value = aura.borderColour,
        windowTitle = "Icon border colour",
        onChange = function(colour) update("borderColour", colour) end,
    })
    numberInput.Add(view, {
        label = "Border thickness",
        value = aura.borderThickness,
        min = 0,
        max = iconOptions.limits.maxBorder,
        step = 1,
        slider = true,
        onChange = function(value) update("borderThickness", value) end,
    })
end

--- Adds swipe and visibility controls for the source's cooldown or active duration.
---@param view EditorView
---@param aura IconOptions
---@param update fun(key: string, value: any)
function iconEditor.state(view, aura, update)
    local source = dataSources.ForAura(aura)
    local swipeStyle = iconOptions.DrawnSwipe(aura.swipeStyle, source)
    choiceCombo.Add(view, {
        label = "Swipe",
        choices = iconOptions.SwipeStylesFor(source),
        value = swipeStyle,
        onChange = function(style) update("swipeStyle", style) end,
    })
    if swipeStyle == "linear" then
        choiceCombo.Add(view, {
            label = "Wipe direction",
            choices = iconOptions.WIPE_DIRECTIONS,
            value = aura.wipeDirection or iconOptions.defaults.wipeDirection,
            onChange = function(direction) update("wipeDirection", direction) end,
        })
    end
    colourInput.Add(view, {
        label = "Swipe colour",
        value = aura.swipeColour,
        windowTitle = "Icon swipe colour",
        onChange = function(colour) update("swipeColour", colour) end,
    })
    local options = {
        {
            text = "Invert swipe",
            value = "invertSwipe",
            selected = aura.invertSwipe == true,
            tooltip = "Make the swipe count down",
        },
    }
    if swipeStyle == "radial" then
        options[#options + 1] = {
            text = "Swipe anticlockwise",
            value = "swipeAnticlockwise",
            selected = aura.swipeAnticlockwise == true,
        }
    end
    local state = source ~= nil and source.state or nil
    if state == "active" then
        options[#options + 1] = {
            text = "Desaturate while inactive",
            value = "dimWhileActive",
            selected = aura.dimWhileActive ~= false,
        }
        options[#options + 1] = {
            text = "Hide while inactive",
            value = "hideWhileInactive",
            selected = aura.hideWhileInactive == true,
            tooltip = "Except while unlocked",
        }
        options[#options + 1] = {
            text = "Hide while active",
            value = "hideWhileActive",
            selected = aura.hideWhileActive == true,
            tooltip = "To show a missing buff; see Show below",
        }
    elseif state == "cooldown" then
        options[#options + 1] = {
            text = "Desaturate while on cooldown",
            value = "dimWhileActive",
            selected = aura.dimWhileActive ~= false,
        }
    end
    view:AddCheckboxButton(options, {
        onChange = function(_, _, value, selected)
            update(value, selected == true)
        end,
    })
    if state == "active" then
        numberInput.Add(view, {
            label = "Show below (seconds)",
            value = aura.showActiveBelow or 0,
            min = 0,
            max = MAX_SHOW_BELOW,
            onChange = function(value) update("showActiveBelow", value) end,
        })
    end
end

return iconEditor
