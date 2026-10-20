-- The plugin's ribbon panel: lists auras and opens them in the aura editor
-- window (UI/aura-editor). Groups show one level at a time: clicking a
-- group's name opens it, and a Back row leads up a level. Dragging a row's
-- name onto a group moves it in; onto the Back row moves it up a level.
-- Usage:
--   local auraPanel = require("UI/aura-panel")
--   auraPanel.Init({ onAurasChanged = function() ... end })

local auraEditor = require("UI/aura-editor")
local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/data-sources")
local displayTypes = require("Auras/display-types")
local uiConstants = require("UI/ui-constants")

local auraPanel = {}

local EVENT_ID = "runeAuras_panel"
local MOUNT_EVENT_ID = "runeAuras_panelMount"
local RENDER_EVENT_ID = "runeAuras_panelRender"
local PADDING = uiConstants.PADDING
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local GAP = uiConstants.GAP
local BUTTON_STEP = BUTTON_SIZE + GAP
-- How far a press on a name must move before it becomes a drag.
local DRAG_THRESHOLD = 6
local DROP_HIGHLIGHT_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x40)
-- Group rows stand out from aura rows: a gold tint behind the row, a gold
-- name and an arrow that opens the group. (PrettyUI has no folder icon.)
local GROUP_ROW_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x1C)

local prettyUI = nil
local handlers = nil
local parent = nil
local view = nil
-- The group being listed, or nil for the top level.
local currentGroupID = nil
-- This build's drop targets: { top, bottom, groupID }.
local dropTargets = {}
-- The drag in progress: { auraID, name, label, ghost, highlight, expanded, target }.
local drag = nil

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
    return formatStr("{} <col={}>({} - {})</col>",
        editing and ("<col=" .. uiConstants.ACCENT_HEX .. ">" .. name .. "</col>") or name,
        uiConstants.MUTED_HEX,
        displayType and displayType.label or "?",
        source and source.label or "no data source")
end

local render, requestRender

local function openEditor(auraID)
    local library = getPrettyUI()
    if library ~= nil then auraEditor.Open(library, auraID) end
end

local function gameAreaSize()
    local area = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    if area == nil then return nil end
    return area.width, area.height
end

-- The size of the level being listed. A group only moves its contents, so
-- inside one or not that's the game area.
local function levelSize()
    return gameAreaSize()
end

local function plainName(aura)
    return (tostring(aura.name or ""):gsub("[<>]", ""))
end

local function groupSummary(group)
    local name = plainName(group)
    local count = #auraStore.Children(group.id)
    return formatStr("<col={}>{}</col> <col={}>(Group - {} {})</col>",
        uiConstants.ACCENT_HEX, name, uiConstants.MUTED_HEX, count, count == 1 and "item" or "items")
end

-- Tints a group's row behind its buttons and name.
local function addGroupRowTint(label)
    local tint = ui.Rectangle.new(view.content)
    tint.fill = true
    tint.rgba = GROUP_ROW_RGBA
    tint.clickthrough = true
    tint:SetPos(0, (label.y or 0) - 2)
    tint:SetSize(math.max(1, view.contentWidth or 1), BUTTON_SIZE + 4)
    pcall(function() tint:MoveToBack() end)
end

local function targetAt(contentY)
    for _, target in ipairs(dropTargets) do
        if contentY >= target.top and contentY < target.bottom then return target end
    end
    return nil
end

-- Ends a drag, moving the dragged row onto the target it was released over.
local function finishDrag()
    local finished = drag
    drag = nil
    if finished == nil then return end
    local target = finished.target
    if target ~= nil and target.groupID ~= finished.auraID then
        if auraStore.MoveToGroup(finished.auraID, target.groupID) then changed() end
    end
    -- Rebuilding restores the expanded label and drops the drag visuals.
    requestRender()
end

