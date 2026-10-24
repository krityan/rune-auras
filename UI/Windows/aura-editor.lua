-- The aura editor: the right of the main window (UI/Windows/main-window),
-- editing the selected aura in tabs:
--   Display     name, display type, size, appearance, text and position, in
--               collapsible sections
--   Trigger     the data type and data source (groups have none)
--   Conditions  not built yet
--   Load        not built yet
-- Usage:
--   local auraEditor = require("UI/Windows/aura-editor")
--   auraEditor.Init({ onAurasChanged = ... })
--   auraEditor.Mount(prettyui, layer)   -- where to build the tabs
--   auraEditor.Show(auraID)             -- or nil for none
--   auraEditor.Unmount()

local anchors = require("Auras/Helpers/anchors")
local auraManager = require("Auras/aura-manager")
local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local displayTypes = require("Auras/Registries/display-types")
local fonts = require("Auras/Helpers/fonts")
local colourInput = require("UI/Controls/colour-input")
local fastTypeahead = require("UI/Controls/fast-typeahead")
local numberInput = require("UI/Controls/number-input")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

-- Display type id -> its editor controls, { size = fn, appearance = fn },
-- each fn(view, aura, update) adding controls to that section.
-- An editor module can set `usesFillColour = false` to drop the generic
-- Fill colour control from Appearance, `usesSource`, `usesAppearance` or
-- `usesText = false` to drop those parts altogether, `usesShowText = false`
-- to drop the Text section's "Show value text" (the Text display is all
-- text), and `usesAnchor = false` for plain X/Y offsets (as groups do). A
-- `layout` function adds a Layout section.
local TYPE_EDITORS = {
    bar = require("UI/Editors/bar"),
    icon = require("UI/Editors/icon"),
    text = require("UI/Editors/text"),
    group = require("UI/Editors/group"),
    dynamicGroup = require("UI/Editors/dynamic-group"),
}

-- Layout convention: every control has its label on its own row above it.
local auraEditor = {}

local REBUILD_EVENT_ID = "runeAuras_editorRebuild"
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
-- Extra space above each section header after the first.
local SECTION_GAP = 20
-- Extra horizontal padding, on both sides, for the controls inside a section.
local SECTION_INDENT = 12
-- PrettyUI's scrollbar width plus its gap to the content.
local SCROLLBAR_GUTTER = 18
-- How faint the scrollbar is while there's nothing to scroll.
local SCROLLBAR_IDLE_ALPHA = 0.4
-- The tabs, in order. Conditions and Load are placeholders for now.
local TAB_DISPLAY, TAB_TRIGGER, TAB_CONDITIONS, TAB_LOAD = 1, 2, 3, 4
local TABS = {
    { text = "Display" },
    { text = "Trigger" },
    { text = "Conditions", disabled = true },
    { text = "Load", disabled = true },
}
local COMING_SOON = "Coming soon."

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
-- auraID -> data type picked in the editor before a source of it was chosen.
-- Forgotten when the editor switches aura or closes.
local pickedTypes = {}
-- The open editor's X/Y inputs, kept so dragging the aura can update them.
local positionInputs = nil
-- Controls the Trigger tab updates when a data source is picked.
local nameField = nil
local colourPicker = nil
-- Section id -> true for collapsed sections; remembered between sessions.
local COLLAPSED_STORAGE_KEY = "editorCollapsedSections"
local collapsedSections = nil
-- The page being built into, and whether it already has a section above the
-- next one.
local host = nil
local hasSection = false

-- Tells the window an aura's `key` changed, so it can redraw what shows it.
local function changed(key)
    if handlers ~= nil and handlers.onAurasChanged ~= nil then
        handlers.onAurasChanged(key)
    end
end

-- Locks an aura again so it stops catching clicks meant for the game.
local function lockAura(auraID)
    if auraID ~= nil and auraStore.Get(auraID) ~= nil then
        auraStore.Set(auraID, "unlocked", false)
        changed("unlocked")
    end
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

-- ComboBox entry ids must be integers, so entries map list positions back to
-- registry ids.
local function comboEntries(list)
    local entries = {}
    local selectedIndexByID = {}
    for index, item in ipairs(list) do
        entries[index] = { label = item.label, id = index }
        selectedIndexByID[item.id] = index
    end
    return entries, selectedIndexByID
