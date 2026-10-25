-- Spacing and colours shared by the UI files, so the panel, the editor and
-- its controls line up and match. Values only one file uses stay in it.

local uiConstants = {}

-- Left/right padding of the panel's and editor window's layouts (the
-- editor's sections add their own indent on top; see contentPadding).
uiConstants.PADDING = 12
-- Space between rows and between controls on a row.
uiConstants.GAP = 8
-- Sprite buttons (eye, pencil, copy/paste and so on).
uiConstants.BUTTON_SIZE = 24
-- A label on its own row above a control.
uiConstants.LABEL_HEIGHT = 24
-- PrettyUI's text field height.
uiConstants.FIELD_HEIGHT = 30
-- Space above each item in a list of them after the first (checks, changes,
-- load options): wider than GAP, so items read as separate.
uiConstants.ITEM_GAP = 14
-- Extra space above each of the editor's section headers after the first.
uiConstants.SECTION_GAP = 20

-- Gold, for highlights: the aura being edited, groups, drop targets.
uiConstants.ACCENT_RGBA = 0xF2C66DFF
uiConstants.ACCENT_HEX = "F2C66D"
-- Grey, for secondary text.
uiConstants.MUTED_RGBA = 0xA0A0A0FF
uiConstants.MUTED_HEX = "A0A0A0"

local RGB_BITS = 0xFFFFFF00
local ALPHA_BITS = 0xFF

--- A colour with its alpha replaced.
---@param rgba integer 0xRRGGBBAA.
---@param alpha integer 0-255.
---@return integer
function uiConstants.WithAlpha(rgba, alpha)
    return (rgba & RGB_BITS) | (alpha & ALPHA_BITS)
end

return uiConstants
