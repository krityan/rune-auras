-- The main window: New and Import along the top, every aura in a tree on
-- the left (UI/Windows/aura-list), and the selected aura's editor on the
-- right (UI/Windows/aura-editor), in tabs. New swaps the editor for a choice
-- of what to make (bar, icon, group, ...). A toggle at the top right
-- switches to a single view instead: the list fills the window, and picking
-- an aura (or New) swaps it for the editor, with a Back button in New's
-- place to return to the list. A movable, resizable
-- PrettyUI window over the game area, opened from the ribbon panel
-- (UI/Windows/aura-panel); it remembers where it was left.
-- Usage:
--   local mainWindow = require("UI/Windows/main-window")
--   mainWindow.Init({ onAurasChanged = ..., onOpenChanged = ... })
--   mainWindow.Toggle()

local auraEditor = require("UI/Windows/aura-editor")
local auraList = require("UI/Windows/aura-list")
local auraStore = require("Auras/aura-store")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local mainWindow = {}

local RENDER_EVENT_ID = "runeAuras_mainWindowRender"
local RESIZE_EVENT_ID = "runeAuras_mainWindowResize"
local NEW_EVENT_ID = "runeAuras_mainWindowNew"
local BACK_EVENT_ID = "runeAuras_mainWindowBack"
local HEADER_EVENT_ID = "runeAuras_mainWindowHeader"
-- Everything above, cancelled when the window goes.
local EVENT_IDS = { RENDER_EVENT_ID, RESIZE_EVENT_ID, NEW_EVENT_ID, BACK_EVENT_ID, HEADER_EVENT_ID }
-- Aura fields the list shows; editing others leaves it as it is.
local LIST_FIELDS = { name = true, display = true, source = true, enabled = true }
-- Frames a window resize must stay still before the panes are laid out for
-- it again, so dragging an edge doesn't rebuild the editor every frame.
local RESIZE_SETTLE_FRAMES = 8
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local WINDOW_WIDTH = 900
local WINDOW_HEIGHT = 600
-- Room for the list and a usable editor beside it.
local WINDOW_MIN_WIDTH = 640
local WINDOW_MIN_HEIGHT = 360
local WINDOW_MARGIN = 60
-- The header row of buttons, and the space between them.
local HEADER_HEIGHT = 56
local HEADER_BUTTON_GAP = 16
-- What New offers, in order: a display type to make an aura of, or a group.
-- Entries without `make` aren't supported yet and show disabled.
-- Labels match the display types' own.
local NEW_ITEMS = {
    { label = "Bar", make = "bar", description = "A bar that fills with a value, like adrenaline or a cooldown." },
    { label = "Icon", make = "icon", description = "An ability or buff icon, swiped as its cooldown or duration runs." },
    { label = "Text", make = "text", description = "Text on its own, from a template: a buff's time, a resource, a cast." },
    { label = "Group", make = "group", description = "Moves several auras together." },
    { label = "Dynamic group", make = "dynamicGroup", description = "Lines up the auras in it that are showing, closing gaps as they come and go." },
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
local DIVIDER_WIDTH = GAP
local DIVIDER_LINE_WIDTH = 2
local DIVIDER_IDLE_RGBA = uiConstants.WithAlpha(uiConstants.MUTED_RGBA, 0x40)
local LIST_WIDTH_STORAGE_KEY = "mainListWidth"
-- "1" while the player prefers the single view to side by side.
local SINGLE_VIEW_STORAGE_KEY = "mainWindowSingleView"
-- Where the player last left the window, as "x,y,width,height", so it
-- reopens there, also after reloading the plugin.
local WINDOW_RECT_STORAGE_KEY = "mainWindowRect"

local handlers = nil
local prettyUI = nil
local window = nil
local listView = nil
local editorArea = nil
local selectedID = nil
local windowRect = nil
local windowRectLoaded = false
local listWidth = nil
-- The choice of what to make, shown in the editor's place after New.
local picker = nil
-- Single view: whether it's on, and whether it's showing the editor (or
-- the picker) rather than the list.
local singleView = nil
local showingDetail = false
-- The header's view, and whether it shows Back (rather than New and Import).
local headerView = nil
local headerShowsBack = false
-- The divider's hit area, the line drawn for it, and its drag in progress:
-- { grab (x within the divider), expanded }.
local divider = nil
local dividerLine = nil
local dividerDrag = nil
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

-- Looked up when needed rather than at load: a dev plugin can load before
-- its dependencies have published their globals.
local function getPrettyUI()
    prettyUI = prettyUI or prettyui
    if prettyUI == nil then
        log("Rune Auras: the PrettyUI plugin is not loaded; enable it to edit auras.")
    end
    return prettyUI
end

local function loadRect()
    if windowRectLoaded then return end
    windowRectLoaded = true
    local saved = PersistentDB:GetString(WINDOW_RECT_STORAGE_KEY)
    local x, y, width, height = tostring(saved or ""):match("^(-?%d+),(-?%d+),(%d+),(%d+)$")
    if x == nil then return end
    windowRect = { x = tonumber(x), y = tonumber(y), width = tonumber(width), height = tonumber(height) }
end

local function rememberRect()
    if window == nil or window.root == nil then return end
    windowRect = {
        x = math.floor(window.root.x),
        y = math.floor(window.root.y),
        width = math.floor(window.root.width),
        height = math.floor(window.root.height),
    }
    windowRectLoaded = true
    PersistentDB:SetString(WINDOW_RECT_STORAGE_KEY, formatStr("{},{},{},{}",
        tostring(windowRect.x), tostring(windowRect.y),
        tostring(windowRect.width), tostring(windowRect.height)))
end

-- Keeps a remembered window inside the game area, which may have shrunk
-- since it was saved.
local function fitRect(rect, area)
    local width = math.max(WINDOW_MIN_WIDTH, math.min(rect.width, area.width))
    local height = math.max(WINDOW_MIN_HEIGHT, math.min(rect.height, area.height))
    return {
        x = math.max(0, math.min(rect.x, area.width - width)),
        y = math.max(0, math.min(rect.y, area.height - height)),
        width = width,
        height = height,
    }
end

local requestRender, requestHeader

local function renderList()
    if window == nil then return end
    local scrollY = listView ~= nil and listView.scrollY or nil
    if listView ~= nil then listView:Destroy() end
    listView = nil
    -- The single view shows the list or the editor, not both.
    if singleView and showingDetail then return end
    listView = prettyUI.SimpleView.new(window.content, {
        x = 0,
        y = HEADER_HEIGHT,
        width = singleView and 0 or listWidth,
        widthAnchor = singleView and 1 or nil,
        height = -HEADER_HEIGHT,
        heightAnchor = 1,
        layout = {
            startY = 4,
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
        requestRender = requestRender,
    })
    if scrollY ~= nil then listView:SetScrollPosition(scrollY) end
end

-- Rebuilds the list on the next frame, so a control is never destroyed
-- inside its own callback.
requestRender = function()
    nextFrame.Run(RENDER_EVENT_ID, renderList)
end

-- Where a new aura or group goes: into the selected group, or beside the
-- selected aura, or the top level.
local function newItemGroup()
    local selected = selectedID ~= nil and auraStore.Get(selectedID) or nil
    if selected == nil then return nil end
    if auraStore.IsGroup(selected) then return selected.id end
    return selected.group
end

-- Where a new group goes: as newItemGroup, but never inside a dynamic
-- group, which holds auras only.
local function newGroupParent()
    local groupID = newItemGroup()
    local group = groupID ~= nil and auraStore.Get(groupID) or nil
    if auraStore.IsDynamicGroup(group) then return group.group end
    return groupID
end

-- Keeps the list wide enough to read and the editor wide enough to use.
local function clampListWidth(width)
    local contentWidth = window ~= nil and window.content ~= nil and window.content.width or 0
    if contentWidth <= 0 then contentWidth = WINDOW_WIDTH end
    local widest = math.max(LIST_MIN_WIDTH, contentWidth - EDITOR_MIN_WIDTH - DIVIDER_WIDTH)
    return math.floor(math.max(LIST_MIN_WIDTH, math.min(width, widest)))
end

local function loadListWidth()
    local saved = tonumber(PersistentDB:GetString(LIST_WIDTH_STORAGE_KEY) or "")
    listWidth = clampListWidth(saved or listWidth or LIST_WIDTH)
end

local function placeDividerLine(width)
    dividerLine:SetPos(width + (DIVIDER_WIDTH - DIVIDER_LINE_WIDTH) // 2, HEADER_HEIGHT)
end

local function goBack()
    -- Run after the Back button's callback, as going back destroys it.
    nextFrame.Run(BACK_EVENT_ID, mainWindow.ShowList)
end

-- Lays the panes out for the view: the editor's area beside the list with
-- the divider between them, or in the single view filling the window below
-- the header (or hidden while the list shows).
local function placePanes()
    local split = not singleView
    divider.hidden = not split
    dividerLine.hidden = not split
    editorArea.hidden = singleView and not showingDetail
    if headerView ~= nil and headerShowsBack ~= (singleView and showingDetail) then
        requestHeader()
    end
    if split then
        editorArea:SetPos(listWidth + DIVIDER_WIDTH, HEADER_HEIGHT)
        editorArea:SetSize(-(listWidth + DIVIDER_WIDTH), -HEADER_HEIGHT, 1, 1)
        divider:SetPos(listWidth, HEADER_HEIGHT)
        divider:SetSize(DIVIDER_WIDTH, -HEADER_HEIGHT, 0, 1)
        placeDividerLine(listWidth)
    else
        editorArea:SetPos(0, HEADER_HEIGHT)
        editorArea:SetSize(0, -HEADER_HEIGHT, 1, 1)
    end
end

-- The list and editor lay their rows out for their width, so both are
-- rebuilt when it changes.
local function relayout()
    placePanes()
    renderList()
    auraEditor.Refresh()
end

local function finishDividerDrag()
    local finished = dividerDrag
    dividerDrag = nil
    if finished == nil or window == nil then return false end
    dividerLine.rgba = DIVIDER_IDLE_RGBA
    if finished.width ~= nil and finished.width ~= listWidth then
        listWidth = finished.width
        PersistentDB:SetString(LIST_WIDTH_STORAGE_KEY, tostring(listWidth))
        relayout()
    else
        -- The divider shrinks back from covering the window.
        placePanes()
    end
    return false
end

-- PrettyUI's window has no resize callback, so its size is watched each
-- frame. Once a new size settles, the list is kept narrow enough to leave
-- the editor room and both are rebuilt for their widths.
local function watchResize()
    local root = window ~= nil and window.root or nil
    if root == nil then return end
    local width, height = root.width, root.height
    if width ~= seenWidth or height ~= seenHeight then
        seenWidth, seenHeight = width, height
        stillFrames = 0
        return
    end
    if (width == laidOutWidth and height == laidOutHeight) or dividerDrag ~= nil then return end
    stillFrames = stillFrames + 1
    if stillFrames < RESIZE_SETTLE_FRAMES then return end
    laidOutWidth, laidOutHeight = width, height
    listWidth = clampListWidth(listWidth)
    relayout()
end

-- Adds the divider between the list and the editor. While it's dragged
-- only its line follows the mouse; the panes are laid out again on release.
local function addDivider()
    dividerLine = ui.Rectangle.new(window.content)
    dividerLine.fill = true
    dividerLine.rgba = DIVIDER_IDLE_RGBA
    dividerLine.clickthrough = true
    dividerLine:SetSize(DIVIDER_LINE_WIDTH, -HEADER_HEIGHT, 0, 1)

    divider = ui.Layer.new(window.content)
    divider.enabled = true
    divider.clickthrough = false
    divider:Subscribe(ui.Hook.ONMOUSEOVER, function()
        dividerLine.rgba = uiConstants.ACCENT_RGBA
        return false
    end)
    divider:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        if dividerDrag == nil then dividerLine.rgba = DIVIDER_IDLE_RGBA end
        return false
    end)
    divider:Subscribe(ui.Hook.ONCLICK, function(_, x)
        dividerDrag = { grab = x }
        return false
    end)
    divider:Subscribe(ui.Hook.ONHOLD, function(component, x)
        if dividerDrag == nil then return false end
        -- Hook coordinates are relative to the divider until it's expanded
        -- over the window (so the hold keeps reporting), then they're the
        -- window's.
        local contentX = dividerDrag.expanded and x or ((component.x or 0) + x)
        if not dividerDrag.expanded then
            dividerDrag.expanded = true
            component:SetPos(0, 0)
            component:SetSize(0, 0, 1, 1)
            component:MoveToFront()
        end
        dividerDrag.width = clampListWidth(contentX - dividerDrag.grab)
        dividerLine.rgba = uiConstants.ACCENT_RGBA
        placeDividerLine(dividerDrag.width)
        return false
    end)
    divider:Subscribe(ui.Hook.ONRELEASE, finishDividerDrag)
    divider:Subscribe(ui.Hook.ONDRAGCOMPLETE, finishDividerDrag)
end

local function makeNew(make)
    local groupID = newItemGroup()
    local made
    if make == "group" then
        made = auraStore.CreateGroup(newGroupParent())
    elseif make == "dynamicGroup" then
        made = auraStore.CreateGroup(newGroupParent(), true)
    else
        made = auraStore.Create(groupID)
        if made.display ~= make then auraStore.Set(made.id, "display", make) end
    end
    changed()
    -- Selected straight away, so it gets set up and named.
    mainWindow.Select(made.id)
end

-- Puts the editor back in the picker's place.
local function closePicker()
    if picker == nil then return end
    picker:Destroy()
    picker = nil
    auraEditor.Mount(prettyUI, editorArea)
end

local function openPicker()
    if picker ~= nil or editorArea == nil then return end
    -- The editor locks the aura it had open as it goes.
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
        layout = {
            startY = 10,
            paddingLeft = PADDING,
            paddingRight = PADDING,
            rowGap = GAP,
            columnGap = GAP,
        },
    })
    picker:AddTitle("New")
    picker:AddText({
        text = "Choose what to make. It goes in the selected group, or beside the selected aura.",
        height = 40,
        maxLines = 2,
        colour = uiConstants.MUTED_RGBA,
    })
    for _, item in ipairs(NEW_ITEMS) do
        local make = item.make
        picker:AddSimpleButton(item.label, function()
            -- Run after this callback: making one rebuilds the picker away.
            nextFrame.Run(NEW_EVENT_ID, function() makeNew(make) end)
        end, {
            width = NEW_BUTTON_WIDTH,
            height = NEW_ROW_HEIGHT,
            disabled = make == nil,
            tooltip = make == nil and COMING_SOON or nil,
        })
        picker:AddText({
            text = make == nil and (item.description .. " " .. COMING_SOON) or item.description,
            inline = true,
            width = -(PADDING + NEW_BUTTON_WIDTH + GAP + PADDING),
            widthAnchor = 1,
            height = NEW_ROW_HEIGHT,
            maxLines = 2,
            colour = uiConstants.MUTED_RGBA,
        })
    end
