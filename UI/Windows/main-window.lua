-- The main window: a movable, resizable PrettyUI window over the game area,
-- with the list toolbar and search on the left and the aura inspector on
-- the right.

local auraEditor = require("UI/Editor/aura-editor")
local auraList = require("UI/Windows/aura-list")
local auraStore = require("Auras/Store/aura-store")
local displayTypes = require("Auras/Registries/display-types")
local sharePanel = require("UI/Windows/share-panel")
local deletePanel = require("UI/Windows/delete-panel")
local selectionPanel = require("UI/Windows/selection-panel")
local auraSelection = require("UI/Windows/aura-selection")
local iconPicker = require("UI/Windows/icon-picker")
local importPreview = require("UI/Windows/import-preview")
local PaneDivider = require("UI/Windows/pane-divider")
local windowRect = require("UI/Windows/window-rect")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")
local heroIcons = require("UI/Controls/hero-icons")
local thumbDrag = require("UI/PrettyUI/thumb-drag")
local pageText = require("UI/Controls/page-text")
local gameText = require("Auras/Helpers/game-text")

local mainWindow = {}

---@class MainWindowHandlers
---@field onAurasChanged fun()? Auras were changed.
---@field onOpenChanged fun()? The window opened or closed.
---@field screenSize ScreenSizeFunction An aura's size on screen, for the list and editor.

local RENDER_EVENT_ID = "runeAuras_mainWindowRender"
local RESIZE_EVENT_ID = "runeAuras_mainWindowResize"
local NEW_EVENT_ID = "runeAuras_mainWindowNew"
local HEADER_EVENT_ID = "runeAuras_mainWindowHeader"
local SHARE_EVENT_ID = "runeAuras_mainWindowShare"
local DUPLICATE_EVENT_ID = "runeAuras_mainWindowDuplicate"
local DELETE_EVENT_ID = "runeAuras_mainWindowDelete"
local PANEL_TAB_EVENT_ID = "runeAuras_mainWindowPanelTab"
local PANEL_EVENT_ID = "runeAuras_mainWindowPanel"
local SELECTION_EVENT_ID = "runeAuras_mainWindowSelection"
-- Everything above, cancelled when the window goes.
local EVENT_IDS = {
    RENDER_EVENT_ID, RESIZE_EVENT_ID, NEW_EVENT_ID, HEADER_EVENT_ID, SHARE_EVENT_ID,
    DUPLICATE_EVENT_ID, DELETE_EVENT_ID, PANEL_TAB_EVENT_ID, PANEL_EVENT_ID, SELECTION_EVENT_ID,
}
local LIST_START_Y = 4
local PANEL_START_Y = 10
local HEADER_START_Y = 8
-- Aura fields the list shows; editing others leaves it as it is.
local LIST_FIELDS = { name = true, display = true, source = true, enabled = true }
-- Frames a window resize must stay still before the panes are laid out for
-- it again, so dragging an edge doesn't rebuild the editor every frame.
local RESIZE_SETTLE_FRAMES = 8
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
-- The header row of buttons, and the space between them.
local HEADER_HEIGHT = 46
-- The search field's row, above the list.
local SEARCH_HEIGHT = uiConstants.FIELD_HEIGHT + GAP
-- Where the list starts: below the header and the search field.
local LIST_TOP = HEADER_HEIGHT + SEARCH_HEIGHT
local TOOLBAR_HEIGHT = 30
local TOOLBAR_GAP = 6
local GROUP_BUTTON_WIDTH = 40
--- What New offers, in order: a display type to make an aura of, or a group.
---@type { make: DisplayID, description: string }[]
local NEW_ITEMS = {
    { make = "icon", description = "Show an icon, with a progress overlay" },
    { make = "bar", description = "Show a progress bar, with optional icon" },
    { make = "segments", description = "Show multiple bars, for stacks and charges" },
    { make = "orb", description = "Show a progress circle, with optional icon" },
    { make = "text", description = "Show simple text, with optional icon" },
    { make = "group", description = "Contains auras and other groups" },
    { make = "dynamicGroup", description = "Contains auras, placed automatically" },
}
local NEW_SUMMARY = "Pick a display type or group from the options below."
-- The line saying where New makes things: this and the group's name, or
-- NO_GROUP_NAME at the top level, and after a group's name the link that
-- clears it, a gap away, underlined this far up from the line's foot.
local NEW_GROUP_PREFIX = "Group: "
local NO_GROUP_NAME = "None"
-- Between the groups in a path, and the most groups it names.
local GROUP_PATH_SEPARATOR = "/"
local MAX_GROUP_DEPTH = 32
local NEW_CLEAR_LABEL = "clear"
local NEW_LINK_GAP = 6
local NEW_LINK_UNDERLINE_RISE = 3
-- Extra room between the Group line and the first button.
local NEW_BUTTONS_GAP = 10
-- New's choices are SimpleButtons, which (unlike FancyButtons) take a
-- height: at least this tall, and taller for a description that wraps to
-- more lines, which is centred on the button.
local NEW_BUTTON_WIDTH = 180
local NEW_ROW_HEIGHT = 40
-- In a narrow window the buttons take this share of the panel's width,
-- down to the width their longest label needs.
local NEW_BUTTON_SHARE = 0.4
local NEW_BUTTON_MIN_WIDTH = 120
-- Room above and below a description that's taller than NEW_ROW_HEIGHT.
local NEW_ROW_MARGIN = 8
-- Kept clear on a panel's right for its scroll view's scrollbar, and the
-- width its text wraps at while the editor's area has none yet.
local PANEL_SCROLLBAR_ROOM = 16
local PANEL_FALLBACK_WIDTH = 300
-- The list's width, which the player can change by dragging the divider
-- between it and the editor (remembered as mainListWidth).
local LIST_WIDTH = 290
local LIST_MIN_WIDTH = 256
local EDITOR_MIN_WIDTH = 260

