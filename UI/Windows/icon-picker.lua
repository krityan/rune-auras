-- The icon picker: a window for choosing an Icon aura's icon from the icon
-- catalogue, searched by name. Its grid builds only the rows on screen and
-- reuses them, as thousands of icons would pass the game's interface part limit.

local iconCatalogue = require("GameData/Catalogues/icon-catalogue")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local rectangles = require("Auras/Displays/Parts/rectangles")
local gameText = require("Auras/Helpers/game-text")
local maths = require("Auras/Helpers/maths")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local windowRect = require("UI/Windows/window-rect")
local gameApi = require("GameData/game-api")

local iconPicker = {}

---@class IconPickerOptions
---@field auraID integer The aura it chooses for (see CloseUnlessFor).
---@field title string The window's title, naming the aura.
---@field beside Rect? The window it's opened from, to open beside; nil opens it in the middle of the game area.
---@field spriteID integer? The sprite chosen now, outlined in the grid.
---@field itemID integer? The item chosen now.
---@field onPick fun(entry: IconEntry) Called with the icon clicked, once the picker has closed.

--- One place in the grid: two sprites, as an item's icon is drawn from the
--- item rather than a sprite id (see SourceIcon).
---@class IconCell
---@field sprite userdata Draws a sprite.
---@field item userdata Draws an item.
---@field resultIndex integer? The result it shows, by its place in the results.

local SEARCH_EVENT_ID = "runeAuras_iconPickerSearch"
local PICK_EVENT_ID = "runeAuras_iconPickerPick"
local WATCH_EVENT_ID = "runeAuras_iconPickerWatch"
local WINDOW_HEIGHT = 520
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
-- The search field's row.
local HEADER_HEIGHT = 48
local HEADER_START_Y = 8
local SEARCH_LENGTH = 64
-- Each of the two lines under the search field.
local LINE_HEIGHT = 20
local STATUS_HEIGHT = LINE_HEIGHT * 2 + GAP
local GRID_TOP = HEADER_HEIGHT + STATUS_HEIGHT
local CELL_SIZE = 36
local CELL_STEP = CELL_SIZE + GAP
-- Icons a row.
local COLUMNS = 8
-- PrettyUI's window frame, each side of its content.
local FRAME_WIDTH = 8
-- How far in from its right edge PrettyUI's scroll view puts its scrollbar.
local SCROLLBAR_ROOM = 13
-- Fits COLUMNS icons, with as much room between the last and the scrollbar
-- as before the first.
local WINDOW_WIDTH = FRAME_WIDTH * 2 + PADDING * 2 + COLUMNS * CELL_STEP - GAP + SCROLLBAR_ROOM
-- Rows built past what shows: one above and one below.
local SPARE_ROWS = 2
-- How far outside its icon a cell's outline is drawn, into the gap.
local OUTLINE_OUTSET = 2
-- Space above the first row, so its outlines aren't cut off by the grid's top edge.
local GRID_TOP_MARGIN = GAP // 2
local HOVER_RGBA = uiConstants.WithAlpha(uiConstants.ACCENT_RGBA, 0x80)
local CHOSEN_RGBA = uiConstants.ACCENT_RGBA
local NAME_COLOUR = 0xE7D7B0FF
local TEXT_FONT = "MUSEO_SANS_15PT_REGULAR"
local EMPTY_HEIGHT = 40
local KIND_LABELS = { ability = "Ability", buff = "Buff", debuff = "Debuff", item = "Item" }

local prettyUI = nil
local window = nil
---@type IconPickerOptions?
local options = nil
-- The grid's scroll view, which only holds the results' height and the
-- scrollbar, made again for each search; the layer it's in; and the layer
-- over it holding the cells (see openWindow).
local gridView = nil
local scrollHolder, cellLayer = nil, nil
-- How far the grid is scrolled, as the cells are placed.
local scrolledY = 0
---@type { name: userdata, detail: userdata }?
local status = nil
local query = ""
---@type IconEntry[]
local results = {}
-- The place in the results of the icon chosen now; nil if it's not among them.
local chosenIndex = nil
---@type IconCell[] Reused as the grid scrolls: a result's cell is its place in the results, wrapped round the list.
local cells = {}
-- How many cells there are: enough for the rows on screen and the spare ones.
local poolSize = 0
---@type IconCell? The cell under the mouse.
local hoveredCell = nil
local hoverOutline, chosenOutline = nil, nil
-- Whether the game ran out of interface parts building this grid, so no more cells are tried.
local limitReached = false
-- Whether that's been logged this session.
local warnedLimit = false