end

-- Builds the header: New and Import, or in the single view while an aura
-- (or New's picker) is open, Back in their place; and the view toggle.
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
        layout = {
            startY = 8,
            paddingLeft = PADDING,
            paddingRight = PADDING,
            rowGap = GAP,
            columnGap = GAP,
        },
    })
    if headerShowsBack then
        headerView:AddFancyButton("Back", goBack, {
            width = 150,
            tooltip = "Back to the list of auras.",
        })
    else
        headerView:AddFancyButton("New", openPicker, {
            width = 150,
            variant = "positive",
            columnGap = HEADER_BUTTON_GAP,
            tooltip = "Make a new aura or group, in the selected group if there is one.",
        })
        headerView:AddFancyButton("Import", function() end, {
            inline = true,
            width = 120,
            disabled = true,
            tooltip = "Importing auras is coming soon.",
        })
    end
    headerView:AddSpriteButton(singleView and "GRID_LAYOUT" or "LIST_LAYOUT", function()
        mainWindow.SetSingleView(not singleView)
    end, {
        inline = true,
        x = -(PADDING + BUTTON_SIZE),
        xAnchor = 1,
        size = BUTTON_SIZE,
        tooltip = singleView and "Show the list and the editor side by side"
            or "Show the list and the editor one at a time",
    })
