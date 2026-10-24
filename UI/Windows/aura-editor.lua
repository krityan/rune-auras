-- The aura editor: the right of the main window (UI/Windows/main-window),
-- editing the selected aura in tabs:
--   Display     name, display type, size, appearance, text and position, in
--               collapsible sections
--   Trigger     the data type and data source (groups have none)
--   Conditions  display changes made while checks pass (see
--               UI/Windows/conditions-tab; groups have none)
--   Load        what decides whether the aura loads (see
--               UI/Windows/load-tab; groups have none)
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
local conditionsTab = require("UI/Windows/conditions-tab")
local loadTab = require("UI/Windows/load-tab")
local gameApi = require("GameData/game-api")

-- Display type id -> its editor controls, { size = fn, appearance = fn },
-- each fn(view, aura, update) adding controls to that section.
-- An editor module can set `usesFillColour = false` to drop the generic
-- Fill colour control from Appearance, `usesSource`, `usesAppearance` or
-- `usesText = false` to drop those parts altogether, `usesShowText = false`
-- to drop the Text section's "Show value text" (the Text display is all
-- text). A `layout` function adds a Layout section.
local TYPE_EDITORS = {
    bar = require("UI/Editors/bar"),
    icon = require("UI/Editors/icon"),
    text = require("UI/Editors/text"),
    segments = require("UI/Editors/segments"),
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
-- The tabs, in order.
local TAB_DISPLAY, TAB_TRIGGER, TAB_CONDITIONS, TAB_LOAD = 1, 2, 3, 4
local TABS = {
    { text = "Display" },
    { text = "Trigger" },
    { text = "Conditions" },
    { text = "Load" },
}

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
-- The first tab shown while they don't all fit (see fitTabs), kept when
-- switching aura.
local firstTab = 1
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
    AddSprite = 2,
}
-- Controls that fill their row when given no width.
local FILL_WIDTH = { AddText = true, AddTextField = true, AddComboBox = true, AddSprite = true }

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

-- PrettyUI's collapse button is 20px tall, too short for the buttons some
-- section headers carry, so headers are stretched to this. Patches its
-- internals (its sprites, label and _ExpandedHeight), so it leaves the
-- header alone if they aren't there.
local HEADER_HEIGHT = uiConstants.BUTTON_SIZE + 4
local HEADER_CAP = 20
-- Keeps header buttons off its rounded right end.
local HEADER_BUTTON_INSET = 6
local function heightenHeader(header)
    if header == nil or header.left == nil or header.middle == nil or header.right == nil
        or header.label == nil or type(header._Resize) ~= "function" then return end
    header.left:SetSize(HEADER_CAP, HEADER_HEIGHT)
    header.middle:SetSize(-HEADER_CAP * 2, HEADER_HEIGHT, 1.0)
    -- It tiles to fill its width, which taller repeats the 20px texture
    -- below itself; stretched, it's one bar.
    header.middle.isTiling = false
    header.right:SetSize(HEADER_CAP, HEADER_HEIGHT)
    header.label:SetSize(-12 - HEADER_CAP, HEADER_HEIGHT, 1.0)
    -- Its controls are built below it, never inside, so it's only ever the
    -- header itself.
    header._ExpandedHeight = function() return HEADER_HEIGHT end
    header:_Resize()
end

-- A section's backing while open: a faint fill and outline under its
-- controls, from just under the header to just past the last control, so
-- it reads as one collapsible piece.
local BOX_FILL_RGBA = 0xFFFFFF08
local BOX_EDGE_RGBA = 0xF2C66D30
local BOX_PADDING = 8

local function newBoxRectangle(rgba, fill)
    local rectangle = ui.Rectangle.new(host.content)
    rectangle.fill = fill
    rectangle.rgba = rgba
    rectangle.clickthrough = true
    return rectangle
end

