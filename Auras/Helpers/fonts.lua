-- Fonts an aura's text can use. The client doesn't publish a font list, so
-- this probes id.Font for the families and sizes that exist.
-- Usage: local fonts = require("Auras/Helpers/fonts")

local gameApi = require("GameData/game-api")

local fonts = {}

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
local MIN_SIZE, MAX_SIZE = 6, 40

fonts.DEFAULT_FONT = "museo_sans_regular"
fonts.DEFAULT_SIZE = 11
-- Extra height around a font's point size so its glyphs aren't clipped.
local LINE_PADDING = 8

-- The height a line of text at this point size needs.
function fonts.LineHeight(size)
    return (size or fonts.DEFAULT_SIZE) + LINE_PADDING
end
local FALLBACK = gameApi.Font("MUSEO_SANS_11PT_REGULAR")

-- Each entry: { id, label, sizes = { ascending }, handles = { [size] = font } }
local available = nil
local availableByID = {}

local function rawLookup(name)
    return gameApi.Font(name)
end

-- id.Font answers even for names that don't exist, so anything equal to
-- what a made-up name returns counts as missing.
local missingFont = nil

local function lookup(name)
    local font = rawLookup(name)
    if font == nil or font == missingFont then return nil end
    return font
end

-- Font names come as both MUSEO_SANS_11PT_REGULAR and NOTO_SANS_09PT_REGULAR.
local function findFont(family, style, size)
    return lookup(string.format("%s_%dPT_%s", family.prefix, size, style.suffix))
        or lookup(string.format("%s_%02dPT_%s", family.prefix, size, style.suffix))
end

local function probe()
    available = {}
    missingFont = rawLookup("RUNE_AURAS_NOT_A_FONT")
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

function fonts.List()
    if available == nil then probe() end
    return available
end

function fonts.Get(fontID)
    if available == nil then probe() end
    return availableByID[fontID]
end

-- Returns the size closest to the one asked for that the font has.
function fonts.NearestSize(fontID, size)
    local entry = fonts.Get(fontID)
    if entry == nil then return size end
    local best = entry.sizes[1]
    for _, candidate in ipairs(entry.sizes) do
        if math.abs(candidate - size) < math.abs(best - size) then best = candidate end
    end
    return best
end

-- A font handle's config (id.Font values are ids), for measuring text.
local function fontConfig(handle) return config.Font.FromID(handle) end
local function lineWidth(font, text) return font:GetStringWidth(text) end
local function textWidth(font, text, wrapWidth) return font:GetStringWidthMultiline(text, wrapWidth) end
local function textHeight(font, text, wrapWidth)
    return (font:GetStringHeightAndLineCount(text, wrapWidth, font.baseline))
end
-- Handle -> its config, or false if it can't be read; and a single line's
-- height, so text that fits on one line needs only its width measured.
local configs = {}
local lineHeights = {}

-- The width of the widest line and the total height of `text` drawn with a
-- font handle (from Resolve), wrapped at wrapWidth pixels. nil if the font
-- can't be read.
function fonts.Measure(handle, text, wrapWidth)
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
            height = gameApi.Read("a text's height", textHeight, font, "X", wrapWidth)
            lineHeights[handle] = height
        end
    else
        width = gameApi.Read("a text's width", textWidth, font, text, wrapWidth)
        height = gameApi.Read("a text's height", textHeight, font, text, wrapWidth)
    end
    if width == nil or height == nil then return nil end
    return width, height
end

function fonts.Resolve(fontID, size)
    local entry = fonts.Get(fontID) or fonts.Get(fonts.DEFAULT_FONT)
    if entry == nil then return FALLBACK end
    return entry.handles[fonts.NearestSize(entry.id, size or fonts.DEFAULT_SIZE)] or FALLBACK
end

return fonts
