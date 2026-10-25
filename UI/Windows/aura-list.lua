-- The aura list on the left of the main window: every aura as a tree,
-- groups (marked by their expand arrow) indented with their contents and
-- collapsible. Clicking a row selects it for the editor; dragging a row's
-- name moves it to wherever it's dropped.
--
-- Only the rows near what's on screen are built: the game gives everything
-- we draw 4,096 components between them, and every row is several, so a
-- few hundred auras' rows ran it out. Rows are a fixed height, so every
-- row's place is worked out without building it, and one spacer holds the
-- whole list's height.

local auraStore = require("Auras/Store/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")
local rectangles = require("Auras/Displays/Parts/rectangles")
local gameText = require("Auras/Helpers/game-text")
local maths = require("Auras/Helpers/maths")

local auraList = {}

---@class AuraListOptions
---@field selectedID integer? The aura being edited.
---@field onSelect fun(auraID: integer?)?
---@field onChanged fun()? Auras were changed.
---@field onDelete fun(auraID: integer)? An aura's bin was clicked: asks how to delete it (see UI/Windows/delete-panel).
---@field requestRender fun()? Rebuild the list next frame.
---@field startY number? The view's layout startY.
---@field scrollY number? Where it'll be scrolled to.
---@field viewHeight number? How much of it shows.

--- One row of the list, worked out by addLevel; its components are only
--- made if it's built.
---@class ListRow
---@field auraID integer
---@field aura Aura
---@field isGroup boolean
---@field depth integer How many groups it's in.
---@field groupID integer? Its parent.
---@field nextID integer? Its next sibling.
---@field firstChildID integer? A shown group's first item.
---@field ancestors table<integer, boolean> The groups it's in.
---@field selected boolean
---@field nameX number Where its name starts, after the arrow or eye.
---@field y number Where it sits, in list coordinates.
---@field boxX number Its box, for highlighting a drop into it.
---@field boxWidth number
---@field label userdata? The name.
---@field hit userdata? The invisible area over the name that takes presses.
---@field tint userdata? The box's fill, whose colour shows hover and selection.
---@field text string? The name's text, plain or (selected) highlighted.
---@field hoverText string? The name's text under the mouse.

--- Where a drop would put the dragged row: a group and the item to go
--- before, for auraStore.Move, plus what to draw.
---@class DropTarget
---@field groupID integer? nil for the top level.
---@field beforeID integer? nil for the end of the group.
---@field lineY number? A line here, between rows.
---@field depth integer? The line's indent.
---@field into ListRow? Or this group's row highlighted.

---@class ListDrag
---@field auraID integer
---@field row ListRow The row being dragged.
---@field ghost userdata The dragged name, following the mouse.
---@field highlight userdata
---@field line userdata
---@field target DropTarget?

local PADDING = uiConstants.PADDING
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local GAP = uiConstants.GAP
local BUTTON_STEP = BUTTON_SIZE + GAP
-- SetPos's x anchor: the share of the parent's width x is measured from.
local FROM_LEFT, FROM_RIGHT = 0, 1
local TOP = 0
-- How far each level of groups is indented.
local INDENT = 16
-- Every row is a button tall, with the layout's row gap below it.
local ROW_STEP = BUTTON_SIZE + GAP
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
-- Each row sits in a box, indented with its depth so nesting shows, and
-- reaching a little past the row above and below.
local BOX_INSET = 4
local BOX_OUTSET = 2
local BOX_RGBA = 0xFFFFFF0C
local BOX_OUTLINE_RGBA = 0xFFFFFF26
local HOVER_ROW_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x1C)
local SELECTED_ROW_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x38)
local DROP_INTO_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x40)
local DROP_LINE_HEIGHT = 2
local NAME_COLOUR = 0xE7D7B0FF
local NAME_FONT = "MUSEO_SANS_15PT_REGULAR"
local EMPTY_HEIGHT, EMPTY_LINES = 48, 2
-- Space right of each name, for the duplicate and delete buttons.
local NAME_RIGHT = PADDING + BUTTON_STEP * 2
-- Group id to true for collapsed groups; remembered between sessions.
local COLLAPSED_STORAGE_KEY = "listCollapsedGroups"
-- childrenOf's key for the top level (a table can't be keyed by nil).
local TOP_LEVEL = false