-- Adds a collapsible section header. Collapsing rebuilds the editor without
-- the section's controls, as PrettyUI's collapse button can only hold a few
-- control types itself. `buttons` ({ sprite, tooltip, onClick }) go at the
-- right end of the header, the first rightmost. An open section draws a box
-- around its controls.
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
    heightenHeader(header)
    for index, button in ipairs(buttons or {}) do
        host:AddSpriteButton(button.sprite, button.onClick, {
            inline = true,
            x = -(PADDING + HEADER_BUTTON_INSET + index * uiConstants.BUTTON_SIZE + (index - 1) * GAP),
            xAnchor = 1,
            size = uiConstants.BUTTON_SIZE,
            tooltip = button.tooltip,
        })
    end
    hasSection = true
    if collapsed then return end
    -- Made before the controls, in the layer PrettyUI puts them in, so it
    -- draws behind them. PrettyUI internals: without host.content, no box.
    local box = nil
    if host.content ~= nil then
        box = { newBoxRectangle(BOX_FILL_RGBA, true), newBoxRectangle(BOX_EDGE_RGBA, false) }
    end
    local view = sectionView()
    build(view)
    if box == nil then return end
    local top = (header.root.y or 0) + HEADER_HEIGHT
    local height = math.max(0, (view.bottom or top) - top) + BOX_PADDING
    for _, rectangle in ipairs(box) do
        rectangle:SetPos(PADDING, top)
        rectangle:SetSize(-PADDING * 2, height, 1, 0)
    end
end

local function gameAreaComponent()
    return gameApi.Component("TOPLEVEL_V2__GAME_AREA")
end

-- The game area's size, which every position is inside (group layers cover
-- it too). nil if unknown.
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
        tooltip = "$current is replaced by the current value, $max by the maximum, $stacks by a buff's stacks, $charges by an ability's charges ready and $name by the data source's name (for Any channel, what's being channelled).",
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

-- The X/Y offsets' ranges, as minX, maxX, minY, maxY: what keeps the aura
-- on screen at the top level, or up to a screen's width or height either
-- way from its group's point. nil if the game area's size is unknown.
local function positionRange(aura)
    local parentWidth, parentHeight = parentSize()
    if parentWidth == nil then return nil end
    if aura.group ~= nil then return -parentWidth, parentWidth, -parentHeight, parentHeight end
    local width, height = auraSize(aura)
    return anchors.OffsetRange(aura.anchor, width, height, parentWidth, parentHeight)
end

-- Moves an aura's offset to a new anchor without moving it on screen.
local function reanchor(aura, anchorID)
    if aura.group ~= nil then
        -- The aura's attach point changes, its group's point doesn't.
        local width, height = auraSize(aura)
        local left, top = anchors.FromPoint(aura.anchor, aura.x, aura.y, width, height, 0, 0)
        aura.x, aura.y = anchors.ToPoint(anchorID, left, top, width, height, 0, 0)
        return
    end
    local parentWidth, parentHeight = parentSize()
    if parentWidth == nil then return end
    local width, height = auraSize(aura)
    local left, top = anchors.ToScreen(aura.anchor, aura.x, aura.y, width, height, parentWidth, parentHeight)
    aura.x, aura.y = anchors.FromScreen(anchorID, left, top, width, height, parentWidth, parentHeight)
end

