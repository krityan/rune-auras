-- The plugin's ribbon panel: a count of the auras, and a button that opens
-- and closes the main window, where they're listed and edited.

local auraStore = require("Auras/Store/aura-store")
local mainWindow = require("UI/Windows/main-window")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")

local auraPanel = {}

local EVENT_ID = "runeAuras_panel"
local MOUNT_EVENT_ID = "runeAuras_panelMount"
local RENDER_EVENT_ID = "runeAuras_panelRender"
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
local TOP_PADDING = 10
local COUNT_HEIGHT = 24
local BUTTON_WIDTH = 200

local prettyUI = nil
local parent = nil
local view = nil

--- PrettyUI, looked up when needed rather than at load: a dev plugin can
--- load before its dependencies have published their globals.
---@return table?
local function getPrettyUI()
    prettyUI = prettyUI or prettyui
    return prettyUI
end

local requestRender

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
    view:AddText({
        text = countText(),
        height = COUNT_HEIGHT,
        maxLines = 1,
        colour = uiConstants.MUTED_RGBA,
    })
    local open = mainWindow.IsOpen()
    -- Open is the positive button; Close is a plain one.
    local variant = nil
    if not open then variant = "positive" end
    view:AddFancyButton(open and "Close auras" or "Open auras", function()
        mainWindow.Toggle()
    end, {
        width = BUTTON_WIDTH,
        variant = variant,
    })
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
    mainWindow.Init({
        onAurasChanged = function()
            if panelHandlers ~= nil and panelHandlers.onAurasChanged ~= nil then
                panelHandlers.onAurasChanged()
            end
            if parent ~= nil then requestRender() end
        end,
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
