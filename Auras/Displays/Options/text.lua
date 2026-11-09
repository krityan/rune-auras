-- A Text aura's options: their defaults and limits, for the display, the
-- store and the editor. Kept apart from the drawing code (Auras/Displays/text)
-- so reading them doesn't load it.

--- A text aura's own options. It uses the aura's own text fields (font,
--- size, colour, template, decimals), not text nodes.
---@class TextOptions: Aura
---@field maxWidth number The widest the box gets before the text wraps onto more lines.
---@field textAlign "left"|"centre"|"right" Where the lines sit when wrapped.
---@field textShadow boolean
---@field hideWhenEmpty boolean Hide while the value is 0 (an idle channel or buff, a ready cooldown), except while unlocked.
---@field showIcon boolean The source's icon at one end, a line tall.
---@field iconSide "left"|"right"

---@type DisplayOptions
local textOptions = {}

-- The display sizes itself, so the editor reads its size from the aura
-- manager rather than the aura (see auraManager.ScreenSize).
textOptions.sizesItself = true

textOptions.defaults = {
    maxWidth = 300,
    -- Nominal size, for the store and editor; the display sizes itself to
    -- its text.
    width = 100,
    height = 24,
    textTemplate = "$name: $value",
    textAlign = "centre",
    textShadow = true,
    hideWhenEmpty = false,
    showIcon = false,
    iconSide = "left",
}

textOptions.limits = { minWidth = 40, maxWidth = 800 }

return textOptions