end

local requestRebuild, sectionView

local function loadCollapsed()
    if collapsedSections ~= nil then return end
    collapsedSections = {}
    for sectionID in tostring(PersistentDB:GetString(COLLAPSED_STORAGE_KEY) or ""):gmatch("[^,]+") do
        collapsedSections[sectionID] = true
    end
end

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
}
-- Controls that fill their row when given no width.
local FILL_WIDTH = { AddText = true, AddTextField = true, AddComboBox = true }

-- A stand-in for the tab page that indents everything added through it by
-- SECTION_INDENT. The flow layout has one padding for the whole page, so
-- each row gets an explicit x (which survives reflows) and fill-width
-- controls stop the same distance from the right edge. contentPadding tells
-- helpers like UI/Controls/number-input the effective padding.
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
            return host[method](host, table.unpack(args, 1, args.n))
        end
    end
    return view
end

-- Adds a collapsible section header. Collapsing rebuilds the editor without
-- the section's controls, as PrettyUI's collapse button can only hold a few
-- control types itself.
local function section(sectionID, title, build)
    loadCollapsed()
    local collapsed = collapsedSections[sectionID] == true
    host:AddCollapseButton(title, {
        marginTop = hasSection and SECTION_GAP or nil,
        expanded = not collapsed,
        tooltip = collapsed and "Show these options" or "Hide these options",
        onToggle = function(_, expanded)
            setCollapsed(sectionID, not expanded)
            requestRebuild()
        end,
    })
    hasSection = true
    if not collapsed then build(sectionView()) end
end

local function gameAreaComponent()
    return gameApi.Component("TOPLEVEL_V2__GAME_AREA")
end

-- The size of what an aura is positioned inside. A group only moves its
-- contents, so inside one or not that's the game area. nil if unknown.
local function parentSize()
    local area = gameAreaComponent()
    if area == nil then return nil end
    return area.width, area.height
end

-- An aura's size on screen: its width/height, or for a display that sizes
-- itself (Text), the size it has now.
local function auraSize(aura)
    local displayType = displayTypes.Get(aura.display)
    if displayType ~= nil and displayType.module.sizesItself then
        local width, height = auraManager.DisplaySize(aura.id)
        if width ~= nil then return width, height end
    end
    return aura.width or 0, aura.height or 0
end

