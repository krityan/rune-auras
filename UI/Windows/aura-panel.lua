-- The plugin's ribbon panel: an aura count, a button that opens and closes
-- the main window and the key that does, an emergency Delete all (which asks first), and in dev
-- builds a button for the debug options.

local auraStore = require("Auras/Store/aura-store")
local debugOptions = require("UI/Windows/debug-options")
local mainWindow = require("UI/Windows/main-window")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local windowKeybind = require("UI/Windows/window-keybind")

local auraPanel = {}

local EVENT_ID = "runeAuras_panel"
local MOUNT_EVENT_ID = "runeAuras_panelMount"
local RENDER_EVENT_ID = "runeAuras_panelRender"
local DELETE_ALL_EVENT_ID = "runeAuras_panelDeleteAll"
local KEYBIND_ENABLE_EVENT_ID = "runeAuras_panelKeybindEnable"
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
local TOP_PADDING = 10
local COUNT_HEIGHT = 24
-- Room kept for the panel's scrollbar if its track can't be read, so buttons
-- are the same width whether it shows or not. (PrettyUI places a button's
-- label for a fixed width, so widths are worked out rather than anchored.)
local SCROLLBAR_ROOM = 24
-- Used until the panel's layer has a width.
local FALLBACK_BUTTON_WIDTH = 180
local WARNING_HEIGHT, WARNING_LINES = 60, 3
-- The release listener's id on the keybind's text box.
local KEYBIND_CLICK_ID = "runeAuras_chooseKey"
-- The marker's colour, which nothing else in the layer has: "RA" in its red
-- and green. It's drawn 0 by 0, so it doesn't show.
local MARKER_RGBA = 0x52410001

local prettyUI = nil
local parent = nil
local view = nil
-- Marks the layer as showing this panel (see isShowing).
local marker = nil
---@type { onAurasChanged: fun()?, screenSize: ScreenSizeFunction }?
local handlers = nil
-- Delete all was pressed, so the warning and Confirm/Cancel show.
local isConfirmingDeleteAll = false
-- The debug options show under their button.
local isShowingDebug = false
-- What the last render showed of the auras, so an edit that changes
-- neither (most of them) doesn't rebuild the panel.
local shownCount = nil
local shownDeleteAll = nil
-- What the last render made that changes in place, and what they show.
local countLabel, openButton, keybindField = nil, nil, nil
local shownOpen, shownKeyText = nil, nil

--- PrettyUI, looked up when needed rather than at load: a dev plugin can
--- load before its dependencies have published their globals.
---@return table?
local function getPrettyUI()
    prettyUI = prettyUI or prettyui
    return prettyUI
end

local requestRender, changeInPlace

--- The width a button needs to fill the panel up to its scrollbar, between
--- its paddings. The bar's left edge is its track's (PrettyUI's scroll
--- view `track`), which is placed whether or not the bar shows.
---@param panelView table
---@return integer
local function fullButtonWidth(panelView)
    local panelWidth = parent ~= nil and parent.width or 0
    local rightEdge = panelWidth - SCROLLBAR_ROOM
    local track = panelView.track
    local trackX = track ~= nil and track.x or 0
    if trackX > 0 then
        rightEdge = trackX
    end

    local width = rightEdge - PADDING * 2
    if width <= 0 then
        return FALLBACK_BUTTON_WIDTH
    end

    return width
end

--- How many auras there are, not counting groups, as text.
---@return string
local function countText()
    local count = 0
    for _, aura in ipairs(auraStore.List()) do
        if not auraStore.IsGroup(aura) then
            count = count + 1
        end
    end

    if count == 0 then
        return "No auras yet."
    end

    return formatStr("{} {}.", count, count == 1 and "aura" or "auras")
end

--- Whether Delete all shows: when there's something to delete, or while its
--- warning is up.
---@return boolean
local function showsDeleteAll()
    return #auraStore.List() > 0 or isConfirmingDeleteAll
end

