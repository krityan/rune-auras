-- An Icon aura's options: their defaults, limits and choices, and which
-- swipe styles suit a source, for the display, the store and the editor.
-- Kept apart from the drawing code (Auras/Displays/icon) so reading them
-- doesn't load it.

--- An icon aura's own options.
---@class IconOptions: Aura
---@field swipeStyle "radial"|"linear"|"none"
---@field swipeColour integer
---@field iconColour integer Multiplied into the icon (white leaves it as it is), e.g. blue while there's not enough adrenaline, through a condition.
---@field backgroundColour integer Behind the icon: shows through its transparent parts (an item's edges).
---@field borderColour integer Drawn inside the icon's square; the icon is inset by its thickness.
---@field borderThickness integer
---@field invertSwipe boolean Cover what's done instead of what's left, so the swipe grows.
---@field swipeAnticlockwise boolean The radial's edge turns anticlockwise rather than clockwise.
---@field wipeDirection "right"|"left"|"down"|"up" The way the linear wipe grows: right from the left edge, left from the right, down from the top, up from the bottom.
---@field dimWhileActive boolean Grey the icon while the value is above 0 (a buff: while inactive).
---@field hideTextWhenReady boolean
---@field hideWhileInactive boolean Hide a buff's icon while it's inactive.
---@field hideWhileActive boolean Hide a buff's icon while it's active, e.g. to only show a missing buff.
---@field showActiveBelow number With hideWhileActive, show again once the time left drops to this many seconds (0: stays hidden).
---@field desaturate boolean? Set only by a condition: greyed whatever the value.

---@class IconDisplayOptions: DisplayOptions
local iconOptions = {}

-- Its value texts are text nodes (see auraTexts.Ensure in Auras/Store/aura-texts).
iconOptions.usesTextNodes = true

iconOptions.defaults = {
    -- Kept equal; the editor offers a single size (see UI/Editor/Types/icon).
    width = 48,
    height = 48,
    swipeStyle = "radial",
    swipeColour = 0x000000B4,
    iconColour = 0xFFFFFFFF,
    backgroundColour = 0x000000FF,
    borderColour = 0x000000FF,
    borderThickness = 1,
    invertSwipe = false,
    swipeAnticlockwise = false,
    wipeDirection = "up",
    dimWhileActive = true,
    hideTextWhenReady = true,
    hideWhileInactive = false,
    hideWhileActive = false,
    showActiveBelow = 0,
}

iconOptions.limits = { minSize = 16, maxSize = 128, maxBorder = 10 }

-- The linear wipe's directions, named after the way it grows, as grow
-- directions are ("right": from the left edge).
iconOptions.WIPE_DIRECTIONS = {
    { id = "right", label = "Left to right" },
    { id = "left", label = "Right to left" },
    { id = "down", label = "Top to bottom" },
    { id = "up", label = "Bottom to top" },
}

iconOptions.SWIPE_STYLES = {
    { id = "radial", label = "Radial" },
    { id = "linear", label = "Linear wipe" },
    { id = "none", label = "None" },
}

--- Whether a swipe style can be drawn for a source. The radial times itself
--- in seconds, so it only suits timers. An on/off source has no amount for
--- either to show.
---@param style string A SWIPE_STYLES id.
---@param source DataSource?
---@return boolean
local function swipeFits(style, source)
    if style == "none" then return true end
    if source ~= nil and source.onOff then return false end
    if style == "radial" then return source ~= nil and source.timed == true end
    return true
end

--- The swipe styles a source can be drawn with, for the editor.
---@param source DataSource?
---@return { id: string, label: string }[]
function iconOptions.SwipeStylesFor(source)
    local styles = {}
    for _, style in ipairs(iconOptions.SWIPE_STYLES) do
        if swipeFits(style.id, source) then styles[#styles + 1] = style end
    end
    return styles
end

--- The swipe style drawn: the aura's, or the first after it that fits the
--- source (radial falls back to the linear wipe, then none).
---@param style string? The aura's swipeStyle.
---@param source DataSource?
---@return string
function iconOptions.DrawnSwipe(style, source)
    style = style or iconOptions.defaults.swipeStyle
    local reached = false
    for _, candidate in ipairs(iconOptions.SWIPE_STYLES) do
        reached = reached or candidate.id == style
        if reached and swipeFits(candidate.id, source) then return candidate.id end
    end
    return "none"
end

return iconOptions