---@type MainWindowHandlers?
local handlers = nil
local prettyUI = nil
local window = nil
local searchView = nil
-- What's typed in the search field, kept while the window is open.
local searchText = ""
local listView = nil
local editorArea = nil
local listWidth = nil
-- A panel shown in the editor's place: New's choice of what to make,
-- Import's or Export's box, or Delete's choices.
local picker = nil
--- A panel's tabs (see openPanel): their names, and the one shown, which
--- changes as the player picks another.
---@class PanelTabs
---@field names string[]
---@field active integer

-- What the panel was opened with, to build it again for a new width.
local panelTitle, panelBuild, panelTabs = nil, nil, nil
-- Whether a tabbed panel is being built, so a tab change made by the
-- build isn't taken for the player's.
local buildingPanel = false
local headerView = nil
---@type PaneDivider?
local divider = nil
-- The window size the panes were last laid out for, and frames since it
-- last changed.
local laidOutWidth, laidOutHeight = 0, 0
local seenWidth, seenHeight = 0, 0
local stillFrames = 0

local function changed()
    if handlers ~= nil and handlers.onAurasChanged ~= nil then
        handlers.onAurasChanged()
    end
end

local function openChanged()
    if handlers ~= nil and handlers.onOpenChanged ~= nil then
        handlers.onOpenChanged()
    end
end

--- PrettyUI, looked up when needed rather than at load: a dev plugin can
--- load before its dependencies have published their globals.
---@return table? prettyUI nil, with a message, if it isn't loaded.
local function getPrettyUI()
    prettyUI = prettyUI or prettyui

    if prettyUI == nil then
        log("RuneAuras: the PrettyUI plugin is not loaded; enable it to edit auras.")
    end

    return prettyUI
end

--- Saves where the window is now, if it's open.
local function rememberRect()
    if window ~= nil and window.root ~= nil then
        windowRect.Remember(window.root)
    end
end

--- A SimpleView's layout with the window's padding and gaps.
---@param startY number
---@return table
local function paddedLayout(startY)
    return { startY = startY, paddingLeft = PADDING, paddingRight = PADDING, rowGap = GAP, columnGap = GAP }
end

local requestRender, requestHeader, openPanel, openTabs, askExport
local selectFromList, groupSelectionLater, deleteSelectionLater
local showSelection, groupSelection, deleteSelection
---@type DeletePanelHost
local deleteHost

--- How much of the list shows: the window below the header and search
--- field. (Not the view's height, which grows to fit what's in it.)
---@return number
local function listViewHeight()
    local content = window ~= nil and window.content or nil
    return math.max(1, (content and content.height or 0) - LIST_TOP)
end

--- Trims spaces from both ends.
---@param value string
---@return string
local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

