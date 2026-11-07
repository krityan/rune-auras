-- A filtering combo box (typeahead) fast enough for long lists. PrettyUI's
-- filter rebuilds every dropdown row once per entry, about 22,500 rows per
-- keystroke for the ~150 ability cooldowns. The open dropdown also makes a
-- row of components for every entry that passes the filter, so a list of
-- thousands (a slot's items) can cap how many it shows.

local fastTypeahead = {}

--- Whether a combo box has the PrettyUI internals Patch wraps.
---@param combo table?
---@return boolean
local function hasInternals(combo)
    local list = combo and combo.dropdown
    return list ~= nil and type(list._RebuildRows) == "function" and type(combo._Filter) == "function"
end

--- Hides the entries past the first `maxShown` that passed the filter, in
--- the list's order, so the dropdown makes no rows for them. Uses
--- List.entries (each with `id` and `visible`) and List:SetEntryVisible(id, visible).
---@param list table The combo box's PrettyUI List.
---@param maxShown integer
local function capShown(list, maxShown)
    if type(list.entries) ~= "table" or type(list.SetEntryVisible) ~= "function" then return end
    local shown = 0
    for _, entry in ipairs(list.entries) do
        if entry.visible then
            shown = shown + 1
            if shown > maxShown then list:SetEntryVisible(entry.id, false) end
        end
    end
end

-- The release listener's id on a typeahead's text box.
local OPEN_ON_RELEASE_ID = "runeAuras_openOnRelease"
-- The once-a-Logic-tick listener's id on an open typeahead's text box.
local CLOSE_ON_SCROLL_ID = "runeAuras_closeOnScroll"

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
    if not ok then return nil, nil end
    return contentY, scrollY
end

--- Lets the mouse wheel past a closed typeahead's arrow, which otherwise
--- stops a scroll view scrolling while the mouse is over it, and has a click
--- on the arrow or the text open the dropdown. While closed, the arrow (the
--- OrderedComboBox's `button`) passes the mouse through to the text box
--- (`input`), which sits left of it and is widened to the whole box under
--- it, and releasing a click on the text box opens the dropdown (on the
--- release, as PrettyUI closes it on a click outside its arrow). While open,
--- the arrow takes the mouse again, so a click on it closes it, and
--- scrolling the view the box sits in closes it, checked once a Logic tick
--- (PrettyUI leaves the dropdown where it was while the box moves away, and
--- its scroll view keeps the wheel from any listener of ours). Wraps
--- OrderedComboBox:_Open and _Close on the instance.
---@param combo table A PrettyUI OrderedComboBox.
local function passMouseThroughArrow(combo)
    local button, input = combo.button, combo.input
    local open, close = combo._Open, combo._Close
    local hasParts = type(button) == "userdata" and type(input) == "userdata"
    if not hasParts or type(open) ~= "function" or type(close) ~= "function" then return end
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
        if combo.open and hasScrolled then pcall(combo._Close, combo) end
        return true
    end
    combo._Open = function(self, ...)
        open(self, ...)
        openedY, openedScrollY = scrollPosition(self)
        pcall(function() input:Subscribe(ui.Hook.ONTIMER, CLOSE_ON_SCROLL_ID, closeOnScroll) end)
        setArrowPasses(false)
    end
    combo._Close = function(self, ...)
        close(self, ...)
        pcall(function() input:Unsubscribe(ui.Hook.ONTIMER, CLOSE_ON_SCROLL_ID) end)
        setArrowPasses(true)
    end
    --- Opens the dropdown when a click in the box is released.
    ---@return boolean continue Let other listeners have the release too.
    local function openOnRelease()
        if not combo.open and not combo.disabled then pcall(combo._Open, combo) end
        return true
    end
    pcall(function()
        -- Its parent's whole width and height.
        input:SetSize(0, 0, 1, 1)
        input:Subscribe(ui.Hook.ONRELEASE, OPEN_ON_RELEASE_ID, openOnRelease)
    end)
    setArrowPasses(not combo.open)
end

--- Patches one combo box so a filter rebuilds its rows once, after it's
--- done, and not at all while the dropdown is closed (it has nothing to
--- draw). PrettyUI's own filter still does the filtering; only the rebuilds
--- it asks for are held back. Wraps OrderedComboBox:_Filter and
--- List:_RebuildRows on the instance, and leaves a combo box without them alone.
---@param combo table? A PrettyUI OrderedComboBox.
---@param maxShown integer? The most entries a filter leaves showing; nil for all.
---@return table? combo The same combo box.
function fastTypeahead.Patch(combo, maxShown)
    if type(combo) == "table" then passMouseThroughArrow(combo) end
    if not hasInternals(combo) then return combo end
    local list = combo.dropdown
    local rebuildRows, filter = list._RebuildRows, combo._Filter
    local isFiltering, rebuildWanted = false, false

    --- Rebuilds the rows while the dropdown is open; during a filter, only
    --- notes that a rebuild is wanted.
    ---@param self table The list.
    local function heldRebuild(self)
        if isFiltering then
            rebuildWanted = true
            return
        end
        if combo.open then return rebuildRows(self) end
    end

    --- Runs PrettyUI's filter, then one rebuild if it asked for any.
    ---@param self table The combo box.
    local function batchedFilter(self, ...)
        isFiltering, rebuildWanted = true, false
        local ok, problem = pcall(filter, self, ...)
        if ok and maxShown ~= nil then capShown(list, maxShown) end
        isFiltering = false
        if rebuildWanted then list:_RebuildRows() end
        if not ok then error(problem, 0) end
    end

    list._RebuildRows = heldRebuild
    combo._Filter = batchedFilter
    return combo
end

--- Adds a filtering combo box, patched before its full list is set, so
--- building it doesn't create a row per entry either.
---@param view EditorView
---@param options table PrettyUI ComboBox options; entries need an `order`.
---@param maxShown integer? The most entries the dropdown shows at once (see Patch); nil for all.
---@return table? combo
function fastTypeahead.Add(view, options, maxShown)
    local entries = options.entries or {}
    local initial = {}
    for _, entry in ipairs(entries) do
        if entry.id == options.selectedID then initial[1] = entry break end
    end
    initial[1] = initial[1] or entries[1]
    local placed = {}
    for key, value in pairs(options) do placed[key] = value end
    placed.entries = initial
    local combo = fastTypeahead.Patch(view:AddComboBox(placed), maxShown)
    if combo ~= nil and type(combo.SetEntries) == "function" then
        combo:SetEntries(entries, options.selectedID)
    end
    return combo
end

return fastTypeahead
