-- The aura list on the left of the main window: every aura as a tree with
-- collapsible groups. A click selects a row for the editor (or, on the empty
-- space below the rows, deselects, showing the home page), dragging a name
-- moves it, right-click opens a menu, and a search narrows the list.

local auraStore = require("Auras/Store/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local uiConstants = require("UI/ui-constants")
local nextFrame = require("UI/next-frame")
local gameApi = require("GameData/game-api")
local rememberedList = require("GameData/remembered-list")
local rectangles = require("Auras/Displays/Parts/rectangles")
local heroIcons = require("UI/Controls/hero-icons")
local buttonCursor = require("UI/Controls/button-cursor")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local gameText = require("Auras/Helpers/game-text")
local maths = require("Auras/Helpers/maths")

local auraList = {}

--- How a click changes the selection: one aura alone, one added or taken
--- out (Ctrl), or every row from the primary to it (Shift).
---@alias SelectMode "only"|"toggle"|"range"

---@class AuraListOptions
---@field selected table<integer, boolean>? The selected auras.
---@field primaryID integer? The selected aura clicked last (see auraSelection.Primary).
---@field selectedCount integer? How many are selected.
---@field selectedRootIDs integer[]? The selected auras not inside another selected group, in list order: what dragging a selected row moves.
---@field search string? Shows only the auras whose names hold it (any case); nil or empty for all.
---@field onSelect fun(auraID: integer?, mode: SelectMode?, shownIDs: integer[]?)? A row clicked (shownIDs: every row, top to bottom, for a range), or nil for none.
---@field onGroupSelected fun()? The menu's Group for several selected.
---@field onDeleteSelected fun()? The menu's Delete for several selected.
---@field onChanged fun()? Auras were changed.
---@field onDuplicate fun(auraID: integer)? Its right-click Duplicate.
---@field onExport fun(auraID: integer)? Its right-click Export.
---@field onDelete fun(auraID: integer)? Its right-click Delete, which asks first.
---@field requestRender fun()? Rebuild the list next frame.
---@field startY number? The view's layout startY.
---@field scrollY number? Where it'll be scrolled to.
---@field viewHeight number? How much of it shows.

--- One row of the list, worked out by addLevel; its components are only
--- made if it's built.
---@class ListRow
---@field auraID integer
---@field aura Aura
---@field index integer Its place in the list, for its shading.
---@field isGroup boolean
---@field isOpen boolean A group showing its contents.
---@field depth integer How many groups it's in.
---@field groupID integer? Its parent.
---@field nextID integer? Its next sibling.
---@field firstChildID integer? A shown group's first item.
---@field ancestors table<integer, boolean> The groups it's in.
---@field selected boolean
---@field nameX number Where its name starts, after the arrow or icon.
---@field hitX number Where the area that takes presses starts: an aura's icon, or a group's name (its arrow is a button).
---@field y number Where it sits, in list coordinates.
---@field label userdata? The name.
---@field hit userdata? The invisible area over the name that takes presses.
---@field tint userdata? The row's fill, whose colour shows hover and selection.
---@field text string? The name's text, plain or (selected) highlighted.
---@field hoverText string? The name's text under the mouse.
---@field pointerOver table<userdata, boolean>? Its parts the mouse is over.
---@field pressed boolean? Its name is held down.
---@field eye userdata? The crossed eye that restores a hidden aura.
---@field built boolean? All its parts were made: the component limit can cut a build short.

--- Where a drop would put the dragged row: a group and the item to go
--- before, for auraStore.Move, plus what to draw.
---@class DropTarget
---@field groupID integer? nil for the top level.
---@field beforeID integer? nil for the end of the group.
---@field lineY number? A line here, between rows.
---@field depth integer? The line's indent.
---@field into ListRow? Or this group's row highlighted.

---@class ListDrag
---@field auraIDs integer[] What's being moved, in list order: the pressed row's aura, or the selection's roots when it's one of several selected.
---@field moving table<integer, boolean> The same ids, for lookups.
---@field row ListRow The row being dragged.
---@field ghost userdata The dragged name, following the mouse.
---@field highlight userdata
---@field line userdata
---@field target DropTarget?

local PADDING = uiConstants.PADDING
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local GAP = uiConstants.GAP
local ICON_NAME_GAP = 4
local BUTTON_STEP = BUTTON_SIZE + ICON_NAME_GAP
-- SetPos's x anchor: the share of the parent's width x is measured from.
local FROM_LEFT, FROM_RIGHT = 0, 1
local TOP = 0
-- How far each level of groups is indented.
local INDENT = 16
-- Compact rows keep the tree readable beside a dense inspector.
local ROW_GAP = 2
local ROW_STEP = BUTTON_SIZE + ROW_GAP
-- Rows built past the edges of what's on screen, as a share of its height,
-- and how far the view can scroll into them before the list is rebuilt.
local BUILD_MARGIN = 0.5
local REBUILD_MARGIN = 0.25
-- How far a press on a name must move before it becomes a drag.
local DRAG_THRESHOLD = 6
-- Where a drop on an aura's row goes: its top half before it, its bottom
-- half after. On a group's row, its top and bottom quarters place the
-- dragged row before or after the group, the middle puts it inside.
local HALF = 0.5
local GROUP_EDGE = 0.25
-- Row fills, alternating down the list, and their hover and selected tints.
local ROW_RGBAS = uiConstants.LIST_ROW_RGBAS
local HOVER_ROW_RGBA = uiConstants.LIST_HOVER_RGBA
local SELECTED_ROW_RGBA = 0x4A4640FF
local DROP_INTO_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x40)
-- The gold bar down the selected row's left edge.
local SELECTED_EDGE_WIDTH = 2
local DROP_LINE_HEIGHT = 2
local NAME_COLOUR = 0xE7D7B0FF
local NAME_FONT = "MUSEO_SANS_15PT_REGULAR"
local EMPTY_HEIGHT, EMPTY_LINES = 48, 2
-- The empty space below the rows, which deselects when clicked, stops this
-- far short of the bottom of what shows, so it never makes a short list
-- scroll.
local DESELECT_AREA_MARGIN = 4
-- An aura's source icon, centred in a button's square.
local ICON_SIZE = 18
local ICON_INSET = (BUTTON_SIZE - ICON_SIZE) // 2
-- A hidden aura's icon is faded.
local HIDDEN_AURA_ALPHA = 0.45
-- A hidden aura's eye occupies one slot; groups also show a count beside it.
local VISIBILITY_WIDTH = BUTTON_SIZE
local EYE_X = -(PADDING + BUTTON_SIZE)
local EYE_SIZE = BUTTON_SIZE * 3 // 4
local EYE_INSET = (BUTTON_SIZE - EYE_SIZE) // 2
local NAME_RIGHT = PADDING + VISIBILITY_WIDTH + GAP
local COUNT_WIDTH = 28
-- childrenOf's key for the top level (a table can't be keyed by nil).
local TOP_LEVEL = false
local HOVER_EVENT_ID = "runeAuras_listHover"
local MENU_EVENT_ID = "runeAuras_listRowMenu"