--- Copies an aura beside itself and selects the copy. Runs after the
--- clicked button's callback, as selecting rebuilds the list and editor.
---@param auraID integer
local function duplicate(auraID)
    nextFrame.Run(DUPLICATE_EVENT_ID, function()
        local aura = auraStore.Get(auraID)
        if aura == nil then
            return
        end

        local width, height = handlers.screenSize(aura)
        local copy = auraStore.Duplicate(auraID, width, height, gameApi.GameAreaSize())
        if copy == nil then
            return
        end

        changed()
        mainWindow.Select(copy.id)
    end)
end

--- Asks how to delete an aura, in the editor's place. Runs after the
--- clicked button's callback, as the panel replaces the editor.
---@param auraID integer
local function askDelete(auraID)
    nextFrame.Run(DELETE_EVENT_ID, function() deletePanel.Open(deleteHost, auraID) end)
end

--- Builds the list again, keeping its scroll position.
local function renderList()
    if window == nil then
        return
    end

    local scrollY = listView ~= nil and listView.scrollY or nil

    if listView ~= nil then
        listView:Destroy()
    end

    listView = nil
    listView = prettyUI.SimpleView.new(window.content, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        x = 0,
        y = LIST_TOP,
        width = listWidth,
        height = -LIST_TOP,
        heightAnchor = 1,
        layout = {
            startY = LIST_START_Y,
            paddingLeft = 0,
            paddingRight = PADDING,
            rowGap = GAP,
            columnGap = GAP,
        },
    })

    auraList.Build(listView, {
        selected = auraSelection.Set(),
        primaryID = auraSelection.Primary(),
        selectedCount = auraSelection.Count(),
        selectedRootIDs = auraSelection.RootIDs(),
        search = trim(searchText),
        onSelect = function(auraID, mode, shownIDs) selectFromList(auraID, mode, shownIDs) end,
        onGroupSelected = function() groupSelectionLater() end,
        onDeleteSelected = function() deleteSelectionLater() end,
        onChanged = changed,
        -- Its right-click menu's actions, as the editor header's buttons.
        onDuplicate = duplicate,
        onExport = function(auraID) askExport(auraID) end,
        onDelete = askDelete,
        requestRender = requestRender,
        startY = LIST_START_Y,
        scrollY = scrollY,
        viewHeight = listViewHeight(),
    })

    if scrollY ~= nil then
        listView:SetScrollPosition(scrollY)
    end

    -- The list is rebuilt as it scrolls past the rows it built, so the drag
    -- moves whichever list view is current.
    thumbDrag.Follow(listView, function() return listView end)
end

--- Rebuilds the list on the next frame, so a control is never destroyed
--- inside its callback.
requestRender = function()
    nextFrame.Run(RENDER_EVENT_ID, renderList)
end

-- Whether New's "clear" was pressed, putting what it makes at the top
-- level whatever is selected; until New is opened again.
local newAtTopLevel = false

--- Where a new aura or group goes: into the selected group, or beside the
--- selected aura; the top level after New's "clear".
---@return integer? groupID nil for the top level.
local function newItemGroup()
    if newAtTopLevel then
        return nil
    end

    local primaryID = auraSelection.Primary()
    local selected = primaryID ~= nil and auraStore.Get(primaryID) or nil
    if selected == nil then
        return nil
    end

    if auraStore.IsGroup(selected) then
        return selected.id
    end

    return selected.group
end

--- Where a new group goes: as newItemGroup, but never inside a dynamic
--- group, which holds auras only.
---@return integer? groupID
local function newGroupParent()
    local groupID = newItemGroup()
    local group = groupID ~= nil and auraStore.Get(groupID) or nil
    if auraStore.IsDynamicGroup(group) then
        return group.group
    end

    return groupID
end

--- Keeps the list wide enough to read and the editor wide enough to use.
---@param width number
---@return integer
local function clampListWidth(width)
    local contentWidth = window ~= nil and window.content ~= nil and window.content.width or 0
    if contentWidth <= 0 then
        contentWidth = windowRect.DEFAULT_WIDTH
    end

    local widest = math.max(LIST_MIN_WIDTH, contentWidth - EDITOR_MIN_WIDTH - PaneDivider.WIDTH)
    return math.floor(math.max(LIST_MIN_WIDTH, math.min(width, widest)))
end