-- A group's point and an aura's spot: an anchor and offset at the top level.
-- In a group, the offset is from the group's point; an aura's anchor then
-- picks the point of it that attaches there, and a group has none.
local function buildPositionOptions(view, aura, update)
    local isGroup = auraStore.IsGroup(aura)
    local inGroup = aura.group ~= nil
    if not (isGroup and inGroup) then
        local anchorList = anchors.List()
        local anchorEntries, anchorIndexByID = comboEntries(anchorList)
        view:AddText(inGroup and "Attach point" or "Anchor point")
        view:AddComboBox({
            entries = anchorEntries,
            selectedID = anchorIndexByID[anchors.Get(aura.anchor).id],
            tooltip = inGroup and "The point of the aura that sits at the X/Y offset from its group's point."
                or isGroup and "The point of the screen the group's point is measured from."
                or "The point of the screen the X/Y offset is measured from.",
            onChange = function(_, entryID, _, eventType)
                if eventType ~= ui.SelectionChangeEvent.SELECTED then return end
                local anchor = anchorList[entryID]
                if anchor == nil or anchor.id == aura.anchor then return end
                -- Keep it where it is on screen; only the offset changes.
                reanchor(aura, anchor.id)
                update("anchor", anchor.id)
                -- The X/Y ranges below depend on the anchor.
                requestRebuild()
            end,
        })
    end

    -- Without a known parent size the ranges are unknown, so fall back to
    -- plain fields.
    local minX, maxX, minY, maxY = positionRange(aura)
    local sizeKnown = minX ~= nil
    local offsetTooltip = inGroup and "Offset from the point of the group it's in, in pixels, right and down."
        or "Offset from the anchor point, in pixels. Positive values point inwards from an edge."
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

    -- Moving a plain group's point keeps its contents in place, so it can
    -- be put back on its anchor without moving anything.
    if isGroup and not auraStore.IsDynamicGroup(aura) then
        view:AddFancyButton("Reset offset", function()
            local width, height = parentSize()
            if width == nil or not auraStore.ResetGroupOffset(aura.id, width, height) then return end
            changed("x")
            requestRebuild()
        end, {
            width = 150,
            tooltip = inGroup and "Puts the group's point on the point of the group it's in, without moving its auras."
                or "Puts the group's point on its anchor (X and Y 0), without moving its auras.",
        })
    end

    view:AddCheckboxButton({
        {
            text = "Unlock to drag on screen",
            value = "unlocked",
            selected = aura.unlocked,
            tooltip = isGroup and "While unlocked, a box shows around the group's auras; drag it to move them all."
                or "While unlocked, click and drag the aura to move it.",
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
    local minX, maxX, minY, maxY = positionRange(aura)
    if minX == nil then return end
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
            -- The previous source's colour, or with none the store's default
            -- or the display type's own (a segmented bar starts green).
            local untouched = previous ~= nil and aura.colour == previous.colour
            if previous == nil then
                local displayType = displayTypes.Get(aura.display)
                local typeDefaults = displayType and displayType.module.defaults or {}
                untouched = aura.colour == auraStore.DEFAULT_COLOUR or aura.colour == typeDefaults.colour
            end
            if untouched then
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
    local typeSections = TYPE_EDITORS[aura.display] or {}
    -- Lets a module drop controls it kept from the last build, which may
    -- not be rebuilt (e.g. in a collapsed section).
    if typeSections.beginBuild ~= nil then typeSections.beginBuild() end
    -- Options an editor module lists in `rebuildOn` change which of its
    -- controls show, so they rebuild it.
    local rebuildOn = typeSections.rebuildOn or {}
    local function update(key, value)
        auraStore.Set(aura.id, key, value)
        changed(key)
        if rebuildOn[key] then requestRebuild() end
    end
    local function updateSize(key, value)
        update(key, value)
        refreshPositionRange(aura, update)
    end

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

    if not auraStore.IsGroup(aura) then
        host = tabs:GetPage(TAB_CONDITIONS)
        hasSection = false
        conditionsTab.Build(aura, {
            section = section,
            view = sectionView,
            onChanged = function() changed("conditions") end,
            requestRebuild = requestRebuild,
        })
    else
        tabs:SetDisabled(TAB_CONDITIONS, true)
        tabs:SetTabTooltip(TAB_CONDITIONS, "Groups have no conditions of their own.")
    end

    -- Groups have load options too: one that isn't loaded takes everything
    -- in it with it.
    host = tabs:GetPage(TAB_LOAD)
    -- Its options come first, so its section is spaced from them.
    hasSection = true
    loadTab.Build(aura, {
        view = sectionView,
        section = section,
        onChanged = function() changed("load") end,
        requestRebuild = requestRebuild,
    })
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

-- PrettyUI's tabs run off the editor's right edge when it's narrow, out of
-- reach. So when they don't all fit, only those that do are shown, from
-- firstTab, between arrows at either end of the strip to scroll through
-- them. Patches PrettyUI internals (its tabs' `tabs` list, each with
-- `visual`, `hit` and `width`, and `tabGap`/`tabInset`), so it leaves the
-- strip alone if they aren't there. The editor is rebuilt when its width
-- changes, so this runs once per build.
local TAB_ARROW_SIZE = 20
local TAB_ARROW_Y = 10
local tabArrows = nil

local fitTabs

local function scrollTabs(by)
    firstTab = firstTab + by
    fitTabs(false)
end

local function placeTab(tab, x, shown)
    tab.visual.hidden = not shown
    tab.hit.hidden = not shown
    if shown then
        tab.visual:SetPos(x, tab.visual.y or 0)
        tab.hit:SetPos(x, 0)
    end
end

-- keepActive scrolls the active tab into view (on building and selecting;
-- not when scrolling with the arrows).
fitTabs = function(keepActive)
    if tabs == nil or parent == nil or type(tabs.tabs) ~= "table" then return end
    local list = tabs.tabs
    local gap, inset = tabs.tabGap or 0, tabs.tabInset or 0
    for _, tab in ipairs(list) do
        if tab.visual == nil or tab.hit == nil or tab.width == nil then return end
    end
    local width = parent.width or 0
    local total = inset - gap
    for _, tab in ipairs(list) do total = total + tab.width + gap end
    local overflowing = total > width
    -- With the arrows in, the tabs start after the left one and must end
    -- before the right one.
    local startX = overflowing and inset + TAB_ARROW_SIZE + GAP or inset
    local room = overflowing and width - (TAB_ARROW_SIZE + GAP) or width
    -- Keep the active tab in view, and don't scroll past the point where
    -- the last tab is already showing.
    if not overflowing then firstTab = 1 end
    if keepActive and activeTab < firstTab then firstTab = activeTab end
    firstTab = math.max(1, math.min(firstTab, #list))
    local function lastShown(from)
        local x, last = startX, from - 1
        for index = from, #list do
            if x + list[index].width > room and index > from then break end
            x, last = x + list[index].width + gap, index
        end
        return last
    end
    while keepActive and activeTab > lastShown(firstTab) and firstTab < activeTab do firstTab = firstTab + 1 end
    while firstTab > 1 and lastShown(firstTab - 1) == #list do firstTab = firstTab - 1 end
    local last = lastShown(firstTab)
    local x = startX
    for index, tab in ipairs(list) do
        local shown = index >= firstTab and index <= last
        placeTab(tab, x, shown)
        if shown then x = x + tab.width + gap end
    end

    if tabArrows == nil then
        tabArrows = {
            left = prettyUI.SpriteButton.new(tabs.root, "ARROW_LEFT", function() scrollTabs(-1) end, {
                x = inset, y = TAB_ARROW_Y, size = TAB_ARROW_SIZE,
            }),
            right = prettyUI.SpriteButton.new(tabs.root, "ARROW_RIGHT", function() scrollTabs(1) end, {
                x = -TAB_ARROW_SIZE, xAnchor = 1, y = TAB_ARROW_Y, size = TAB_ARROW_SIZE,
            }),
        }
    end
    tabArrows.left.root.hidden = not overflowing
    tabArrows.right.root.hidden = not overflowing
    tabArrows.left:SetDisabled(firstTab <= 1)
    tabArrows.right:SetDisabled(last >= #list)
    -- Selecting a tab brings PrettyUI's strip to the front; keep them above.
    tabArrows.left.root:MoveToFront()
    tabArrows.right.root:MoveToFront()
end

local function destroyContents()
    nextFrame.Cancel(REBUILD_EVENT_ID)
    -- The arrows are in the tabs' layer, so go with it.
    tabArrows = nil
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
        onChange = function(_, index)
            activeTab = index
            fitTabs(true)
        end,
    })
    for index = 1, #TABS do keepScrollbar(tabs:GetPage(index)) end
    buildEditor(aura)
    -- After building: disabling a tab (as for groups) has PrettyUI lay the
    -- strip out again.
    fitTabs(true)
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
