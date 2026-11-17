-- A row split into two halves, as the text picker's fields are: a control
-- on the left, then one on the right, with a gap between them or the word
-- "is" ("Value is Below 5"). Load options and conditions' checks lay their
-- rows out with it.

local uiConstants = require("UI/ui-constants")

local splitRow = {}

local GAP = uiConstants.GAP
-- The room for "is" in the middle.
local IS_WIDTH = 16
-- The right half's x and both halves' widths are anchored at the middle of the row.
splitRow.HALF = 0.5

--- Where the halves go: the width each gets (with widthAnchor HALF; the
--- left one starts at the view's padding), and where the right one starts
--- (with xAnchor HALF).
---@param view EditorView
---@param withIs boolean Whether "is" goes between them, rather than a gap.
---@return number halfWidth
---@return number rightX
function splitRow.Halves(view, withIs)
    local middle = withIs and IS_WIDTH + GAP * 2 or GAP
    return -(view.contentPadding * 2 + middle) / 2, middle / 2
end

--- Adds "is" in the middle of the row, after its left control.
---@param view EditorView
function splitRow.AddIs(view)
    view:AddText({
        text = "is",
        inline = true,
        x = -IS_WIDTH / 2,
        xAnchor = splitRow.HALF,
        width = IS_WIDTH,
        height = uiConstants.LABEL_HEIGHT,
        offsetY = (uiConstants.FIELD_HEIGHT - uiConstants.LABEL_HEIGHT) // 2,
        maxLines = 1,
    })
end

return splitRow