--- Loads the list's width the player chose.
local function loadListWidth()
    listWidth = clampListWidth(PaneDivider.SavedWidth() or listWidth or LIST_WIDTH)
end

--- Builds the search field above the list, preserving its filter.
local function renderSearch()
    if searchView ~= nil then
        searchView:Destroy()
    end

    searchView = nil
    searchView = prettyUI.SimpleView.new(window.content, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        x = 0,
        y = HEADER_HEIGHT,
        width = listWidth,
        height = SEARCH_HEIGHT,
        scrollable = false,
        layout = paddedLayout(0),
    })
    local field
    field = searchView:AddTextField({
        text = searchText,
        placeholder = "Search",
        onChange = function()
            searchText = field:GetText() or ""
            requestRender()
        end,
    })
end

--- Places the editor beside the list and rebuilds the search for its width.
local function placePanes()
    editorArea:SetPos(listWidth + PaneDivider.WIDTH, 0)
    editorArea:SetSize(-(listWidth + PaneDivider.WIDTH), 0, 1, 1)
    divider:Place(listWidth)
    renderSearch()
end

--- Lays everything out again for a new width: the list, editor and header
--- lay their rows out for their width, so all are rebuilt.
local function relayout()
    placePanes()
    renderList()
    auraEditor.Refresh()

    -- Panels lay their rows out for their width too.
    if picker ~= nil then
        openPanel(panelTitle, panelBuild, panelTabs)
    end

    requestHeader()
end

--- After a divider drag: lays the panes out for the list's new width, or
--- just shrinks the divider back from covering the window.
---@param width integer? The new width; nil if it didn't change.
local function onDividerReleased(width)
    if window == nil then
        return
    end

    if width == nil then
        placePanes()
        return
    end

    listWidth = width
    relayout()
end

--- Watches the window each frame: PrettyUI's window has no resize
--- callback. Once a new size settles, the list is kept narrow enough to
--- leave the editor room and both are rebuilt for their widths. Also
--- rebuilds the list when it scrolls past the rows it built.
local function watchResize()
    local root = window ~= nil and window.root or nil
    if root == nil then
        return
    end

    if listView ~= nil and auraList.NeedsRender(listView.scrollY or 0, listViewHeight()) then
        requestRender()
    end

    local width, height = root.width, root.height
    if width ~= seenWidth or height ~= seenHeight then
        seenWidth, seenHeight = width, height
        stillFrames = 0
        return
    end

    local isLaidOut = width == laidOutWidth and height == laidOutHeight
    if isLaidOut or (divider ~= nil and divider:IsDragging()) then
        return
    end

    stillFrames = stillFrames + 1

    if stillFrames < RESIZE_SETTLE_FRAMES then
        return
    end

    laidOutWidth, laidOutHeight = width, height
    listWidth = clampListWidth(listWidth)
    relayout()
end

--- Adds the divider between the list and the editor.
local function addDivider()
    divider = PaneDivider.new(window.content, {
        top = 0,
        clamp = clampListWidth,
        onReleased = onDividerReleased,
    })
end

--- Makes what New's choice says, where New puts things, and selects it so
--- it gets set up and named.
---@param make DisplayID
local function makeNew(make)
    local made
    if make == "group" then
        made = auraStore.CreateGroup(newGroupParent())
    elseif make == "dynamicGroup" then
        made = auraStore.CreateDynamicGroup(newGroupParent())
    else
        made = auraStore.Create(newItemGroup())

        if made.display ~= make then
            auraStore.Set(made.id, "display", make)
        end

        -- Groups have no trigger; an aura is set up from its source first.
        auraEditor.ShowTriggerTab()
    end

    changed()
    mainWindow.Select(made.id)
end

--- Puts the editor back in a panel's place.
local function closePicker()
    if picker == nil then
        return
    end

    picker:Destroy()
    picker = nil
    panelTitle, panelBuild, panelTabs = nil, nil, nil
    auraEditor.Mount(prettyUI, editorArea)
end

local buildNewItems

