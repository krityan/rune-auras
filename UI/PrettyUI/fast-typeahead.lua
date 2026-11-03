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

--- Patches one combo box so a filter rebuilds its rows once, after it's
--- done, and not at all while the dropdown is closed (it has nothing to
--- draw). PrettyUI's own filter still does the filtering; only the rebuilds
--- it asks for are held back. Wraps OrderedComboBox:_Filter and
--- List:_RebuildRows on the instance, and leaves a combo box without them alone.
---@param combo table? A PrettyUI OrderedComboBox.
---@param maxShown integer? The most entries a filter leaves showing; nil for all.
---@return table? combo The same combo box.
function fastTypeahead.Patch(combo, maxShown)
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
