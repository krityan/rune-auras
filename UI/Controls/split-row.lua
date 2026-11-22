-- A row split into two halves: a control on each side, with a gap or the word
-- "is" between them ("Value is Below 5"), as load options and checks use.

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
---@param endSpace number? Room kept at the row's right end, after the right half (for a button); nil for none.
---@return number halfWidth
---@return number rightX
---@return number middleX The middle of the gap between them (with xAnchor HALF), for AddIs.
function splitRow.Halves(view, withIs, endSpace)
    local middle = withIs and IS_WIDTH + GAP * 2 or GAP
    local reserved = endSpace or 0
    return -(view.contentPadding * 2 + middle + reserved) / 2, (middle - reserved) / 2, -reserved / 2
end

--- Adds "is" in the middle of the row, after its left control.
---@param view EditorView
---@param middleX number? Halves' middleX, for a row that keeps room at its end; nil for the row's middle.
function splitRow.AddIs(view, middleX)
    view:AddText({
        text = "is",
        inline = true,
        x = (middleX or 0) - IS_WIDTH / 2,
        xAnchor = splitRow.HALF,
        width = IS_WIDTH,
        height = uiConstants.LABEL_HEIGHT,
        offsetY = (uiConstants.FIELD_HEIGHT - uiConstants.LABEL_HEIGHT) // 2,
        maxLines = 1,
    })
end

return splitRow