--- Shows a tabbed panel in the editor's place (see PanelTabs): the tabs as
--- the editor's are, with only the shown tab's page built. Picking another
--- tab builds the panel again on the next frame, as the click's callback
--- belongs to the tabs being replaced.
---@param build fun(view: table, tabIndex: integer)
---@param tabs PanelTabs
function openTabs(build, tabs)
    local tabList = {}
    for index, name in ipairs(tabs.names) do
        tabList[index] = { text = name }
    end

    picker = prettyUI.Tabs.new(editorArea, tabList, {
        categoryID = uiConstants.PRETTYUI_EDITOR_CATEGORY,
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        activeIndex = tabs.active,
        contentLayout = paddedLayout(PANEL_START_Y),
        onChange = function(_, index)
            if buildingPanel or index == tabs.active then
                return
            end

            tabs.active = index

            nextFrame.Run(PANEL_TAB_EVENT_ID, function()
                if picker ~= nil and panelTabs == tabs then
                    openPanel(panelTitle, panelBuild, panelTabs)
                end
            end)
        end,
    })
    buildingPanel = true
    local built, problem = pcall(build, picker:GetPage(tabs.active), tabs.active)
    buildingPanel = false

    if not built then
        error(problem, 0)
    end
end

--- Shows a panel in the editor's place. The editor locks the aura it had
--- open as it goes. The panel is built again with `build` when the window's
--- width changes, so it should build from what's current.
---@param title string? PrettyUI's title for it; nil for a panel that writes its title (New) or has tabs.
---@param build fun(view: table, tabIndex: integer?) Adds its controls: to the panel, or the shown tab's page.
---@param tabs PanelTabs? Its tabs; nil for none.
function openPanel(title, build, tabs)
    panelTitle, panelBuild, panelTabs = title, build, tabs

    if editorArea == nil then
        return
    end

    if picker ~= nil then
        picker:Destroy()
        picker = nil
    end

    auraEditor.Unmount()

    if tabs ~= nil then
        openTabs(build, tabs)
        return
    end

    picker = prettyUI.SimpleView.new(editorArea, {
        categoryID = uiConstants.PRETTYUI_EDITOR_CATEGORY,
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        layout = paddedLayout(PANEL_START_Y),
    })

    if title ~= nil then
        picker:AddTitle(title)
    end

    build(picker)
end

--- Shows New's choice of what to make, in place of the editor or another
--- panel (Import, Export, Delete), whose pending action is dropped. Does
--- nothing while New is already showing.
local function openPicker()
    if picker ~= nil and panelBuild == buildNewItems then
        return
    end

    sharePanel.Cancel()
    deletePanel.Cancel()
    selectionPanel.Cancel()
    newAtTopLevel = false
    -- No PrettyUI title: New writes its title, as the home page does.
    openPanel(nil, buildNewItems)
end

--- How wide a panel's text (page text, placed by hand) can be: the
--- editor area less its padding and the scroll bar's room.
---@return number
local function panelTextWidth()
    local width = (editorArea ~= nil and editorArea.width or 0) - PADDING * 2 - PANEL_SCROLLBAR_ROOM
    if width <= 0 then
        width = PANEL_FALLBACK_WIDTH
    end

    return width
end

--- Where the window is on screen, for opening the icon picker or an
--- import's preview beside it.
---@return Rect? bounds nil while it's closed.
local function windowBounds()
    local root = window ~= nil and window.root or nil
    if root == nil then
        return nil
    end

    return { x = root.x, y = root.y, width = root.width, height = root.height }
end

---@type SharePanelHost
local shareHost = {
    openPanel = openPanel,
    textArea = function() return PANEL_START_Y, panelTextWidth() end,
    onImported = function(made)
        changed()
        mainWindow.Select(made[1].id)
    end,
    windowBounds = windowBounds,
}

--- Shows an aura's export in the editor's place. Runs after the clicked
--- button's (or menu entry's) callback, as the panel replaces the editor.
---@param auraID integer
function askExport(auraID)
    nextFrame.Run(SHARE_EVENT_ID, function() sharePanel.OpenExport(shareHost, auraID) end)
end

deleteHost = {
    openPanel = openPanel,
    onDone = function(deleted)
        if deleted then
            changed()
        end

        -- Back to what was selected, less what went with the delete.
        auraSelection.Prune()
        showSelection()

        if deleted then
            requestRender()
        end
    end,
}

---@type SelectionPanelHost
local selectionHost = {
    openPanel = openPanel,
    onGroup = function() groupSelection() end,
    onDelete = function() deleteSelection() end,
}

