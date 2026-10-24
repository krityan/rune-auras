-- The aura list on the left of the main window (UI/Windows/main-window): every
-- aura as a tree, groups (marked by their expand arrow) indented with their
-- contents and collapsible. Clicking a row selects it for the editor; the
-- row under the mouse is highlighted. Dragging a row's name moves it to
-- wherever it's dropped: between rows to reorder (in or out of groups), or
-- onto the middle of a group's row to put it in that group.
-- Usage:
--   local auraList = require("UI/Windows/aura-list")
--   auraList.Build(view, {
--       selectedID = id,
--       onSelect = function(auraID) ... end,
--       onChanged = function() ... end,     -- auras were changed
--       requestRender = function() ... end, -- rebuild the list next frame
--   })

local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local auraList = {}

local PADDING = uiConstants.PADDING
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local GAP = uiConstants.GAP
local BUTTON_STEP = BUTTON_SIZE + GAP
-- How far each level of groups is indented.
local INDENT = 16
-- How far a press on a name must move before it becomes a drag.
local DRAG_THRESHOLD = 6
-- Where a drop on a group's row goes: its top and bottom quarters place
-- the dragged row before or after the group, the middle puts it inside.
local GROUP_EDGE = 0.25
-- Each row sits in a box, indented with its depth so nesting shows.
local BOX_INSET = 4
local BOX_RGBA = 0xFFFFFF0C
local BOX_OUTLINE_RGBA = 0xFFFFFF26
local HOVER_ROW_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x1C)
local SELECTED_ROW_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x38)
local DROP_INTO_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x40)
local DROP_LINE_HEIGHT = 2
-- Space right of each name, for the duplicate and delete buttons.
local NAME_RIGHT = PADDING + BUTTON_STEP * 2
-- Group id -> true for collapsed groups; remembered between sessions.
local COLLAPSED_STORAGE_KEY = "listCollapsedGroups"

local view = nil
local options = nil
local collapsed = nil
-- This build's contents of each group, in order (the top level under
-- `false`), worked out once rather than per row, and the cursor its names
-- show.
local childrenOf = {}
local cursorID = nil
-- This build's rows, top to bottom: { auraID, isGroup, depth, groupID
-- (its parent), nextID (next sibling), firstChildID (if shown), ancestors
-- (set of the groups it's in), y (where it was built), nameX (where its
-- name starts), boxX, boxWidth, label, hit (the area over the name that
-- takes presses), tint, text, hoverText, selected }.
local rows = {}
-- The drag in progress: { auraID, row, ghost, highlight, line, target }.
local drag = nil

local function loadCollapsed()
    if collapsed ~= nil then return end
    collapsed = {}
    for id in tostring(PersistentDB:GetString(COLLAPSED_STORAGE_KEY) or ""):gmatch("%d+") do
        collapsed[tonumber(id)] = true
    end
end

