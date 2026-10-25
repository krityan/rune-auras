-- Stretches PrettyUI's collapse button (a section header) to fit buttons:
-- it's 20px tall, too short for the buttons some section headers carry.
-- Patches its internals (its sprites, label and _ExpandedHeight), so it
-- leaves a header alone if they aren't there; check in game when PrettyUI
-- updates.

local uiConstants = require("UI/ui-constants")

local tallHeader = {}

-- Room above and below a header button.
local BUTTON_MARGIN = 2
tallHeader.HEIGHT = uiConstants.BUTTON_SIZE + BUTTON_MARGIN * 2
-- Keeps header buttons off its rounded right end.
tallHeader.BUTTON_INSET = 6
-- The width of the header's rounded ends.
local CAP_WIDTH = 20
-- The header label's inset from its right end.
local LABEL_INSET = 12

--- Stretches a section header to HEIGHT.
---@param header table A PrettyUI CollapseButton.
function tallHeader.Stretch(header)
    local hasInternals = header ~= nil and header.left ~= nil and header.middle ~= nil and header.right ~= nil
        and header.label ~= nil and type(header._Resize) == "function"
    if not hasInternals then return end
    local height = tallHeader.HEIGHT
    header.left:SetSize(CAP_WIDTH, height)
    header.middle:SetSize(-CAP_WIDTH * 2, height, 1.0)
    -- It tiles to fill its width, which taller repeats the 20px texture
    -- below itself; stretched, it's one bar.
    header.middle.isTiling = false
    header.right:SetSize(CAP_WIDTH, height)
    header.label:SetSize(-LABEL_INSET - CAP_WIDTH, height, 1.0)
    -- Its controls are built below it, never inside, so it's only ever the
    -- header itself.
    header._ExpandedHeight = function() return height end
    header:_Resize()
end

return tallHeader