--- Shows the selection in the editor's place: the selected aura (or the
--- home page with none); several of one display type edited together; or
--- the Selection panel for several of mixed types, or with groups.
function showSelection()
    if auraSelection.Count() <= 1 then
        closePicker()
        auraEditor.Show(auraSelection.Primary())
        return
    end

    if auraSelection.SharedDisplay() == nil then
        selectionPanel.Open(selectionHost, auraSelection.IDs())
        return
    end

    closePicker()
    auraEditor.ShowMany(auraSelection.PrimaryFirst())
end

--- Puts the selection in a new group, kept where it is on screen, and
--- selects the group.
function groupSelection()
    local group = auraStore.GroupTogether(auraSelection.RootIDs(), gameApi.GameAreaSize())
    if group == nil then
        return
    end

    changed()
    mainWindow.Select(group.id)
end

--- Asks how to delete the selection.
function deleteSelection()
    local auraIDs = {}
    for index, auraID in ipairs(auraSelection.IDs()) do
        auraIDs[index] = auraID
    end

    deletePanel.OpenMany(deleteHost, auraIDs, auraSelection.RootIDs())
end

--- Changes the selection for a click in the list: one aura alone, one added
--- or taken out (Ctrl), or a range (Shift), and shows it.
---@param auraID integer? nil to select nothing.
---@param mode SelectMode?
---@param shownIDs integer[]? For a range, the list's rows, top to bottom.
function selectFromList(auraID, mode, shownIDs)
    if auraID == nil or mode == nil or mode == "only" then
        mainWindow.Select(auraID)
        return
    end

    if mode == "toggle" then
        auraSelection.Toggle(auraID)
    else
        auraSelection.Range(auraID, shownIDs or {})
    end

    showSelection()
    requestRender()
end

--- groupSelection, after the menu's or button's callback, as it rebuilds
--- the list and editor.
function groupSelectionLater()
    nextFrame.Run(SELECTION_EVENT_ID, groupSelection)
end

--- deleteSelection, after the menu's callback, as the panel replaces the editor.
function deleteSelectionLater()
    nextFrame.Run(SELECTION_EVENT_ID, deleteSelection)
end

--- A group as the New panel says it: its path from the top level, each
--- group it's in first ("Ranged/Buffs"), or the top level's name.
---@param groupID integer? nil for the top level.
---@return string
local function placeName(groupID)
    local names = {}
    local group = groupID ~= nil and auraStore.Get(groupID) or nil

    -- Capped, so a damaged save's loop of groups can't hang it.
    while group ~= nil and #names < MAX_GROUP_DEPTH do
        table.insert(names, 1, gameText.Plain(group.name))
        group = group.group ~= nil and auraStore.Get(group.group) or nil
    end

    if #names == 0 then
        return NO_GROUP_NAME
    end

    return table.concat(names, GROUP_PATH_SEPARATOR)
end

--- New's "clear": puts what New makes at the top level, and shows the panel
--- again with Group: None, after the click's callback.
local function clearNewGroup()
    newAtTopLevel = true

    nextFrame.Run(NEW_EVENT_ID, function()
        if picker ~= nil then
            openPanel(panelTitle, panelBuild, panelTabs)
        end
    end)
end

--- Adds New's "Group:" line: the group a new aura goes in, or None, and
--- after a group's name a "clear" link that makes it None.
---@param content userdata
---@param y number
---@param width number
---@return number height
local function addNewGroupLine(content, y, width)
    local groupID = newItemGroup()
    local line = NEW_GROUP_PREFIX .. placeName(groupID)
    local height = pageText.Add(content, "text", line, PADDING, y, width)
    local lineWidth = groupID ~= nil and pageText.Width("text", line) or nil
    if lineWidth == nil then
        return height
    end

    local linkX = PADDING + lineWidth + NEW_LINK_GAP
    -- Only the word takes the click, not the rest of the line.
    local labelWidth = pageText.Width("text", NEW_CLEAR_LABEL)
    local linkWidth = labelWidth ~= nil and labelWidth + 1 or width - (linkX - PADDING)
    local _, link = pageText.Add(content, "text", NEW_CLEAR_LABEL, linkX, y, linkWidth, uiConstants.ACCENT_RGBA)
    link.enabled = true
    link.clickthrough = false

    link:Subscribe(ui.Hook.ONCLICK, function()
        clearNewGroup()
        return false
    end)

    -- Underlined, as a link: a line the label's width along its foot.
    if labelWidth ~= nil then
        local underline = ui.Rectangle.new(content)
        underline.clickthrough = true
        underline.rgba = uiConstants.ACCENT_RGBA
        underline:SetPos(linkX, y + height - NEW_LINK_UNDERLINE_RISE)
        underline:SetSize(labelWidth, 1)
    end

    return height