--- How tall the grid shows, below the search field and status lines: from
--- the window's height until its content has been laid out.
---@return number
local function gridHeight()
    local contentHeight = window.content.height or 0
    if contentHeight <= 0 then
        contentHeight = WINDOW_HEIGHT
    end

    return math.max(1, contentHeight - GRID_TOP)
end

--- Where a result's cell sits in the cells' layer, as the grid is scrolled.
---@param resultIndex integer
---@return number x
---@return number y
local function cellPosition(resultIndex)
    local row, column = (resultIndex - 1) // COLUMNS, (resultIndex - 1) % COLUMNS
    return PADDING + column * CELL_STEP, GRID_TOP_MARGIN + row * CELL_STEP - scrolledY
end

--- Shows what's under the mouse, or with nothing there, how many icons
--- were found and whether the items are still loading.
---@param entry IconEntry?
local function showStatus(entry)
    if status == nil then
        return
    end

    if entry ~= nil then
        status.name.content = gameText.Plain(entry.name)
        status.detail.content = KIND_LABELS[entry.kind] .. ": " .. gameText.Plain(entry.key)
        return
    end

    status.name.content = #results == 1 and "1 icon" or formatStr("{} icons", #results)
    local detail = ""
    if limitReached then
        detail = "Too much on screen to show them all"
    elseif not iconCatalogue.ItemsLoaded() then
        detail = "Loading items..."
    end

    status.detail.content = detail
end

--- Notes that the game ran out of interface parts building the picker, and
--- logs it once a session. Any other error is a bug, so it's raised again.
---@param problem any The error.
local function reportBuildFailure(problem)
    if not gameApi.IsComponentLimitError(problem) then
        error(problem, 0)
    end

    limitReached = true

    if warnedLimit then
        return
    end

    warnedLimit = true
    log("RuneAuras: the icon picker can't be shown in full: the game's limit on interface parts was reached. "
        .. "Disabling or deleting auras you don't use makes room.")
end

--- Places an outline around a result's cell, or hides it.
---@param outline userdata
---@param resultIndex integer? nil hides it.
local function placeOutline(outline, resultIndex)
    outline.hidden = resultIndex == nil

    if resultIndex == nil then
        return
    end

    local x, y = cellPosition(resultIndex)
    outline:SetPos(x - OUTLINE_OUTSET, y - OUTLINE_OUTSET)
    outline:SetSize(CELL_SIZE + OUTLINE_OUTSET * 2, CELL_SIZE + OUTLINE_OUTSET * 2)
end

--- Scrolls the grid for the mouse wheel turned over a cell, which takes the
--- wheel from the grid's scrolling. A notch scrolls a row.
---@param _ userdata
---@param delta integer Notches turned, positive down.
---@return boolean
local function scrollByWheel(_, delta)
    if gridView == nil or type(delta) ~= "number" or delta == 0 then
        return false
    end

    local farthest = math.max(0, (gridView.contentHeight or 0) - gridHeight())
    gridView:SetScrollPosition(maths.Clamp((gridView.scrollY or 0) + delta * CELL_STEP, 0, farthest))
    return false
end

--- Uses a cell's icon: closes the picker and reports it, after the click's
--- callback, as closing destroys the cell.
---@param cell IconCell
local function pick(cell)
    local entry = cell.resultIndex and results[cell.resultIndex]
    if entry == nil or options == nil then
        return
    end

    local onPick = options.onPick
    nextFrame.Run(PICK_EVENT_ID, function()
        iconPicker.Close()
        onPick(entry)
    end)
end