-- Sprite names for the list's icons: normal, then under the mouse.
local ICONS = {
    expanded = { "RS3_ICON_DIRECTION_DOWN_32PX_2", "RS3_ICON_DIRECTION_DOWN_32PX_3" },
    collapsed = { "RS3_ICON_DIRECTION_RIGHT_32PX_2", "RS3_ICON_DIRECTION_RIGHT_32PX_3" },
    shown = { "RS3_ICON_WARDROBE_EFFECTS_24PX_2", "RS3_ICON_WARDROBE_EFFECTS_24PX_3" },
    hidden = { "RS3_ICON_HIDE_16PX_0", "RS3_ICON_HIDE_16PX_1" },
    duplicate = { "RS3_ICON_PURCHASE_MORE_0", "RS3_ICON_PURCHASE_MORE_1" },
    delete = { "HUD_COMBAT_BTN_BIN", "HUD_COMBAT_BTN_BIN_OVER" },
}

local view = nil
---@type AuraListOptions?
local options = nil
---@type table<integer, boolean>?
local collapsed = nil
---@type table<integer|boolean, Aura[]> This build's contents of each group, in order, worked out once rather than per row.
local childrenOf = {}
-- The cursor its names show.
local cursorID = nil
---@type ListRow[] This build's rows, top to bottom.
local rows = {}
---@type ListDrag?
local drag = nil
-- The stretch of the list this build made rows for, in list coordinates.
local builtTop, builtBottom = nil, nil

--- Loads which groups are collapsed, once.
local function loadCollapsed()
    if collapsed ~= nil then return end
    collapsed = {}
    for id in tostring(PersistentDB:GetString(COLLAPSED_STORAGE_KEY) or ""):gmatch("%d+") do
        collapsed[tonumber(id)] = true
    end
end

--- Collapses or opens a group, and saves which are collapsed. Groups deleted
--- since are forgotten.
---@param groupID integer
---@param isCollapsed boolean
local function setCollapsed(groupID, isCollapsed)
    loadCollapsed()
    collapsed[groupID] = isCollapsed or nil
    local list = {}
    for id in pairs(collapsed) do
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

---@return number
local function contentWidth()
    return math.max(1, view.contentWidth or 1)
end

--- A row's text, plain and highlighted: the name (gold when highlighted)
--- and, muted, what it is.
---@param aura Aura
---@return string plain
---@return string highlighted
local function rowTexts(aura)
    local name = gameText.Plain(aura.name)
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

--- Places a rectangle over a row's box.
---@param rectangle userdata
---@param row ListRow
local function coverRow(rectangle, row)
    rectangle:SetPos(row.boxX, row.y - BOX_OUTSET)
    rectangle:SetSize(row.boxWidth, BUTTON_SIZE + BOX_OUTSET * 2)
end

--- Places a new part of a row's box over the row, behind everything.
---@param row ListRow
---@param part userdata A rectangle in the list's content.
---@return userdata part
local function addBoxPart(row, part)
    coverRow(part, row)
    part:MoveToBack()
    return part
end

--- Adds the row's box: one fill whose colour shows hover and selection, and
--- an outline (gold when selected): two parts rather than a layered tint.
---@param row ListRow
---@param rowX number
local function addRowBox(row, rowX)
    row.boxX = math.max(0, rowX - BOX_INSET)
    row.boxWidth = math.max(1, contentWidth() - row.boxX - BOX_INSET)
    local fillRGBA = row.selected and SELECTED_ROW_RGBA or BOX_RGBA
    local outlineRGBA = row.selected and uiConstants.ACCENT_RGBA or BOX_OUTLINE_RGBA
    row.tint = addBoxPart(row, rectangles.Filled(view.content, fillRGBA))
    addBoxPart(row, rectangles.Outline(view.content, outlineRGBA))
end