--- Shows a changed aura count in place, or rebuilds the panel if Delete all
--- comes or goes.
local function refreshPanel()
    if parent == nil then
        return
    end

    if showsDeleteAll() ~= shownDeleteAll then
        requestRender()
        return
    end

    local count = countText()
    if count ~= shownCount then
        shownCount = count
        -- AddText gives the native text.
        changeInPlace(function() countLabel.content = count end)
    end
end

--- Tells the plugin the auras changed, and updates the panel if its count or
--- Delete all changed.
local function aurasChanged()
    if handlers ~= nil and handlers.onAurasChanged ~= nil then
        handlers.onAurasChanged()
    end

    refreshPanel()
end

--- Shows or hides Delete all's warning and Confirm/Cancel.
---@param confirming boolean
local function setConfirming(confirming)
    isConfirmingDeleteAll = confirming
    requestRender()
end

--- Delete all's first press: asks first.
local function askDeleteAll()
    setConfirming(true)
end

--- Cancel: hides the warning again.
local function cancelDeleteAll()
    setConfirming(false)
end

--- Closes the main window so the editor doesn't keep a deleted aura, and
--- drops it without its close handler if that fails: this runs when the
--- window may be what's broken.
local function forceCloseWindow()
    if pcall(mainWindow.Close) and not mainWindow.IsOpen() then
        return
    end

    pcall(mainWindow.Destroy)
end

--- Deletes every aura and group, after Confirm.
local function deleteAll()
    setConfirming(false)
    forceCloseWindow()
    local deleted, result = pcall(auraStore.DeleteAll)
    if deleted then
        log(formatStr("RuneAuras: deleted all {} auras and groups.", result))
    else
        log("[ERROR] RuneAuras: deleting all auras failed: " .. tostring(result))
    end

    aurasChanged()
end

--- Confirm: deletes on the next frame, as rebuilding the panel destroys
--- this button.
local function confirmDeleteAll()
    nextFrame.Run(DELETE_ALL_EVENT_ID, deleteAll)
end

--- Adds Delete all, and under it, once pressed, the warning and
--- Confirm/Cancel.
---@param panelView table
local function addDeleteAll(panelView)
    local width = fullButtonWidth(panelView)
    panelView:AddSimpleButton("Delete all auras", askDeleteAll, {
        width = width,
        tooltip = "For emergency use",
    })

    if not isConfirmingDeleteAll then
        return
    end

    panelView:AddText({
        text = "Deletes every aura and group. This can't be undone.",
        height = WARNING_HEIGHT,
        maxLines = WARNING_LINES,
        colour = uiConstants.DANGER_RGBA,
    })

    -- Side by side, half the width each less the gap between them.
    local halfWidth = (width - GAP) // 2
    panelView:AddSimpleButton("Confirm", confirmDeleteAll, { width = halfWidth })
    panelView:AddSimpleButton("Cancel", cancelDeleteAll, { inline = true, width = halfWidth })
end

--- What the keybind's text box shows: the key, or nothing for none or while
--- choosing (its placeholder says to press a key then).
---@return string
local function keybindText()
    local isShown = not windowKeybind.IsChoosing() and windowKeybind.IsSet()
    return isShown and windowKeybind.Name() or ""
end

--- The keybind's text box's placeholder.
---@return string
local function keybindPlaceholder()
    return windowKeybind.IsChoosing() and "Press a key" or ""
end

--- Shows the keybind, or that a key is awaited, in its text box.
local function showKeybind()
    shownKeyText = keybindText()

    changeInPlace(function()
        keybindField:SetText(shownKeyText)
        keybindField:SetPlaceholder(keybindPlaceholder())
    end)

    -- Done choosing: the box keeps the focus from the click, which nothing
    -- takes away directly, so it's disabled until the next frame.
    if not windowKeybind.IsChoosing() and keybindField ~= nil then
        changeInPlace(function() keybindField:SetDisabled(true) end)

        nextFrame.Run(KEYBIND_ENABLE_EVENT_ID, function()
            if keybindField ~= nil then
                changeInPlace(function() keybindField:SetDisabled(false) end)
            end
        end)
    end
