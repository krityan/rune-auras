-- Spacing and colours shared by the UI files, so the panel, the editor and
-- its controls line up and match. Values only one file uses stay in it.

local uiConstants = {}

-- Left/right padding of the panel and editor layouts.
uiConstants.PADDING = 12
-- Space between rows and between controls on a row.
uiConstants.GAP = 8
-- Sprite buttons (eye, pencil, copy/paste and so on).
uiConstants.BUTTON_SIZE = 24
-- A label on a separate row above a control.
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
-- Red, for errors and warnings.
uiConstants.DANGER_RGBA = 0xE07060FF
-- Row fills, alternating down a list (the aura list, Import's examples).
uiConstants.LIST_ROW_RGBAS = { 0x211E1BFF, 0x2A2622FF }
-- A row's fill under the mouse.
uiConstants.LIST_HOVER_RGBA = 0x393530FF

-- PrettyUI's id allocation for the controls the plugin constructs (Window.new,
-- SimpleView.new, Tabs.new; what's added through them inherits it). "auto"
-- builds a long page several times faster than the default (nil), which checks
-- every id. But in PrettyUI 1.3.0 a window in the game area under "auto" can
-- give a later part (the outline drawn while dragging) an id one of its
-- controls already has, which fails. The editor area doesn't clash, so only
-- it gets "auto".
-- TODO: set PRETTYUI_CATEGORY to "auto" too with a PrettyUI release that fixes that.
uiConstants.PRETTYUI_CATEGORY = nil
uiConstants.PRETTYUI_EDITOR_CATEGORY = "auto"

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