end

--- Adds New's page: its title, the group new auras go in, then a button for each
--- choice with its description beside it. The texts aren't in the view's
--- layout, so a spacer holds their room above the buttons.
---@param view table
buildNewItems = function(view)
    local width = panelTextWidth()
    local content = view.content
    local y = PANEL_START_Y
    y = y + pageText.Add(content, "title", "New", PADDING, y, width)
    y = y + pageText.GapBefore("text")
    y = y + pageText.Add(content, "text", NEW_SUMMARY, PADDING, y, width)
    y = y + pageText.GapBefore("text")
    y = y + addNewGroupLine(content, y, width) + NEW_BUTTONS_GAP
    view:AddText({ text = "", height = y - PANEL_START_Y })
    -- The buttons follow the spacer in the view's layout, a row and a gap each.
    local rowY = y + GAP
    -- Narrower buttons in a narrow window leave the descriptions room.
    local buttonWidth = math.max(NEW_BUTTON_MIN_WIDTH, math.min(NEW_BUTTON_WIDTH, width * NEW_BUTTON_SHARE // 1))
    local descriptionX = PADDING + buttonWidth + GAP
    local descriptionWidth = width - buttonWidth - GAP
    for _, item in ipairs(NEW_ITEMS) do
        local make = item.make
        -- A row is as tall as its description, so a long one wrapped in a
        -- narrow window doesn't run into the next; its button grows to match.
        local textHeight = pageText.Height("text", item.description, descriptionWidth)
        local rowHeight = math.max(NEW_ROW_HEIGHT, math.ceil(textHeight) + NEW_ROW_MARGIN)
        view:AddSimpleButton(displayTypes.Get(make).label, function()
            -- Run after this callback: making one rebuilds the picker away.
            nextFrame.Run(NEW_EVENT_ID, function() makeNew(make) end)
        end, {
            width = buttonWidth,
            height = rowHeight,
        })

        pageText.AddCentred(content, "text", item.description, descriptionX, rowY, descriptionWidth, rowHeight)
        rowY = rowY + rowHeight + GAP
    end
end

--- Builds New, Import and New group above the list.
local function renderHeader()
    if window == nil then
        return
    end

    if headerView ~= nil then
        headerView:Destroy()
    end

    headerView = prettyUI.SimpleView.new(window.content, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        x = 0, y = 0, width = listWidth, height = HEADER_HEIGHT, scrollable = false,
    })
    local groupX = listWidth - PADDING - GROUP_BUTTON_WIDTH
    local buttonWidth = (groupX - PADDING - TOOLBAR_GAP * 2) // 2
    heroIcons.Button(prettyUI, headerView.content, "plus", openPicker, {
        x = PADDING, y = HEADER_START_Y, width = buttonWidth, height = TOOLBAR_HEIGHT,
        text = "New", tooltip = "New aura",
    })

    heroIcons.Button(prettyUI, headerView.content, "arrow-down-tray", function()
        nextFrame.Run(SHARE_EVENT_ID, function() sharePanel.OpenImport(shareHost) end)
    end, {
        x = PADDING + buttonWidth + TOOLBAR_GAP, y = HEADER_START_Y,
        width = buttonWidth, height = TOOLBAR_HEIGHT, text = "Import",
    })

    heroIcons.Button(prettyUI, headerView.content, "folder-plus", function()
        nextFrame.Run(NEW_EVENT_ID, function() makeNew("group") end)
    end, {
        x = groupX, y = HEADER_START_Y, width = GROUP_BUTTON_WIDTH,
        height = TOOLBAR_HEIGHT, tooltip = "New group",
    })
end

--- Rebuilds the toolbar after the list width changes.
requestHeader = function()
    nextFrame.Run(HEADER_EVENT_ID, renderHeader)
end

--- Forgets the window's contents and stops its events, and closes the icon
--- picker and import preview opened from it; the window itself is closed
--- or destroyed by the caller.
local function teardown()
    for _, eventID in ipairs(EVENT_IDS) do
        nextFrame.Cancel(eventID)
    end

    sharePanel.Cancel()
    deletePanel.Cancel()
    selectionPanel.Cancel()
    iconPicker.Close()
    importPreview.Close()
    auraEditor.Unmount()
    auraList.Destroy()
    listView, editorArea, picker, headerView, searchView = nil, nil, nil, nil, nil
    searchText = ""
    divider = nil
    window = nil
end

--- Sets up the editor, and what the window reports.
---@param windowHandlers MainWindowHandlers
function mainWindow.Init(windowHandlers)
    handlers = windowHandlers

    auraEditor.Init({
        screenSize = windowHandlers.screenSize,
        windowBounds = windowBounds,
        onAurasChanged = function(key)
            changed()

            if window ~= nil and (key == nil or LIST_FIELDS[key]) then
                requestRender()
            end
        end,
        onExport = askExport,
        onDuplicate = duplicate,
        onDelete = askDelete,
        -- Their header's buttons: after the click's callback, as both
        -- replace the editor.
        onGroupSelection = function() groupSelectionLater() end,
        onDeleteSelection = function() deleteSelectionLater() end,
    })
end

---@return boolean
function mainWindow.IsOpen()
    return window ~= nil
end

--- Opens the window where it was left (kept inside the game area).
---@return boolean opened false if it's already open, or PrettyUI or the game area isn't there.
function mainWindow.Open()
    if window ~= nil or getPrettyUI() == nil then
        return false
    end

    local area = gameApi.GameArea()
    if area == nil then
        return false
    end

    auraSelection.Prune()

    local rect = windowRect.Opening(area)
    local opened
    opened = prettyUI.Window.new(area, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        title = "RuneAuras",
        x = rect.x,
        y = rect.y,
        width = rect.width,
        height = rect.height,
        minWidth = windowRect.MIN_WIDTH,
        minHeight = windowRect.MIN_HEIGHT,
        resizable = true,
        -- Movable and resizable while the player's interface is locked too.
        respectInterfaceLock = false,
        -- The list and editor scroll separately; the window itself doesn't.
        scrollable = false,
        destroyOnClose = true,
        -- Runs for the title bar's close button as well as mainWindow.Close.
        onClose = function()
            if window ~= opened then
                return
            end

            rememberRect()
            teardown()
            openChanged()
        end,
    })
    window = opened
    loadListWidth()
    renderHeader()

    -- The inspector fills the right pane from the top.
    editorArea = ui.Layer.new(window.content)
    editorArea.clickthrough = true
    addDivider()
    placePanes()
    auraEditor.Mount(prettyUI, editorArea)

    renderList()
    showSelection()
    laidOutWidth, laidOutHeight = window.root.width, window.root.height
    seenWidth, seenHeight = laidOutWidth, laidOutHeight
    Event.Draw.Subscribe(RESIZE_EVENT_ID, watchResize)
    openChanged()
    return true
