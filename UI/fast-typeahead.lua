-- Speeds up PrettyUI's filtering combo box (OrderedComboBox) for long lists.
-- Its filter calls List:SetEntryVisible once per entry, and each call
-- rebuilds every row of the dropdown (a layer, rectangle, text and several
-- hooks per row), so a list of n entries rebuilt n times per keystroke or
-- open: about 22,500 rows for the ~150 ability cooldowns. This patches one
-- combo box so a filter rebuilds the rows once, and only while the dropdown
-- is open (a closed dropdown has nothing to draw).
-- It replaces PrettyUI internals (OrderedComboBox:_Filter, List:_RebuildRows)
-- on the instance, and leaves the combo box alone if they aren't there.
-- Usage: fastTypeahead.Add(view, comboBoxOptions)   -- entries need an `order`

local fastTypeahead = {}

function fastTypeahead.Patch(combo)
    local list = combo and combo.dropdown
    if list == nil or type(list._RebuildRows) ~= "function"
        or type(combo._Filter) ~= "function" or type(combo._LayoutDropdown) ~= "function" then
        return combo
    end

    local rebuild = list._RebuildRows
    list._RebuildRows = function(self)
        if combo.open then return rebuild(self) end
    end

    combo._Filter = function(self, value)
        local query = string.lower(tostring(value or ""))
        for _, entry in ipairs(self.entries) do
            entry.visible = query == ""
                or string.find(string.lower(entry.label), query, 1, true) ~= nil
            local row = list.entriesByID and list.entriesByID[entry.id]
            if row ~= nil then
                row.visible = entry.visible
                if not entry.visible then row.selected = false end
            end
        end
        list:_RebuildRows()
        local selected = self.selectedID and self.entriesByID[self.selectedID]
        if selected and selected.visible then
            list:SetSelected(self.selectedID, true, false)
        end
        self:_LayoutDropdown()
    end
    return combo
end

-- Adds a filtering combo box with the patch applied before its full list is
-- set, so building it doesn't create a row per entry either.
function fastTypeahead.Add(view, options)
    local entries = options.entries or {}
    local initial = {}
    for _, entry in ipairs(entries) do
        if entry.id == options.selectedID then initial[1] = entry break end
    end
    initial[1] = initial[1] or entries[1]
    local placed = {}
    for key, value in pairs(options) do placed[key] = value end
    placed.entries = initial
    local combo = fastTypeahead.Patch(view:AddComboBox(placed))
    if combo ~= nil and type(combo.SetEntries) == "function" then
        combo:SetEntries(entries, options.selectedID)
    end
    return combo
end

return fastTypeahead
