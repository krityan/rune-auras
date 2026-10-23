-- The plugin's ribbon panel: a button that opens and closes the main window
-- (UI/Windows/main-window), where auras are listed and edited.
-- Usage:
--   local auraPanel = require("UI/Windows/aura-panel")
--   auraPanel.Init({ onAurasChanged = function() ... end })

local auraStore = require("Auras/aura-store")
local mainWindow = require("UI/Windows/main-window")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")

local auraPanel = {}

local EVENT_ID = "runeAuras_panel"
local MOUNT_EVENT_ID = "runeAuras_panelMount"
local RENDER_EVENT_ID = "runeAuras_panelRender"
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP

local prettyUI = nil
local parent = nil
local view = nil

-- Looked up when needed rather than at load: a dev plugin can load before
-- its dependencies have published their globals.
local function getPrettyUI()
    prettyUI = prettyUI or prettyui
    return prettyUI
end

local requestRender

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
            startY = 10,
            paddingLeft = PADDING,
            paddingRight = PADDING,
            rowGap = GAP,
            columnGap = GAP,
        },
    })
    view:AddTitle("Rune Auras")
    local count = 0
    for _, aura in ipairs(auraStore.List()) do
        if not auraStore.IsGroup(aura) then count = count + 1 end
    end
    view:AddText({
        text = count == 0 and "No auras yet."
            or formatStr("{} {}.", count, count == 1 and "aura" or "auras"),
        height = 24,
        maxLines = 1,
        colour = uiConstants.MUTED_RGBA,
    })
    local open = mainWindow.IsOpen()
    view:AddFancyButton(open and "Close auras" or "Open auras", function()
        mainWindow.Toggle()
    end, {
        width = 200,
        variant = open and nil or "positive",
        tooltip = "Show or hide the window for making and editing auras.",
    })
end

-- Rebuilds on the next frame, so the button isn't destroyed inside its own
-- callback.
requestRender = function()
    nextFrame.Run(RENDER_EVENT_ID, render)
end

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

-- Drops the panel's contents (the main window is separate: see
-- mainWindow.Destroy).
function auraPanel.Destroy()
    nextFrame.Cancel(MOUNT_EVENT_ID)
    nextFrame.Cancel(RENDER_EVENT_ID)
    if view ~= nil then view:Destroy() end
    view = nil
    parent = nil
end

function auraPanel.Shutdown()
    Event.ContentLayerReady.Unsubscribe(EVENT_ID)
    auraPanel.Destroy()
end

return auraPanel