--- Makes a cell's sprite clickable, outlining it and naming its icon while
--- the mouse is over it.
---@param cell IconCell
---@param sprite userdata
local function bindCell(cell, sprite)
    sprite.enabled = true
    sprite.clickthrough = false
    sprite:Subscribe(ui.Hook.ONSCROLLWHEEL, scrollByWheel)

    sprite:Subscribe(ui.Hook.ONMOUSEOVER, function()
        hoveredCell = cell
        placeOutline(hoverOutline, cell.resultIndex)
        showStatus(results[cell.resultIndex])
        return false
    end)

    sprite:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        if hoveredCell ~= cell then
            return false
        end

        hoveredCell = nil
        placeOutline(hoverOutline, nil)
        showStatus(nil)
        return false
    end)

    sprite:Subscribe(ui.Hook.ONCLICK, function()
        pick(cell)
        return false
    end)
end

--- A new, empty cell in the grid.
---@return IconCell
local function newCell()
    local cell = {}
    for _, part in ipairs({ "sprite", "item" }) do
        local sprite = ui.Sprite.new(cellLayer)
        sprite.hidden = true
        sprite:SetSize(CELL_SIZE, CELL_SIZE)
        bindCell(cell, sprite)
        cell[part] = sprite
    end

    return cell
end

--- Shows a result in a cell, or nothing past the last result.
---@param cell IconCell
---@param resultIndex integer
local function showResult(cell, resultIndex)
    cell.resultIndex = resultIndex
    local entry = results[resultIndex]
    local isItem = entry ~= nil and entry.item ~= nil
    if isItem then
        SourceIcon.ShowObject(cell.item, entry.item)
    elseif entry ~= nil then
        cell.sprite.spriteID = entry.sprite
    end

    cell.sprite.hidden = entry == nil or isItem
    cell.item.hidden = not isItem
end

--- Moves a cell to its result's place, as the grid is scrolled.
---@param cell IconCell
local function placeCell(cell)
    local x, y = cellPosition(cell.resultIndex)
    cell.sprite:SetPos(x, y)
    cell.item:SetPos(x, y)
end

--- Hides every cell and outline, as when the grid couldn't be shown.
local function hideCells()
    for _, cell in pairs(cells) do
        cell.resultIndex = nil
        cell.sprite.hidden, cell.item.hidden = true, true
    end

    placeOutline(hoverOutline, nil)
    placeOutline(chosenOutline, nil)
end

--- The cell for a result, made the first time its place in the pool is used.
---@param resultIndex integer
---@return IconCell? cell nil once the game has run out of interface parts.
local function cellFor(resultIndex)
    local slot = (resultIndex - 1) % poolSize + 1
    if cells[slot] ~= nil or limitReached then
        return cells[slot]
    end

    local ok, made = pcall(newCell)
    if not ok then
        reportBuildFailure(made)
        showStatus(nil)
        return nil
    end

    cells[slot] = made
    return made
end

