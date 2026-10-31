-- The main window: a movable, resizable PrettyUI window over the game area,
-- opened from the ribbon panel, with New and Import along the top, the aura
-- list on the left and the selected aura's editor on the right. Panels
-- (New's choice of what to make, Import, Export) take the editor's place. A
-- toggle at the top right switches to a single view: the list fills the
-- window, and picking an aura (or New) swaps it for the editor, with Back
-- in New's place. Where it opens is worked out by window-rect, and the
-- divider between the panes is pane-divider.

local auraEditor = require("UI/Editor/aura-editor")
local auraList = require("UI/Windows/aura-list")
local auraStore = require("Auras/Store/aura-store")
local displayTypes = require("Auras/Registries/display-types")
local sharePanel = require("UI/Windows/share-panel")
local deletePanel = require("UI/Windows/delete-panel")
local PaneDivider = require("UI/Windows/pane-divider")
local windowRect = require("UI/Windows/window-rect")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local mainWindow = {}

---@class MainWindowHandlers
---@field onAurasChanged fun()? Auras were changed.
---@field onOpenChanged fun()? The window opened or closed.

local RENDER_EVENT_ID = "runeAuras_mainWindowRender"
local RESIZE_EVENT_ID = "runeAuras_mainWindowResize"
local NEW_EVENT_ID = "runeAuras_mainWindowNew"
local BACK_EVENT_ID = "runeAuras_mainWindowBack"
local HEADER_EVENT_ID = "runeAuras_mainWindowHeader"
local SHARE_EVENT_ID = "runeAuras_mainWindowShare"
-- Everything above, cancelled when the window goes.
local EVENT_IDS = { RENDER_EVENT_ID, RESIZE_EVENT_ID, NEW_EVENT_ID, BACK_EVENT_ID, HEADER_EVENT_ID, SHARE_EVENT_ID }
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
local HEADER_HEIGHT = 56
local HEADER_BUTTON_GAP = 16
local NEW_BUTTON_WIDTH_HEADER = 150
local IMPORT_BUTTON_WIDTH = 120
local BACK_BUTTON_WIDTH = 150
local HINT_HEIGHT, HINT_LINES = 40, 2
--- What New offers, in order: a display type to make an aura of, or a group.
--- Entries without `make` aren't supported yet and show disabled; they need
--- a `label`, while the rest show their display type's label.
---@type { make: DisplayID?, label: string?, description: string }[]
local NEW_ITEMS = {
    { make = "bar", description = "A bar that fills with a value, like adrenaline or a cooldown." },
    { make = "icon", description = "An ability or buff icon, swiped as its cooldown or duration runs." },
    { make = "text", description = "Text on its own, from a template: a buff's time, a resource, a cast." },
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
local COMING_SOON = "Coming soon."
-- The list's width, which the player can change by dragging the divider
-- between it and the editor (remembered as mainListWidth).
local LIST_WIDTH = 330
local LIST_MIN_WIDTH = 180
local EDITOR_MIN_WIDTH = 260
-- "1" while the player prefers the single view to side by side.
local SINGLE_VIEW_STORAGE_KEY = "mainWindowSingleView"
local SINGLE_VIEW_ON, SINGLE_VIEW_OFF = "1", "0"

---@type MainWindowHandlers?
local handlers = nil
local prettyUI = nil
local window = nil
local listView = nil
local editorArea = nil
local selectedID = nil
local listWidth = nil
-- A panel shown in the editor's place: New's choice of what to make,
-- Import's or Export's box, or Delete's choices.
local picker = nil
-- What the panel was opened with, to build it again for a new width.
local panelTitle, panelBuild = nil, nil
-- Single view: whether it's on, and whether it's showing the editor (or a
-- panel) rather than the list.
local singleView = nil
local showingDetail = false
-- The header's view, and whether it shows Back (rather than New and Import).
local headerView = nil
local headerShowsBack = false
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

--- How much of the list shows: the window below the header. (Not the
--- view's own height, which grows to fit what's in it.)
---@return number
local function listViewHeight()
    local content = window ~= nil and window.content or nil
    return math.max(1, (content and content.height or 0) - HEADER_HEIGHT)
end

--- Builds the list again, keeping its scroll position. The single view shows
--- the list or the editor, not both.
local function renderList()
    if window == nil then return end
    local scrollY = listView ~= nil and listView.scrollY or nil
    if listView ~= nil then listView:Destroy() end
    listView = nil
    if singleView and showingDetail then return end
    listView = prettyUI.SimpleView.new(window.content, {
        x = 0,
        y = HEADER_HEIGHT,
        width = singleView and 0 or listWidth,
        widthAnchor = singleView and 1 or nil,
        height = -HEADER_HEIGHT,
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
        onSelect = function(auraID) mainWindow.Select(auraID) end,
        onChanged = changed,
        onDelete = function(auraID) deletePanel.Open(deleteHost, auraID) end,
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

--- Back to the list, after the Back button's callback, as going back
--- destroys it.
local function goBack()
    nextFrame.Run(BACK_EVENT_ID, mainWindow.ShowList)
end

--- Lays the panes out for the view: the editor's area beside the list with
--- the divider between them, or in the single view filling the window below
--- the header (or hidden while the list shows).
local function placePanes()
    local split = not singleView
    divider:SetShown(split)
    editorArea.hidden = singleView and not showingDetail
    local wantsBack = singleView and showingDetail
    if headerView ~= nil and headerShowsBack ~= wantsBack then requestHeader() end
    if split then
        editorArea:SetPos(listWidth + PaneDivider.WIDTH, HEADER_HEIGHT)
        editorArea:SetSize(-(listWidth + PaneDivider.WIDTH), -HEADER_HEIGHT, 1, 1)
        divider:Place(listWidth)
    else
        editorArea:SetPos(0, HEADER_HEIGHT)
        editorArea:SetSize(0, -HEADER_HEIGHT, 1, 1)
    end
end

--- Lays everything out again for a new width: the list, editor and header
--- lay their rows out for their width, so all are rebuilt (the header's view
--- toggle is pinned to the right only when it's built).
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
        top = HEADER_HEIGHT,
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
    if singleView and not showingDetail then
        showingDetail = true
        placePanes()
        requestRender()
    end
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
        local displayType = make and displayTypes.Get(make)
        local label = item.label or (displayType and displayType.label) or tostring(make)
        view:AddSimpleButton(label, function()
            -- Run after this callback: making one rebuilds the picker away.
            nextFrame.Run(NEW_EVENT_ID, function() makeNew(make) end)
        end, {
            width = NEW_BUTTON_WIDTH,
            height = NEW_ROW_HEIGHT,
            disabled = make == nil,
            tooltip = make == nil and COMING_SOON or nil,
        })
        view:AddText({
            text = make == nil and (item.description .. " " .. COMING_SOON) or item.description,
            inline = true,
            width = -(PADDING + NEW_BUTTON_WIDTH + GAP + PADDING),
            widthAnchor = 1,
            height = NEW_ROW_HEIGHT,
            maxLines = HINT_LINES,
            colour = uiConstants.MUTED_RGBA,
        })
    end
end

--- Builds the header: New and Import, or in the single view while an aura
--- (or a panel) is open, Back in their place; and the view toggle.
local function renderHeader()
    if window == nil then return end
    if headerView ~= nil then headerView:Destroy() end
    headerShowsBack = singleView and showingDetail
    headerView = prettyUI.SimpleView.new(window.content, {
        x = 0,
        y = 0,
        width = 0,
        widthAnchor = 1,
        height = HEADER_HEIGHT,
        scrollable = false,
        layout = paddedLayout(HEADER_START_Y),
    })
    if headerShowsBack then
        headerView:AddFancyButton("Back", goBack, {
            width = BACK_BUTTON_WIDTH,
        })
    else
        headerView:AddFancyButton("New", openPicker, {
            width = NEW_BUTTON_WIDTH_HEADER,
            variant = "positive",
            columnGap = HEADER_BUTTON_GAP,
            tooltip = "Goes in the selected group",
        })
        headerView:AddFancyButton("Import", function()
            -- Opening it rebuilds the header in the single view, so after
            -- this callback.
            nextFrame.Run(SHARE_EVENT_ID, function() sharePanel.OpenImport(shareHost) end)
        end, {
            inline = true,
            width = IMPORT_BUTTON_WIDTH,
            tooltip = "From an export string",
        })
    end
    headerView:AddSpriteButton(singleView and "GRID_LAYOUT" or "LIST_LAYOUT", function()
        mainWindow.SetSingleView(not singleView)
    end, {
        inline = true,
        x = -(PADDING + BUTTON_SIZE),
        xAnchor = 1,
        size = BUTTON_SIZE,
        tooltip = singleView and "Side by side" or "One at a time",
    })
end

--- Rebuilds the header on the next frame: it's often one of its own
--- buttons (New, Back, the toggle) that changes what it shows.
requestHeader = function()
    nextFrame.Run(HEADER_EVENT_ID, renderHeader)
end

--- Forgets the window's contents and stops its events; the window itself
--- is closed or destroyed by the caller.
local function teardown()
    for _, eventID in ipairs(EVENT_IDS) do nextFrame.Cancel(eventID) end
    sharePanel.Cancel()
    deletePanel.Cancel()
    auraEditor.Unmount()
    auraList.Destroy()
    listView, editorArea, picker, headerView = nil, nil, nil, nil
    divider = nil
    window = nil
end

--- Sets up the editor, and what the window reports.
---@param windowHandlers MainWindowHandlers?
function mainWindow.Init(windowHandlers)
    handlers = windowHandlers
    auraEditor.Init({
        onAurasChanged = function(key)
            changed()
            if window ~= nil and (key == nil or LIST_FIELDS[key]) then requestRender() end
        end,
        -- The editor's own Export button: its panel replaces the editor,
        -- so after that button's callback.
        onExport = function(auraID)
            nextFrame.Run(SHARE_EVENT_ID, function() sharePanel.OpenExport(shareHost, auraID) end)
        end,
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

    if singleView == nil then
        singleView = PersistentDB:GetString(SINGLE_VIEW_STORAGE_KEY) == SINGLE_VIEW_ON
    end
    if selectedID ~= nil and auraStore.Get(selectedID) == nil then selectedID = nil end
    -- The single view reopens on the list.
    showingDetail = false
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
    renderHeader()

    -- The editor's area: everything right of the list and the divider,
    -- below the header.
    loadListWidth()
    editorArea = ui.Layer.new(window.content)
    editorArea.clickthrough = true
    addDivider()
    placePanes()
    auraEditor.Mount(prettyUI, editorArea)

    renderList()
    -- The single view opens on the list, so its editor waits until an aura
    -- is picked.
    auraEditor.Show(not singleView and selectedID or nil)
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

--- Selects an aura in the list and opens it in the editor. In the single
--- view, picking one opens it in place of the list.
---@param auraID integer? nil for none.
function mainWindow.Select(auraID)
    local reselected = auraID == selectedID
    selectedID = auraID
    if window == nil then return end
    closePicker()
    -- Laid out first so the editor builds at its new size.
    local wantsDetail = auraID ~= nil
    if singleView and showingDetail ~= wantsDetail then
        showingDetail = wantsDetail
        placePanes()
    end
    -- Showing the aura already open does nothing, so it doesn't flicker.
    auraEditor.Show(auraID)
    -- The list moves its highlight, or in the single view goes.
    if not reselected or (singleView and showingDetail) then requestRender() end
end

--- Single view: back from the editor (or a panel) to the list. The
--- selection stays, for where New puts things.
function mainWindow.ShowList()
    if window == nil or not singleView or not showingDetail then return end
    closePicker()
    -- Locks the aura that was open.
    auraEditor.Show(nil)
    showingDetail = false
    placePanes()
    renderList()
end

--- Switches between the list and editor side by side and the single view,
--- remembering the choice. The single view carries on showing what the
--- editor side had open.
---@param on boolean
function mainWindow.SetSingleView(on)
    on = on == true
    if singleView == on then return end
    singleView = on
    PersistentDB:SetString(SINGLE_VIEW_STORAGE_KEY, on and SINGLE_VIEW_ON or SINGLE_VIEW_OFF)
    if window == nil then return end
    showingDetail = on and (picker ~= nil or selectedID ~= nil)
    -- The toggle's own sprite and tooltip change, so next frame.
    requestHeader()
    placePanes()
    renderList()
    -- The editor's area changed size: build what's selected, or rebuild it
    -- if it's already showing.
    if picker == nil and not auraEditor.Show(selectedID) then auraEditor.Refresh() end
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
