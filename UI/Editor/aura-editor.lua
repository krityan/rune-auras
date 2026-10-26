-- The aura editor: the right of the main window, editing the selected aura
-- in tabs (Display, Trigger, Conditions, Load; each its own file). Owns the
-- tabs and the collapsible sections they're built from, and which display
-- type's editor controls apply. Its fixes to PrettyUI live in UI/PrettyUI.

local auraStore = require("Auras/Store/aura-store")
local rectangles = require("Auras/Displays/Parts/rectangles")
local nextFrame = require("UI/next-frame")
local tallHeader = require("UI/PrettyUI/tall-header")
local TabStrip = require("UI/PrettyUI/tab-strip")
local uiConstants = require("UI/ui-constants")
local displayTab = require("UI/Editor/display-tab")
local triggerTab = require("UI/Editor/trigger-tab")
local conditionsTab = require("UI/Editor/conditions-tab")
local loadTab = require("UI/Editor/load-tab")

--- A display type's editor controls, from UI/Editor/Types. Each section function
--- adds that section's controls.
---@class TypeEditor
---@field size fun(view: EditorView, aura: Aura, update: fun(key: string, value: any))? The Size section.
---@field appearance fun(view: EditorView, aura: Aura, update: fun(key: string, value: any))? Added to Appearance, after Fill colour.
---@field layout fun(view: EditorView, aura: Aura, update: fun(key: string, value: any))? A Layout section.
---@field usesFillColour boolean? false drops the generic Fill colour from Appearance.
---@field usesSource boolean? false drops the Trigger tab and the display type (groups).
---@field usesAppearance boolean? false drops Appearance.
---@field usesText boolean? false drops the Text section.
---@field usesShowText boolean? false drops Show text (the Text display is all text).
---@field rebuildOn table<string, boolean>? Options that change which of its controls show; changing one rebuilds the editor.
---@field beginBuild fun()? Called at the start of every build, to drop controls kept from the last one (a collapsed section isn't rebuilt).

--- A page's stand-in that indents everything added through it by
--- SECTION_INDENT (see sectionView). It has PrettyUI SimpleView's Add
--- methods.
---@class EditorView
---@field contentPadding number The effective left/right padding, for controls that place themselves (see UI/Controls/number-input).
---@field bottom number? How far down its controls reach.

--- What a tab is given to build with.
---@class EditorTabContext
---@field section fun(sectionID: string, title: string, build: fun(view: EditorView), buttons: table[]?) Adds a collapsible section.
---@field view fun(): EditorView A view for controls outside any section.
---@field onChanged fun() After any edit (the Conditions and Load tabs).
---@field changed fun(key: string?) Tells the window an aura's field changed, so it can redraw what shows it.
---@field update fun(key: string, value: any) Sets an aura field, saves, and reports it.
---@field requestRebuild fun() Rebuilds next frame, after an edit that adds or removes controls.
---@field typeEditor TypeEditor
---@field onExport fun(auraID: integer)?

---@type table<DisplayID, TypeEditor>
local TYPE_EDITORS = {
    bar = require("UI/Editor/Types/bar"),
    icon = require("UI/Editor/Types/icon"),
    text = require("UI/Editor/Types/text"),
    segments = require("UI/Editor/Types/segments"),
    group = require("UI/Editor/Types/group"),
    dynamicGroup = require("UI/Editor/Types/dynamic-group"),
}

local auraEditor = {}

local REBUILD_EVENT_ID = "runeAuras_editorRebuild"
-- build's choices: keep each tab's scroll position, or start at the top.
local KEEP_SCROLL, FROM_TOP = true, false
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
local SECTION_GAP = uiConstants.SECTION_GAP
-- Extra horizontal padding, on both sides, for the controls inside a section.
local SECTION_INDENT = 12
local PAGE_START_Y = 10
local HINT_START_Y = 20
local HINT_HEIGHT, HINT_LINES = 48, 2
-- The tabs, in order.
local TAB_DISPLAY, TAB_TRIGGER, TAB_CONDITIONS, TAB_LOAD = 1, 2, 3, 4
local TABS = {
    { text = "Display" },
    { text = "Trigger" },
    { text = "Conditions" },
    { text = "Load" },
}

---@type { onAurasChanged: fun(key: string?)?, onExport: fun(auraID: integer)? }?
local handlers = nil
local prettyUI = nil
-- The layer the editor builds into, and what's in it: the tabs, or a hint
-- when no aura is selected.
local parent = nil
local tabs = nil
local hint = nil
local editingID = nil
-- The tab last shown, kept when switching aura.
local activeTab = TAB_DISPLAY
-- Whether the editor is being built (so a tab change is made by the build,
-- not by the player).
local building = false
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

--- Locks an aura again so it stops catching clicks meant for the game.
---@param auraID integer?
local function lockAura(auraID)
    if auraID ~= nil and auraStore.Get(auraID) ~= nil then
        auraStore.Set(auraID, "unlocked", false)
        changed("unlocked")
    end
end

local requestRebuild, sectionView

--- Loads which sections are collapsed, once.
local function loadCollapsed()
    if collapsedSections ~= nil then return end
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
    for id in pairs(collapsedSections) do list[#list + 1] = id end
    table.sort(list)
    PersistentDB:SetString(COLLAPSED_STORAGE_KEY, table.concat(list, ","))
end

-- Where each Add method a section uses takes its options table.
local OPTIONS_INDEX = {
    AddText = 1,
    AddTextField = 1,
    AddComboBox = 1,
    AddSlider = 1,
    AddColourPicker = 1,
    AddCheckboxButton = 2,
    AddSpriteButton = 3,
    AddFancyButton = 3,
    AddSprite = 2,
}
-- Controls that fill their row when given no width.
local FILL_WIDTH = { AddText = true, AddTextField = true, AddComboBox = true, AddSprite = true }

--- A stand-in for the tab page that indents everything added through it by
--- SECTION_INDENT. The flow layout has one padding for the whole page, so
--- each row gets an explicit x (which survives reflows) and fill-width
--- controls stop the same distance from the right edge.
---@return EditorView
sectionView = function()
    local inset = PADDING + SECTION_INDENT
    local view = { contentPadding = inset }
    for method, optionsIndex in pairs(OPTIONS_INDEX) do
        view[method] = function(_, ...)
            local args = table.pack(...)
            local options = args[optionsIndex]
            if method == "AddText" and type(options) ~= "table" then
                options = { text = tostring(options or "") }
            end
            local placed = {}
            for key, value in pairs(options or {}) do placed[key] = value end
            if placed.inline ~= true then
                placed.x = placed.x or inset
                if placed.width == nil and FILL_WIDTH[method] then
                    placed.width = -(inset * 2)
                    placed.widthAnchor = 1
                end
            end
            args[optionsIndex] = placed
            args.n = math.max(args.n, optionsIndex)
            local control = host[method](host, table.unpack(args, 1, args.n))
            -- How far down the controls reach, for a section's box.
            local component = type(control) == "table" and control.root or nil
            if component ~= nil and component.y ~= nil and component.height ~= nil then
                view.bottom = math.max(view.bottom or 0, component.y + component.height)
            end
            return control
        end
    end
    return view
end

-- A section's backing while open: a faint fill and outline under its
-- controls, from just under the header to just past the last control, so
-- it reads as one collapsible piece.
local BOX_FILL_RGBA = 0xFFFFFF08
local BOX_EDGE_RGBA = 0xF2C66D30
local BOX_PADDING = 8

--- Adds the buttons at the right end of a section header, the first rightmost.
---@param buttons table[] Each { sprite, tooltip, onClick }.
local function addHeaderButtons(buttons)
    for index, button in ipairs(buttons) do
        host:AddSpriteButton(button.sprite, button.onClick, {
            inline = true,
            x = -(PADDING + tallHeader.BUTTON_INSET + index * uiConstants.BUTTON_SIZE + (index - 1) * GAP),
            xAnchor = 1,
            size = uiConstants.BUTTON_SIZE,
            tooltip = button.tooltip,
        })
    end
end

--- Adds a collapsible section. Collapsing rebuilds the editor without the
--- section's controls, as PrettyUI's collapse button can only hold a few
--- control types itself. An open section draws a box behind its controls.
---@param sectionID string Remembered collapsed across sessions.
---@param title string
---@param build fun(view: EditorView) Adds its controls.
---@param buttons table[]? Each { sprite, tooltip, onClick }, at the header's right end.
local function section(sectionID, title, build, buttons)
    loadCollapsed()
    local collapsed = collapsedSections[sectionID] == true
    local header = host:AddCollapseButton(title, {
        marginTop = hasSection and SECTION_GAP or nil,
        expanded = not collapsed,
        onToggle = function(_, expanded)
            setCollapsed(sectionID, not expanded)
            requestRebuild()
        end,
    })
    tallHeader.Stretch(header)
    addHeaderButtons(buttons or {})
    hasSection = true
    if collapsed then return end
    -- Made before the controls, in the layer PrettyUI puts them in, so it
    -- draws behind them. PrettyUI internals: without host.content, no box.
    local box = nil
    if host.content ~= nil then
        box = { rectangles.Filled(host.content, BOX_FILL_RGBA), rectangles.Outline(host.content, BOX_EDGE_RGBA) }
    end
    local view = sectionView()
    build(view)
    if box == nil then return end
    local top = (header.root.y or 0) + tallHeader.HEIGHT
    local height = math.max(0, (view.bottom or top) - top) + BOX_PADDING
    for _, rectangle in ipairs(box) do
        rectangle:SetPos(PADDING, top)
        rectangle:SetSize(-PADDING * 2, height, 1, 0)
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
    if typeEditor.beginBuild ~= nil then typeEditor.beginBuild() end
    local rebuildOn = typeEditor.rebuildOn or {}
    local function update(key, value)
        auraStore.Set(aura.id, key, value)
        changed(key)
        if rebuildOn[key] then requestRebuild() end
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
        onExport = handlers ~= nil and handlers.onExport or nil,
    }
    if shown == TAB_DISPLAY then
        displayTab.Build(aura, context)
    elseif shown == TAB_TRIGGER then
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
    if tabs == nil or parent == nil or tabStrip == nil then return end
    tabStrip:Fit(tabs, parent.width or 0, activeTab)
end

--- Destroys the tabs or hint, and forgets the tabs' controls.
local function destroyContents()
    nextFrame.Cancel(REBUILD_EVENT_ID)
    if tabStrip ~= nil then tabStrip:Forget() end
    if tabs ~= nil then tabs:Destroy() end
    if hint ~= nil then hint:Destroy() end
    tabs, hint = nil, nil
    displayTab.Forget()
end

--- Shows the hint for when no aura is selected.
local function showHint()
    hint = prettyUI.SimpleView.new(parent, {
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        layout = { startY = HINT_START_Y, paddingLeft = PADDING, paddingRight = PADDING, rowGap = GAP },
    })
    hint:AddText({
        text = "Select an aura on the left to edit it, or make one with New.",
        height = HINT_HEIGHT,
        maxLines = HINT_LINES,
        colour = uiConstants.MUTED_RGBA,
    })
end

--- Makes the tabs, building the one picked when the player switches.
local function makeTabs()
    tabs = prettyUI.Tabs.new(parent, TABS, {
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
            if building then return end
            activeTab = index
            fitTabStrip()
            requestRebuild()
        end,
    })
end

--- Builds (or rebuilds) the editor for editingID, or a hint when there's none.
---@param keepScroll boolean KEEP_SCROLL to keep each tab's scroll position (e.g. when one option changes another's range), or FROM_TOP.
local function build(keepScroll)
    local scrollYs = {}
    if keepScroll and tabs ~= nil then
        for index = 1, #TABS do
            local page = tabs:GetPage(index)
            scrollYs[index] = page and page.scrollY or nil
        end
    end
    destroyContents()
    if parent == nil or prettyUI == nil then return end

    local aura = editingID ~= nil and auraStore.Get(editingID) or nil
    if aura == nil then
        editingID = nil
        showHint()
        return
    end

    makeTabs()
    -- Reset whatever happens, or an error in a build would leave every
    -- later tab click ignored; the error still surfaces.
    building = true
    local ok, problem = pcall(buildEditor, aura)
    building = false
    if not ok then error(problem, 0) end
    -- After building: disabling a tab (as for groups) has PrettyUI lay the
    -- strip out again.
    fitTabStrip()
    for index, scrollY in pairs(scrollYs) do
        local page = tabs:GetPage(index)
        if page ~= nil then page:SetScrollPosition(scrollY) end
    end