local ICONS = {
    expanded = "chevron-down",
    collapsed = "chevron-right",
    hidden = "eye-slash",
}

local view = nil
---@type AuraListOptions?
local options = nil

--- Whether a group still exists, so its collapsed state is worth saving.
---@param groupID integer
---@return boolean
local function groupExists(groupID)
    return auraStore.Get(groupID) ~= nil
end

local collapsedGroups = rememberedList.new("listCollapsedGroups", { numeric = true, keep = groupExists })
---@type table<integer|boolean, Aura[]> This build's contents of each group, in order, worked out once rather than per row.
local childrenOf = {}
---@type table<integer, boolean>? While searching, the auras shown: those whose names hold the search, everything in a group whose name does, and the groups they're in.
local matched = nil
---@type ListRow[] This build's rows, top to bottom.
local rows = {}
---@type ListDrag?
local drag = nil
-- The stretch of the list this build made rows for, in list coordinates.
local builtTop, builtBottom = nil, nil

local function changed()
    if options.onChanged ~= nil then
        options.onChanged()
    end
end

local function rerender()
    if options.requestRender ~= nil then
        options.requestRender()
    end
end

---@return number
local function contentWidth()
    return math.max(1, view.contentWidth or 1)
end

--- A row's name, gold for a group and white when highlighted.
---@param aura Aura
---@return string plain
---@return string highlighted
local function rowTexts(aura)
    local name = gameText.Plain(aura.name)
    local plain = auraStore.IsGroup(aura) and "<col=" .. uiConstants.ACCENT_HEX .. ">" .. name .. "</col>" or name
    return plain, "<col=FFFFFF>" .. name .. "</col>"
end

--- A row's fill colour when the mouse isn't over it.
---@param row ListRow
---@return integer
local function restingRGBA(row)
    if row.selected then
        return SELECTED_ROW_RGBA
    end

    return ROW_RGBAS[row.index % 2 + 1]
end