end

-- Rebuilds the header on the next frame: it's often one of its own buttons
-- (New, Back, the toggle) that changes what it shows.
requestHeader = function()
    nextFrame.Run(HEADER_EVENT_ID, renderHeader)
end

-- Forgets the window's contents and stops its events; the window itself is
-- closed or destroyed by the caller.
local function teardown()
    for _, eventID in ipairs(EVENT_IDS) do nextFrame.Cancel(eventID) end
    auraEditor.Unmount()
    auraList.Destroy()
    listView, editorArea, picker, headerView = nil, nil, nil, nil
    divider, dividerLine, dividerDrag = nil, nil, nil
    window = nil
end

function mainWindow.Init(windowHandlers)
    handlers = windowHandlers
    auraEditor.Init({
        onAurasChanged = function(key)
            changed()
            if window ~= nil and (key == nil or LIST_FIELDS[key]) then requestRender() end
        end,
    })
end

function mainWindow.IsOpen()
    return window ~= nil
end

function mainWindow.Open()
    if window ~= nil or getPrettyUI() == nil then return false end
    local area = gameApi.Component("TOPLEVEL_V2__GAME_AREA")
    if area == nil then return false end

    loadRect()
    if singleView == nil then
        singleView = PersistentDB:GetString(SINGLE_VIEW_STORAGE_KEY) == "1"
    end
    if selectedID ~= nil and auraStore.Get(selectedID) == nil then selectedID = nil end
    -- The single view reopens on the list.
    showingDetail = false
    local rect = windowRect and fitRect(windowRect, area) or {
        x = math.max(0, (area.width - WINDOW_WIDTH) // 2),
        y = WINDOW_MARGIN,
        width = math.min(WINDOW_WIDTH, area.width),
        height = math.max(WINDOW_MIN_HEIGHT, math.min(WINDOW_HEIGHT, area.height - WINDOW_MARGIN * 2)),
    }
    local opened
    opened = prettyUI.Window.new(area, {
        title = "Rune Auras",
        x = rect.x,
        y = rect.y,
        width = rect.width,
        height = rect.height,
        minWidth = WINDOW_MIN_WIDTH,
        minHeight = WINDOW_MIN_HEIGHT,
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

function mainWindow.Close()
    -- Window:Close runs onClose, which tidies up and notifies.
    if window ~= nil then window:Close() end
end

function mainWindow.Toggle()
    if window ~= nil then mainWindow.Close() else mainWindow.Open() end
end

-- Selects an aura (or nil for none) in the list and opens it in the editor.
function mainWindow.Select(auraID)
    local reselected = auraID == selectedID
    selectedID = auraID
    if window == nil then return end
    closePicker()
    -- In the single view, picking an aura opens it in place of the list
    -- (laid out first so the editor builds at its new size).
    if singleView and showingDetail ~= (auraID ~= nil) then
        showingDetail = auraID ~= nil
        placePanes()
    end
    -- Showing the aura already open does nothing, so it doesn't flicker.
    auraEditor.Show(auraID)
    -- The list moves its highlight, or in the single view goes.
    if not reselected or (singleView and showingDetail) then requestRender() end
end

-- Single view: back from the editor (or New's picker) to the list. The
-- selection stays, for where New puts things.
function mainWindow.ShowList()
    if window == nil or not singleView or not showingDetail then return end
    closePicker()
    -- Locks the aura that was open.
    auraEditor.Show(nil)
    showingDetail = false
    placePanes()
    renderList()
end

-- Switches between the list and editor side by side and the single view,
-- remembering the choice.
function mainWindow.SetSingleView(on)
    on = on == true
    if singleView == on then return end
    singleView = on
    PersistentDB:SetString(SINGLE_VIEW_STORAGE_KEY, on and "1" or "0")
    if window == nil then return end
    -- The single view carries on showing what the editor side had open.
    showingDetail = on and (picker ~= nil or selectedID ~= nil)
    -- The toggle's own sprite and tooltip change, so next frame.
    requestHeader()
    placePanes()
    renderList()
    -- The editor's area changed size: build what's selected, or rebuild it
    -- if it's already showing.
    if picker == nil and not auraEditor.Show(selectedID) then auraEditor.Refresh() end
end

-- Drops the window without notifying, e.g. on logout when the game area is
-- going away. The selection is kept for next time.
function mainWindow.Destroy()
    rememberRect()
    local closing = window
    teardown()
    if closing ~= nil and closing.root ~= nil then closing:Destroy() end
end

return mainWindow
