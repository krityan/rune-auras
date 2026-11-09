-- An Orb aura's options: their defaults, limits and choices, for the
-- display, the store and the editor. Kept apart from the drawing code
-- (Auras/Displays/orb) so reading them doesn't load it.

--- An orb aura's own options.
---@class OrbOptions: Aura
---@field fillStyle "vertical"|"radial"
---@field fillAnticlockwise boolean A radial fill's edge turns anticlockwise rather than clockwise.
---@field backgroundColour integer
---@field borderColour integer
---@field borderThickness integer
---@field invertFill boolean Fill as the value drops.
---@field smoothFill boolean Move the fill every frame for sources that extrapolate between server ticks.
---@field hideWhenEmpty boolean Hide while the value is 0, except while unlocked.
---@field showIcon boolean The source's icon in the middle, under the fill, which sweeps over it like the Icon display's swipe.
---@field dimWhileActive boolean Grey the icon while the value is above 0 (a buff: while inactive), as the Icon display does.

---@type DisplayOptions
local orbOptions = {}

-- Its value texts are text nodes (see auraTexts.Ensure in Auras/Store/aura-texts).
orbOptions.usesTextNodes = true

orbOptions.defaults = {
    -- Kept equal; the editor offers a single size (see UI/Editor/Types/orb).
    width = 64,
    height = 64,
    fillStyle = "vertical",
    fillAnticlockwise = false,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000FF,
    borderThickness = 2,
    invertFill = false,
    smoothFill = false,
    hideWhenEmpty = false,
    showIcon = false,
    dimWhileActive = false,
}

orbOptions.FILL_STYLES = {
    { id = "vertical", label = "Vertical" },
    { id = "radial", label = "Radial" },
}

orbOptions.limits = { minSize = 16, maxSize = 256, maxBorder = 10 }

return orbOptions