end

--- Closes the window. Window:Close runs onClose, which tidies up and notifies.
function mainWindow.Close()
    if window ~= nil then
        window:Close()
    end
end

--- Opens the window, or closes it if it's open.
function mainWindow.Toggle()
    if window ~= nil then
        mainWindow.Close()
    else
        mainWindow.Open()
    end
end

--- Selects an aura alone and opens it in the editor beside the list.
---@param auraID integer? nil for none.
function mainWindow.Select(auraID)
    local reselected = auraSelection.Count() <= 1 and auraID == auraSelection.Primary()
    auraSelection.Only(auraID)

    if window == nil then
        return
    end

    closePicker()
    auraEditor.Show(auraID)

    if not reselected then
        requestRender()
    end
end

--- Shows changed data sources: the list's icons, the editor's source
--- pickers, and a panel showing in its place (Import's examples show their
--- sources' icons), built again on the next frame.
function mainWindow.OnSourcesChanged()
    auraEditor.OnSourcesChanged()

    if window == nil then
        return
    end

    requestRender()

    nextFrame.Run(PANEL_EVENT_ID, function()
        if picker ~= nil then
            openPanel(panelTitle, panelBuild, panelTabs)
        end
    end)
end

--- Drops the window without notifying, e.g. on logout when the game area
--- is going away. The selection is kept for next time.
function mainWindow.Destroy()
    rememberRect()
    local closing = window
    teardown()

    if closing ~= nil and closing.root ~= nil then
        closing:Destroy()
    end
end

return mainWindow