--- Places a rectangle over a row, the whole list's width and the gaps
--- around it, so the fills meet.
---@param rectangle userdata
---@param row ListRow
local function coverRow(rectangle, row)
    rectangle:SetPos(0, row.y - ROW_GAP // 2)
    rectangle:SetSize(contentWidth(), ROW_STEP)
end

--- Adds the row's fill, behind everything, and the gold edge of the
--- selected row clicked last.
---@param row ListRow
local function addRowBackground(row)
    row.tint = rectangles.Filled(view.content, restingRGBA(row))
    coverRow(row.tint, row)

    if not row.selected or row.auraID ~= options.primaryID then
        return
    end

    local edge = rectangles.Filled(view.content, uiConstants.ACCENT_RGBA)
    edge:SetPos(0, row.y - ROW_GAP // 2)
    edge:SetSize(SELECTED_EDGE_WIDTH, ROW_STEP)
end

--- Whether a row shows as under the mouse: its name is held, or the mouse
--- is over one of its parts while nothing is being dragged.
---@param row ListRow
---@return boolean
local function isHovered(row)
    return row.pressed == true or (drag == nil and next(row.pointerOver) ~= nil)
end

--- Highlights the hovered row's fill and name, preserving selection colours.
---@param row ListRow
local function showHover(row)
    if not row.built then
        return
    end

    local hovered = isHovered(row)
    if not row.selected then
        row.tint.rgba = hovered and HOVER_ROW_RGBA or restingRGBA(row)
        row.label.content = hovered and row.hoverText or row.text
    end
end

--- Re-checks every built row's hover state.
local function refreshHover()
    for _, row in ipairs(rows) do
        showHover(row)
    end
end

--- Notes the mouse entering or leaving one of a row's parts. Entering shows
--- at once; leaving waits a frame, as moving from the name onto one of the
--- row's buttons leaves the one before it enters the other.
---@param row ListRow
---@param part userdata
---@param over boolean
local function notePointer(row, part, over)
    row.pointerOver[part] = over or nil

    if over then
        showHover(row)
    else
        nextFrame.Run(HOVER_EVENT_ID, refreshHover)
    end
end

--- Where a drop on a row would put the dragged one.
---@param row ListRow
---@param fraction number How far down the row's drop zone, 0 to 1.
---@param top number The zone's top.
---@param bottom number Its bottom.
---@return DropTarget
local function dropOnRow(row, fraction, top, bottom)
    local before = { groupID = row.groupID, beforeID = row.auraID, lineY = top, depth = row.depth }
    local after = { groupID = row.groupID, beforeID = row.nextID, lineY = bottom, depth = row.depth }
    if not row.isGroup then
        return fraction < HALF and before or after
    end

    if fraction < GROUP_EDGE then
        return before
    end

    if fraction < 1 - GROUP_EDGE then
        return { groupID = row.auraID, beforeID = nil, into = row }
    end

    -- The bottom edge of an open group is the top of its contents.
    if row.firstChildID ~= nil then
        return { groupID = row.auraID, beforeID = row.firstChildID, lineY = bottom, depth = row.depth + 1 }
    end

    return after
end

--- Whether a row is being dragged, or is inside a group being dragged, so
--- nothing dragged can drop onto or into it.
---@param row ListRow
---@return boolean
local function isDragged(row)
    if drag.moving[row.auraID] then
        return true
    end

    for groupID in pairs(row.ancestors) do
        if drag.moving[groupID] then
            return true
        end
    end

    return false
end

--- Where a drop at a height in the list would put the dragged rows.
---@param contentY number In list coordinates.
---@return DropTarget? target nil when they can't go there (onto one of them, or into their contents).
local function dropAtRow(contentY)
    if #rows == 0 then
        return nil
    end

    local lastRow = rows[#rows]
    local listBottom = lastRow.y + ROW_STEP
    if contentY >= listBottom then
        -- Below everything: the end of the top level.
        return { groupID = nil, beforeID = nil, lineY = listBottom - ROW_GAP // 2, depth = 0 }
    end

    for index, row in ipairs(rows) do
        local top = row.y - ROW_GAP // 2
        local nextRow = rows[index + 1]
        local bottom = nextRow and nextRow.y - ROW_GAP // 2 or listBottom
        if contentY < bottom or nextRow == nil then
            if isDragged(row) then
                return nil
            end

            local fraction = (contentY - top) / math.max(1, bottom - top)
            return dropOnRow(row, fraction, top, bottom)
        end
    end

    return nil
end

--- dropAtRow, but nil where the store wouldn't take every dragged aura (a
--- group into a dynamic group, which holds auras only).
---@param contentY number
---@return DropTarget?
local function dropAt(contentY)
    local target = dropAtRow(contentY)
    if target == nil or target.groupID == nil then
        return target
    end

    local group = auraStore.Get(target.groupID)
    for _, auraID in ipairs(drag.auraIDs) do
        if not auraStore.CanHold(group, auraStore.Get(auraID)) then
            return nil
        end
    end

    return target
end

-- Keeps auras in place on screen when they change group.
local areaSize = gameApi.GameAreaSize

--- Ends a drag, moving the dragged rows to where it was released.
local function finishDrag()
    local finished = drag
    drag = nil

    if finished == nil then
        return
    end

    local target = finished.target
    if target ~= nil and auraStore.MoveMany(finished.auraIDs, target.groupID, target.beforeID, areaSize()) then
        -- Show where it went.
        if target.groupID ~= nil then
            collapsedGroups:Remove(target.groupID)
        end

        changed()
    end

    -- Rebuilding restores the expanded hit area and drops the drag visuals.
    rerender()
end

-- A row's hit area and icons take the mouse, so a wheel turned over them
-- never reaches the list's scrolling; they scroll it themselves, this
-- far per notch. ONSCROLLWHEEL's delta is notches turned, positive down,
-- and a row a notch matches the list's scrolling.
local WHEEL_STEP = ROW_STEP

--- Scrolls the list for the mouse wheel turned over one of its rows.
---@param _ userdata The component under the mouse.
---@param delta integer The scrollWheelYDelta.
---@return boolean
local function scrollByWheel(_, delta)
    if view == nil or type(delta) ~= "number" or delta == 0 then
        return false
    end

    local shown = math.max(1, options and options.viewHeight or 0)
    local farthest = math.max(0, (view.contentHeight or 0) - shown)
    local target = (view.scrollY or 0) + delta * WHEEL_STEP
    view:SetScrollPosition(maths.Clamp(target, 0, farthest))
    return false
end

--- Expands a pressed row's hit area over the whole list, so the hold keeps
--- reporting however fast the mouse moves (hold hooks only fire while the
--- mouse is over the component). It's invisible, so nothing on screen moves.
---@param row ListRow
local function capture(row)
    row.hit:SetPos(0, 0)
    row.hit:SetSize(contentWidth(), math.max(1, view.contentHeight or 1))
    row.hit:MoveToFront()
end

--- Puts a row's hit area back over its icon and name.
---@param row ListRow
local function release(row)
    row.hit:SetPos(row.hitX, row.y)
    row.hit:SetSize(math.max(1, contentWidth() - row.hitX - PADDING), BUTTON_SIZE)
end

--- What dragging a row moves: the whole selection (its roots) when the row
--- is one of several selected, otherwise the row's aura alone.
---@param row ListRow
---@return integer[] auraIDs In list order.
local function draggedIDs(row)
    local rootIDs = options.selectedRootIDs
    local isSelectionDrag = row.selected and (options.selectedCount or 0) > 1 and rootIDs ~= nil and #rootIDs > 0
    if isSelectionDrag then
        return rootIDs
    end

    return { row.auraID }
end

--- Starts dragging a row (or the selection it's in): makes the drop
--- highlight, the line, and the ghost name that follows the mouse.
---@param row ListRow
---@param aura Aura
local function startDrag(row, aura)
    local auraIDs = draggedIDs(row)
    local moving = {}
    for _, auraID in ipairs(auraIDs) do
        moving[auraID] = true
    end

    drag = { auraIDs = auraIDs, moving = moving, row = row }
    drag.highlight = rectangles.Filled(view.content, DROP_INTO_RGBA)
    drag.highlight.hidden = true
    drag.line = rectangles.Filled(view.content, uiConstants.ACCENT_RGBA)
    drag.line.hidden = true
    drag.ghost = ui.Text.new(view.content)
    drag.ghost.font = gameApi.Font(NAME_FONT)
    drag.ghost.rgba = uiConstants.ACCENT_RGBA
    drag.ghost.isShadowed = true
    drag.ghost.maxLines = 1
    drag.ghost.clickthrough = true
    drag.ghost.content = #auraIDs > 1 and formatStr("Move {} selected", #auraIDs) or "Move " .. gameText.Plain(aura.name)
    drag.ghost:SetSize(math.max(1, contentWidth() - PADDING * 2 - BUTTON_STEP), BUTTON_SIZE)
    drag.ghost:MoveToFront()
end

--- Follows the mouse during a drag, showing where a drop would go.
---@param contentY number In list coordinates.
local function moveDrag(contentY)
    drag.ghost:SetPos(PADDING + BUTTON_STEP, contentY - BUTTON_SIZE // 2)
    local target = dropAt(contentY)
    drag.target = target
    drag.highlight.hidden = target == nil or target.into == nil
    drag.line.hidden = target == nil or target.into ~= nil

    if target == nil then
        return
    end

    if target.into ~= nil then
        coverRow(drag.highlight, target.into)
    else
        local lineX = PADDING + target.depth * INDENT
        drag.line:SetPos(lineX, target.lineY - DROP_LINE_HEIGHT // 2)
        drag.line:SetSize(math.max(1, contentWidth() - lineX - PADDING), DROP_LINE_HEIGHT)
    end
end

--- How a click changes the selection, from the keys held as it's released:
--- Shift for a range (with Ctrl too), Ctrl to add or take out one row.
--- FIXME: after typing in the search box, the game blocks keyboard reads,
--- so Ctrl and Shift read as up and a click selects one row alone.
---@return SelectMode
local function clickMode()
    if gameApi.IsShiftDown() then
        return "range"
    end

    if gameApi.IsControlDown() then
        return "toggle"
    end

    return "only"
end

--- Every row's aura, top to bottom, built or not.
---@return integer[]
local function shownIDs()
    local ids = {}
    for index, row in ipairs(rows) do
        ids[index] = row.auraID
    end

    return ids
end

--- Makes a row's name clickable and draggable, through an invisible hit area
--- over it, and highlights the row under the mouse. A press only becomes a drag
--- once it has moved DRAG_THRESHOLD.
---@param row ListRow
---@param aura Aura
local function bindRow(row, aura)
    -- Empty text rather than a layer, as text is what showed the cursor.
    local hit = ui.Text.new(view.content)
    hit.content = ""
    hit.enabled = true
    hit.clickthrough = false
    hit:Subscribe(ui.Hook.ONSCROLLWHEEL, scrollByWheel)
    row.hit = hit
    release(row)
    buttonCursor.Apply(hit)
    -- Where it was pressed, in list coordinates, and whether the hit area
    -- has been expanded yet.
    local press = nil

    hit:Subscribe(ui.Hook.ONMOUSEOVER, function()
        notePointer(row, hit, true)
        return false
    end)

    hit:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        notePointer(row, hit, false)
        return false
    end)

    hit:Subscribe(ui.Hook.ONCLICK, function(component, x, y)
        press = { x = (component.x or 0) + x, y = (component.y or 0) + y }
        row.pressed = true
        return false
    end)

    hit:Subscribe(ui.Hook.ONHOLD, function(component, x, y)
        if press == nil then
            return false
        end

        -- Hook coordinates are relative to the hit area, which is at the
        -- list's origin once expanded.
        if not press.captured then
            x, y = (component.x or 0) + x, (component.y or 0) + y
            press.captured = true
            capture(row)
        end

        local movedFar = math.abs(x - press.x) + math.abs(y - press.y) >= DRAG_THRESHOLD
        if drag == nil and movedFar then
            startDrag(row, aura)
        end

        if drag ~= nil and drag.row == row then
            moveDrag(y)
        end

        return false
    end)

    local function onRelease()
        local pressed = press
        press = nil
        row.pressed = false

        if drag ~= nil and drag.row == row then
            finishDrag()
        elseif pressed ~= nil then
            if pressed.captured then
                release(row)
            end

            if options.onSelect ~= nil then
                local mode = clickMode()
                options.onSelect(aura.id, mode, mode == "range" and shownIDs() or nil)
            end
        end

        return false
    end

    hit:Subscribe(ui.Hook.ONRELEASE, onRelease)
    hit:Subscribe(ui.Hook.ONDRAGCOMPLETE, onRelease)
end

--- Adds a tintable row action that forwards scrolling to the list.
---@param row ListRow
---@param name string Heroicons filename without its extension.
---@param x number
---@param xAnchor number FROM_LEFT or FROM_RIGHT: which edge x is measured from.
---@param action fun() Runs when it's clicked.
---@return userdata icon
local function addIcon(row, name, x, xAnchor, action)
    local icon = heroIcons.Sprite(view.content, name)
    icon:SetPos(x, row.y, xAnchor, TOP)
    icon:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    icon.enabled = true
    icon.clickthrough = false
    icon:Subscribe(ui.Hook.ONSCROLLWHEEL, scrollByWheel)
    buttonCursor.Apply(icon)

    icon:Subscribe(ui.Hook.ONMOUSEOVER, function()
        icon.rgba = uiConstants.ACCENT_RGBA
        notePointer(row, icon, true)
        return false
    end)

    icon:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        icon.rgba = NAME_COLOUR
        notePointer(row, icon, false)
        return false
    end)

    icon:Subscribe(ui.Hook.ONCLICK, function()
        action()
        return false
    end)

    return icon
end

--- Adds a row's name, muted for a hidden aura.
---@param row ListRow
---@param aura Aura
local function addRowName(row, aura)
    local text, highlighted = rowTexts(aura)
    row.text = row.selected and highlighted or text
    row.hoverText = highlighted
    local label = ui.Text.new(view.content)
    label.font = gameApi.Font(NAME_FONT)
    label.rgba = aura.enabled and NAME_COLOUR or uiConstants.MUTED_RGBA
    label.isShadowed = true
    label.alignVertical = ui.AlignMode.CENTRE
    label.maxLines = 1
    label.clickthrough = true
    label.content = row.text
    label:SetPos(row.nameX, row.y)
    label:SetSize(math.max(1, contentWidth() - row.nameX - NAME_RIGHT - (row.isGroup and COUNT_WIDTH or 0)), BUTTON_SIZE)
    row.label = label
end

--- Adds an aura's icon where a group's arrow would be: its data source's
--- sprite or item, faded while the aura is hidden. Nothing without one.
---@param row ListRow
---@param aura Aura
---@param rowX number
local function addSourceIcon(row, aura, rowX)
    local _, spriteID, objectID = dataSources.Details(aura.source)
    local icon = SourceIcon.NewStill(view.content, spriteID, objectID, ICON_SIZE)
    if icon == nil then
        return
    end

    icon:SetPos(rowX + ICON_INSET, row.y + ICON_INSET)

    if not aura.enabled then
        icon.alpha = HIDDEN_AURA_ALPHA
    end
end

--- Adds a group's item count, right-aligned where its buttons go.
---@param row ListRow
---@param group Aura
local function addCount(row, group)
    local count = ui.Text.new(view.content)
    count.font = gameApi.Font(NAME_FONT)
    count.rgba = uiConstants.MUTED_RGBA
    count.isShadowed = true
    count.alignHorizontal = ui.AlignMode.BOTTOMRIGHT
    count.alignVertical = ui.AlignMode.CENTRE
    count.maxLines = 1
    count.clickthrough = true
    count.content = tostring(#(childrenOf[group.id] or {}))
    count:SetPos(-(NAME_RIGHT + COUNT_WIDTH), row.y, FROM_RIGHT, TOP)
    count:SetSize(COUNT_WIDTH, BUTTON_SIZE)
end

--- Saves an aura's visibility and refreshes its row and display.
---@param auraID integer
---@param enabled boolean
local function setVisibility(auraID, enabled)
    if auraStore.Get(auraID) == nil then
        return
    end

    auraStore.Set(auraID, "enabled", enabled)
    changed()
    rerender()
end

--- Selects a menu's row unless a left press or drag already owns the input.
---@param row ListRow
local function selectFromMenu(row)
    if row.pressed or drag ~= nil then
        return
    end

    if options.onSelect ~= nil then
        options.onSelect(row.aura.id)
    end
end

--- Moves a named plugin entry to its priority position.
---@param menu userdata The writable mini-menu.
---@param label string The complete label supplied when adding the entry.
---@param position integer One-based position, highest priority last.
local function placeMenuEntry(menu, label, position)
    for index, entry in ipairs(menu.entries) do
        if entry.fullText == label or entry.overrideText == label then
            if index ~= position then
                menu:Swap(index, position)
            end

            return
        end
    end
end

--- Keeps Cancel at the bottom and our actions on top, in the order given.
---@param menu userdata The writable mini-menu.
---@param labels string[] Our actions' labels, the topmost first.
local function orderRowMenu(menu, labels)
    for index, entry in ipairs(menu.entries) do
        if entry.actionType == MiniMenuActionType.CANCEL then
            if index ~= 1 then
                menu:Swap(index, 1)
            end

            break
        end
    end

    local count = #menu.entries
    for index, label in ipairs(labels) do
        placeMenuEntry(menu, label, count - index + 1)
    end
end

--- Runs a row's menu action for its aura, unless a left press or drag
--- already owns the input.
---@param action fun(auraID: integer)?
---@param row ListRow
local function runRowAction(action, row)
    if action == nil or row.pressed or drag ~= nil then
        return
    end

    action(row.aura.id)
end

--- Runs a menu action for the whole selection, unless a left press or
--- drag already owns the input.
---@param action fun()?
---@param row ListRow The row the menu was opened on.
local function runSelectionAction(action, row)
    if action == nil or row.pressed or drag ~= nil then
        return
    end

    action()
end

--- Adds the hovered row's actions: on a row of several selected, Group and
--- Delete for all of them first; then Edit, Hide or Show, Duplicate (not
--- for a group, as duplicating one doesn't copy its contents), Export and
--- Delete, each named with the aura.
---@param event table The writable MiniMenuReady event.
local function addRowMenu(event)
    if view == nil or drag ~= nil then
        return
    end

    for _, row in ipairs(rows) do
        if row.built and next(row.pointerOver) ~= nil and not row.pressed then
            local menu = event.miniMenu
            local aura = row.aura
            local name = "<col=" .. uiConstants.ACCENT_HEX .. ">" .. gameText.Plain(aura.name) .. "</col>"
            local labels = {}
            local count = options.selectedCount or 0
            if row.selected and count > 1 then
                labels[#labels + 1] = formatStr("Group {} selected", count)
                menu:Add(labels[#labels], runSelectionAction, options.onGroupSelected, row)
                labels[#labels + 1] = formatStr("Delete {} selected", count)
                menu:Add(labels[#labels], runSelectionAction, options.onDeleteSelected, row)
            end

            labels[#labels + 1] = "Edit " .. name
            menu:Add(labels[#labels], selectFromMenu, row)
            labels[#labels + 1] = (aura.enabled and "Hide " or "Show ") .. name
            menu:Add(labels[#labels], setVisibility, aura.id, not aura.enabled)

            if not row.isGroup then
                labels[#labels + 1] = "Duplicate " .. name
                menu:Add(labels[#labels], runRowAction, options.onDuplicate, row)
            end

            labels[#labels + 1] = "Export " .. name
            menu:Add(labels[#labels], runRowAction, options.onExport, row)
            labels[#labels + 1] = "Delete " .. name
            menu:Add(labels[#labels], runRowAction, options.onDelete, row)
            orderRowMenu(menu, labels)
            return
        end
    end
end

--- Adds a smaller, centred crossed eye that restores a hidden aura.
---@param row ListRow
---@param aura Aura
local function addVisibilityIcon(row, aura)
    if aura.enabled then
        return
    end

    row.eye = addIcon(row, ICONS.hidden, EYE_X, FROM_RIGHT, function()
        setVisibility(aura.id, true)
    end)
    row.eye:SetPos(EYE_X + EYE_INSET, row.y + EYE_INSET, FROM_RIGHT, TOP)
    row.eye:SetSize(EYE_SIZE, EYE_SIZE)
end

--- Builds one row where it sits: a group's expand/collapse arrow and item
--- count, or an aura's icon; its name; and its visibility indicator.
---@param row ListRow
---@param aura Aura
local function buildRow(row, aura)
    local rowX = PADDING + row.depth * INDENT
    row.pointerOver = {}
    addRowBackground(row)

    if row.isGroup then
        addIcon(row, row.isOpen and ICONS.expanded or ICONS.collapsed, rowX, FROM_LEFT, function()
            if row.isOpen then
                collapsedGroups:Add(aura.id)
            else
                collapsedGroups:Remove(aura.id)
            end

            rerender()
        end)

        addCount(row, aura)
    else
        addSourceIcon(row, aura, rowX)
    end

    addRowName(row, aura)
    bindRow(row, aura)
    addVisibilityIcon(row, aura)
    row.built = true
    showHover(row)
end

--- A group's contents the list shows, in order: all of them, or while
--- searching only those it matched.
---@param groupID integer? nil for the top level.
---@return Aura[]
local function shownChildren(groupID)
    local children = childrenOf[groupID or TOP_LEVEL] or {}
    if matched == nil then
        return children
    end

    local shown = {}
    for _, aura in ipairs(children) do
        if matched[aura.id] then
            shown[#shown + 1] = aura
        end
    end

    return shown
end

--- Works out every row shown (groups' contents unless they're collapsed,
--- or all of them while searching), in order, with where each sits,
--- without building any.
---@param groupID integer? nil for the top level.
---@param depth integer
---@param ancestors table<integer, boolean> The groups this level is in.
---@param startY number Where the list starts.
local function addLevel(groupID, depth, ancestors, startY)
    local children = shownChildren(groupID)
    for index, aura in ipairs(children) do
        local nextSibling = children[index + 1]
        local isGroup = auraStore.IsGroup(aura)
        local rowX = PADDING + depth * INDENT
        local nameX = rowX + BUTTON_STEP
        local row = {
            auraID = aura.id,
            aura = aura,
            index = #rows + 1,
            isGroup = isGroup,
            isOpen = isGroup and (matched ~= nil or not collapsedGroups:Contains(aura.id)),
            depth = depth,
            groupID = aura.group,
            nextID = nextSibling and nextSibling.id or nil,
            ancestors = ancestors,
            selected = options.selected ~= nil and options.selected[aura.id] == true,
            nameX = nameX,
            hitX = isGroup and nameX or rowX,
            y = startY + #rows * ROW_STEP,
        }
        rows[#rows + 1] = row

        if row.isOpen then
            local inner = { [aura.id] = true }
            for id in pairs(ancestors) do
                inner[id] = true
            end

            local contents = shownChildren(aura.id)
            row.firstChildID = contents[1] and contents[1].id or nil
            addLevel(aura.id, depth + 1, inner, startY)
        end
    end
end

--- A blank of some rows, holding their place in the layout.
---@param count integer
local function addSpacer(count)
    if count <= 0 then
        return
    end

    view:AddText({ text = "", height = count * ROW_STEP - ROW_GAP })
end

--- Groups the store's list by parent, in order.
local function collectChildren()
    childrenOf = {}

    for _, aura in ipairs(auraStore.List()) do
        local parent = aura.group or TOP_LEVEL
        local contents = childrenOf[parent]
        if contents == nil then
            contents = {}
            childrenOf[parent] = contents
        end

        contents[#contents + 1] = aura
    end
end

--- Marks an aura and everything in it, at any depth, as matched.
---@param aura Aura
local function matchWithContents(aura)
    matched[aura.id] = true

    for _, child in ipairs(childrenOf[aura.id] or {}) do
        matchWithContents(child)
    end
end

--- Marks the groups an aura is in as matched, so the tree leads to it.
---@param aura Aura
local function matchAncestors(aura)
    local parentID = aura.group
    while parentID ~= nil and not matched[parentID] do
        matched[parentID] = true
        parentID = auraStore.Get(parentID).group
    end
end

--- Works out which auras a search shows (see matched).
---@param search string? nil or empty for no search.
local function collectMatches(search)
    matched = nil

    if search == nil or search == "" then
        return
    end

    matched = {}
    local wanted = search:lower()
    for _, aura in ipairs(auraStore.List()) do
        if gameText.Plain(aura.name):lower():find(wanted, 1, true) ~= nil then
            matchWithContents(aura)
            matchAncestors(aura)
        end
    end
end

--- Builds the rows from first to last. The game's limit on interface parts
--- can be reached partway (see the aura manager); the rest of the rows are
--- then left out. Anything else is a bug, so it isn't hidden.
---@param first integer
---@param last integer
---@return boolean limited Whether the limit cut it short.
local function buildRows(first, last)
    for index = first, last do
        local ok, problem = pcall(buildRow, rows[index], rows[index].aura)
        if not ok then
            if not gameApi.IsComponentLimitError(problem) then
                error(problem, 0)
            end

            return true
        end
    end

    return false
end

--- Shows a line of text in place of the rows.
---@param text string
local function showMessage(text)
    view:AddText({ text = text, height = EMPTY_HEIGHT, maxLines = EMPTY_LINES })
end

--- Deselects whatever is selected, showing the home page.
local function deselect()
    if (options.selectedCount or 0) > 0 and options.onSelect ~= nil then
        options.onSelect(nil)
    end
end

--- Makes the empty space below the list's last item, down to the bottom of
--- what shows, deselect the aura being edited when clicked. The view's
--- content ends at its last item, so a spacer extends it over that space
--- first, and an invisible area over the spacer takes the click (and passes
--- the mouse wheel on, as the rows do).
---@param top number Where the last item ends, in list coordinates.
local function makeDeselectArea(top)
    local spacerTop = top + GAP
    local spacerHeight = math.floor((options.viewHeight or 0) - spacerTop - DESELECT_AREA_MARGIN)
    if spacerHeight <= 0 then
        return
    end

    view:AddText({ text = "", height = spacerHeight })
    -- Empty text, as the rows' hit areas are.
    local area = ui.Text.new(view.content)
    area.content = ""
    area.enabled = true
    area.clickthrough = false
    area:SetPos(0, top)
    area:SetSize(contentWidth(), spacerTop + spacerHeight - top)
    area:Subscribe(ui.Hook.ONSCROLLWHEEL, scrollByWheel)

    area:Subscribe(ui.Hook.ONCLICK, function()
        deselect()
        return false
    end)
end

--- Adds the deselecting area (see makeDeselectArea). The game's limit on
--- interface parts can be reached making it, as for the rows (see
--- buildRows): the list then goes without it.
---@param top number Where the last item ends, in list coordinates.
local function addDeselectArea(top)
    local ok, problem = pcall(makeDeselectArea, top)
    if not ok and not gameApi.IsComponentLimitError(problem) then
        error(problem, 0)
    end
end

--- Builds the list into a view: the rows around what's on screen (where it
--- will be scrolled to, and half a screen either side), over one spacer
--- holding the whole list's height. Every row is several components, so
--- building them all would reach the game's limit of 4,096 with a few hundred
--- auras; rows are a fixed height, so each one's place is known unbuilt.
---@param listView table A PrettyUI SimpleView.
---@param listOptions AuraListOptions?
function auraList.Build(listView, listOptions)
    view = listView
    options = listOptions or {}
    Event.MiniMenuReady.Subscribe(MENU_EVENT_ID, addRowMenu)
    -- A rebuild ends any drag; its components went with the old view.
    drag = nil
    rows = {}
    -- Until rows are built, there's nothing to rebuild for scrolling.
    builtTop, builtBottom = nil, nil
    collectChildren()
    collectMatches(options.search)

    local startY = options.startY or 0
    if childrenOf[TOP_LEVEL] == nil then
        showMessage("No auras yet. Use New above to show game data on screen.")
        addDeselectArea(startY + EMPTY_HEIGHT)
        return
    end

    addLevel(nil, 0, {}, startY)

    if #rows == 0 then
        showMessage("No auras match.")
        addDeselectArea(startY + EMPTY_HEIGHT)
        return
    end

    local scrollY = options.scrollY or view.scrollY or 0
    -- The height that shows, not the view's height: that grows to fit its
    -- content, which would build every row.
    local height = math.max(ROW_STEP, options.viewHeight or 0)
    local margin = height * BUILD_MARGIN
    local first = math.max(1, math.floor((scrollY - margin - startY) / ROW_STEP) + 1)
    local last = math.min(#rows, math.ceil((scrollY + height + margin - startY) / ROW_STEP))
    addSpacer(#rows)
    addDeselectArea(startY + #rows * ROW_STEP - ROW_GAP)
    local limited = buildRows(first, last)
    builtTop = first > 1 and rows[first].y or -math.huge
    -- Cut short by the limit, scrolling on couldn't build more, so it
    -- doesn't ask to (a rebuild every frame).
    local builtToEnd = limited or last >= #rows or rows[last] == nil
    builtBottom = builtToEnd and math.huge or rows[last].y + BUTTON_SIZE
end

--- Whether the view has scrolled far enough past the rows this build made
--- that it should be rebuilt. Never mid-drag: a rebuild would drop it.
---@param scrollY number
---@param height number? How much of the view shows.
---@return boolean
function auraList.NeedsRender(scrollY, height)
    if view == nil or drag ~= nil or builtTop == nil then
        return false
    end

    local margin = (height or 0) * REBUILD_MARGIN
    return scrollY - margin < builtTop or scrollY + (height or 0) + margin > builtBottom
end

--- Forgets the view, e.g. when the window closes.
function auraList.Destroy()
    nextFrame.Cancel(HOVER_EVENT_ID)
    Event.MiniMenuReady.Unsubscribe(MENU_EVENT_ID)
    drag = nil
    rows = {}
    builtTop, builtBottom = nil, nil
    childrenOf = {}
    matched = nil
    view = nil
end

return auraList
