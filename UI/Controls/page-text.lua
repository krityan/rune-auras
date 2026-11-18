-- Page text: the styled blocks the editor's home page and the New panel are
-- written in (a title, headings, body text and gold-dot bullets), each a
-- plain text placed in a view's content, wrapped to a width and measured,
-- so a page can be laid out block by block.

local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local gameApi = require("GameData/game-api")
local uiConstants = require("UI/ui-constants")

local pageText = {}

---@alias PageBlockKind "title"|"heading"|"subheading"|"text"|"bullet"|"subbullet"

---@class PageStyle
---@field font string A font-catalogue id.
---@field size integer Point size: one Museo Sans has (11 regular only; 13, 15, 17, 19, 21, 24), as another snaps to the nearest and levels can end up the same size.
---@field rgba integer
---@field gapBefore integer Pixels above it, after another block.
---@field indent integer Pixels in from the left.
---@field bullet boolean? Starts with a gold dot (see BULLET_NAME).

local BODY_RGBA = 0xD8D0C0FF
local SUBHEADING_RGBA = 0xE7D7B0FF
-- A bullet's dot (resources/Shapes/bullet.png, gold as the headings: an
-- image of ours draws untinted), its size and the room it takes before the
-- text. The game's text has no bullet character, so without the image (it
-- loads after a plugin refresh) a bullet starts with BULLET_MARK instead.
local BULLET_FOLDER, BULLET_NAME = "Shapes", "bullet"
local BULLET_SIZE = 6
local BULLET_ROOM = 14
local BULLET_MARK = "- "
-- Measured for the height of one line, to centre a bullet's dot on it.
local ONE_LINE = "X"
-- A character's width as a share of its point size, roughly: for working
-- out how many fit on a line when the font can't be measured.
local CHAR_WIDTH_PER_SIZE = 0.5
-- A wrap width no line reaches, for measuring a line unwrapped.
local UNWRAPPED_WIDTH = 100000

---@type table<PageBlockKind, PageStyle>
local STYLES = {
    title = { font = "museo_sans_bold", size = 19, rgba = uiConstants.ACCENT_RGBA, gapBefore = 0, indent = 0 },
    heading = { font = "museo_sans_bold", size = 17, rgba = uiConstants.ACCENT_RGBA, gapBefore = 18, indent = 0 },
    subheading = { font = "museo_sans_bold", size = 15, rgba = SUBHEADING_RGBA, gapBefore = 12, indent = 0 },
    text = { font = "museo_sans_regular", size = 13, rgba = BODY_RGBA, gapBefore = 6, indent = 0 },
    bullet = { font = "museo_sans_regular", size = 13, rgba = BODY_RGBA, gapBefore = 2, indent = 8, bullet = true },
    subbullet = { font = "museo_sans_regular", size = 13, rgba = BODY_RGBA, gapBefore = 2, indent = 24, bullet = true },
}

--- The space a kind of block leaves above itself, after another block.
---@param kind PageBlockKind
---@return integer
function pageText.GapBefore(kind)
    return STYLES[kind].gapBefore
end

