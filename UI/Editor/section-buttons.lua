-- The header buttons of a list item the editor shows as a section (a
-- condition, a text node): remove, duplicate, and move down and up.

local sectionButtons = {}

local REBUILD = true

--- The buttons for list[index], as the editor's section takes them. Each
--- changes the list through `edit` and rebuilds, as they add or remove sections.
---@param list table[]
---@param index integer
---@param edit fun(change: fun(), rebuild: boolean?) Makes a change, then saves and reports it.
---@param copyItem fun(item: table): table A copy to insert after the item, with a key of its own.
---@return table[] buttons Each { sprite, tooltip, onClick }; the move buttons only where it can move.
function sectionButtons.ForListItem(list, index, edit, copyItem)
    local item = list[index]
    --- Moves the item `by` places along the list.
    ---@param by integer
    local function move(by)
        edit(function()
            table.remove(list, index)
            table.insert(list, index + by, item)
        end, REBUILD)
    end
    local buttons = {
        {
            sprite = "TRASH",
            tooltip = "Remove",
            onClick = function() edit(function() table.remove(list, index) end, REBUILD) end,
        },
        {
            sprite = "PLUS",
            tooltip = "Duplicate",
            onClick = function()
                edit(function() table.insert(list, index + 1, copyItem(item)) end, REBUILD)
            end,
        },
    }
    if index < #list then
        buttons[#buttons + 1] = { sprite = "ARROW_DOWN", tooltip = "Move down", onClick = function() move(1) end }
    end
    if index > 1 then
        buttons[#buttons + 1] = { sprite = "ARROW_UP", tooltip = "Move up", onClick = function() move(-1) end }
    end
    return buttons
end

return sectionButtons