--- Shows the rows from one just above what's on screen to one just below
--- it, so a row scrolled in is already there, and places them as the grid
--- is scrolled. Only cells whose result changed are drawn again.
local function showRows()
    local firstRow = math.max(0, math.floor((scrolledY - GRID_TOP_MARGIN) / CELL_STEP))
    local first = math.max(0, firstRow - SPARE_ROWS // 2) * COLUMNS + 1
    for resultIndex = first, first + poolSize - 1 do
        local cell = cellFor(resultIndex)
        if cell ~= nil then
            if cell.resultIndex ~= resultIndex then
                showResult(cell, resultIndex)
            end

            placeCell(cell)
        end
    end

    local isChosenShown = chosenIndex ~= nil and chosenIndex >= first and chosenIndex < first + poolSize
    placeOutline(chosenOutline, isChosenShown and chosenIndex or nil)

    -- The cell under the mouse moved, and may show another icon now.
    if hoveredCell ~= nil then
        local entry = results[hoveredCell.resultIndex]
        placeOutline(hoverOutline, entry ~= nil and hoveredCell.resultIndex or nil)
        showStatus(entry)
    end
end

--- Works out how many cells the grid needs from its height, dropping cells
--- made for another: the window's content may not have been laid out when
--- it first searched (see gridHeight).
local function fitPool()
    local shownRows = math.ceil(gridHeight() / CELL_STEP)
    local fitSize = (shownRows + SPARE_ROWS) * COLUMNS
    if fitSize == poolSize then
        return
    end

    for _, cell in pairs(cells) do
        cell.sprite:Destroy()
        cell.item:Destroy()
    end

    cells, hoveredCell = {}, nil
    poolSize = fitSize
end

--- Shows the results from the top: a new scroll view holding their height
--- (or saying none match), and the cells, kept from the last search, given
--- the new results.
local function showResults()
    if gridView ~= nil then
        gridView:Destroy()
    end

    gridView = nil
    fitPool()
    gridView = prettyUI.SimpleView.new(scrollHolder, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        width = 0,
        widthAnchor = 1,
        height = 0,
        heightAnchor = 1,
        layout = { startY = 0, paddingLeft = PADDING, paddingRight = PADDING, rowGap = 0 },
    })

    if #results == 0 then
        gridView:AddText({ text = "No icons match.", height = EMPTY_HEIGHT, colour = uiConstants.MUTED_RGBA })
    else
        gridView:AddText({ text = "", height = GRID_TOP_MARGIN + math.ceil(#results / COLUMNS) * CELL_STEP })
    end

    scrolledY, limitReached = 0, false

    for _, cell in pairs(cells) do
        cell.resultIndex = nil
    end

    showRows()
end

--- Whether an entry is the icon chosen now.
---@param entry IconEntry
---@return boolean
local function isChosen(entry)
    if entry.item ~= nil then
        return entry.item == options.itemID
    end

    return entry.sprite == options.spriteID
end

--- Searches for what's typed and shows the results. A grid the game runs
--- out of interface parts for goes, rather than staying half made.
local function runSearch()
    if window == nil then
        return
    end

    results = iconCatalogue.Search(query)
    chosenIndex = nil

    for index, entry in ipairs(results) do
        if isChosen(entry) then
            chosenIndex = index
            break
        end
    end

    local shown, problem = pcall(showResults)
    if not shown then
        if gridView ~= nil then
            gridView:Destroy()
        end

        gridView = nil
        hideCells()
        reportBuildFailure(problem)
    end

    showStatus(nil)
end

--- Moves the cells with the scroll view, each frame it's scrolled.
local function watchScroll()
    if gridView == nil then
        return
    end

    local scrollY = gridView.scrollY or 0
    if scrollY == scrolledY then
        return
    end

    scrolledY = scrollY
    showRows()
end

--- A line of text under the search field.
---@param y number
---@param rgba integer
---@return userdata
local function addStatusLine(y, rgba)
    local text = ui.Text.new(window.content)
    text.font = gameApi.Font(TEXT_FONT)
    text.rgba = rgba
    text.isShadowed = true
    text.maxLines = 1
    text.clickthrough = true
    text:SetPos(PADDING, y)
    text:SetSize(-(PADDING * 2), LINE_HEIGHT, 1, 0)
    return text
end

--- A layer over the grid's area, below the search field and status lines,
--- that lets the mouse through except where its contents take it.
---@param rightMargin number Kept clear on the right.
---@return userdata
local function addGridLayer(rightMargin)
    local layer = ui.Layer.new(window.content)
    layer.enabled = true
    layer.clickthrough = true
    layer:SetPos(0, GRID_TOP)
    layer:SetSize(-rightMargin, -GRID_TOP, 1, 1)
    return layer
end

--- Adds the grid's two layers: one for the scroll view, and over it, clear of
--- its scrollbar, one for the cells. A scroll view can't change height, so each
--- search makes another; the cells are kept and follow it (see watchScroll).
local function buildGridLayers()
    scrollHolder = addGridLayer(0)
    cellLayer = addGridLayer(SCROLLBAR_ROOM)
    -- Made before the cells, so under them, but around them in the gap.
    hoverOutline = rectangles.Outline(cellLayer, HOVER_RGBA)
    hoverOutline.hidden = true
    chosenOutline = rectangles.Outline(cellLayer, CHOSEN_RGBA)
    chosenOutline.hidden = true
end

--- Adds the search field and the lines naming the icon under the mouse.
local function buildHeader()
    local header = prettyUI.SimpleView.new(window.content, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        x = 0,
        y = 0,
        width = 0,
        widthAnchor = 1,
        height = HEADER_HEIGHT,
        scrollable = false,
        layout = { startY = HEADER_START_Y, paddingLeft = PADDING, paddingRight = PADDING, rowGap = GAP },
    })
    header:AddTextField({
        placeholder = "Search by name",
        maxLength = SEARCH_LENGTH,
        tooltip = "Ability, buff or item; struct names too",
        onChange = function(_, _, content)
            query = tostring(content or "")
            nextFrame.Run(SEARCH_EVENT_ID, runSearch)
        end,
    })

    status = {
        name = addStatusLine(HEADER_HEIGHT, NAME_COLOUR),
        detail = addStatusLine(HEADER_HEIGHT + LINE_HEIGHT, uiConstants.MUTED_RGBA),
    }
end

--- Forgets the window and stops its work; the window itself is closed or
--- destroyed by the caller.
local function teardown()
    Event.Draw.Unsubscribe(WATCH_EVENT_ID)
    nextFrame.Cancel(SEARCH_EVENT_ID)
    iconCatalogue.StopLoading()
    window, options, gridView, status = nil, nil, nil, nil
    scrollHolder, cellLayer, scrolledY = nil, nil, 0
    cells, results, hoveredCell, hoverOutline, chosenOutline = {}, {}, nil, nil, nil
    limitReached = false
end

--- Makes the window (see windowRect.Beside), with its search field and grid,
--- and starts listing the items if they aren't yet (see
--- iconCatalogue.LoadItems), searching again once they are.
---@param area userdata The game area.
---@param pickerOptions IconPickerOptions
local function openWindow(area, pickerOptions)
    local areaWidth, areaHeight = gameApi.GameAreaSize()
    local x, y = windowRect.Beside(pickerOptions.beside, WINDOW_WIDTH, WINDOW_HEIGHT,
        areaWidth or WINDOW_WIDTH, areaHeight or WINDOW_HEIGHT)
    local opened
    opened = prettyUI.Window.new(area, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        title = gameText.Plain(pickerOptions.title),
        x = x,
        y = y,
        width = WINDOW_WIDTH,
        height = WINDOW_HEIGHT,
        resizable = false,
        -- Movable while the player's interface is locked too.
        respectInterfaceLock = false,
        scrollable = false,
        destroyOnClose = true,
        -- Runs for the title bar's close button as well as Close.
        onClose = function()
            if window == opened then
                teardown()
            end
        end,
    })
    window, options, query = opened, pickerOptions, ""
    buildHeader()
    buildGridLayers()
    runSearch()
    Event.Draw.Subscribe(WATCH_EVENT_ID, watchScroll)
    iconCatalogue.LoadItems(function() nextFrame.Run(SEARCH_EVENT_ID, runSearch) end)
end

--- Opens the picker, closing one already open. If the game runs out of
--- interface parts for the window, what was made of it goes (see
--- reportBuildFailure).
---@param pickerOptions IconPickerOptions
function iconPicker.Open(pickerOptions)
    iconPicker.Close()
    prettyUI = prettyui
    local area = gameApi.GameArea()
    if prettyUI == nil or area == nil then
        return
    end

    local opened, problem = pcall(openWindow, area, pickerOptions)
    if opened then
        return
    end

    iconPicker.Close()
    reportBuildFailure(problem)
end

--- Closes the picker, if it's open, without picking anything.
function iconPicker.Close()
    local closing = window
    teardown()

    if closing ~= nil and closing.root ~= nil then
        closing:Destroy()
    end
end

--- Closes the picker unless it's choosing for this aura.
---@param auraID integer? nil closes it whatever it's for.
function iconPicker.CloseUnlessFor(auraID)
    if options ~= nil and options.auraID == auraID then
        return
    end

    iconPicker.Close()
end

return iconPicker