--- Shows the button pointer while the mouse is over a component (its
--- cursor config's mouseOverCursor, per the API stubs).
---@param component userdata
local function applyButtonCursor(component)
    component.cursorConfig.mouseOverCursor = cursorID
end

--- Gives a clickable component the button pointer. Guarded: a component
--- without a cursor config just keeps the default.
---@param component userdata
local function setButtonCursor(component)
    if cursorID ~= nil then pcall(applyButtonCursor, component) end
end

--- Highlights a row while the mouse is over it (not the selected one, nor
--- during a drag).
---@param row ListRow
---@param hovered boolean
local function setHovered(row, hovered)
    if row.selected or drag ~= nil or row.tint == nil then return end
    row.tint.rgba = hovered and HOVER_ROW_RGBA or BOX_RGBA
    row.label.content = hovered and row.hoverText or row.text
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
    if not row.isGroup then return fraction < HALF and before or after end
    if fraction < GROUP_EDGE then return before end
    if fraction < 1 - GROUP_EDGE then return { groupID = row.auraID, beforeID = nil, into = row } end
    -- The bottom edge of an open group is the top of its contents.
    if row.firstChildID ~= nil then
        return { groupID = row.auraID, beforeID = row.firstChildID, lineY = bottom, depth = row.depth + 1 }
    end
    return after
end

--- Where a drop at a height in the list would put the dragged row.
---@param contentY number In list coordinates.
---@return DropTarget? target nil when it can't go there (onto itself, or into its own contents).
local function dropAtRow(contentY)
    if #rows == 0 then return nil end
    local lastRow = rows[#rows]
    local listBottom = lastRow.y + BUTTON_SIZE + GAP
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
            return dropOnRow(row, fraction, top, bottom)
        end
    end
    return nil
end

--- dropAtRow, but nil where the store wouldn't take it (a group into a
--- dynamic group, which holds auras only).
---@param contentY number
---@return DropTarget?
local function dropAt(contentY)
    local target = dropAtRow(contentY)
    if target ~= nil and target.groupID ~= nil
        and not auraStore.CanHold(auraStore.Get(target.groupID), auraStore.Get(drag.auraID)) then
        return nil
    end
    return target
end

-- Keeps auras in place on screen when they change group.
local areaSize = gameApi.GameAreaSize

--- Ends a drag, moving the dragged row to where it was released.
local function finishDrag()
    local finished = drag
    drag = nil
    if finished == nil then return end
    local target = finished.target
    if target ~= nil and auraStore.Move(finished.auraID, target.groupID, target.beforeID, areaSize()) then
        -- Show where it went.
        if target.groupID ~= nil then setCollapsed(target.groupID, false) end
        changed()
    end
    -- Rebuilding restores the expanded hit area and drops the drag visuals.
    rerender()
end

-- A row's hit area and icons take the mouse, so a wheel turned over them
-- never reaches the list's own scrolling; they scroll it themselves, this
-- far per notch. ONSCROLLWHEEL's delta is notches turned, positive down
-- (seen in game), and a row a notch matches the list's own scrolling.
local WHEEL_STEP = ROW_STEP

--- Scrolls the list for the mouse wheel turned over one of its rows.
---@param _ userdata The component under the mouse.
---@param delta integer The scrollWheelYDelta.
---@return boolean
local function scrollByWheel(_, delta)
    if view == nil or type(delta) ~= "number" or delta == 0 then return false end
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

--- Puts a row's hit area back over its name.
---@param row ListRow
local function release(row)
    row.hit:SetPos(row.nameX, row.y)
    row.hit:SetSize(math.max(1, contentWidth() - row.nameX - NAME_RIGHT), BUTTON_SIZE)
end

--- Starts dragging a row: makes the drop highlight, the line, and the ghost
--- name that follows the mouse.
---@param row ListRow
---@param aura Aura
local function startDrag(row, aura)
    drag = { auraID = aura.id, row = row }
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
    drag.ghost.content = "Move " .. gameText.Plain(aura.name)
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
    if target == nil then return end
    if target.into ~= nil then
        coverRow(drag.highlight, target.into)
    else
        local lineX = PADDING + target.depth * INDENT
        drag.line:SetPos(lineX, target.lineY - DROP_LINE_HEIGHT // 2)
        drag.line:SetSize(math.max(1, contentWidth() - lineX - PADDING), DROP_LINE_HEIGHT)
    end
end

--- Makes a row's name clickable and draggable, and highlights its row
--- while the mouse is over it. The name itself ignores the mouse: an
--- invisible hit area over it takes the press, so it can be expanded
--- without moving the text. A press takes hold of the mouse at once, but
--- only becomes a drag once it has moved DRAG_THRESHOLD.
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
    setButtonCursor(hit)
    -- Where it was pressed, in list coordinates, and whether the hit area
    -- has been expanded yet.
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
        local movedFar = math.abs(x - press.x) + math.abs(y - press.y) >= DRAG_THRESHOLD
        if drag == nil and movedFar then startDrag(row, aura) end
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

--- Adds a list icon: a plain sprite that swaps to its highlighted version
--- under the mouse. (PrettyUI's sprite buttons are several interface parts
--- each, with their tooltips, and the game has 4,096 for everything we
--- draw: a row of them cost about 44.)
---@param names string[] Sprite names: normal, then under the mouse.
---@param x number
---@param y number
---@param xAnchor number FROM_LEFT or FROM_RIGHT: which edge x is measured from.
---@param action fun() Runs when it's clicked.
---@return userdata icon
local function addIcon(names, x, y, xAnchor, action)
    local icon = ui.Sprite.new(view.content)
    local neutral, active = gameApi.Sprite(names[1]), gameApi.Sprite(names[2])
    if neutral ~= nil then icon.spriteID = neutral end
    icon:SetPos(x, y, xAnchor, TOP)
    icon:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    icon.enabled = true
    icon.clickthrough = false
    icon:Subscribe(ui.Hook.ONSCROLLWHEEL, scrollByWheel)
    setButtonCursor(icon)
    icon:Subscribe(ui.Hook.ONMOUSEOVER, function()
        if active ~= nil then icon.spriteID = active end
        return false
    end)
    icon:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        if neutral ~= nil then icon.spriteID = neutral end
        return false
    end)
    icon:Subscribe(ui.Hook.ONCLICK, function()
        action()
        return false
    end)
    return icon
end

--- Adds a row's name.
---@param row ListRow
---@param aura Aura
local function addRowName(row, aura)
    local text, highlighted = rowTexts(aura)
    row.text = row.selected and highlighted or text
    row.hoverText = highlighted
    local label = ui.Text.new(view.content)
    label.font = gameApi.Font(NAME_FONT)
    label.rgba = NAME_COLOUR
    label.isShadowed = true
    label.alignVertical = ui.AlignMode.CENTRE
    label.maxLines = 1
    label.clickthrough = true
    label.content = row.text
    label:SetPos(row.nameX, row.y)
    label:SetSize(math.max(1, contentWidth() - row.nameX - NAME_RIGHT), BUTTON_SIZE)
    row.label = label
end

--- Builds one row where it sits: for a group, an expand/collapse arrow;
--- then the eye, the name and, on the right, duplicate (auras only) and
--- delete. The icons that change auras rebuild the list after; delete only
--- asks how (see onDelete).
---@param row ListRow
---@param aura Aura
local function buildRow(row, aura)
    local auraID = aura.id
    local isGroup = row.isGroup
    local rowX = PADDING + row.depth * INDENT
    local y = row.y

    if isGroup then
        local isCollapsed = collapsed[auraID] == true
        addIcon(isCollapsed and ICONS.collapsed or ICONS.expanded, rowX, y, FROM_LEFT, function()
            setCollapsed(auraID, not isCollapsed)
            rerender()
        end)
    end
    -- Aura rows line their eye up with their group's eye, past the arrow.
    addIcon(aura.enabled and ICONS.shown or ICONS.hidden, rowX + BUTTON_STEP, y, FROM_LEFT, function()
        auraStore.Set(auraID, "enabled", not aura.enabled)
        changed()
        rerender()
    end)
    addRowName(row, aura)
    addRowBox(row, rowX)
    bindRow(row, aura)

    if not isGroup then
        -- Copying a group would mean copying everything in it; not yet.
        addIcon(ICONS.duplicate, -(PADDING + BUTTON_SIZE + BUTTON_STEP), y, FROM_RIGHT, function()
            local copy = auraStore.Duplicate(auraID, areaSize())
            if copy == nil then return end
            changed()
            if options.onSelect ~= nil then options.onSelect(copy.id) end
            rerender()
        end)
    end
    addIcon(ICONS.delete, -(PADDING + BUTTON_SIZE), y, FROM_RIGHT, function()
        if options.onDelete ~= nil then options.onDelete(auraID) end
    end)
end

--- Works out every row shown (groups' contents unless they're collapsed),
--- in order, with where each sits, without building any.
---@param groupID integer? nil for the top level.
---@param depth integer
---@param ancestors table<integer, boolean> The groups this level is in.
---@param startY number Where the list starts.
local function addLevel(groupID, depth, ancestors, startY)
    local children = childrenOf[groupID or TOP_LEVEL] or {}
    for index, aura in ipairs(children) do
        local nextSibling = children[index + 1]
        local isGroup = auraStore.IsGroup(aura)
        local rowX = PADDING + depth * INDENT
        local row = {
            auraID = aura.id,
            aura = aura,
            isGroup = isGroup,
            depth = depth,
            groupID = aura.group,
            nextID = nextSibling and nextSibling.id or nil,
            ancestors = ancestors,
            selected = aura.id == options.selectedID,
            nameX = rowX + BUTTON_STEP * 2,
            y = startY + #rows * ROW_STEP,
            -- As addRowBox makes it.
            boxX = math.max(0, rowX - BOX_INSET),
        }
        row.boxWidth = math.max(1, contentWidth() - row.boxX - BOX_INSET)
        rows[#rows + 1] = row
        if isGroup and collapsed[aura.id] ~= true then
            local inner = { [aura.id] = true }
            for id in pairs(ancestors) do inner[id] = true end
            local contents = childrenOf[aura.id]
            row.firstChildID = contents and contents[1].id or nil
            addLevel(aura.id, depth + 1, inner, startY)
        end
    end
end

--- A blank of some rows, holding their place in the layout.
---@param count integer
local function addSpacer(count)
    if count <= 0 then return end
    view:AddText({ text = "", height = count * ROW_STEP - GAP })
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
            if not gameApi.IsComponentLimitError(problem) then error(problem, 0) end
            return true
        end
    end
    return false
end

--- Builds the list into a view: the rows around what's on screen (where it
--- will be scrolled to, and half a screen either side), over one spacer
--- holding the whole list's height.
---@param listView table A PrettyUI SimpleView.
---@param listOptions AuraListOptions?
function auraList.Build(listView, listOptions)
    view = listView
    options = listOptions or {}
    -- A rebuild ends any drag; its components went with the old view.
    drag = nil
    rows = {}
    loadCollapsed()
    cursorID = gameApi.Cursor("CURSOR_BLANK")
    collectChildren()

    if childrenOf[TOP_LEVEL] == nil then
        view:AddText({
            text = "No auras yet. Use New above to show game data on screen.",
            height = EMPTY_HEIGHT,
            maxLines = EMPTY_LINES,
        })
        return
    end
    local startY = options.startY or 0
    addLevel(nil, 0, {}, startY)
    local scrollY = options.scrollY or view.scrollY or 0
    -- The height that shows, not the view's own: that grows to fit its
    -- content, which would build every row.
    local height = math.max(ROW_STEP, options.viewHeight or 0)
    local margin = height * BUILD_MARGIN
    local first = math.max(1, math.floor((scrollY - margin - startY) / ROW_STEP) + 1)
    local last = math.min(#rows, math.ceil((scrollY + height + margin - startY) / ROW_STEP))
    addSpacer(#rows)
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
    if view == nil or drag ~= nil or builtTop == nil then return false end
    local margin = (height or 0) * REBUILD_MARGIN
    return scrollY - margin < builtTop or scrollY + (height or 0) + margin > builtBottom
end

--- Forgets the view, e.g. when the window closes.
function auraList.Destroy()
    drag = nil
    rows = {}
    builtTop, builtBottom = nil, nil
    childrenOf = {}
    view = nil
end

return auraList