--- How tall a text is in a style, wrapped at a width: measured in its font,
--- or worked out roughly from its length if the font can't be read.
---@param handle integer A font handle.
---@param style PageStyle
---@param text string
---@param width number
---@return number
local function textHeight(handle, style, text, width)
    local _, measured = fontCatalogue.Measure(handle, text, width)
    if measured ~= nil then return measured end
    local charsPerLine = math.max(1, width / (style.size * CHAR_WIDTH_PER_SIZE))
    return math.ceil(#text / charsPerLine) * fontCatalogue.LineHeight(style.size)
end

--- How wide a line of text is in a kind's font, for placing something
--- after it on the same line.
---@param kind PageBlockKind
---@param text string
---@return number? width nil if the font can't be read.
function pageText.Width(kind, text)
    local style = STYLES[kind]
    local handle = fontCatalogue.Resolve(style.font, style.size)
    local width = fontCatalogue.Measure(handle, text, UNWRAPPED_WIDTH)
    return width
end

--- How tall a block of text would be, wrapped at a width (a bullet's text
--- less its dot's room), for placing it before adding it.
---@param kind PageBlockKind
---@param text string
---@param width number
---@return number
function pageText.Height(kind, text, width)
    local style = STYLES[kind]
    local handle = fontCatalogue.Resolve(style.font, style.size)
    local textWidth = width - style.indent - (style.bullet and BULLET_ROOM or 0)
    return textHeight(handle, style, text, textWidth)
end

--- Sets a sprite to one of the plugin's images.
---@param sprite userdata
---@param image userdata
local function setSpriteImage(sprite, image)
    sprite.sprite = image
end

--- Adds a bullet's gold dot, level with the middle of its text's first line.
---@param content userdata
---@param handle integer The text's font handle.
---@param style PageStyle
---@param image userdata The dot's image.
---@param x number
---@param y number The text's top.
---@param width number
local function addBulletDot(content, handle, style, image, x, y, width)
    local _, lineHeight = fontCatalogue.Measure(handle, ONE_LINE, width)
    lineHeight = lineHeight or fontCatalogue.LineHeight(style.size)
    local dot = ui.Sprite.new(content)
    dot.clickthrough = true
    dot:SetPos(x, y + (lineHeight - BULLET_SIZE) / 2)
    -- Sized first: an image assigned at 0 by 0 draws nothing.
    dot:SetSize(BULLET_SIZE, BULLET_SIZE)
    pcall(setSpriteImage, dot, image)
end

--- A wrapping text in the content, left-aligned, letting the mouse through
--- (so a scroll view under it still scrolls), not yet placed or sized.
---@param content userdata
---@param handle integer A font handle.
---@param rgba integer
---@param text string
---@param alignVertical integer A ui.AlignMode.
---@return userdata
local function newText(content, handle, rgba, text, alignVertical)
    local component = ui.Text.new(content)
    -- Font first: assigning a font resets the colour.
    component.font = handle
    component.rgba = rgba
    component.maxLines = 0
    component.alignHorizontal = ui.AlignMode.TOPLEFT
    component.alignVertical = alignVertical
    component.clickthrough = true
    component.content = text
    return component
end

--- Adds a block of text to a view's content at a point, wrapped at a width;
--- a bullet has its gold dot before it, or a dash if the dot's image isn't
--- loaded. It lets the mouse through, so a scroll view under it still scrolls.
---@param content userdata
---@param kind PageBlockKind
---@param text string
---@param x number
---@param y number
---@param width number
---@param rgba integer? A colour in place of the kind's (a link's).
---@return number height
---@return userdata component The text, for a caller that makes it clickable.
function pageText.Add(content, kind, text, x, y, width, rgba)
    local style = STYLES[kind]
    local handle = fontCatalogue.Resolve(style.font, style.size)
    local left = x + style.indent
    local shown = text
    local bulletImage = style.bullet and gameApi.ResourceImage(BULLET_FOLDER, BULLET_NAME) or nil
    if bulletImage ~= nil then
        addBulletDot(content, handle, style, bulletImage, left, y, width)
        left = left + BULLET_ROOM
    elseif style.bullet then
        shown = BULLET_MARK .. text
    end
    local blockWidth = width - (left - x)
    local height = textHeight(handle, style, shown, blockWidth)
    local component = newText(content, handle, rgba or style.rgba, shown, ui.AlignMode.TOPLEFT)
    component:SetPos(left, y)
    component:SetSize(blockWidth, height)
    return height, component
end

--- Adds a block of text centred up and down in a box (a description beside
--- a button of that height), which the client centres as it draws it, so
--- it sits right whatever its lines measure. Not for bullets.
---@param content userdata
---@param kind PageBlockKind
---@param text string
---@param x number
---@param y number The box's top.
---@param width number
---@param height number The box's height.
---@return userdata component
function pageText.AddCentred(content, kind, text, x, y, width, height)
    local style = STYLES[kind]
    local handle = fontCatalogue.Resolve(style.font, style.size)
    local component = newText(content, handle, style.rgba, text, ui.AlignMode.CENTRE)
    component:SetPos(x + style.indent, y)
    component:SetSize(width - style.indent, height)
    return component
end

return pageText
