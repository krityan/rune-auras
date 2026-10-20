-- The plugin's ribbon panel: lists auras and opens them in the aura editor
-- window (UI/aura-editor).
-- Usage:
--   local auraPanel = require("UI/aura-panel")
--   auraPanel.Init({ onAurasChanged = function() ... end })

local auraEditor = require("UI/aura-editor")
local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/data-sources")
local displayTypes = require("Auras/display-types")

local auraPanel = {}

local EVENT_ID = "runeAuras_panel"
local MOUNT_EVENT_ID = "runeAuras_panelMount"
local RENDER_EVENT_ID = "runeAuras_panelRender"
local PADDING = 12
local BUTTON_SIZE = 24
local GAP = 8
local BUTTON_STEP = BUTTON_SIZE + GAP

local prettyUI = nil
local handlers = nil
local parent = nil
local view = nil

local function changed()
    if handlers ~= nil and handlers.onAurasChanged ~= nil then
        handlers.onAurasChanged()
    end
end

-- Looked up when needed rather than at load: a dev plugin can load before
-- its dependencies have published their globals.
local function getPrettyUI()
    prettyUI = prettyUI or prettyui
    if prettyUI == nil then
        log("Rune Auras: the PrettyUI plugin is not loaded; enable it to edit auras.")
    end
    return prettyUI
end

-- The aura being edited has its name highlighted. Angle brackets are
-- dropped from the name so it can't add markup of its own.
local function auraSummary(aura, editing)
    local displayType = displayTypes.Get(aura.display)
    local source = dataSources.Get(aura.source)
    local name = (aura.name:gsub("[<>]", ""))
    return formatStr("{} <col=A0A0A0>({} - {})</col>",
        editing and ("<col=F2C66D>" .. name .. "</col>") or name,
        displayType and displayType.label or "?",
        source and source.label or "no data source")
end

local render, requestRender

local function openEditor(auraID)
    local library = getPrettyUI()
    if library ~= nil then auraEditor.Open(library, auraID) end
end

local function buildList()
    view:AddTitle("Auras")

    local auras = auraStore.List()
    if #auras == 0 then
        view:AddText({
            text = "No auras yet. Create one to show game data on screen.",
            height = 48,
            maxLines = 2,
        })
    end

    local editingID = auraEditor.EditingID()
    for _, aura in ipairs(auras) do
        local auraID = aura.id
        local editing = auraID == editingID
        view:AddSpriteButton(aura.enabled and "EYE" or "HIDE", function()
            auraStore.Set(auraID, "enabled", not aura.enabled)
            changed()
            requestRender()
        end, {
            size = BUTTON_SIZE,
            tooltip = aura.enabled and "Hide aura" or "Show aura",
        })
        local label = view:AddText({
            text = auraSummary(aura, editing),
            inline = true,
            width = -(PADDING * 2 + BUTTON_STEP * 3),
            widthAnchor = 1,
            height = BUTTON_SIZE,
            maxLines = 1,
            tooltip = "Edit " .. aura.name,
        })
        -- Clicking the name opens the aura in the editor, like the pencil.
        label.enabled = true
        label.clickthrough = false
        label:Subscribe(ui.Hook.ONCLICK, function()
            if not editing then openEditor(auraID) end
            return false
        end)
        view:AddSpriteButton("PENCIL", function()
            if editing then
                auraEditor.Close()
            else
                openEditor(auraID)
            end
        end, {
            inline = true,
            x = -(PADDING + BUTTON_SIZE + BUTTON_STEP),
            xAnchor = 1,
            size = BUTTON_SIZE,
            tooltip = editing and "Close the aura editor" or "Edit aura",
        })
        view:AddSpriteButton("TRASH", function()
            if editing then auraEditor.Close() end
            auraStore.Delete(auraID)
            changed()
            requestRender()
        end, {
            inline = true,
            x = -(PADDING + BUTTON_SIZE),
            xAnchor = 1,
            size = BUTTON_SIZE,
            tooltip = "Delete aura",
        })
    end

    view:AddFancyButton("New aura", function()
        local aura = auraStore.Create()
        changed()
        openEditor(aura.id)
    end, {
        width = 200,
        variant = "positive",
    })
end

render = function()
    local scrollY = view ~= nil and view.scrollY or nil
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
    buildList()
    if scrollY ~= nil then view:SetScrollPosition(scrollY) end
end

-- Rebuilds on the next frame, e.g. after the editor opens, closes or renames
-- an aura, so a control is never destroyed inside its own callback.
requestRender = function()
    Event.Draw.Subscribe(RENDER_EVENT_ID, function()
        Event.Draw.Unsubscribe(RENDER_EVENT_ID)
        render()
    end)
end

function auraPanel.Init(panelHandlers)
    handlers = panelHandlers
    auraEditor.Init({
        onAurasChanged = function()
            changed()
            -- Names and sources show in the list.
            if parent ~= nil then requestRender() end
        end,
        onEditorChanged = function()
            if parent ~= nil then requestRender() end
        end,
    })
    -- The ribbon panel's layer isn't sized yet when it is announced, so wait
    -- one frame before building into it.
    Event.ContentLayerReady.Subscribe(EVENT_ID, function(event)
        local layer = event.component
        auraPanel.Destroy()
        Event.Draw.Subscribe(MOUNT_EVENT_ID, function()
            Event.Draw.Unsubscribe(MOUNT_EVENT_ID)
            parent = layer
            render()
        end)
    end)
end

function auraPanel.Destroy()
    Event.Draw.Unsubscribe(MOUNT_EVENT_ID)
    Event.Draw.Unsubscribe(RENDER_EVENT_ID)
    if view ~= nil then view:Destroy() end
    view = nil
    parent = nil
end

function auraPanel.Shutdown()
    Event.ContentLayerReady.Unsubscribe(EVENT_ID)
    auraPanel.Destroy()
end

return auraPanel