end

--- The keybind's text box, clicked: waits for a key, or stops waiting if it
--- already was. A key typed into the box meanwhile is undone (see addKeybind).
---@return boolean continue Let PrettyUI have the release too.
local function toggleChoosingKey()
    if windowKeybind.IsChoosing() then
        windowKeybind.CancelChoosing()
    else
        windowKeybind.Choose(showKeybind)
        showKeybind()
    end

    return true
end

--- Adds the key that opens and closes the window, in a text box as the
--- game's keybinds are (empty for none), clicked to choose another.
---@param panelView table
local function addKeybind(panelView)
    shownKeyText = keybindText()
    local field
    field = panelView:AddTextField({
        width = fullButtonWidth(panelView),
        text = shownKeyText,
        placeholder = keybindPlaceholder(),
        -- It only shows the key: typing into it is undone.
        onChange = function()
            if field ~= nil and field:GetText() ~= shownKeyText then
                field:SetText(shownKeyText)
            end
        end,
    })
    keybindField = field

    local root = type(field) == "table" and field.root or nil
    if type(root) == "userdata" then
        pcall(function()
            root.text.alignHorizontal = ui.AlignMode.CENTRE
            root:Subscribe(ui.Hook.ONRELEASE, KEYBIND_CLICK_ID, toggleChoosingKey)
        end)
    end
end

--- Shows or hides the debug options.
local function toggleDebug()
    isShowingDebug = not isShowingDebug
    requestRender()
end

--- Adds the debug options' button and, once pressed, the options.
---@param panelView table
local function addDebug(panelView)
    local width = fullButtonWidth(panelView)
    local label = isShowingDebug and "Hide debug options" or "Debug options"
    panelView:AddSimpleButton(label, toggleDebug, { width = width })

    if isShowingDebug then
        debugOptions.Add(panelView, width)
    end
end

--- Whether a component is the panel's marker.
---@param component userdata
---@return boolean
local function isMarker(component)
    return component.rgba == MARKER_RGBA
end

--- Whether a layer holds the panel's marker. Its components may be another
--- plugin's, so each is read guarded.
---@param layer userdata
---@return boolean
local function holdsMarker(layer)
    local found = false
    layer:IterateDynamicComponents(function(component)
        local ok, isOurs = pcall(isMarker, component)
        found = ok and isOurs
        return found
    end)

    return found
end

--- Makes the panel's marker in the layer.
---@param layer userdata
---@return userdata
local function makeMarker(layer)
    local made = ui.Rectangle.new(layer)
    made:SetSize(0, 0)
    made.rgba = MARKER_RGBA
    return made
end

--- Whether the panel is what the ribbon shows: its marker is still in the
--- layer. Every plugin's panel shares that layer, which the client clears for
--- another plugin's panel or a closed ribbon with no event, and then reuses
--- the components' ids, so the marker is the only sign. The panel changes
--- nothing in the layer while this is false.
---@return boolean
local function isShowing()
    if parent == nil then
        return false
    end

    local ok, found = pcall(holdsMarker, parent)
    return ok and found
end

--- Drops the panel's contents if they're still showing. If the layer has
--- been cleared, their components may be another plugin's now, so they're
--- only forgotten.
local function dropContents()
    if isShowing() then
        if view ~= nil then
            view:Destroy()
        end

        if marker ~= nil then
            marker:Destroy()
        end
    end

    view, marker = nil, nil
    countLabel, openButton, keybindField, shownOpen = nil, nil, nil, nil
end

--- Changes the panel's controls in place, if they're still showing (else
--- forgets the layer, as rerender does); rebuilds it if the change fails.
---@param change fun()
changeInPlace = function(change)
    if not isShowing() then
        dropContents()
        parent = nil
        return
    end

    if not pcall(change) then
        requestRender()
    end
end

--- The Open button's label.
---@param open boolean Whether the window is open.
---@return string
local function openLabel(open)
    return open and "Close auras" or "Open auras"
