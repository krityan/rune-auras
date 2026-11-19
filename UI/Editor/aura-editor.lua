-- The aura editor: the right of the main window, editing the selected aura
-- in tabs (Display, Trigger, Conditions, Load; each its own file) under its
-- header (editor-header), with flat collapsible sections and aligned form rows.

local auraStore = require("Auras/Store/aura-store")
local rectangles = require("Auras/Displays/Parts/rectangles")
local nextFrame = require("UI/next-frame")
local formView = require("UI/Editor/form-view")
local heroIcons = require("UI/Controls/hero-icons")
local TabStrip = require("UI/PrettyUI/tab-strip")
local uiConstants = require("UI/ui-constants")
local editorHeader = require("UI/Editor/editor-header")
local gameApi = require("GameData/game-api")
local displayTab = require("UI/Editor/display-tab")
local triggerTab = require("UI/Editor/trigger-tab")
local conditionsTab = require("UI/Editor/conditions-tab")
local loadTab = require("UI/Editor/load-tab")
local homePage = require("UI/Editor/home-page")
local iconPicker = require("UI/Windows/icon-picker")

--- A display type's editor controls, from UI/Editor/Types. Each section function
--- adds that section's controls.
---@class TypeEditor
---@field size fun(view: EditorView, aura: Aura, update: fun(key: string, value: any))? The Size section.
---@field appearance fun(view: EditorView, aura: Aura, update: fun(key: string, value: any), context: EditorTabContext)? Added to Appearance, after Fill colour.
---@field state fun(view: EditorView, aura: Aura, update: fun(key: string, value: any))? Cooldown or duration appearance controls.
---@field layout fun(view: EditorView, aura: Aura, update: fun(key: string, value: any))? A Layout section.
---@field usesFillColour boolean? false drops the generic Fill colour from Appearance.
---@field usesSource boolean? false drops the Trigger tab and the display type (groups).
---@field usesAppearance boolean? false drops Appearance.
---@field usesText (boolean|fun(aura: Aura): boolean)? false (or a function returning it for the aura) drops the Text section.
---@field usesShowText boolean? false drops Show text (the Text display is all text).
---@field showTextOption { field: string, label: string }? The Text section's checkbox in place of Show text (a Segmented bar's Show progress text).
---@field hideWhenReadyLabel (fun(aura: Aura): string?)? Each text node's checkbox to blank it while the source is ready (TextNode.hideWhenReady), by its label for the aura's source; nil (or no function) for none.
---@field rebuildOn table<string, boolean>? Options that change which of its controls show; changing one rebuilds the editor.
---@field beginBuild fun()? Called at the start of every build, to drop controls kept from the last one (a collapsed section isn't rebuilt).
---@field choosesIcon boolean? Opens the icon picker for the aura, which closes once the editor shows another aura or a type without this.

--- A tab page with aligned label rows, exposing PrettyUI SimpleView's Add methods.
---@class EditorView
---@field contentPadding number The effective left/right padding, for controls that place themselves (see UI/Controls/number-input).

--- What a tab is given to build with.
---@class EditorTabContext
---@field section fun(sectionID: string, title: string, build: fun(view: EditorView), buttons: table[]?) Adds a collapsible section, with buttons (see sectionButtons.ForListItem) on its header's line.
---@field view fun(): EditorView A view for controls outside any section.
---@field onChanged fun() After any edit (the Trigger tab's source options, and the Conditions and Load tabs).
---@field changed fun(key: string?) Tells the window an aura's field changed, so it can redraw what shows it.
---@field update fun(key: string, value: any) Sets an aura field, saves, and reports it.
---@field requestRebuild fun() Rebuilds next frame, after an edit that adds or removes controls.
---@field typeEditor TypeEditor
---@field screenSize ScreenSizeFunction An aura's size on screen.
---@field windowBounds fun(): Rect? Where the editor's window is on screen, for opening a window beside it (the icon picker); nil if it isn't open.

--- What the editor reports to, and asks of, the window it's in.
---@class EditorHandlers
---@field onAurasChanged fun(key: string?)? An aura's field changed (nil: several).
---@field onExport fun(auraID: integer)?
---@field onDuplicate fun(auraID: integer)?
---@field onDelete fun(auraID: integer)? Asks how to delete it.
---@field screenSize ScreenSizeFunction
---@field windowBounds fun(): Rect? Where the window is on screen, for opening the icon picker beside it.

---@type table<DisplayID, TypeEditor>
local TYPE_EDITORS = {
    bar = require("UI/Editor/Types/bar"),
    icon = require("UI/Editor/Types/icon"),
    text = require("UI/Editor/Types/text"),
    segments = require("UI/Editor/Types/segments"),
    orb = require("UI/Editor/Types/orb"),
    group = require("UI/Editor/Types/group"),
    dynamicGroup = require("UI/Editor/Types/dynamic-group"),
}

local auraEditor = {}

local REBUILD_EVENT_ID = "runeAuras_editorRebuild"
-- build's choices: keep each tab's scroll position, or start at the top.
local KEEP_SCROLL, FROM_TOP = true, false
-- setUnlocked's choices.
local UNLOCKED, LOCKED = true, false
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
local SECTION_GAP = uiConstants.SECTION_GAP
-- Flat section headings leave room for 24px actions.
local SECTION_HEADER_HEIGHT = 28
local SECTION_ICON_SIZE = 12
local SECTION_TITLE_INSET = 20
local SECTION_RULE_RGBA = 0x756C6080
local PAGE_START_Y = 10
local HOME_START_Y = 20
-- Kept clear on the home page's right for the scroll view's scrollbar.
local HOME_SCROLLBAR_ROOM = 16
-- The home page's width while the editor's area has none yet.
local HOME_FALLBACK_WIDTH = 300
-- The home page's short form (see showHomePage).
local SHORT_HOME_TEXT = "Select an aura on the left to edit it, or make one with New."
local SHORT_HOME_HEIGHT, SHORT_HOME_LINES = 48, 2
-- The tabs, in order.
local TAB_DISPLAY, TAB_TRIGGER, TAB_CONDITIONS, TAB_LOAD = 1, 2, 3, 4
local TABS = {
    { text = "Display" },
    { text = "Trigger" },
    { text = "Conditions" },
    { text = "Load" },
}

---@type EditorHandlers?
local handlers = nil
local prettyUI = nil
-- The layer the editor builds into, and what's in it: the header, and the
-- tabs in a layer below it; or the home page when no aura is selected.
local parent = nil
local header = nil
local tabsArea = nil
local tabs = nil
local homeView = nil
local editingID = nil
-- The tab last shown, kept when switching aura.
local activeTab = TAB_DISPLAY
-- Whether the editor is being built (so a tab change is made by the build,
-- not by the player).
local building = false
-- The aura the editor unlocked for dragging: the one whose Display tab is
-- showing, or nil.
local dragUnlockedID = nil
-- Fits the tab strip to the editor's width; made once, so the tabs stay
-- scrolled where they were when switching aura.
---@type TabStrip?
local tabStrip = nil
-- Section id to true for collapsed sections; remembered between sessions.
local COLLAPSED_STORAGE_KEY = "editorCollapsedSections"
local collapsedSections = nil
-- The page being built into, and whether it already has a section above the
-- next one.
local host = nil
local hasSection = false

--- Tells the window an aura's field changed, so it can redraw what shows it.
---@param key string?
local function changed(key)
    if handlers ~= nil and handlers.onAurasChanged ~= nil then
        handlers.onAurasChanged(key)
    end
end

--- Unlocks an aura so it can be dragged, or locks it so it stops catching
--- clicks meant for the game. Saves and reports the change.
---@param auraID integer? nil: does nothing.
---@param unlocked boolean UNLOCKED or LOCKED.
local function setUnlocked(auraID, unlocked)
    if auraID ~= nil and auraStore.Get(auraID) ~= nil then
        auraStore.Set(auraID, "unlocked", unlocked)
        changed("unlocked")
    end
end

--- Keeps only the aura whose Display tab is showing unlocked for dragging,
--- locking the one unlocked before. Only acts when that changes, so a
--- rebuild doesn't undo the player unticking "Unlock to drag on screen".
---@param auraID integer? The aura whose Display tab is showing, or nil.
local function unlockForDisplayTab(auraID)
    if auraID == dragUnlockedID then
        return
    end

    setUnlocked(dragUnlockedID, LOCKED)
    setUnlocked(auraID, UNLOCKED)
    dragUnlockedID = auraID
end

local requestRebuild, requestTabsRebuild, sectionView

--- Loads which sections are collapsed, once.
local function loadCollapsed()
    if collapsedSections ~= nil then
        return
    end

    collapsedSections = {}

    for sectionID in tostring(PersistentDB:GetString(COLLAPSED_STORAGE_KEY) or ""):gmatch("[^,]+") do
        collapsedSections[sectionID] = true
    end
end

--- Collapses or opens a section, and saves which are collapsed.
---@param sectionID string
---@param collapsed boolean
local function setCollapsed(sectionID, collapsed)
    loadCollapsed()
    collapsedSections[sectionID] = collapsed or nil
    local list = {}
    for id in pairs(collapsedSections) do
        list[#list + 1] = id
    end

    table.sort(list)
    PersistentDB:SetString(COLLAPSED_STORAGE_KEY, table.concat(list, ","))
end

--- A view that aligns labels with their controls at the inspector's current width.
---@return EditorView
sectionView = function()
    return formView.New(host, parent.width or 0)
end

--- Adds the buttons at the right end of a section header, on its line,
--- the first rightmost: Heroicon buttons, as the editor header's are.
---@param buttons table[] Each { icon, tooltip, onClick, danger }.
---@param headerY number The header's top, in the page's content.
local function addHeaderButtons(buttons, headerY)
    local y = headerY + (SECTION_HEADER_HEIGHT - uiConstants.BUTTON_SIZE) // 2
    for index, button in ipairs(buttons) do
        heroIcons.Button(prettyUI, host.content, button.icon, button.onClick, {
            x = -(PADDING + index * uiConstants.BUTTON_SIZE + (index - 1) * GAP),
            xAnchor = 1,
            y = y,
            tooltip = button.tooltip,
            colour = button.danger and uiConstants.DANGER_RGBA or nil,
        })
    end
end

--- Adds a flat section heading that remembers its collapsed state.
---@param sectionID string
---@param title string
---@param build fun(view: EditorView)
---@param buttons table[]? Actions at the right of the heading.
local function section(sectionID, title, build, buttons)
    loadCollapsed()
    local collapsed = collapsedSections[sectionID] == true
    local heading = host:AddTitle({
        text = title,
        x = PADDING + SECTION_TITLE_INSET,
        width = -(PADDING * 2 + SECTION_TITLE_INSET + #(buttons or {}) * (uiConstants.BUTTON_SIZE + GAP)),
        widthAnchor = 1,
        height = SECTION_HEADER_HEIGHT,
        marginTop = hasSection and SECTION_GAP or 0,
        colour = uiConstants.ACCENT_RGBA,
    })

    local icon = heroIcons.Sprite(host.content, collapsed and "chevron-right" or "chevron-down")
    icon:SetPos(PADDING, heading.y + (SECTION_HEADER_HEIGHT - SECTION_ICON_SIZE) // 2)
    icon:SetSize(SECTION_ICON_SIZE, SECTION_ICON_SIZE)

    local rule = rectangles.Filled(host.content, SECTION_RULE_RGBA)
    rule:SetPos(PADDING, heading.y + SECTION_HEADER_HEIGHT - 1)
    rule:SetSize(-PADDING * 2, 1, 1, 0)

    heading.enabled = true
    heading.clickthrough = false
    icon.enabled = true
    icon.clickthrough = false

    --- Toggles this section after its current controls finish handling the click.
    ---@return boolean continue
    local function toggleSection()
        setCollapsed(sectionID, not collapsed)
        requestRebuild()
        return false
    end

    heading:Subscribe(ui.Hook.ONCLICK, toggleSection)
    icon:Subscribe(ui.Hook.ONCLICK, toggleSection)
    local page = host

    --- Scrolls the page while the pointer is over the heading or its chevron.
    ---@param _ userdata
    ---@param delta number
    ---@return boolean continue
    local function scrollHeading(_, delta)
        page:SetScrollPosition((page.scrollY or 0) + delta * uiConstants.FIELD_HEIGHT)
        return false
    end

    heading:Subscribe(ui.Hook.ONSCROLLWHEEL, scrollHeading)
    icon:Subscribe(ui.Hook.ONSCROLLWHEEL, scrollHeading)
    addHeaderButtons(buttons or {}, heading.y)
    hasSection = true

    if not collapsed then
        build(sectionView())
    end
end

--- Disables the tabs an aura doesn't have. Groups only move what's in them:
--- no data, so no trigger, and no conditions. Disabling the open tab moves
--- to another (see `building`).
---@param aura Aura
---@param typeEditor TypeEditor
local function disableUnusedTabs(aura, typeEditor)
    if typeEditor.usesSource == false then
        tabs:SetDisabled(TAB_TRIGGER, true)
        tabs:SetTabTooltip(TAB_TRIGGER, "Groups have no trigger")
    end

    if auraStore.IsGroup(aura) then
        tabs:SetDisabled(TAB_CONDITIONS, true)
        tabs:SetTabTooltip(TAB_CONDITIONS, "Groups have no conditions")
    end
end

--- Builds the tab showing for an aura. Only the tab showing is built: the
--- game has 4,096 interface parts for everything we draw, and all four
--- tabs' controls together were enough to run out with a few hundred auras.
--- Switching tab rebuilds (see the tabs' onChange).
---@param aura Aura
local function buildEditor(aura)
    local typeEditor = TYPE_EDITORS[aura.display] or {}
    -- The icon picker chooses for one aura, and only while it can have one.
    iconPicker.CloseUnlessFor(typeEditor.choosesIcon and aura.id or nil)

    if typeEditor.beginBuild ~= nil then
        typeEditor.beginBuild()
    end

    local rebuildOn = typeEditor.rebuildOn or {}
    local function update(key, value)
        auraStore.Set(aura.id, key, value)
        changed(key)

        if rebuildOn[key] then
            requestRebuild()
        end
    end

    disableUnusedTabs(aura, typeEditor)

    local shown = tabs:GetActiveIndex()
    host = tabs:GetPage(shown)
    hasSection = false
    ---@type EditorTabContext
    local context = {
        section = section,
        view = sectionView,
        changed = changed,
        update = update,
        requestRebuild = requestRebuild,
        typeEditor = typeEditor,
        screenSize = handlers.screenSize,
        windowBounds = handlers.windowBounds,
    }
    if shown == TAB_DISPLAY then
        displayTab.Build(aura, context)
    elseif shown == TAB_TRIGGER then
        context.onChanged = function() changed("sourceOptions") end
        triggerTab.Build(aura, context)
    elseif shown == TAB_CONDITIONS then
        context.onChanged = function() changed("conditions") end
        conditionsTab.Build(aura, context)
    elseif shown == TAB_LOAD then
        -- Groups have load options too: one that isn't loaded takes
        -- everything in it with it. Its options come first, so its section
        -- is spaced from them.
        hasSection = true
        context.onChanged = function() changed("load") end
        loadTab.Build(aura, context)
    end

    host = nil
end

--- Fits the tab strip to the editor's width, keeping the active tab in view.
local function fitTabStrip()
    if tabs == nil or parent == nil or tabStrip == nil then
        return
    end

    tabStrip:Fit(tabs, parent.width or 0, activeTab)
end

--- Destroys the header and tabs or the home page, and forgets the tabs' controls.
local function destroyContents()
    nextFrame.Cancel(REBUILD_EVENT_ID)

    if tabStrip ~= nil then
        tabStrip:Forget()
    end

    if header ~= nil then
        header:Destroy()
    end

    if tabs ~= nil then
        tabs:Destroy()
    end

    if tabsArea ~= nil then
        tabsArea:Destroy()
    end

    if homeView ~= nil then
        homeView:Destroy()
    end

    header, tabsArea, tabs, homeView = nil, nil, nil, nil
    displayTab.Forget()
end

--- A scroll view filling the editor's area, for the home page.
---@return table view A PrettyUI SimpleView.
local function newHomeView()
    return prettyUI.SimpleView.new(parent, {
        categoryID = uiConstants.PRETTYUI_EDITOR_CATEGORY,
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        layout = { startY = HOME_START_Y, paddingLeft = PADDING, paddingRight = PADDING, rowGap = GAP },
    })
end

--- Adds the home page's short form, one line: for when the game has too few
--- interface parts left for the whole page.
local function addShortHome()
    homeView:AddText({
        text = SHORT_HOME_TEXT,
        height = SHORT_HOME_HEIGHT,
        maxLines = SHORT_HOME_LINES,
        colour = uiConstants.MUTED_RGBA,
    })
end

--- What the header's controls do for an aura. Groups aren't duplicated:
--- copying one would mean copying everything in it.
---@param aura Aura
---@return EditorHeaderHandlers
local function headerHandlers(aura)
    local auraID = aura.id
    ---@type EditorHeaderHandlers
    local headerControls = {
        onRename = function(name)
            auraStore.Set(auraID, "name", name)
            changed("name")
        end,
    }
    if handlers.onExport ~= nil then
        headerControls.onExport = function() handlers.onExport(auraID) end
    end

    if handlers.onDuplicate ~= nil and not auraStore.IsGroup(aura) then
        headerControls.onDuplicate = function() handlers.onDuplicate(auraID) end
    end

    if handlers.onDelete ~= nil then
        headerControls.onDelete = function() handlers.onDelete(auraID) end
    end

    return headerControls
end

--- Makes the header, and the layer below it the tabs go in.
---@param aura Aura
local function makeHeader(aura)
    header = editorHeader.Build(prettyUI, parent, aura, headerHandlers(aura))
    tabsArea = ui.Layer.new(parent)
    tabsArea.clickthrough = true
    tabsArea:SetPos(0, editorHeader.HEIGHT)
    tabsArea:SetSize(0, -editorHeader.HEIGHT, 1, 1)
end

--- Shows the home page, for when no aura is selected, wrapped to the
--- editor's width less the scroll view's scrollbar. Its texts are about 50
--- interface parts: if the game runs out of them, the page goes and its
--- one-line short form shows instead, if even that fits. Any other error
--- is a bug, so it's raised again.
local function showHomePage()
    homeView = newHomeView()
    local width = (parent.width or 0) - PADDING * 2 - HOME_SCROLLBAR_ROOM
    if width <= 0 then
        width = HOME_FALLBACK_WIDTH
    end

    local shown, problem = pcall(homePage.Add, homeView, PADDING, HOME_START_Y, width)
    if shown then
        return
    end

    homeView:Destroy()
    homeView = nil

    if not gameApi.IsComponentLimitError(problem) then
        error(problem, 0)
    end

    local made, view = pcall(newHomeView)
    if not made then
        return
    end

    homeView = view
    pcall(addShortHome)
end

--- Makes the tabs, building the one picked when the player switches.
local function makeTabs()
    tabs = prettyUI.Tabs.new(tabsArea, TABS, {
        categoryID = uiConstants.PRETTYUI_EDITOR_CATEGORY,
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        activeIndex = activeTab,
        contentLayout = {
            startY = PAGE_START_Y,
            paddingLeft = PADDING,
            paddingRight = PADDING,
            rowGap = GAP,
            columnGap = GAP,
        },
        onChange = function(_, index)
            -- A tab the build disables (Trigger for a group) moves it to
            -- another; that isn't the player's choice, so it's not kept.
            if building then
                return
            end

            activeTab = index
            fitTabStrip()
            -- Only the tabs: the header above them is the same for every tab.
            requestTabsRebuild()
        end,
    })
end

--- Each tab's scroll position, to put back after rebuilding.
---@param keepScroll boolean KEEP_SCROLL, or FROM_TOP for none.
---@return table<integer, number> scrollYs Tab index to its page's scroll position.
local function tabScrolls(keepScroll)
    local scrollYs = {}
    if keepScroll and tabs ~= nil then
        for index = 1, #TABS do
            local page = tabs:GetPage(index)
            scrollYs[index] = page and page.scrollY or nil
        end
    end

    return scrollYs
end

--- Makes the tabs under the header and builds the shown one, then puts
--- each tab's scroll position back.
---@param aura Aura
---@param scrollYs table<integer, number>
local function buildTabs(aura, scrollYs)
    makeTabs()
    -- Before building, so the Display tab's Unlock to drag shows it ticked;
    -- again after, as the build can move to another tab (see disableUnusedTabs).
    unlockForDisplayTab(tabs:GetActiveIndex() == TAB_DISPLAY and editingID or nil)
    -- Reset whatever happens, or an error in a build would leave every
    -- later tab click ignored; the error still surfaces.
    building = true
    local ok, problem = pcall(buildEditor, aura)
    building = false
    unlockForDisplayTab(tabs:GetActiveIndex() == TAB_DISPLAY and editingID or nil)

    if not ok then
        error(problem, 0)
    end

    -- After building: disabling a tab (as for groups) has PrettyUI lay the
    -- strip out again.
    fitTabStrip()

    for index, scrollY in pairs(scrollYs) do
        local page = tabs:GetPage(index)
        if page ~= nil then
            page:SetScrollPosition(scrollY)
        end
    end
end

--- Builds (or rebuilds) the editor for editingID, or the home page when there's none.
---@param keepScroll boolean KEEP_SCROLL to keep each tab's scroll position (e.g. when one option changes another's range), or FROM_TOP.
local function build(keepScroll)
    local scrollYs = tabScrolls(keepScroll)
    destroyContents()

    if parent == nil or prettyUI == nil then
        return
    end

    local aura = editingID ~= nil and auraStore.Get(editingID) or nil
    if aura == nil then
        editingID = nil
        unlockForDisplayTab(nil)
        iconPicker.Close()
        showHomePage()
        return
    end

    makeHeader(aura)
    buildTabs(aura, scrollYs)
end

--- Rebuilds the editor where it's scrolled to.
local function rebuildKeepingScroll() build(KEEP_SCROLL) end

--- Rebuilds only the tabs, keeping the header (its icon, name and
--- buttons, the same for every tab), where they're scrolled to: for a tab
--- change. Without a header to keep (the aura went), the whole editor.
local function rebuildTabsKeepingScroll()
    local aura = editingID ~= nil and auraStore.Get(editingID) or nil
    if header == nil or tabsArea == nil or tabs == nil or aura == nil or parent == nil then
        build(KEEP_SCROLL)
        return
    end

    local scrollYs = tabScrolls(KEEP_SCROLL)

    if tabStrip ~= nil then
        tabStrip:Forget()
    end

    tabs:Destroy()
    tabs = nil
    displayTab.Forget()
    buildTabs(aura, scrollYs)
end

--- Rebuilds on the next frame, keeping the scroll positions. Use this from
--- a control's own callback so the control isn't destroyed while it's running.
requestRebuild = function()
    nextFrame.Run(REBUILD_EVENT_ID, rebuildKeepingScroll)
end

--- Rebuilds only the tabs on the next frame (see rebuildTabsKeepingScroll),
--- as it's called from the tabs' own callback. A whole rebuild already
--- waiting does this too, so it's left to run.
requestTabsRebuild = function()
    if nextFrame.Pending(REBUILD_EVENT_ID) == rebuildKeepingScroll then
        return
    end

    nextFrame.Run(REBUILD_EVENT_ID, rebuildTabsKeepingScroll)
end

--- Sets what the editor reports.
---@param editorHandlers EditorHandlers
function auraEditor.Init(editorHandlers)
    handlers = editorHandlers
end

--- Sets where the editor builds: a layer in the main window.
---@param prettyUILibrary table
---@param layer userdata
function auraEditor.Mount(prettyUILibrary, layer)
    prettyUI = prettyUILibrary
    parent = layer
    tabStrip = tabStrip or TabStrip.new(prettyUI)
end

--- Edits an aura. While its Display tab shows, it's unlocked so it can be
--- dragged straight away (see unlockForDisplayTab). Does nothing if that's
--- already what it shows, so reselecting the open aura doesn't rebuild it.
---@param auraID integer? nil for none.
---@return boolean built
function auraEditor.Show(auraID)
    if auraID == editingID and (tabs ~= nil or homeView ~= nil) then
        return false
    end

    if editingID ~= nil and editingID ~= auraID then
        triggerTab.Forget()
    end

    editingID = auraID
    build(FROM_TOP)
    return true
end

--- Has the editor show the Trigger tab from the next aura on, as a new
--- aura is set up from its source first.
function auraEditor.ShowTriggerTab()
    activeTab = TAB_TRIGGER
end

--- Builds the editor again for its area's current size, keeping the tab and
--- scroll positions.
function auraEditor.Refresh()
    if parent ~= nil then
        build(KEEP_SCROLL)
    end
end

--- Rebuilds next frame, if it's showing, so its source pickers list the
--- current sources (buffs the background walk found, say).
function auraEditor.OnSourcesChanged()
    if parent ~= nil then
        requestRebuild()
    end
end

--- The aura being edited.
---@return integer? auraID nil when there's none.
function auraEditor.EditingID()
    return tabs ~= nil and editingID or nil
end

--- Shows a dragged aura's new offset in the editor, if it's open.
---@param auraID integer
function auraEditor.OnAuraMoved(auraID)
    if auraID ~= editingID then
        return
    end

    local aura = auraStore.Get(auraID)
    if aura == nil then
        return
    end

    displayTab.OnAuraMoved(aura)
end

--- Drops the editor, e.g. when the main window closes or on logout. The
--- aura being edited is locked, or it would keep catching clicks.
function auraEditor.Unmount()
    destroyContents()
    parent = nil
    editingID = nil
    triggerTab.Forget()
    unlockForDisplayTab(nil)
end

return auraEditor