local function setCollapsed(groupID, isCollapsed)
    loadCollapsed()
    collapsed[groupID] = isCollapsed or nil
    local list = {}
    for id in pairs(collapsed) do
        -- Groups deleted since are forgotten.
        if auraStore.Get(id) ~= nil then list[#list + 1] = id end
    end
    table.sort(list)
    PersistentDB:SetString(COLLAPSED_STORAGE_KEY, table.concat(list, ","))
end

local function changed()
    if options.onChanged ~= nil then options.onChanged() end
end

local function rerender()
    if options.requestRender ~= nil then options.requestRender() end
end

local function plainName(aura)
    return (tostring(aura.name or ""):gsub("[<>]", ""))
end

local function contentWidth()
    return math.max(1, view.contentWidth or 1)
end

-- A row's text, plain and highlighted: the name (gold when highlighted)
-- and, muted, what it is. Angle brackets are dropped from the name so it
-- can't add markup.
local function rowTexts(aura)
    local name = plainName(aura)
    local detail
    if auraStore.IsGroup(aura) then
        local count = #(childrenOf[aura.id] or {})
        detail = formatStr("{} {}", count, count == 1 and "item" or "items")
    else
        local displayType = displayTypes.Get(aura.display)
        local source = dataSources.Get(aura.source)
        detail = formatStr("{} - {}", displayType and displayType.label or "?",
            source and source.label or "no data source")
    end
    local suffix = formatStr(" <col={}>({})</col>", uiConstants.MUTED_HEX, detail)
    return name .. suffix, "<col=" .. uiConstants.ACCENT_HEX .. ">" .. name .. "</col>" .. suffix
end

-- A rectangle in the list that ignores the mouse.
local function newRectangle(fill, rgba)
    local rectangle = ui.Rectangle.new(view.content)
    rectangle.fill = fill
    rectangle.rgba = rgba
    rectangle.clickthrough = true
    return rectangle
end

-- Places a rectangle over a row's box.
local function coverRow(rectangle, row)
    rectangle:SetPos(row.boxX, row.y - 2)
    rectangle:SetSize(row.boxWidth, BUTTON_SIZE + 4)
end

local function addBoxPart(row, fill, rgba)
    local part = newRectangle(fill, rgba)
    coverRow(part, row)
    part:MoveToBack()
    return part
end

-- The row's box: a faint fill and outline, with a tint shown while it's
-- selected or under the mouse. The selected row's outline is gold.
local function addRowBox(row, rowX)
    row.boxX = math.max(0, rowX - BOX_INSET)
    row.boxWidth = math.max(1, contentWidth() - row.boxX - BOX_INSET)
    addBoxPart(row, false, row.selected and uiConstants.ACCENT_RGBA or BOX_OUTLINE_RGBA)
    row.tint = addBoxPart(row, true, row.selected and SELECTED_ROW_RGBA or HOVER_ROW_RGBA)
    row.tint.hidden = not row.selected
    addBoxPart(row, true, BOX_RGBA)
end

-- Gives a row's name the pointer PrettyUI's buttons use, as it's clickable.
local function setButtonCursor(component)
    if cursorID == nil then return end
    component.opConfig:ClearOpCursors()
    component.cursorConfig.mouseOverCursor = cursorID
    component.opConfig:SetOpCursor(0, cursorID)
end

local function setHovered(row, hovered)
    if row.selected or drag ~= nil then return end
    row.tint.hidden = not hovered
    row.label.content = hovered and row.hoverText or row.text
end

-- Where a drop at `contentY` (list coordinates) would put the dragged row:
-- { groupID, beforeID } for auraStore.Move, plus what to draw: a line at
-- `lineY`, indented to `depth`, or the group row `into` highlighted.
-- nil when it can't go there (onto itself, or into its own contents).
local function dropAtRow(contentY)
    if #rows == 0 then return nil end
    local last = rows[#rows]
    local listBottom = last.y + BUTTON_SIZE + GAP
    if contentY >= listBottom then
        -- Below everything: the end of the top level.
        return { groupID = nil, beforeID = nil, lineY = listBottom - GAP // 2, depth = 0 }
    end
    for index, row in ipairs(rows) do
        local top = row.y - GAP // 2
        local nextRow = rows[index + 1]
        local bottom = nextRow and nextRow.y - GAP // 2 or listBottom
        if contentY < bottom or nextRow == nil then
            if row.auraID == drag.auraID or row.ancestors[drag.auraID] then return nil end
            local fraction = (contentY - top) / math.max(1, bottom - top)
            local before = { groupID = row.groupID, beforeID = row.auraID, lineY = top, depth = row.depth }
            local after = { groupID = row.groupID, beforeID = row.nextID, lineY = bottom, depth = row.depth }
            if not row.isGroup then
                return fraction < 0.5 and before or after
            end
            if fraction < GROUP_EDGE then return before end
            if fraction < 1 - GROUP_EDGE then
                return { groupID = row.auraID, beforeID = nil, into = row }
            end
            -- The bottom edge of an open group is the top of its contents.
            if row.firstChildID ~= nil then
                return { groupID = row.auraID, beforeID = row.firstChildID, lineY = bottom, depth = row.depth + 1 }
            end
            return after
        end
    end
    return nil
end

-- dropAtRow, but nil where the store wouldn't take it (a group into a
-- dynamic group, which holds auras only).
local function dropAt(contentY)
    local target = dropAtRow(contentY)
    if target ~= nil and target.groupID ~= nil
        and not auraStore.CanHold(auraStore.Get(target.groupID), auraStore.Get(drag.auraID)) then
        return nil
    end
    return target
end

-- Ends a drag, moving the dragged row to where it was released.
local function finishDrag()
    local finished = drag
    drag = nil
    if finished == nil then return end
    local target = finished.target
    if target ~= nil and auraStore.Move(finished.auraID, target.groupID, target.beforeID) then
        -- Show where it went.
        if target.groupID ~= nil then setCollapsed(target.groupID, false) end
        changed()
    end
    -- Rebuilding restores the expanded hit area and drops the drag visuals.
    rerender()
end

-- Expands a pressed row's hit area over the whole list, like PrettyUI's
-- window title drag, so the hold keeps reporting however fast the mouse
-- moves. It's invisible, so nothing on screen moves.
local function capture(row)
    row.hit:SetPos(0, 0)
    row.hit:SetSize(contentWidth(), math.max(1, view.contentHeight or 1))
    row.hit:MoveToFront()
end

local function release(row)
    row.hit:SetPos(row.nameX, row.y)
    row.hit:SetSize(math.max(1, contentWidth() - row.nameX - NAME_RIGHT), BUTTON_SIZE)
end

local function startDrag(row, aura)
    drag = { auraID = aura.id, row = row }
    drag.highlight = newRectangle(true, DROP_INTO_RGBA)
    drag.highlight.hidden = true
    drag.line = newRectangle(true, uiConstants.ACCENT_RGBA)
    drag.line.hidden = true
    drag.ghost = ui.Text.new(view.content)
    drag.ghost.font = gameApi.Font("MUSEO_SANS_15PT_REGULAR")
    drag.ghost.rgba = uiConstants.ACCENT_RGBA
    drag.ghost.isShadowed = true
    drag.ghost.maxLines = 1
    drag.ghost.clickthrough = true
    drag.ghost.content = "Move " .. plainName(aura)
    drag.ghost:SetSize(math.max(1, contentWidth() - PADDING * 2 - BUTTON_STEP), BUTTON_SIZE)
    drag.ghost:MoveToFront()
end

-- Follows the mouse at `contentY` (list coordinates) during a drag.
local function moveDrag(contentY)
    drag.ghost:SetPos(PADDING + BUTTON_STEP, contentY - BUTTON_SIZE // 2)
    local target = dropAt(contentY)
    drag.target = target
    drag.highlight.hidden = target == nil or target.into == nil
    drag.line.hidden = target == nil or target.into ~= nil
    if target == nil then return end
    if target.into ~= nil then
        coverRow(drag.highlight, target.into)
    else
        local lineX = PADDING + target.depth * INDENT
        drag.line:SetPos(lineX, target.lineY - DROP_LINE_HEIGHT // 2)
        drag.line:SetSize(math.max(1, contentWidth() - lineX - PADDING), DROP_LINE_HEIGHT)
    end
end

-- Makes a row's name clickable and draggable, and highlights its row
-- while the mouse is over it. The name itself ignores the mouse: an
-- invisible hit area over it takes the press, so it can be expanded without
-- moving the text. A press takes hold of the mouse at once, but only becomes
-- a drag once it has moved DRAG_THRESHOLD.
local function bindRow(row, aura)
    -- Empty text rather than a layer, as text is what showed the cursor.
    local hit = ui.Text.new(view.content)
    hit.content = ""
    hit.enabled = true
    hit.clickthrough = false
    row.hit = hit
    release(row)
    setButtonCursor(hit)
    -- { x, y } where it was pressed, in list coordinates, and whether the
    -- hit area has been expanded yet.
    local press = nil
    hit:Subscribe(ui.Hook.ONMOUSEOVER, function()
        setHovered(row, true)
        return false
    end)
    hit:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        if press == nil then setHovered(row, false) end
        return false
    end)
    hit:Subscribe(ui.Hook.ONCLICK, function(component, x, y)
        press = { x = (component.x or 0) + x, y = (component.y or 0) + y }
        return false
    end)
    hit:Subscribe(ui.Hook.ONHOLD, function(component, x, y)
        if press == nil then return false end
        -- Hook coordinates are relative to the hit area, which is at the
        -- list's origin once expanded.
        if not press.captured then
            x, y = (component.x or 0) + x, (component.y or 0) + y
            press.captured = true
            capture(row)
        end
        if drag == nil and math.abs(x - press.x) + math.abs(y - press.y) >= DRAG_THRESHOLD then
            startDrag(row, aura)
        end
        if drag ~= nil and drag.row == row then moveDrag(y) end
        return false
    end)
    local function onRelease()
        local pressed = press
        press = nil
        if drag ~= nil and drag.row == row then
            finishDrag()
        elseif pressed ~= nil then
            if pressed.captured then release(row) end
            if options.onSelect ~= nil then options.onSelect(aura.id) end
        end
        return false
    end
    hit:Subscribe(ui.Hook.ONRELEASE, onRelease)
    hit:Subscribe(ui.Hook.ONDRAGCOMPLETE, onRelease)
end

-- Adds one row: for a group, an expand/collapse arrow; then the eye, the
-- name and, on the right, duplicate (auras only) and delete. Returns it.
local function addRow(aura, depth, ancestors, nextID)
    local auraID = aura.id
    local isGroup = auraStore.IsGroup(aura)
    local selected = auraID == options.selectedID
    local rowX = PADDING + depth * INDENT
    local isCollapsed = isGroup and collapsed[auraID] == true

    if isGroup then
        view:AddSpriteButton(isCollapsed and "ARROW_RIGHT" or "ARROW_DOWN", function()
            setCollapsed(auraID, not isCollapsed)
            rerender()
        end, {
            x = rowX,
            size = BUTTON_SIZE,
            tooltip = isCollapsed and "Show what's in this group" or "Hide what's in this group",
        })
    end
    view:AddSpriteButton(aura.enabled and "EYE" or "HIDE", function()
        auraStore.Set(auraID, "enabled", not aura.enabled)
        changed()
        rerender()
    end, {
        -- Aura rows line their eye up with their group's, past the arrow.
        x = (not isGroup) and (rowX + BUTTON_STEP) or nil,
        inline = isGroup,
        size = BUTTON_SIZE,
        tooltip = isGroup and (aura.enabled and "Hide group" or "Show group")
            or (aura.enabled and "Hide aura" or "Show aura"),
    })
    local row = {
        auraID = auraID,
        isGroup = isGroup,
        depth = depth,
        groupID = aura.group,
        nextID = nextID,
        ancestors = ancestors,
        selected = selected,
        -- The name's span starts after the arrow or eye and runs up to the
        -- buttons on the right; worked out here rather than read back from
        -- the label.
        nameX = rowX + BUTTON_STEP * 2,
    }
    local text, highlighted = rowTexts(aura)
    row.text = selected and highlighted or text
    row.hoverText = highlighted
    row.label = view:AddText({
        text = row.text,
        inline = true,
        width = -(row.nameX + NAME_RIGHT),
        widthAnchor = 1,
        height = BUTTON_SIZE,
        maxLines = 1,
    })
    -- Where the row was built, for drop zones and the hit area.
    row.y = row.label.y or 0
    addRowBox(row, rowX)
    bindRow(row, aura)

    if not isGroup then
        -- Copying a group would mean copying everything in it; not yet.
        view:AddSpriteButton("PLUS", function()
            local area = gameApi.Component("TOPLEVEL_V2__GAME_AREA")
            local copy = auraStore.Duplicate(auraID, area and area.width, area and area.height)
            if copy == nil then return end
            changed()
            if options.onSelect ~= nil then options.onSelect(copy.id) end
            rerender()
        end, {
            inline = true,
            x = -(PADDING + BUTTON_SIZE + BUTTON_STEP),
            xAnchor = 1,
            size = BUTTON_SIZE,
            tooltip = "Duplicate aura",
        })
    end
    view:AddSpriteButton("TRASH", function()
        if selected and options.onSelect ~= nil then options.onSelect(nil) end
        -- A deleted group's contents move up a level and keep their place.
        auraStore.Delete(auraID)
        changed()
        rerender()
    end, {
        inline = true,
        x = -(PADDING + BUTTON_SIZE),
        xAnchor = 1,
        size = BUTTON_SIZE,
        tooltip = isGroup and "Delete group (what's in it moves up a level)" or "Delete aura",
    })
    rows[#rows + 1] = row
    return row, isGroup and not isCollapsed
end

local function addLevel(groupID, depth, ancestors)
    local children = childrenOf[groupID or false] or {}
    for index, aura in ipairs(children) do
        local nextSibling = children[index + 1]
        local row, open = addRow(aura, depth, ancestors, nextSibling and nextSibling.id or nil)
        if open then
            local inner = { [aura.id] = true }
            for id in pairs(ancestors) do inner[id] = true end
            local contents = childrenOf[aura.id]
            row.firstChildID = contents and contents[1].id or nil
            addLevel(aura.id, depth + 1, inner)
        end
    end
end

-- Builds the list into `listView`, a PrettyUI SimpleView.
function auraList.Build(listView, listOptions)
    view = listView
    options = listOptions or {}
    -- A rebuild ends any drag; its components went with the old view.
    drag = nil
    rows = {}
    loadCollapsed()
    cursorID = gameApi.Cursor("CURSOR_BLANK")
    childrenOf = {}
    for _, aura in ipairs(auraStore.List()) do
        local parent = aura.group or false
        local contents = childrenOf[parent]
        if contents == nil then
            contents = {}
            childrenOf[parent] = contents
        end
        contents[#contents + 1] = aura
    end

    if childrenOf[false] == nil then
        view:AddText({
            text = "No auras yet. Use New above to show game data on screen.",
            height = 48,
            maxLines = 2,
        })
        return
    end
    addLevel(nil, 0, {})
end

-- Forgets the view, e.g. when the window closes.
function auraList.Destroy()
    drag = nil
    rows = {}
    childrenOf = {}
    view = nil
end

return auraList
