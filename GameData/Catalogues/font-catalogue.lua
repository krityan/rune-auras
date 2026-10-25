-- Fonts an aura's text can use, and measuring text in them. The client
-- doesn't publish a font list, so this probes id.Font for the families and
-- sizes that exist.

local gameApi = require("GameData/game-api")

local fontCatalogue = {}

--- A font family and style that exists, with the sizes it has.
---@class FontEntry
---@field id string Family and style, e.g. "museo_sans_bold".
---@field label string Shown in the editor.
---@field sizes integer[] Point sizes it has, ascending.
---@field handles table<integer, integer> Point size to its id.Font handle.

local FAMILIES = {
    { id = "museo_sans", label = "Museo Sans", prefix = "MUSEO_SANS" },
    { id = "noto_sans", label = "Noto Sans", prefix = "NOTO_SANS" },
    { id = "cinzel", label = "Cinzel", prefix = "CINZEL" },
}
local STYLES = {
    { id = "regular", label = "", suffix = "REGULAR" },
    { id = "bold", label = " Bold", suffix = "BOLD" },
    { id = "regular_outline", label = " Outline", suffix = "REGULAR_OUTLINE" },
    { id = "bold_outline", label = " Bold Outline", suffix = "BOLD_OUTLINE" },
}
-- Point sizes probed for each family and style.
local MIN_SIZE, MAX_SIZE = 6, 40

fontCatalogue.DEFAULT_FONT = "museo_sans_regular"
fontCatalogue.DEFAULT_SIZE = 11
-- Extra height around a font's point size so its glyphs aren't clipped.
local LINE_PADDING = 8
-- A name no font has: id.Font answers even for names that don't exist, so
-- anything equal to what this returns counts as missing.
local MISSING_FONT_NAME = "RUNE_AURAS_NOT_A_FONT"
-- Measured for the height of one line.
local ONE_LINE_SAMPLE = "X"

--- The height a line of text at a point size needs.
---@param size integer? nil for DEFAULT_SIZE.
---@return integer
function fontCatalogue.LineHeight(size)
    return (size or fontCatalogue.DEFAULT_SIZE) + LINE_PADDING
end
local FALLBACK = gameApi.Font("MUSEO_SANS_11PT_REGULAR")

---@type FontEntry[]? nil until probed.
local available = nil
---@type table<string, FontEntry>
local availableByID = {}
-- What id.Font gives for a font that doesn't exist (see MISSING_FONT_NAME).
local missingFont = nil

--- A font handle by name, or nil if there's no such font.
---@param name string
---@return integer?
local function lookup(name)
    local font = gameApi.Font(name)
    if font == nil or font == missingFont then return nil end
    return font
end

--- A family's font in a style and size. Names come as both
--- MUSEO_SANS_11PT_REGULAR and NOTO_SANS_09PT_REGULAR.
---@return integer? handle
local function findFont(family, style, size)
    return lookup(string.format("%s_%dPT_%s", family.prefix, size, style.suffix))
        or lookup(string.format("%s_%02dPT_%s", family.prefix, size, style.suffix))
end

--- Builds the list of fonts that exist.
local function probe()
    available = {}
    missingFont = gameApi.Font(MISSING_FONT_NAME)
    for _, family in ipairs(FAMILIES) do
        for _, style in ipairs(STYLES) do
            local entry = {
                id = family.id .. "_" .. style.id,
                label = family.label .. style.label,
                sizes = {},
                handles = {},
            }
            for size = MIN_SIZE, MAX_SIZE do
                local font = findFont(family, style, size)
                if font ~= nil then
                    entry.sizes[#entry.sizes + 1] = size
                    entry.handles[size] = font
                end
            end
            if #entry.sizes > 0 then
                available[#available + 1] = entry
                availableByID[entry.id] = entry
            end
        end
    end
end

--- Every font that exists, probing on first use.
---@return FontEntry[]
function fontCatalogue.List()
    if available == nil then probe() end
    return available
end

--- A font by id, probing on first use.
---@param fontID string?
---@return FontEntry? entry nil if it doesn't exist.
function fontCatalogue.Get(fontID)
    if available == nil then probe() end
    return availableByID[fontID]
end

--- The size closest to `size` that a font has.
---@param fontID string
---@param size integer
---@return integer size `size` itself if the font doesn't exist.
function fontCatalogue.NearestSize(fontID, size)
    local entry = fontCatalogue.Get(fontID)
    if entry == nil then return size end
    local best = entry.sizes[1]
    for _, candidate in ipairs(entry.sizes) do
        if math.abs(candidate - size) < math.abs(best - size) then best = candidate end
    end
    return best
end

-- Game reads for Measure, through gameApi.Read. id.Font values are ids, so
-- measuring needs the font's config.
local function fontConfig(handle) return config.Font.FromID(handle) end
local function lineWidth(font, text) return font:GetStringWidth(text) end
local function textWidth(font, text, wrapWidth) return font:GetStringWidthMultiline(text, wrapWidth) end
local function textHeight(font, text, wrapWidth)
    return (font:GetStringHeightAndLineCount(text, wrapWidth, font.baseline))
end
-- Handle to its config, or false if it can't be read.
local configs = {}
-- Handle to one line's height, so text that fits on one line needs only its
-- width measured.
local lineHeights = {}

--- The size of text drawn in a font, wrapped at a width.
---@param handle integer A font handle (from Resolve).
---@param text string
---@param wrapWidth number Pixels.
---@return number? width The widest line; nil if the font can't be read.
---@return number? height All lines.
function fontCatalogue.Measure(handle, text, wrapWidth)
    local font = configs[handle]
    if font == nil then
        font = gameApi.Read("a font's config", fontConfig, handle) or false
        configs[handle] = font
    end
    if not font then return nil end
    -- The unwrapped width says whether it wraps at all (the wrapped width
    -- never exceeds wrapWidth, so it can't tell).
    local width = gameApi.Read("a text's width", lineWidth, font, text)
    if width == nil then return nil end
    local height
    if width <= wrapWidth then
        height = lineHeights[handle]
        if height == nil then
            height = gameApi.Read("a text's height", textHeight, font, ONE_LINE_SAMPLE, wrapWidth)
            lineHeights[handle] = height
        end
    else
        width = gameApi.Read("a text's width", textWidth, font, text, wrapWidth)
        height = gameApi.Read("a text's height", textHeight, font, text, wrapWidth)
    end
    if width == nil or height == nil then return nil end
    return width, height
end

--- The font handle to draw with: the nearest size the font has, falling
--- back to the default font, then to Museo Sans 11.
---@param fontID string?
---@param size integer? nil for DEFAULT_SIZE.
---@return integer handle
function fontCatalogue.Resolve(fontID, size)
    local entry = fontCatalogue.Get(fontID) or fontCatalogue.Get(fontCatalogue.DEFAULT_FONT)
    if entry == nil then return FALLBACK end
    return entry.handles[fontCatalogue.NearestSize(entry.id, size or fontCatalogue.DEFAULT_SIZE)] or FALLBACK
end

return fontCatalogue
