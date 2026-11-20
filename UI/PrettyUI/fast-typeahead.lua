-- A filtering combo box (typeahead) fast enough for long lists: its dropdown
-- builds only the rows in view, itself, as PrettyUI's builds one per entry on
-- every keystroke and passes the client's 1-second limit on a long list.

local buttonCursor = require("UI/Controls/button-cursor")
local thumbDrag = require("UI/PrettyUI/thumb-drag")

local fastTypeahead = {}

-- Rows built beyond those in view, above and below, so a few wheel steps
-- don't each rebuild.
local ROW_MARGIN = 5
-- An entry's background when it has no colour set.
local TRANSPARENT = 0x00000000
-- An entry icon's size, in pixels, at the list's entryIconScale of 100 (percent).
local ICON_PIXELS = 16
local PERCENT = 100
-- Where a row's icon and text sit, in pixels.
local ICON_LEFT, ICON_GAP = 7, 6
local TEXT_LEFT, TEXT_RIGHT = 8, 6

--- Whether a combo box has the PrettyUI internals Patch builds on.
---@param combo table?
---@return boolean
local function hasInternals(combo)
    local list = combo and combo.dropdown
    if list == nil or type(combo._Filter) ~= "function" then
        return false
    end

    local parts = { list.entries, list.rows, list.viewport, list.entryHeight, list.frame, list.upArrow,
        list.downArrow, list.track, list.thumb }
    for index = 1, #parts do
        if parts[index] == nil then
            return false
        end
    end

    local methods = { "_RebuildRows", "SetScrollPosition", "_ViewportHeight", "_ResolvedWidth", "_Select",
        "_OnScrollWheel" }
    for _, name in ipairs(methods) do
        if type(list[name]) ~= "function" then
            return false
        end
    end

    return true
end

--- A row's background: the selected colour, the hover colour while the
--- mouse is over it, otherwise its entry's colour (none by default).
---@param list table The dropdown List.
---@param entry table
---@param hovered boolean
---@return integer rgba
local function backgroundColour(list, entry, hovered)
    if entry.selected then
        return entry.selectedColour or list.selectedColour
    end

    if hovered then
        return entry.hoverColour or list.hoverColour
    end

    return entry.backgroundColour or TRANSPARENT
end

--- A row's text colour: greyed for a disabled list or entry.
---@param list table The dropdown List.
---@param entry table
---@return integer rgba
local function textColour(list, entry)
    if list.disabled or not entry.enabled then
        return entry.disabledTextColour or list.disabledTextColour
    end

    return entry.textColour or list.textColour
end