end

--- Relabels the Open button when the window opens or closes. It's plain
--- either way: a SimpleButton can't change its look (variant) once made, but
--- its label (`content`, a native text) changes in place.
local function showOpenState()
    local open = mainWindow.IsOpen()
    if parent == nil or open == shownOpen then
        return
    end

    shownOpen = open
    changeInPlace(function() openButton.content.content = openLabel(open) end)
end

--- Builds the panel's contents again.
local function render()
    dropContents()

    if parent == nil or getPrettyUI() == nil then
        return
    end

    view = prettyUI.SimpleView.new(parent, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        layout = {
            startY = TOP_PADDING,
            paddingLeft = PADDING,
            paddingRight = PADDING,
            rowGap = GAP,
            columnGap = GAP,
        },
    })
    -- Without it the panel can't tell it's still showing, so it isn't
    -- changed again until the client gives the layer back.
    local made, madeMarker = pcall(makeMarker, parent)
    marker = made and madeMarker or nil
    view:AddTitle("RuneAuras")
    shownCount = countText()

    countLabel = view:AddText({
        text = shownCount,
        height = COUNT_HEIGHT,
        maxLines = 1,
        colour = uiConstants.MUTED_RGBA,
    })

    shownOpen = mainWindow.IsOpen()
    openButton = view:AddSimpleButton(openLabel(shownOpen), function()
        mainWindow.Toggle()
    end, {
        width = fullButtonWidth(view),
    })

    addKeybind(view)
    shownDeleteAll = showsDeleteAll()

    if shownDeleteAll then
        addDeleteAll(view)
    end

    if debugOptions.IsAvailable() then
        addDebug(view)
    end
end

--- Builds the panel again if it's still showing; otherwise forgets the
--- layer, as it's another plugin's or the ribbon is closed. It's built
--- afresh when the client gives the layer back (see Init).
local function rerender()
    if not isShowing() then
        dropContents()
        parent = nil
        return
    end

    render()
end

--- Rebuilds on the next frame, so the button isn't destroyed inside its
--- callback.
requestRender = function()
    nextFrame.Run(RENDER_EVENT_ID, rerender)
end

--- Sets up the main window, and builds the panel whenever the client gives
--- it a layer.
---@param panelHandlers { onAurasChanged: fun()?, screenSize: ScreenSizeFunction }
function auraPanel.Init(panelHandlers)
    handlers = panelHandlers
    windowKeybind.Start(mainWindow.Toggle)

    mainWindow.Init({
        onAurasChanged = aurasChanged,
        screenSize = panelHandlers.screenSize,
        -- The button says Open or Close.
        onOpenChanged = showOpenState,
    })

    -- The ribbon panel's layer isn't sized yet when it is announced, so wait
    -- one frame before building into it.
    Event.ContentLayerReady.Subscribe(EVENT_ID, function(event)
        local layer = event.component
        auraPanel.Destroy()

        nextFrame.Run(MOUNT_EVENT_ID, function()
            parent = layer
            render()
        end)
    end)
end

--- Drops the panel's contents (the main window is separate: see
--- mainWindow.Destroy).
function auraPanel.Destroy()
    -- First: it asks for a render, cancelled below.
    windowKeybind.CancelChoosing()
    nextFrame.Cancel(MOUNT_EVENT_ID)
    nextFrame.Cancel(RENDER_EVENT_ID)
    nextFrame.Cancel(DELETE_ALL_EVENT_ID)
    nextFrame.Cancel(KEYBIND_ENABLE_EVENT_ID)
    isConfirmingDeleteAll = false
    dropContents()
    parent = nil
end

--- Rebuilds the panel if its count or Delete all changed, e.g. once the
--- saved auras have loaded.
function auraPanel.Refresh()
    refreshPanel()
end

--- Stops building the panel, and drops it.
function auraPanel.Shutdown()
    Event.ContentLayerReady.Unsubscribe(EVENT_ID)
    auraPanel.Destroy()
    windowKeybind.Stop()
end

return auraPanel