local function moveDrag(label, x, y)
    -- Hook coordinates are relative to the label. Once the drag starts it's
    -- expanded over the whole list (like PrettyUI's window title drag, so
    -- the hold keeps reporting), and then they're list coordinates.
    local contentY = drag.expanded and y or ((label.y or 0) + y)
    if not drag.expanded then
        drag.expanded = true
        local width = math.max(1, view.contentWidth or 1)
        drag.highlight = ui.Rectangle.new(view.content)
        drag.highlight.fill = true
        drag.highlight.rgba = DROP_HIGHLIGHT_RGBA
        drag.highlight.clickthrough = true
        drag.highlight.hidden = true
        drag.ghost = ui.Text.new(view.content)
        drag.ghost.font = id.Font.MUSEO_SANS_15PT_REGULAR
        drag.ghost.rgba = uiConstants.ACCENT_RGBA
        drag.ghost.isShadowed = true
        drag.ghost.maxLines = 1
        drag.ghost.clickthrough = true
        drag.ghost.content = "Move " .. drag.name
        drag.ghost:SetSize(math.max(1, width - PADDING * 2 - BUTTON_STEP), BUTTON_SIZE)
        label.content = ""
        label:SetPos(0, 0)
        label:SetSize(width, math.max(1, view.contentHeight or 1))
        label:MoveToFront()
    end
    drag.ghost:SetPos(PADDING + BUTTON_STEP, contentY - BUTTON_SIZE // 2)
    local target = targetAt(contentY)
    if target ~= nil and target.groupID == drag.auraID then target = nil end
    drag.target = target
    drag.highlight.hidden = target == nil
    if target ~= nil then
        drag.highlight:SetPos(0, target.top)
        drag.highlight:SetSize(math.max(1, view.contentWidth or 1), target.bottom - target.top)
    end
end

-- Makes a row's name clickable (`onClick`) and, for an aura or group,
-- draggable onto a group or the Back row.
local function bindRowLabel(label, aura, onClick)
    label.enabled = true
    label.clickthrough = false
    local press = nil
    label:Subscribe(ui.Hook.ONCLICK, function(_, x, y)
        press = { x = x, y = y }
        return false
    end)
    label:Subscribe(ui.Hook.ONHOLD, function(component, x, y)
        if drag == nil and press ~= nil and aura ~= nil
            and math.abs(x - press.x) + math.abs(y - press.y) >= DRAG_THRESHOLD then
            drag = { auraID = aura.id, name = plainName(aura), label = label }
        end
        if drag ~= nil and drag.label == label then moveDrag(component, x, y) end
        return false
    end)
    local function release()
        local wasPressed = press ~= nil
        press = nil
        if drag ~= nil and drag.label == label then
            finishDrag()
        elseif wasPressed and onClick ~= nil then
            onClick()
        end
        return false
    end
    label:Subscribe(ui.Hook.ONRELEASE, release)
    label:Subscribe(ui.Hook.ONDRAGCOMPLETE, release)
end

local function addDropTarget(label, groupID)
    local top = label.y or 0
    dropTargets[#dropTargets + 1] = { top = top, bottom = top + BUTTON_SIZE, groupID = groupID }
end

local function buildList()
    dropTargets = {}
    local current = currentGroupID ~= nil and auraStore.Get(currentGroupID) or nil
    if not auraStore.IsGroup(current) then
        current, currentGroupID = nil, nil
    end
    view:AddTitle(current and plainName(current) or "Auras")

    if current ~= nil then
        local parentGroup = current.group ~= nil and auraStore.Get(current.group) or nil
        local function goUp()
            currentGroupID = current.group
            requestRender()
        end
        view:AddSpriteButton("BACK", goUp, {
            size = BUTTON_SIZE,
            tooltip = "Back up a level",
        })
        local backLabel = view:AddText({
            text = "Back to " .. (parentGroup and plainName(parentGroup) or "all auras"),
            inline = true,
            width = -(PADDING * 2 + BUTTON_STEP),
            widthAnchor = 1,
            height = BUTTON_SIZE,
            maxLines = 1,
            colour = uiConstants.MUTED_RGBA,
            tooltip = "Back up a level. Drop an aura here to move it up a level.",
        })
        bindRowLabel(backLabel, nil, goUp)
        addDropTarget(backLabel, current.group)
    end

    local children = auraStore.Children(currentGroupID)
    if #children == 0 then
        view:AddText({
            text = current and "This group is empty. Drag auras onto it from the level above, or make new ones here."
                or "No auras yet. Create one to show game data on screen.",
            height = 48,
            maxLines = 2,
        })
    end

    local editingID = auraEditor.EditingID()
    for _, aura in ipairs(children) do
        local auraID = aura.id
        local editing = auraID == editingID
        local isGroup = auraStore.IsGroup(aura)
        view:AddSpriteButton(aura.enabled and "EYE" or "HIDE", function()
            auraStore.Set(auraID, "enabled", not aura.enabled)
            changed()
            requestRender()
        end, {
            size = BUTTON_SIZE,
            tooltip = isGroup and (aura.enabled and "Hide group" or "Show group")
                or (aura.enabled and "Hide aura" or "Show aura"),
        })
        local label = view:AddText({
            text = isGroup and groupSummary(aura) or auraSummary(aura, editing),
            inline = true,
            width = -(PADDING * 2 + BUTTON_STEP * 4),
            widthAnchor = 1,
            height = BUTTON_SIZE,
            maxLines = 1,
            tooltip = isGroup and ("Open " .. aura.name .. ". Drag to move it.")
                or ("Edit " .. aura.name .. ". Drag onto a group to move it."),
        })
        -- Clicking a group's name opens it; an aura's opens it in the editor.
        bindRowLabel(label, aura, function()
            if isGroup then
                currentGroupID = auraID
                requestRender()
            elseif not editing then
                openEditor(auraID)
            end
        end)
        if isGroup then
            addDropTarget(label, auraID)
            addGroupRowTint(label)
            -- Where an aura has Duplicate, a group has an arrow into it.
            -- (Copying a group would mean copying everything in it; not yet.)
            view:AddSpriteButton("ARROW_RIGHT", function()
                currentGroupID = auraID
                requestRender()
            end, {
                inline = true,
                x = -(PADDING + BUTTON_SIZE + BUTTON_STEP * 2),
                xAnchor = 1,
                size = BUTTON_SIZE,
                tooltip = "Open group",
            })
        else
            view:AddSpriteButton("PLUS", function()
                local width, height = levelSize()
                if auraStore.Duplicate(auraID, width, height) == nil then return end
                changed()
                requestRender()
            end, {
                inline = true,
                x = -(PADDING + BUTTON_SIZE + BUTTON_STEP * 2),
                xAnchor = 1,
                size = BUTTON_SIZE,
                tooltip = "Duplicate aura",
            })
        end
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
            tooltip = editing and "Close the aura editor"
                or (isGroup and "Rename or move group" or "Edit aura"),
        })
        view:AddSpriteButton("TRASH", function()
            if editing then auraEditor.Close() end
            -- A deleted group's contents keep their place in this level.
            auraStore.Delete(auraID)
            changed()
            requestRender()
        end, {
            inline = true,
            x = -(PADDING + BUTTON_SIZE),
            xAnchor = 1,
            size = BUTTON_SIZE,
            tooltip = isGroup and "Delete group (what's in it moves up a level)" or "Delete aura",
        })
    end

    view:AddFancyButton("New aura", function()
        local aura = auraStore.Create(currentGroupID)
        changed()
        openEditor(aura.id)
    end, {
        width = 200,
        variant = "positive",
    })
    view:AddFancyButton("New group", function()
        -- Opened straight away, like a new aura, so it gets named.
        local group = auraStore.CreateGroup(currentGroupID)
        changed()
        openEditor(group.id)
    end, {
        width = 200,
    })
end

render = function()
    -- A rebuild ends any drag; its components go with the old view.
    drag = nil
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
