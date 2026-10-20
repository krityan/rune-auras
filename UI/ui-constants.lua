-- Spacing and colours shared by the UI files, so the panel, the editor and
-- its controls line up and match. Values only one file uses stay in it.
-- Usage: local uiConstants = require("UI/ui-constants")

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

-- Gold, for highlights: the aura being edited, groups, drop targets.
uiConstants.ACCENT_RGBA = 0xF2C66DFF
uiConstants.ACCENT_HEX = "F2C66D"
-- Grey, for secondary text.
uiConstants.MUTED_RGBA = 0xA0A0A0FF
uiConstants.MUTED_HEX = "A0A0A0"

-- A 0xRRGGBBAA colour with its alpha replaced (0-255).
function uiConstants.WithAlpha(rgba, alpha)
    return (rgba & 0xFFFFFF00) | (alpha & 0xFF)
end

return uiConstants
