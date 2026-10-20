-- Fonts an aura's text can use. The client doesn't publish a font list, so
-- this probes id.Font for the families and sizes that exist.
-- Usage: local fonts = require("Auras/Helpers/fonts")

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
local FALLBACK = id.Font.MUSEO_SANS_11PT_REGULAR

-- Each entry: { id, label, sizes = { ascending }, handles = { [size] = font } }
local available = nil
local availableByID = {}

local function rawLookup(name)
    local found, font = pcall(function() return id.Font[name] end)
    return found and font or nil
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

function fonts.Resolve(fontID, size)
    local entry = fonts.Get(fontID) or fonts.Get(fonts.DEFAULT_FONT)
    if entry == nil then return FALLBACK end
    return entry.handles[fonts.NearestSize(entry.id, size or fonts.DEFAULT_SIZE)] or FALLBACK
end

return fonts
