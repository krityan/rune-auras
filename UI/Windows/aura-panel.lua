-- The plugin's ribbon panel: a count of the auras, a button that opens and
-- closes the main window, where they're listed and edited, and an emergency
-- Delete all, for when the window can't be used, which asks first.

local auraStore = require("Auras/Store/aura-store")
local mainWindow = require("UI/Windows/main-window")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")

local auraPanel = {}

local EVENT_ID = "runeAuras_panel"
local MOUNT_EVENT_ID = "runeAuras_panelMount"
local RENDER_EVENT_ID = "runeAuras_panelRender"
local DELETE_ALL_EVENT_ID = "runeAuras_panelDeleteAll"
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
local TOP_PADDING = 10
local COUNT_HEIGHT = 24
-- Room kept for the panel's scrollbar if its track can't be read, so
-- buttons are the same width whether it shows or not. PrettyUI's buttons
-- place their label for a fixed width, so widths are worked out here
-- rather than anchored. They're simple buttons: a fancy one is never
-- narrower than 225px, wider than the panel.
local SCROLLBAR_ROOM = 24
-- Used until the panel's layer has a width.
local FALLBACK_BUTTON_WIDTH = 180
local WARNING_HEIGHT, WARNING_LINES = 60, 3

local prettyUI = nil
local parent = nil
local view = nil
---@type { onAurasChanged: fun()? }?
local handlers = nil
-- Delete all was pressed, so the warning and Confirm/Cancel show.
local isConfirmingDeleteAll = false
-- What the last render showed of the auras, so an edit that changes
-- neither (most of them) doesn't rebuild the panel.
local shownCount = nil
local shownDeleteAll = nil

--- PrettyUI, looked up when needed rather than at load: a dev plugin can
--- load before its dependencies have published their globals.
---@return table?
local function getPrettyUI()
    prettyUI = prettyUI or prettyui
    return prettyUI
end

local requestRender

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
    if trackX > 0 then rightEdge = trackX end
    local width = rightEdge - PADDING * 2
    if width <= 0 then return FALLBACK_BUTTON_WIDTH end
    return width
end

--- How many auras there are, not counting groups, as text.
---@return string
local function countText()
    local count = 0
    for _, aura in ipairs(auraStore.List()) do
        if not auraStore.IsGroup(aura) then count = count + 1 end
    end
    if count == 0 then return "No auras yet." end
    return formatStr("{} {}.", count, count == 1 and "aura" or "auras")
end

--- Whether Delete all shows: when there's something to delete, or while its
--- warning is up.
---@return boolean
local function showsDeleteAll()
    return #auraStore.List() > 0 or isConfirmingDeleteAll
end

--- Tells the plugin the auras changed, and rebuilds the panel if its count
--- or Delete all changed.
local function aurasChanged()
    if handlers ~= nil and handlers.onAurasChanged ~= nil then handlers.onAurasChanged() end
    if parent == nil then return end
    local panelChanged = countText() ~= shownCount or showsDeleteAll() ~= shownDeleteAll
    if panelChanged then requestRender() end
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
    if pcall(mainWindow.Close) and not mainWindow.IsOpen() then return end
    pcall(mainWindow.Destroy)
end

--- Deletes every aura and group, after Confirm.
local function deleteAll()
    setConfirming(false)
    forceCloseWindow()
    local deleted, result = pcall(auraStore.DeleteAll)
    if deleted then
        log(formatStr("Rune Auras: deleted all {} auras and groups.", result))
    else
        log("[ERROR] Rune Auras: deleting all auras failed: " .. tostring(result))
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
    if not isConfirmingDeleteAll then return end
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

--- Builds the panel's contents again.
local function render()
    if view ~= nil then view:Destroy() end
    view = nil
    if parent == nil or getPrettyUI() == nil then return end

    view = prettyUI.SimpleView.new(parent, {
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
    view:AddTitle("Rune Auras")
    shownCount = countText()
    view:AddText({
        text = shownCount,
        height = COUNT_HEIGHT,
        maxLines = 1,
        colour = uiConstants.MUTED_RGBA,
    })
    local open = mainWindow.IsOpen()
    -- Open is the positive button; Close is a plain one.
    local variant = nil
    if not open then variant = "positive" end
    view:AddSimpleButton(open and "Close auras" or "Open auras", function()
        mainWindow.Toggle()
    end, {
        width = fullButtonWidth(view),
        variant = variant,
    })
    shownDeleteAll = showsDeleteAll()
    if shownDeleteAll then addDeleteAll(view) end
end

--- Rebuilds on the next frame, so the button isn't destroyed inside its own
--- callback.
requestRender = function()
    nextFrame.Run(RENDER_EVENT_ID, render)
end

--- Sets up the main window, and builds the panel whenever the client gives
--- it a layer.
---@param panelHandlers { onAurasChanged: fun()? }?
function auraPanel.Init(panelHandlers)
    handlers = panelHandlers
    mainWindow.Init({
        onAurasChanged = aurasChanged,
        -- The button says Open or Close.
        onOpenChanged = function()
            if parent ~= nil then requestRender() end
        end,
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
    nextFrame.Cancel(MOUNT_EVENT_ID)
    nextFrame.Cancel(RENDER_EVENT_ID)
    nextFrame.Cancel(DELETE_ALL_EVENT_ID)
    isConfirmingDeleteAll = false
    if view ~= nil then view:Destroy() end
    view = nil
    parent = nil
end

--- Stops building the panel, and drops it.
function auraPanel.Shutdown()
    Event.ContentLayerReady.Unsubscribe(EVENT_ID)
    auraPanel.Destroy()
end

return auraPanel
