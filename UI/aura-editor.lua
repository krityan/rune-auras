-- The aura editor: a movable, resizable window over the game area for
-- editing one aura at a time.
-- Usage:
--   local auraEditor = require("UI/aura-editor")
--   auraEditor.Init({ onAurasChanged = ..., onEditorChanged = ... })
--   auraEditor.Open(prettyui, auraID)

local anchors = require("Auras/anchors")
local auraStore = require("Auras/aura-store")
local dataSources = require("Auras/data-sources")
local displayTypes = require("Auras/display-types")
local fonts = require("Auras/fonts")
local colourInput = require("UI/colour-input")
local fastTypeahead = require("UI/fast-typeahead")
local numberInput = require("UI/number-input")

-- Display type id -> its editor controls, { size = fn, appearance = fn },
-- each fn(view, aura, update) adding controls to that section.
-- An editor module can set `usesFillColour = false` to drop the generic
-- Fill colour control from Appearance, `usesSource`, `usesAppearance` or
-- `usesText = false` to drop those parts altogether, and `usesAnchor = false`
-- for plain X/Y offsets (as groups do).
local TYPE_EDITORS = {
    bar = require("UI/Editors/bar"),
    icon = require("UI/Editors/icon"),
    group = require("UI/Editors/group"),
}

-- Layout convention: every control has its label on its own row above it.
local auraEditor = {}

local REBUILD_EVENT_ID = "runeAuras_editorRebuild"
local PADDING = 12
local GAP = 8
-- Extra space above each section header after the first.
local SECTION_GAP = 20
-- Extra horizontal padding, on both sides, for the controls inside a section.
local SECTION_INDENT = 12
local WINDOW_WIDTH = 400
-- Narrow enough to tuck aside, wide enough for a slider and number field.
local WINDOW_MIN_WIDTH = 320
local WINDOW_HEIGHT = 560
local WINDOW_MIN_HEIGHT = 240
local WINDOW_MARGIN = 80
-- PrettyUI's scrollbar width plus its gap to the content.
local SCROLLBAR_GUTTER = 18
-- How faint the scrollbar is while there's nothing to scroll.
local SCROLLBAR_IDLE_ALPHA = 0.4

local handlers = nil
local prettyUI = nil
local window = nil
local editingID = nil
-- auraID -> data type picked in the editor before a source of it was chosen.
-- Forgotten when the editor closes or switches aura.
local pickedTypes = {}
-- Where the player last left the window, so reopening puts it back there.
-- Saved as "x,y,width,height" so it also survives reloading the plugin.
local WINDOW_RECT_STORAGE_KEY = "editorWindowRect"
local windowRect = nil
local windowRectLoaded = false
-- The open editor's X/Y inputs, kept so dragging the aura can update them.
local positionInputs = nil
-- Section id -> true for collapsed sections; remembered between sessions.
local COLLAPSED_STORAGE_KEY = "editorCollapsedSections"
local collapsedSections = nil
-- Whether the editor being built already has a section above the next one.
local hasSection = false

local function changed()
    if handlers ~= nil and handlers.onAurasChanged ~= nil then
        handlers.onAurasChanged()
    end
end

local function editorChanged()
    if handlers ~= nil and handlers.onEditorChanged ~= nil then
        handlers.onEditorChanged()
    end
end

-- Locks an aura again so it stops catching clicks meant for the game.
local function lockAura(auraID)
    if auraID ~= nil and auraStore.Get(auraID) ~= nil then
        auraStore.Set(auraID, "unlocked", false)
        changed()
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