local function buildTextOptions(view, aura, update, usesShowText)
    if usesShowText then
        view:AddCheckboxButton({
            {
                text = "Show value text",
                value = "showText",
                selected = aura.showText,
            },
        }, {
            onChange = function(_, _, _, selected)
                update("showText", selected == true)
            end,
        })
    end

    view:AddText("Text template")
    view:AddTextField({
        text = aura.textTemplate,
        placeholder = "e.g. $current / $max",
        maxLength = 64,
        tooltip = "$current is replaced by the current value, $max by the maximum, $stacks by a buff's stacks and $name by the data source's name (for Any channel, what's being channelled).",
        onChange = function(_, _, content)
            update("textTemplate", content)
        end,
    })

    view:AddCheckboxButton({
        {
            text = "Limit decimals",
            value = "limitDecimals",
            selected = aura.limitDecimals == true,
            tooltip = "Show whole numbers until the value drops below the threshold below.",
        },
    }, {
        onChange = function(_, _, _, selected)
            update("limitDecimals", selected == true)
        end,
    })
    numberInput.Add(view, {
        label = "Show decimals below (seconds)",
        value = aura.decimalsBelow,
        min = 0,
        max = 120,
        step = 1,
        slider = true,
        tooltip = "With Limit decimals on, values at or above this show as whole numbers, rounded up.",
        onChange = function(value) update("decimalsBelow", value) end,
    })

    colourInput.Add(view, {
        label = "Text colour",
        value = aura.textColour,
        windowTitle = "Text colour",
        onChange = function(colour) update("textColour", colour) end,
    })

    local fontList = fonts.List()
    local fontEntries, fontIndexByID = comboEntries(fontList)
    view:AddText("Font")
    view:AddComboBox({
        entries = fontEntries,
        selectedID = fontIndexByID[aura.textFont],
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local font = fontList[entryID]
            if font == nil or font.id == aura.textFont then return end
            -- Fonts come in different sizes, so keep the closest one.
            aura.textSize = fonts.NearestSize(font.id, aura.textSize)
            update("textFont", font.id)
            -- The size range below depends on the font.
            requestRebuild()
        end,
    })

    local font = fonts.Get(aura.textFont)
    if font == nil then return end
    local sizeInput
    sizeInput = numberInput.Add(view, {
        label = "Text size",
        value = fonts.NearestSize(font.id, aura.textSize),
        min = font.sizes[1],
        max = font.sizes[#font.sizes],
        step = 1,
        slider = true,
        tooltip = "Snaps to the nearest size this font has.",
        onChange = function(value)
            local size = fonts.NearestSize(font.id, value)
            if size ~= value then sizeInput:SetValue(size) end
            update("textSize", size)
        end,
    })
end

-- A group has no anchor: its X/Y just move everything in it.
local function buildGroupPositionOptions(view, aura, update)
    local tooltip = "Moves everything in the group, in pixels."
    -- An offset can move the contents up to a screen's width or height
    -- either way. Without a known size, plain fields.
    local width, height = parentSize()
    local sizeKnown = width ~= nil
    positionInputs = {
        x = numberInput.Add(view, {
            label = "X offset", value = aura.x, negative = true, tooltip = tooltip,
            min = sizeKnown and -width or nil, max = sizeKnown and width or nil,
            slider = sizeKnown,
            onChange = function(value) update("x", value) end,
        }),
        y = numberInput.Add(view, {
            label = "Y offset", value = aura.y, negative = true, tooltip = tooltip,
            min = sizeKnown and -height or nil, max = sizeKnown and height or nil,
            slider = sizeKnown,
            onChange = function(value) update("y", value) end,
        }),
    }
    view:AddCheckboxButton({
        {
            text = "Unlock to drag on screen",
            value = "unlocked",
            selected = aura.unlocked,
            tooltip = "While unlocked, a box shows around the group's auras; drag it to move them all.",
        },
    }, {
        onChange = function(_, _, _, selected)
            update("unlocked", selected == true)
        end,
    })
end

local function buildPositionOptions(view, aura, update)
    local anchorList = anchors.List()
    local anchorEntries, anchorIndexByID = comboEntries(anchorList)
    view:AddText("Anchor point")
    view:AddComboBox({
        entries = anchorEntries,
        selectedID = anchorIndexByID[anchors.Get(aura.anchor).id],
        tooltip = "The point of the screen (or of the group it's in) the X/Y offset is measured from.",
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local anchor = anchorList[entryID]
            if anchor == nil or anchor.id == aura.anchor then return end
            -- Keep the aura where it is on screen; only the offset changes.
            local parentWidth, parentHeight = parentSize()
            if parentWidth ~= nil then
                local width, height = auraSize(aura)
                local left, top = anchors.ToScreen(aura.anchor, aura.x, aura.y,
                    width, height, parentWidth, parentHeight)
                aura.x, aura.y = anchors.FromScreen(anchor.id, left, top,
                    width, height, parentWidth, parentHeight)
            end
            update("anchor", anchor.id)
            -- The X/Y ranges below depend on the anchor.
            requestRebuild()
        end,
    })

    -- Without a known parent size the ranges are unknown, so fall back to
    -- plain fields.
    local parentWidth, parentHeight = parentSize()
    local sizeKnown = parentWidth ~= nil
    local minX, maxX, minY, maxY
    if sizeKnown then
        local width, height = auraSize(aura)
        minX, maxX, minY, maxY = anchors.OffsetRange(aura.anchor, width, height, parentWidth, parentHeight)
    end
    local offsetTooltip = "Offset from the anchor point, in pixels. Positive values point inwards from an edge."
    positionInputs = {
        x = numberInput.Add(view, {
            label = "X offset",
            value = aura.x,
            min = minX,
            max = maxX,
            slider = sizeKnown,
            negative = minX == nil or minX < 0,
            tooltip = offsetTooltip,
            onChange = function(value) update("x", value) end,
        }),
        y = numberInput.Add(view, {
            label = "Y offset",
            value = aura.y,
            min = minY,
            max = maxY,
            slider = sizeKnown,
            negative = minY == nil or minY < 0,
            tooltip = offsetTooltip,
            onChange = function(value) update("y", value) end,
        }),
    }

    view:AddCheckboxButton({
        {
            text = "Unlock to drag on screen",
            value = "unlocked",
            selected = aura.unlocked,
            tooltip = "While unlocked, click and drag the aura to move it.",
        },
    }, {
        onChange = function(_, _, _, selected)
            update("unlocked", selected == true)
        end,
    })
end

-- The X/Y ranges depend on the aura's size, so resizing narrows them and
-- pulls the offsets back inside, matching where the display clamps itself.
local function refreshPositionRange(aura, update)
    local parentWidth, parentHeight = parentSize()
    if parentWidth == nil then return end
    local width, height = auraSize(aura)
    local minX, maxX, minY, maxY = anchors.OffsetRange(aura.anchor, width, height, parentWidth, parentHeight)
    local x = math.max(minX, math.min(maxX, aura.x))
    local y = math.max(minY, math.min(maxY, aura.y))
    if x ~= aura.x then update("x", x) end
    if y ~= aura.y then update("y", y) end
    if positionInputs == nil then return end
    positionInputs.x:SetRange(minX, maxX)
    positionInputs.y:SetRange(minY, maxY)
    positionInputs.x:SetValue(x)
    positionInputs.y:SetValue(y)
end

-- The Display tab: what the aura is and how it's drawn, in sections.
local function buildDisplayTab(aura, update, updateSize, typeSections)
    section("general", "General", function(view)
        view:AddText("Name")
        nameField = view:AddTextField({
            text = aura.name,
            placeholder = auraStore.IsGroup(aura) and "Group name" or "Aura name",
            maxLength = 32,
            onChange = function()
                local name = trim(nameField:GetText())
                if name ~= "" then update("name", name) end
            end,
        })

        -- Groups have no display type of their own.
        if typeSections.usesSource ~= false then
            local types = displayTypes.Selectable()
            local typeEntries, typeIndexByID = comboEntries(types)
            view:AddText("Display type")
            view:AddComboBox({
                entries = typeEntries,
                selectedID = typeIndexByID[aura.display],
                tooltip = "How the aura is drawn on screen.",
                onChange = function(_, entryID, _, eventType)
                    if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
                    local displayType = types[entryID]
                    if displayType == nil or displayType.id == aura.display then return end
                    update("display", displayType.id)
                    -- Type-specific options below depend on the display type.
                    requestRebuild()
                end,
            })
        end
    end)

    if typeSections.size ~= nil then
        section("size", "Size", function(view)
            typeSections.size(view, aura, updateSize)
        end)
    end

    if typeSections.usesAppearance ~= false then
        section("appearance", "Appearance", function(view)
            if typeSections.usesFillColour ~= false then
                colourPicker = colourInput.Add(view, {
                    label = "Fill colour",
                    value = aura.colour,
                    windowTitle = "Aura colour",
                    onChange = function(colour) update("colour", colour) end,
                })
            end
            if typeSections.appearance ~= nil then
                typeSections.appearance(view, aura, update)
            end
        end)
    end

    if typeSections.usesText ~= false then
        section("text", "Text", function(view)
            buildTextOptions(view, aura, update, typeSections.usesShowText ~= false)
        end)
    end

    if typeSections.layout ~= nil then
        section("layout", "Layout", function(view)
            typeSections.layout(view, aura, update)
        end)
    end

    section("position", "Position", function(view)
        if auraStore.IsDynamicGroup(auraStore.Get(aura.group)) then
            -- Its dynamic group places it; its own position comes back if
            -- it's moved out.
            view:AddText({
                text = "Its dynamic group positions it. Move the group, or change its Layout, to move it.",
                height = 40,
                maxLines = 2,
                colour = uiConstants.MUTED_RGBA,
            })
        elseif typeSections.usesAnchor == false then
            buildGroupPositionOptions(view, aura, update)
        else
            buildPositionOptions(view, aura, update)
        end
    end)
end

-- The Trigger tab: which game value the aura shows.
local function buildTriggerTab(aura, update)
    local auraID = aura.id
    local view = sectionView()
    local currentSource = dataSources.Get(aura.source)
    local typeList = dataSources.Types()
    local dataTypeID = pickedTypes[auraID] or (currentSource and currentSource.type) or typeList[1].id
    local dataTypeEntries, dataTypeIndexByID = comboEntries(typeList)
    view:AddText("Data type")
    view:AddComboBox({
        entries = dataTypeEntries,
        selectedID = dataTypeIndexByID[dataTypeID],
        tooltip = "What kind of game value the aura shows.",
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local picked = typeList[entryID]
            if picked == nil or picked.id == dataTypeID then return end
            -- The aura keeps its source until one of the new type is picked.
            pickedTypes[auraID] = picked.id
            requestRebuild()
        end,
    })

    -- Entries with an `order` make PrettyUI use its filtering combo box,
    -- so the player can type to narrow long lists such as cooldowns.
    local sources = dataSources.ListByType(dataTypeID)
    local sourceEntries = {}
    local selectedEntry = nil
    for index, source in ipairs(sources) do
        sourceEntries[index] = { label = source.label, id = index, order = 1 }
        if source.id == aura.source then selectedEntry = index end
    end
    if selectedEntry == nil then
        -- Shown until a source of this type is chosen.
        sourceEntries[#sourceEntries + 1] = { label = "Choose a source...", id = 0, order = 0 }
        selectedEntry = 0
    end
    view:AddText("Data source")
    fastTypeahead.Add(view, {
        entries = sourceEntries,
        selectedID = selectedEntry,
        tooltip = "Which game value the aura shows. Type to filter the list.",
        onChange = function(_, entryID, _, eventType)
            if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
            local source = sources[entryID]
            if source == nil or source.id == aura.source then return end
            pickedTypes[auraID] = nil
            -- Follow the new source's name and colour unless the player
            -- already picked their own.
            local previous = dataSources.Get(aura.source)
            if aura.name == "New aura" or (previous ~= nil and aura.name == previous.label) then
                aura.name = source.label
                if nameField ~= nil then nameField:SetText(source.label) end
            end
            local untouched = previous == nil and auraStore.DEFAULT_COLOUR or previous.colour
            if aura.colour == untouched then
                aura.colour = source.colour
                if colourPicker ~= nil then colourPicker:SetValue(source.colour) end
            end
            update("source", source.id)
            -- Some options (e.g. a bar's Smooth fill) depend on the source.
            requestRebuild()
        end,
    })
end

local function buildEditor(aura)
    local function update(key, value)
        auraStore.Set(aura.id, key, value)
        changed(key)
    end
    local function updateSize(key, value)
        update(key, value)
        refreshPositionRange(aura, update)
    end
    local typeSections = TYPE_EDITORS[aura.display] or {}

    host = tabs:GetPage(TAB_DISPLAY)
    hasSection = false
    buildDisplayTab(aura, update, updateSize, typeSections)

    -- Groups only move what's in them: no data, so no trigger.
    if typeSections.usesSource ~= false then
        host = tabs:GetPage(TAB_TRIGGER)
        hasSection = false
        buildTriggerTab(aura, update)
    else
        tabs:SetDisabled(TAB_TRIGGER, true)
        tabs:SetTabTooltip(TAB_TRIGGER, "Groups only move what's in them, so they have no trigger.")
    end
    host = nil
end

local function setAlpha(component, alpha)
    if component ~= nil then component.alpha = alpha end
end

-- PrettyUI hides a scroll area's scrollbar (here, a tab page's), and widens
-- its content, whenever nothing overflows, so opening or collapsing a
-- section made everything jump sideways. This keeps the gutter and shows the bar faded instead. It
-- patches PrettyUI's scroll controller internals (Scroll:_Layout), so it
-- does nothing if those aren't there.
local function keepScrollbar(target)
    local scroll = target._scroll
    if scroll == nil or type(scroll._Layout) ~= "function" then return end
    local layout = scroll._Layout
    scroll._Layout = function(self)
        layout(self)
        local idle = not self.scrollbarVisible
        if idle then
            self.contentWidth = math.max(1, self.width - SCROLLBAR_GUTTER)
            self.viewport:SetSize(self.contentWidth, 0, 0, 1.0)
            self.viewport:SetScrollSize(self.contentWidth, self.scrollHeight)
            self.content:SetSize(self.contentWidth, self.scrollHeight)
            -- Let the window pick up the narrower content width.
            if self.onLayout then self.onLayout(self) end
        end
        self.track.hidden = false
        self.upArrow.hidden = false
        self.downArrow.hidden = false
        local alpha = idle and SCROLLBAR_IDLE_ALPHA or 1
        for _, part in ipairs({
            self.upArrow, self.downArrow,
            self.trackTop, self.trackCentre, self.trackBottom,
            self.thumbTop, self.thumbCentre, self.thumbBottom,
        }) do
            setAlpha(part, alpha)
        end
    end
    -- Refresh is PrettyUI internals too, so it may not be there.
    if type(scroll.Refresh) == "function" then pcall(scroll.Refresh, scroll) end
end

local function destroyContents()
    nextFrame.Cancel(REBUILD_EVENT_ID)
    if tabs ~= nil then tabs:Destroy() end
    if hint ~= nil then hint:Destroy() end
    tabs, hint = nil, nil
    positionInputs, nameField, colourPicker = nil, nil, nil
end

-- Builds (or rebuilds) the editor for editingID, or a hint when there's
-- none. keepScroll keeps each tab's scroll position, e.g. when one option
-- changes another's range.
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
        hint = prettyUI.SimpleView.new(parent, {
            width = 0,
            height = 0,
            widthAnchor = 1,
            heightAnchor = 1,
            layout = { startY = 20, paddingLeft = PADDING, paddingRight = PADDING, rowGap = GAP },
        })
        hint:AddText({
            text = "Select an aura on the left to edit it, or make one with New.",
            height = 48,
            maxLines = 2,
            colour = uiConstants.MUTED_RGBA,
        })
        return
    end

    tabs = prettyUI.Tabs.new(parent, TABS, {
        width = 0,
        height = 0,
        widthAnchor = 1,
        heightAnchor = 1,
        activeIndex = activeTab,
        contentLayout = {
            startY = 10,
            paddingLeft = PADDING,
            paddingRight = PADDING,
            rowGap = GAP,
            columnGap = GAP,
        },
        onChange = function(_, index) activeTab = index end,
    })
    tabs:SetTabTooltip(TAB_CONDITIONS, COMING_SOON)
    tabs:SetTabTooltip(TAB_LOAD, COMING_SOON)
    for index = 1, #TABS do keepScrollbar(tabs:GetPage(index)) end
    buildEditor(aura)
    for index, scrollY in pairs(scrollYs) do
        local page = tabs:GetPage(index)
        if page ~= nil then page:SetScrollPosition(scrollY) end
    end
end

local function rebuildKeepingScroll() build(true) end

-- Rebuilds on the next frame, keeping the scroll positions. Use this from a
-- control's own callback so the control isn't destroyed while it's running.
requestRebuild = function()
    nextFrame.Run(REBUILD_EVENT_ID, rebuildKeepingScroll)
end

function auraEditor.Init(editorHandlers)
    handlers = editorHandlers
end

-- Sets where the editor builds: a layer in the main window.
function auraEditor.Mount(prettyUILibrary, layer)
    prettyUI = prettyUILibrary
    parent = layer
end

-- Edits an aura (nil for none), switching away from any aura already open.
-- Does nothing if that's already what it shows, so reselecting the open
-- aura doesn't rebuild it. Returns whether it built.
function auraEditor.Show(auraID)
    if auraID == editingID and (tabs ~= nil or hint ~= nil) then return false end
    if editingID ~= nil and editingID ~= auraID then
        lockAura(editingID)
        pickedTypes = {}
    end
    editingID = auraID
    build(false)
    return true
end

-- Builds the editor again for its area's current size, keeping the tab and
-- scroll positions.
function auraEditor.Refresh()
    if parent ~= nil then build(true) end
end

-- The aura being edited, or nil when there's none.
function auraEditor.EditingID()
    return tabs ~= nil and editingID or nil
end

-- Shows a dragged aura's new offset in the editor, if it's open.
function auraEditor.OnAuraMoved(auraID)
    if positionInputs == nil or auraID ~= editingID then return end
    local aura = auraStore.Get(auraID)
    if aura == nil then return end
    positionInputs.x:SetValue(aura.x)
    positionInputs.y:SetValue(aura.y)
end

-- Drops the editor, e.g. when the main window closes or on logout. The aura
-- being edited is locked, or it would keep catching clicks.
function auraEditor.Unmount()
    destroyContents()
    parent = nil
    local auraID = editingID
    editingID = nil
    pickedTypes = {}
    lockAura(auraID)
end

return auraEditor