end

--- Rebuilds the editor where it's scrolled to.
local function rebuildKeepingScroll() build(KEEP_SCROLL) end

--- Rebuilds on the next frame, keeping the scroll positions. Use this from
--- a control's own callback so the control isn't destroyed while it's running.
requestRebuild = function()
    nextFrame.Run(REBUILD_EVENT_ID, rebuildKeepingScroll)
end

--- Sets what the editor reports.
---@param editorHandlers { onAurasChanged: fun(key: string?)?, onExport: fun(auraID: integer)? }
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

--- Edits an aura, switching away from (and locking) any aura already open.
--- Does nothing if that's already what it shows, so reselecting the open
--- aura doesn't rebuild it.
---@param auraID integer? nil for none.
---@return boolean built
function auraEditor.Show(auraID)
    if auraID == editingID and (tabs ~= nil or hint ~= nil) then return false end
    if editingID ~= nil and editingID ~= auraID then
        lockAura(editingID)
        triggerTab.Forget()
    end
    editingID = auraID
    build(FROM_TOP)
    return true
end

--- Builds the editor again for its area's current size, keeping the tab and
--- scroll positions.
function auraEditor.Refresh()
    if parent ~= nil then build(KEEP_SCROLL) end
end

--- Rebuilds next frame, if it's showing, so its source pickers list the
--- current sources (buffs the background walk found, say).
function auraEditor.OnSourcesChanged()
    if parent ~= nil then requestRebuild() end
end

--- The aura being edited.
---@return integer? auraID nil when there's none.
function auraEditor.EditingID()
    return tabs ~= nil and editingID or nil
end

--- Shows a dragged aura's new offset in the editor, if it's open.
---@param auraID integer
function auraEditor.OnAuraMoved(auraID)
    if auraID ~= editingID then return end
    local aura = auraStore.Get(auraID)
    if aura == nil then return end
    displayTab.OnAuraMoved(aura)
end

--- Drops the editor, e.g. when the main window closes or on logout. The
--- aura being edited is locked, or it would keep catching clicks.
function auraEditor.Unmount()
    destroyContents()
    parent = nil
    local auraID = editingID
    editingID = nil
    triggerTab.Forget()
    lockAura(auraID)
end

return auraEditor
