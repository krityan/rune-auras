-- The main window: a movable, resizable PrettyUI window over the game area,
-- with the list toolbar and search on the left and the aura inspector on
-- the right.

local auraEditor = require("UI/Editor/aura-editor")
local auraList = require("UI/Windows/aura-list")
local auraStore = require("Auras/Store/aura-store")
local displayTypes = require("Auras/Registries/display-types")
local sharePanel = require("UI/Windows/share-panel")
local deletePanel = require("UI/Windows/delete-panel")
local iconPicker = require("UI/Windows/icon-picker")
local PaneDivider = require("UI/Windows/pane-divider")
local windowRect = require("UI/Windows/window-rect")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")
local heroIcons = require("UI/Controls/hero-icons")

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
-- Everything above, cancelled when the window goes.
local EVENT_IDS = {
    RENDER_EVENT_ID, RESIZE_EVENT_ID, NEW_EVENT_ID, HEADER_EVENT_ID, SHARE_EVENT_ID,
    DUPLICATE_EVENT_ID, DELETE_EVENT_ID,
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
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
-- The header row of buttons, and the space between them.
local HEADER_HEIGHT = 46
-- The search field's row, above the list.
local SEARCH_HEIGHT = uiConstants.FIELD_HEIGHT + GAP
-- Where the list starts: below the header and the search field.
local LIST_TOP = HEADER_HEIGHT + SEARCH_HEIGHT
local TOOLBAR_HEIGHT = 30
local TOOLBAR_GAP = 6
local GROUP_BUTTON_WIDTH = 40
local HINT_HEIGHT, HINT_LINES = 40, 2
--- What New offers, in order: a display type to make an aura of, or a group.
---@type { make: DisplayID, description: string }[]
local NEW_ITEMS = {
    { make = "bar", description = "A bar that fills with a value, like adrenaline or a cooldown." },
    { make = "icon", description = "An ability or buff icon, swiped as its cooldown or duration runs." },
    { make = "text", description = "Text on its own: a buff's time, a resource, a cast." },
    { make = "segments", description = "A row of small bars filling one per stack, like Necrosis." },
    { make = "orb", description = "A circle that fills like a bar, upwards or round." },
    { make = "group", description = "Moves several auras together." },
    { make = "dynamicGroup", description = "Lines up the auras in it that are showing, closing gaps as they come and go." },
}
-- New's choices are SimpleButtons, which (unlike FancyButtons) take a
-- height: as tall as the description of up to two lines beside each, so
-- both centre on the same line.
local NEW_BUTTON_WIDTH = 180
local NEW_ROW_HEIGHT = 40
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
local selectedID = nil
local listWidth = nil
-- A panel shown in the editor's place: New's choice of what to make,
-- Import's or Export's box, or Delete's choices.
local picker = nil
-- What the panel was opened with, to build it again for a new width.
local panelTitle, panelBuild = nil, nil
local headerView = nil
---@type PaneDivider?
local divider = nil
-- The window size the panes were last laid out for, and frames since it
-- last changed.
local laidOutWidth, laidOutHeight = 0, 0
local seenWidth, seenHeight = 0, 0
local stillFrames = 0

local function changed()
    if handlers ~= nil and handlers.onAurasChanged ~= nil then handlers.onAurasChanged() end
end

local function openChanged()
    if handlers ~= nil and handlers.onOpenChanged ~= nil then handlers.onOpenChanged() end
end

--- PrettyUI, looked up when needed rather than at load: a dev plugin can
--- load before its dependencies have published their globals.
---@return table? prettyUI nil, with a message, if it isn't loaded.
local function getPrettyUI()
    prettyUI = prettyUI or prettyui
    if prettyUI == nil then
        log("Rune Auras: the PrettyUI plugin is not loaded; enable it to edit auras.")
    end
    return prettyUI
end

--- Saves where the window is now, if it's open.
local function rememberRect()
    if window ~= nil and window.root ~= nil then windowRect.Remember(window.root) end
end

--- A SimpleView's layout with the window's padding and gaps.
---@param startY number
---@return table
local function paddedLayout(startY)
    return { startY = startY, paddingLeft = PADDING, paddingRight = PADDING, rowGap = GAP, columnGap = GAP }
end

local requestRender, requestHeader, openPanel
---@type DeletePanelHost
local deleteHost

--- How much of the list shows: the window below the header and search
--- field. (Not the view's own height, which grows to fit what's in it.)
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
        if aura == nil then return end
        local width, height = handlers.screenSize(aura)
        local copy = auraStore.Duplicate(auraID, width, height, gameApi.GameAreaSize())
        if copy == nil then return end
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
    if window == nil then return end
    local scrollY = listView ~= nil and listView.scrollY or nil
    if listView ~= nil then listView:Destroy() end
    listView = nil
    listView = prettyUI.SimpleView.new(window.content, {
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
        selectedID = selectedID,
        search = trim(searchText),
        onSelect = function(auraID) mainWindow.Select(auraID) end,
        onChanged = changed,
        requestRender = requestRender,
        startY = LIST_START_Y,
        scrollY = scrollY,
        viewHeight = listViewHeight(),
    })
    if scrollY ~= nil then listView:SetScrollPosition(scrollY) end
end

--- Rebuilds the list on the next frame, so a control is never destroyed
--- inside its own callback.
requestRender = function()
    nextFrame.Run(RENDER_EVENT_ID, renderList)
end

--- Where a new aura or group goes: into the selected group, or beside the
--- selected aura.
---@return integer? groupID nil for the top level.
local function newItemGroup()
    local selected = selectedID ~= nil and auraStore.Get(selectedID) or nil
    if selected == nil then return nil end
    if auraStore.IsGroup(selected) then return selected.id end
    return selected.group
end

--- Where a new group goes: as newItemGroup, but never inside a dynamic
--- group, which holds auras only.
---@return integer? groupID
local function newGroupParent()
    local groupID = newItemGroup()
    local group = groupID ~= nil and auraStore.Get(groupID) or nil
    if auraStore.IsDynamicGroup(group) then return group.group end
    return groupID
end

--- Keeps the list wide enough to read and the editor wide enough to use.
---@param width number
---@return integer
local function clampListWidth(width)
    local contentWidth = window ~= nil and window.content ~= nil and window.content.width or 0
    if contentWidth <= 0 then contentWidth = windowRect.DEFAULT_WIDTH end
    local widest = math.max(LIST_MIN_WIDTH, contentWidth - EDITOR_MIN_WIDTH - PaneDivider.WIDTH)
    return math.floor(math.max(LIST_MIN_WIDTH, math.min(width, widest)))
end

--- Loads the list's width the player chose.
local function loadListWidth()
    listWidth = clampListWidth(PaneDivider.SavedWidth() or listWidth or LIST_WIDTH)
end

--- Builds the search field above the list, preserving its filter.
local function renderSearch()
    if searchView ~= nil then searchView:Destroy() end
    searchView = nil
    searchView = prettyUI.SimpleView.new(window.content, {
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
    if picker ~= nil then openPanel(panelTitle, panelBuild) end
    requestHeader()
end

--- After a divider drag: lays the panes out for the list's new width, or
--- just shrinks the divider back from covering the window.
---@param width integer? The new width; nil if it didn't change.
local function onDividerReleased(width)
    if window == nil then return end
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
    if root == nil then return end
    if listView ~= nil and auraList.NeedsRender(listView.scrollY or 0, listViewHeight()) then requestRender() end
    local width, height = root.width, root.height
    if width ~= seenWidth or height ~= seenHeight then
        seenWidth, seenHeight = width, height
        stillFrames = 0
        return
    end
    local isLaidOut = width == laidOutWidth and height == laidOutHeight
    if isLaidOut or (divider ~= nil and divider:IsDragging()) then return end
    stillFrames = stillFrames + 1
    if stillFrames < RESIZE_SETTLE_FRAMES then return end
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
        if made.display ~= make then auraStore.Set(made.id, "display", make) end
        -- Groups have no trigger; an aura is set up from its source first.
        auraEditor.ShowTriggerTab()
    end
    changed()
    mainWindow.Select(made.id)
end

--- Puts the editor back in a panel's place.
local function closePicker()
    if picker == nil then return end
    picker:Destroy()
    picker = nil
    panelTitle, panelBuild = nil, nil
    auraEditor.Mount(prettyUI, editorArea)
end

local buildNewItems

--- Shows a panel in the editor's place. The editor locks the aura it had
--- open as it goes. The panel is built again with `build` when the window's
--- width changes, so it should build from what's current.
---@param title string
---@param build fun(view: table) Adds its controls.
function openPanel(title, build)
    panelTitle, panelBuild = title, build
    if editorArea == nil then return end
    if picker ~= nil then
        picker:Destroy()
        picker = nil
    end
    auraEditor.Unmount()
    picker = prettyUI.SimpleView.new(editorArea, {
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        layout = paddedLayout(PANEL_START_Y),
    })
    picker:AddTitle(title)
    build(picker)
end

--- Shows New's choice of what to make.
local function openPicker()
    if picker ~= nil then return end
    openPanel("New", function(view)
        buildNewItems(view)
    end)
end

---@type SharePanelHost
local shareHost = {
    openPanel = openPanel,
    onImported = function(made)
        changed()
        mainWindow.Select(made[1].id)
    end,
}

deleteHost = {
    openPanel = openPanel,
    onDone = function(deleted)
        if deleted then changed() end
        -- Back to what was selected, unless that's gone with the delete.
        local keptID = selectedID ~= nil and auraStore.Get(selectedID) ~= nil and selectedID or nil
        mainWindow.Select(keptID)
        if deleted then requestRender() end
    end,
}

--- Adds New's choices: a button for each, with its description beside it.
---@param view table
buildNewItems = function(view)
    view:AddText({
        text = "Choose what to make. It goes in the selected group, or beside the selected aura.",
        height = HINT_HEIGHT,
        maxLines = HINT_LINES,
        colour = uiConstants.MUTED_RGBA,
    })
    for _, item in ipairs(NEW_ITEMS) do
        local make = item.make
        view:AddSimpleButton(displayTypes.Get(make).label, function()
            -- Run after this callback: making one rebuilds the picker away.
            nextFrame.Run(NEW_EVENT_ID, function() makeNew(make) end)
        end, {
            width = NEW_BUTTON_WIDTH,
            height = NEW_ROW_HEIGHT,
        })
        view:AddText({
            text = item.description,
            inline = true,
            width = -(PADDING + NEW_BUTTON_WIDTH + GAP + PADDING),
            widthAnchor = 1,
            height = NEW_ROW_HEIGHT,
            maxLines = HINT_LINES,
            colour = uiConstants.MUTED_RGBA,
        })
    end
end

--- Builds New, Import and New group above the list.
local function renderHeader()
    if window == nil then return end
    if headerView ~= nil then headerView:Destroy() end
    headerView = prettyUI.SimpleView.new(window.content, {
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
--- picker opened from its editor; the window itself is closed or destroyed
--- by the caller.
local function teardown()
    for _, eventID in ipairs(EVENT_IDS) do nextFrame.Cancel(eventID) end
    sharePanel.Cancel()
    deletePanel.Cancel()
    iconPicker.Close()
    auraEditor.Unmount()
    auraList.Destroy()
    listView, editorArea, picker, headerView, searchView = nil, nil, nil, nil, nil
    searchText = ""
    divider = nil
    window = nil
end

--- Where the window is on screen, for opening the icon picker beside it.
---@return Rect? bounds nil while it's closed.
local function windowBounds()
    local root = window ~= nil and window.root or nil
    if root == nil then return nil end
    return { x = root.x, y = root.y, width = root.width, height = root.height }
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
            if window ~= nil and (key == nil or LIST_FIELDS[key]) then requestRender() end
        end,
        -- The editor's own Export button: its panel replaces the editor,
        -- so after that button's callback.
        onExport = function(auraID)
            nextFrame.Run(SHARE_EVENT_ID, function() sharePanel.OpenExport(shareHost, auraID) end)
        end,
        onDuplicate = duplicate,
        onDelete = askDelete,
    })
end

---@return boolean
function mainWindow.IsOpen()
    return window ~= nil
end

--- Opens the window where it was left (kept inside the game area).
---@return boolean opened false if it's already open, or PrettyUI or the game area isn't there.
function mainWindow.Open()
    if window ~= nil or getPrettyUI() == nil then return false end
    local area = gameApi.GameArea()
    if area == nil then return false end

    if selectedID ~= nil and auraStore.Get(selectedID) == nil then selectedID = nil end
    local rect = windowRect.Opening(area)
    local opened
    opened = prettyUI.Window.new(area, {
        title = "Rune Auras",
        x = rect.x,
        y = rect.y,
        width = rect.width,
        height = rect.height,
        minWidth = windowRect.MIN_WIDTH,
        minHeight = windowRect.MIN_HEIGHT,
        resizable = true,
        -- The list and editor scroll on their own; the window itself doesn't.
        scrollable = false,
        destroyOnClose = true,
        -- Runs for the title bar's close button as well as mainWindow.Close.
        onClose = function()
            if window ~= opened then return end
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
    auraEditor.Show(selectedID)
    laidOutWidth, laidOutHeight = window.root.width, window.root.height
    seenWidth, seenHeight = laidOutWidth, laidOutHeight
    Event.Draw.Subscribe(RESIZE_EVENT_ID, watchResize)
    openChanged()
    return true
end

--- Closes the window. Window:Close runs onClose, which tidies up and notifies.
function mainWindow.Close()
    if window ~= nil then window:Close() end
end

--- Opens the window, or closes it if it's open.
function mainWindow.Toggle()
    if window ~= nil then mainWindow.Close() else mainWindow.Open() end
end

--- Selects an aura and opens it in the editor beside the list.
---@param auraID integer? nil for none.
function mainWindow.Select(auraID)
    local reselected = auraID == selectedID
    selectedID = auraID
    if window == nil then return end
    closePicker()
    auraEditor.Show(auraID)
    if not reselected then requestRender() end
end

--- Shows changed data sources: the list's icons and the editor's source
--- pickers.
function mainWindow.OnSourcesChanged()
    auraEditor.OnSourcesChanged()
    if window ~= nil then requestRender() end
end

--- Drops the window without notifying, e.g. on logout when the game area
--- is going away. The selection is kept for next time.
function mainWindow.Destroy()
    rememberRect()
    local closing = window
    teardown()
    if closing ~= nil and closing.root ~= nil then closing:Destroy() end
end

return mainWindow