--- The entries the filter left showing, in the list's order.
---@param list table The dropdown List.
---@return table[]
local function shownEntries(list)
    local shown = {}
    for _, entry in ipairs(list.entries) do
        if entry.visible then
            shown[#shown + 1] = entry
        end
    end

    return shown
end

--- The first and last shown entry the view covers (counted from 1), widened
--- by a margin either way.
---@param list table The dropdown List.
---@param count integer How many entries are shown.
---@param margin integer Rows to add above and below.
---@return integer first
---@return integer last
local function rowsInView(list, count, margin)
    local height = list.entryHeight
    local top = list.scrollY or 0
    local first = top // height + 1
    local last = (top + list:_ViewportHeight()) // height + 1
    return math.max(1, first - margin), math.min(count, last + margin)
end

--- Builds one dropdown row as PrettyUI's List expects it, from plain
--- components: a background, an optional icon and the text, under an empty
--- text on top that takes the mouse (and shows the pointer, which a layer
--- doesn't).
---@param list table The dropdown List.
---@param entry table
---@param position integer The row's place among the shown entries, from 0.
---@param onWheel fun(component: userdata, delta: number): boolean Passes the wheel to the list.
---@return table row
local function addRow(list, entry, position, onWheel)
    local height = list.entryHeight
    local baseY = position * height
    local root = ui.Layer.new(list.viewport)
    root:SetPos(0, baseY)
    root:SetSize(0, height, 1, 0)
    root.clickthrough = false

    local background = ui.Rectangle.new(root)
    background:SetSize(0, 0, 1, 1)
    background.fill = true
    background.rgba = backgroundColour(list, entry, false)
    background.clickthrough = true

    local textLeft = TEXT_LEFT
    if entry.icon ~= nil then
        local size = math.max(1, ICON_PIXELS * (list.entryIconScale or PERCENT) // PERCENT)
        local icon = ui.Sprite.new(root)
        icon:SetPos(ICON_LEFT, (height - size) // 2)
        icon:SetSize(size, size)
        icon.spriteID = entry.icon
        icon.clickthrough = true
        textLeft = ICON_LEFT + size + ICON_GAP
    end

    local label = ui.Text.new(root)
    label:SetPos(textLeft, 0)
    label:SetSize(-textLeft - TEXT_RIGHT, height, 1, 0)
    label.font = list.font
    label.rgba = textColour(list, entry)
    label.content = entry.text
    label.isShadowed = list.shadowed
    label.maxLines = 1
    label.alignVertical = ui.AlignMode.CENTRE
    label.clickthrough = true

    local hit = ui.Text.new(root)
    hit:SetSize(0, 0, 1, 1)
    hit.content = ""
    hit.clickthrough = false
    hit:Subscribe(ui.Hook.ONSCROLLWHEEL, onWheel)

    if not list.disabled and entry.enabled then
        hit:Subscribe(ui.Hook.ONMOUSEOVER, function()
            background.rgba = backgroundColour(list, entry, true)
            return true
        end)

        hit:Subscribe(ui.Hook.ONMOUSELEAVE, function()
            background.rgba = backgroundColour(list, entry, false)
            return true
        end)

        hit:Subscribe(ui.Hook.ONCLICK, function()
            local isSingle = (list.maxSelected or 1) <= 1
            local selected = isSingle or not entry.selected
            if list:_Select(entry, selected, true) and list._onEntryClick then
                list._onEntryClick(list, entry.id, entry.selected)
            end

            return false
        end)

        buttonCursor.Apply(hit)
    end

    return { root = root, background = background, label = label, entry = entry, baseY = baseY }
end

-- The release listener's id on a typeahead's text box.
local OPEN_ON_RELEASE_ID = "runeAuras_openOnRelease"
-- The once-a-Logic-tick listener's id on an open typeahead's text box.
local CLOSE_ON_SCROLL_ID = "runeAuras_closeOnScroll"
-- The click listener's id on the view content an open typeahead sits in.
local CLOSE_ON_CLICK_ID = "runeAuras_closeOnClickAway"

---@type table? The typeahead whose dropdown is open: only one is at a time.
local openCombo = nil

--- Closes the open typeahead's dropdown, if any.
local function closeOpenCombo()
    local combo = openCombo
    if combo ~= nil and combo.open then
        pcall(combo._Close, combo)
    end
end

--- Closes the open dropdown on a click in its view outside any control.
---@return boolean continue Let other listeners have the click too.
local function closeOnClickAway()
    closeOpenCombo()
    return true
end

--- Where the view a typeahead sits in is scrolled to: the y of the view's
--- content (the OrderedComboBox's `parent`) and its holder's scrollY,
--- whichever one scrolling moves.
---@param combo table
---@return number? contentY
---@return number? scrollY
local function scrollPosition(combo)
    local ok, contentY, scrollY = pcall(function()
        local content = combo.parent
        local holder = content.parent
        return content.y, holder and holder.scrollY
    end)
    if not ok then
        return nil, nil
    end

    return contentY, scrollY
end

--- Lets the mouse wheel scroll past a closed typeahead's arrow, and makes a
--- click on the arrow or text open the dropdown. While closed, the arrow
--- (`button`) passes the mouse to the text box (`input`), widened under it,
--- which opens the dropdown on release. While open, the arrow takes the mouse
--- again to close it, and the dropdown also closes when its view scrolls
--- (checked each Logic tick), on a click on the view's `parent` outside a
--- control, or when another opens. Wraps OrderedComboBox:_Open and _Close.
---@param combo table A PrettyUI OrderedComboBox.
local function passMouseThroughArrow(combo)
    local button, input = combo.button, combo.input
    local open, close = combo._Open, combo._Close
    local hasParts = type(button) == "userdata" and type(input) == "userdata"
    if not hasParts or type(open) ~= "function" or type(close) ~= "function" then
        return
    end

    --- Lets the mouse through the arrow, or not.
    ---@param passes boolean
    local function setArrowPasses(passes)
        pcall(function() button.clickthrough = passes end)
    end

    local openedY, openedScrollY = nil, nil

    --- Closes the dropdown once the view has scrolled since it opened.
    ---@return boolean continue Let other listeners have the tick too.
    local function closeOnScroll()
        local contentY, scrollY = scrollPosition(combo)
        local hasScrolled = contentY ~= openedY or scrollY ~= openedScrollY
        if combo.open and hasScrolled then
            pcall(combo._Close, combo)
        end

        return true
    end

    combo._Open = function(self, ...)
        if openCombo ~= self then
            closeOpenCombo()
        end

        open(self, ...)

        -- PrettyUI doesn't open a box scrolled out of its view or hidden;
        -- the arrow keeps letting the mouse through then.
        if not self.open then
            return
        end

        openCombo = self
        openedY, openedScrollY = scrollPosition(self)

        pcall(function()
            input:Subscribe(ui.Hook.ONTIMER, CLOSE_ON_SCROLL_ID, closeOnScroll)
            self.parent:Subscribe(ui.Hook.ONCLICK, CLOSE_ON_CLICK_ID, closeOnClickAway)
        end)

        setArrowPasses(false)
    end
    combo._Close = function(self, ...)
        close(self, ...)

        if openCombo == self then
            openCombo = nil
            pcall(function() self.parent:Unsubscribe(ui.Hook.ONCLICK, CLOSE_ON_CLICK_ID) end)
        end

        pcall(function() input:Unsubscribe(ui.Hook.ONTIMER, CLOSE_ON_SCROLL_ID) end)
        setArrowPasses(true)
    end

    --- Opens the dropdown when a click in the box is released.
    ---@return boolean continue Let other listeners have the release too.
    local function openOnRelease()
        if not combo.open and not combo.disabled then
            pcall(combo._Open, combo)
        end

        return true
    end

    pcall(function()
        -- Its parent's whole width and height.
        input:SetSize(0, 0, 1, 1)
        input:Subscribe(ui.Hook.ONRELEASE, OPEN_ON_RELEASE_ID, openOnRelease)
    end)

    setArrowPasses(not combo.open)
end

--- Patches one combo box so its dropdown builds only the rows in view, once
--- after each filter and not at all while closed. Replaces OrderedComboBox's
--- _Filter and the List's _RebuildRows and SetScrollPosition on the instance;
--- a combo box without those internals is left to PrettyUI.
---@param combo table? A PrettyUI OrderedComboBox.
---@return table? combo The same combo box.
function fastTypeahead.Patch(combo)
    if type(combo) == "table" then
        passMouseThroughArrow(combo)
    end

    if not hasInternals(combo) then
        return combo
    end

    local list = combo.dropdown
    local filter, setScroll = combo._Filter, list.SetScrollPosition
    local isFiltering, rebuildWanted = false, false
    ---@type { first: integer, last: integer, count: integer }? The rows built last, and how many entries were shown.
    local built = nil

    --- Passes the wheel over a row to the list, which scrolls it.
    ---@return boolean
    local function onWheel(component, delta)
        return list:_OnScrollWheel(component, delta)
    end

    --- Replaces the rows with those in view, sized for every shown entry so
    --- the scrollbar covers them all.
    local function buildRows()
        for _, row in ipairs(list.rows) do
            row.root:Destroy()
        end

        list.rows = {}
        local shown = shownEntries(list)
        local count = #shown
        list.contentHeight = math.max(1, count * list.entryHeight)
        list.viewport:SetScrollSize(math.max(1, list:_ResolvedWidth() - 2),
            math.max(list:_ViewportHeight(), list.contentHeight))
        -- Clamps the scroll to the new length, before working out the view.
        setScroll(list, list.scrollY)
        local first, last = rowsInView(list, count, ROW_MARGIN)
        for index = first, last do
            list.rows[#list.rows + 1] = addRow(list, shown[index], index - 1, onWheel)
        end

        built = { first = first, last = last, count = count }
        -- Sizes the new rows to the list's width.
        setScroll(list, list.scrollY)

        for _, edge in ipairs(list.frame) do
            edge:MoveToFront()
        end

        list.upArrow:MoveToFront()
        list.downArrow:MoveToFront()
        list.track:MoveToFront()
    end

    --- Rebuilds the rows while the dropdown is open; during a filter, only
    --- notes that a rebuild is wanted.
    local function heldRebuild()
        if isFiltering then
            rebuildWanted = true
            return
        end

        if combo.open then
            buildRows()
        end
    end

    --- Scrolls the list, then builds the rows coming into view if the built
    --- ones no longer cover it. During a filter (which scrolls and lays the
    --- dropdown out) it only scrolls: the filter's rebuild follows.
    ---@param self table The list.
    ---@param value number?
    local function scrollAndFill(self, value)
        setScroll(self, value)

        if isFiltering or not combo.open or built == nil then
            return
        end

        local first, last = rowsInView(self, built.count, 0)
        if first < built.first or last > built.last then
            buildRows()
        end
    end

    --- Runs PrettyUI's filter, then one rebuild if it asked for any.
    ---@param self table The combo box.
    local function batchedFilter(self, ...)
        isFiltering, rebuildWanted = true, false
        local ok, problem = pcall(filter, self, ...)
        isFiltering = false

        if rebuildWanted then
            list:_RebuildRows()
        end

        if not ok then
            error(problem, 0)
        end
    end

    thumbDrag.Follow(list)
    list._RebuildRows = heldRebuild
    list.SetScrollPosition = scrollAndFill
    combo._Filter = batchedFilter
    return combo
end

--- Adds a filtering combo box, patched before its full list is set, so
--- building it doesn't create a row per entry either.
---@param view EditorView
---@param options table PrettyUI ComboBox options; entries need an `order`.
---@return table? combo
function fastTypeahead.Add(view, options)
    local entries = options.entries or {}
    local initial = {}
    for _, entry in ipairs(entries) do
        if entry.id == options.selectedID then
            initial[1] = entry
            break
        end
    end

    initial[1] = initial[1] or entries[1]
    local placed = {}
    for key, value in pairs(options) do
        placed[key] = value
    end

    placed.entries = initial
    local combo = fastTypeahead.Patch(view:AddComboBox(placed))
    if combo ~= nil and type(combo.SetEntries) == "function" then
        combo:SetEntries(entries, options.selectedID)
    end

    return combo
end

return fastTypeahead
