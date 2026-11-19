-- The button pointer, for clickable things that aren't PrettyUI buttons:
-- the aura list's rows, Import's examples.

local gameApi = require("GameData/game-api")

local buttonCursor = {}

local CURSOR_NAME = "CURSOR_BLANK"

-- The cursor's id, read once it can be.
local cursorID = nil

--- Shows the button pointer while the mouse is over a component (its
--- cursor config's mouseOverCursor).
---@param component userdata
---@param id integer
local function applyCursor(component, id)
    component.cursorConfig.mouseOverCursor = id
end

--- Gives a clickable component the button pointer. Guarded: a component
--- without a cursor config, or before the cursor can be read, keeps the
--- default. Empty text shows it where a layer doesn't, so use that as a
--- clickable area.
---@param component userdata
function buttonCursor.Apply(component)
    cursorID = cursorID or gameApi.Cursor(CURSOR_NAME)

    if cursorID ~= nil then
        pcall(applyCursor, component, cursorID)
    end
end

return buttonCursor