-- A stand-in for the window that indents everything added through it by
-- SECTION_INDENT. The flow layout has one padding for the whole window, so
-- each row gets an explicit x (which survives reflows) and fill-width
-- controls stop the same distance from the right edge. contentPadding tells
-- helpers like UI/number-input the effective padding.
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
            return window[method](window, table.unpack(args, 1, args.n))
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
    window:AddCollapseButton(title, {
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
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
end

-- The size of what an aura is positioned inside. A group only moves its
-- contents, so inside one or not that's the game area. nil if unknown.
local function parentSize()
    local area = gameAreaComponent()
    if area == nil then return nil end
    return area.width, area.height
end

local function buildTextOptions(view, aura, update)
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

    view:AddText("Text template")
    view:AddTextField({
        text = aura.textTemplate,
        placeholder = "e.g. $current / $max",
        maxLength = 64,
        tooltip = "$current is replaced by the current value and $max by the maximum.",
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
                local width, height = aura.width or 0, aura.height or 0
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
        minX, maxX, minY, maxY = anchors.OffsetRange(aura.anchor,
            aura.width or 0, aura.height or 0, parentWidth, parentHeight)
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
    local minX, maxX, minY, maxY = anchors.OffsetRange(aura.anchor,
        aura.width or 0, aura.height or 0, parentWidth, parentHeight)
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

local function buildEditor(aura)
    local auraID = aura.id
    local function update(key, value)
        auraStore.Set(auraID, key, value)
        changed()
    end
    local function updateSize(key, value)
        update(key, value)
        refreshPositionRange(aura, update)
    end

    local typeSections = TYPE_EDITORS[aura.display] or {}
    -- Set by the Appearance section so a data source change can update it.
    local colourPicker

    section("general", "General", function(view)
        view:AddText("Name")
        local nameField
        nameField = view:AddTextField({
            text = aura.name,
            placeholder = auraStore.IsGroup(aura) and "Group name" or "Aura name",
            maxLength = 32,
            onChange = function()
                local name = trim(nameField:GetText())
                if name ~= "" then
                    update("name", name)
                    auraEditor.RefreshTitle()
                end
            end,
        })

        -- Groups have no display type or data of their own.
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
                        nameField:SetText(source.label)
                    end
                    local untouched = previous == nil and auraStore.DEFAULT_COLOUR or previous.colour
                    if aura.colour == untouched then
                        aura.colour = source.colour
                        if colourPicker ~= nil then colourPicker:SetValue(source.colour) end
                    end
                    update("source", source.id)
                    auraEditor.RefreshTitle()
                    -- Some options (e.g. a bar's Smooth fill) depend on the source.
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
            buildTextOptions(view, aura, update)
        end)
    end

    section("position", "Position", function(view)
        if typeSections.usesAnchor == false then
            buildGroupPositionOptions(view, aura, update)
        else
            buildPositionOptions(view, aura, update)
        end
    end)

    window:AddFancyButton("Done", function()
        auraEditor.Close()
    end, {
        width = 200,
        variant = "positive",
    })
end

local function loadRect()
    if windowRectLoaded then return end
    windowRectLoaded = true
    local saved = PersistentDB:GetString(WINDOW_RECT_STORAGE_KEY)
    local x, y, width, height = tostring(saved or ""):match("^(-?%d+),(-?%d+),(%d+),(%d+)$")
    if x == nil then return end
    windowRect = {
        x = tonumber(x),
        y = tonumber(y),
        width = tonumber(width),
        height = tonumber(height),
    }
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

local function destroyWindow()
    Event.Draw.Unsubscribe(REBUILD_EVENT_ID)
    local closing = window
    window = nil
    positionInputs = nil
    if closing ~= nil and closing.root ~= nil then closing:Destroy() end
end

local function setAlpha(component, alpha)
    pcall(function() component.alpha = alpha end)
end

-- PrettyUI hides a window's scrollbar, and widens its content, whenever
-- nothing overflows, so opening or collapsing a section made everything
-- jump sideways. This keeps the gutter and shows the bar faded instead. It
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
    pcall(function() scroll:Refresh() end)
end

-- Builds (or rebuilds) the window for editingID. keepScroll keeps the
-- scroll position, e.g. when one option changes another's range.
local function build(keepScroll)
    local scrollY = keepScroll and window ~= nil and window.scrollY or nil
    rememberRect()
    destroyWindow()

    local aura = editingID ~= nil and auraStore.Get(editingID) or nil
    local area = gameAreaComponent()
    if aura == nil or area == nil or prettyUI == nil then
        editingID = nil
        return false
    end

    loadRect()
    local rect = windowRect and fitRect(windowRect, area) or {
        x = math.max(0, area.width - WINDOW_WIDTH - WINDOW_MARGIN),
        y = WINDOW_MARGIN,
        width = WINDOW_WIDTH,
        height = math.max(WINDOW_MIN_HEIGHT, math.min(WINDOW_HEIGHT, area.height - WINDOW_MARGIN * 2)),
    }
    local opened
    opened = prettyUI.Window.new(area, {
        title = "Edit " .. aura.name,
        x = rect.x,
        y = rect.y,
        width = rect.width,
        height = rect.height,
        minWidth = WINDOW_MIN_WIDTH,
        minHeight = WINDOW_MIN_HEIGHT,
        resizable = true,
        destroyOnClose = true,
        -- Runs for the title bar's close button as well as auraEditor.Close.
        onClose = function()
            if window ~= opened then return end
            rememberRect()
            window = nil
            positionInputs = nil
            local auraID = editingID
            editingID = nil
            pickedTypes = {}
            lockAura(auraID)
            editorChanged()
        end,
        layout = {
            startY = 10,
            paddingLeft = PADDING,
            paddingRight = PADDING,
            rowGap = GAP,
            columnGap = GAP,
        },
    })
    window = opened
    keepScrollbar(window)
    hasSection = false
    buildEditor(aura)
    if scrollY ~= nil then window:SetScrollPosition(scrollY) end
    return true
end

-- Rebuilds on the next frame, keeping the scroll position. Use this from a
-- control's own callback so the control isn't destroyed while it's running.
requestRebuild = function()
    Event.Draw.Subscribe(REBUILD_EVENT_ID, function()
        Event.Draw.Unsubscribe(REBUILD_EVENT_ID)
        build(true)
    end)
end

function auraEditor.Init(editorHandlers)
    handlers = editorHandlers
end

-- Opens the editor for an aura, switching away from any aura already open.
function auraEditor.Open(prettyUILibrary, auraID)
    prettyUI = prettyUILibrary
    if editingID ~= nil and editingID ~= auraID then
        lockAura(editingID)
        pickedTypes = {}
    end
    editingID = auraID
    local opened = build(false)
    editorChanged()
    return opened
end

function auraEditor.Close()
    -- Window:Close runs onClose, which locks the aura and notifies.
    if window ~= nil then window:Close() end
end

-- The aura being edited, or nil when the editor is closed.
function auraEditor.EditingID()
    return window ~= nil and editingID or nil
end

-- Updates the window title after a rename without rebuilding it.
function auraEditor.RefreshTitle()
    local aura = editingID ~= nil and auraStore.Get(editingID) or nil
    if window ~= nil and aura ~= nil then window:SetTitle("Edit " .. aura.name) end
end

-- Shows a dragged aura's new offset in the editor, if it's open.
function auraEditor.OnAuraMoved(auraID)
    if positionInputs == nil or auraID ~= editingID then return end
    local aura = auraStore.Get(auraID)
    if aura == nil then return end
    positionInputs.x:SetValue(aura.x)
    positionInputs.y:SetValue(aura.y)
end

-- Drops the window without notifying, e.g. on logout when the game area is
-- going away.
function auraEditor.Destroy()
    rememberRect()
    destroyWindow()
    local auraID = editingID
    editingID = nil
    pickedTypes = {}
    -- Lock here too, or a logout or reload leaves the aura catching clicks.
    lockAura(auraID)
end

return auraEditor
