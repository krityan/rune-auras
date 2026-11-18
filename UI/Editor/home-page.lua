-- The editor's home page, shown while no aura is selected: a welcome, how to
-- get started, where to find examples and help, and what display types,
-- data sources, groups, conditions and load conditions are. Each paragraph
-- is a plain text in the scroll view's content, wrapped to the page's width
-- and placed by its measured height, with one spacer giving the view the
-- page's height to scroll through.

local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local gameApi = require("GameData/game-api")
local uiConstants = require("UI/ui-constants")

local homePage = {}

---@alias HomeBlockKind "title"|"heading"|"subheading"|"text"|"bullet"|"subbullet"

---@class HomeStyle
---@field font string A font-catalogue id.
---@field size integer Point size: one Museo Sans has (11 regular only; 13, 15, 17, 19, 21, 24), as another snaps to the nearest and levels can end up the same size.
---@field rgba integer
---@field gapBefore integer Pixels above it.
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
-- Room kept clear of the bottom, so the last line isn't against the edge.
local BOTTOM_MARGIN = 16
-- A character's width as a share of its point size, roughly: for working
-- out how many fit on a line when the font can't be measured.
local CHAR_WIDTH_PER_SIZE = 0.5

---@type table<HomeBlockKind, HomeStyle>
local STYLES = {
    title = { font = "museo_sans_bold", size = 19, rgba = uiConstants.ACCENT_RGBA, gapBefore = 0, indent = 0 },
    heading = { font = "museo_sans_bold", size = 17, rgba = uiConstants.ACCENT_RGBA, gapBefore = 18, indent = 0 },
    subheading = { font = "museo_sans_bold", size = 15, rgba = SUBHEADING_RGBA, gapBefore = 12, indent = 0 },
    text = { font = "museo_sans_regular", size = 13, rgba = BODY_RGBA, gapBefore = 6, indent = 0 },
    bullet = { font = "museo_sans_regular", size = 13, rgba = BODY_RGBA, gapBefore = 2, indent = 8, bullet = true },
    subbullet = { font = "museo_sans_regular", size = 13, rgba = BODY_RGBA, gapBefore = 2, indent = 24, bullet = true },
}

-- The page, top to bottom: each block's kind and text. It's regenerated
-- whole from the page's source text, so don't edit it by hand.
local PAGE = {
    { "title", "Welcome to RuneAuras" },

    { "heading", "Getting Started" },
    { "bullet", "Click new (in the top left)" },
    { "bullet", "Pick a display type (icon, bar, etc.)" },
    { "bullet", "Choose what data to display" },

    { "heading", "Need Inspiration?" },
    { "text", "To see some examples, hit the import button and pick from one of the included examples. "
        .. "Whether you want buff bars that exclusively show your consumables or simply a customisable "
        .. "adrenaline bar, examples can get you started." },

    { "heading", "Help/Feedback" },
    { "text", "The best place to get help or give feedback is in the RuneScape Plugin Portal discord, search "
        .. "the plugin forum for \"RuneAuras\" to find the thread for this specific plugin." },

    { "heading", "Concepts" },

    { "subheading", "Display Types" },
    { "text", "Display types are how you want to show the data, whether that be an icon with a radial swipe, "
        .. "or a bar counting down. All display types work for all data, so pick the one that works for "
        .. "you!" },
    { "text", "Currently Supported:" },
    { "bullet", "Icon" },
    { "bullet", "Bar" },
    { "bullet", "Segmented Bar" },
    { "bullet", "Orb" },
    { "bullet", "Text" },

    { "subheading", "Data Sources" },
    { "text", "A data source is what you are displaying via your chosen display type, this could be a "
        .. "resource like adrenaline, a buff, or even the special attack cooldown of your currently "
        .. "equipped weapon." },
    { "text", "Currently Supported:" },
    { "bullet", "Player" },
    { "subbullet", "Lifepoints" },
    { "subbullet", "Adrenaline" },
    { "subbullet", "Prayer Points" },
    { "subbullet", "Summoning Points" },
    { "subbullet", "Autocast Spell" },
    { "bullet", "Target" },
    { "subbullet", "Health" },
    { "bullet", "Buff" },
    { "bullet", "Debuff" },
    { "bullet", "Target Debuff" },
    { "subbullet", "Ability" },
    { "subbullet", "Hexes" },
    { "bullet", "Ability Cooldown" },
    { "bullet", "Special Attack Cooldown" },
    { "bullet", "Channel" },
    { "bullet", "Stalled Ability" },
    { "bullet", "Extra Action Button" },

    { "subheading", "Groups" },
    { "text", "Groups are nestable groups of auras, they offer some shared customisation of auras within the "
        .. "group such as position on screen and whether or not to show them (see load conditions below)." },

    { "subheading", "Dynamic groups" },
    { "text", "Dynamic groups are groups that grow dynamically rather than each aura having a fixed location. "
        .. "An example of this would be the ingame buff bar." },

    { "subheading", "Conditions" },
    { "text", "Conditions allow you to change some display options in response to a condition such as, do I "
        .. "have enough adrenaline to cast this ability?" },
    { "text", "An example of a condition would be changing your adrenaline bar to be red when you have 4 or "
        .. "more bloodlust stacks, just like the ingame adrenaline bar." },
    { "text", "Conditions are made up of checks and changes, with checks defining the condition that must be "
        .. "met for the changes to take effect." },

    { "subheading", "Load Conditions" },
    { "text", "Load conditions offer options to enable or disable your aura/group based on data not directly "
        .. "available to an aura, such as a certain weapon being equipped. You can also configure checks "
        .. "in the same way as conditions if you need more customisation." },
}

--- How tall a text is, wrapped at a width: measured in its font, or worked
--- out roughly from its length if the font can't be read.
---@param handle integer A font handle.
---@param style HomeStyle
---@param text string
---@param width number
---@return number
local function textHeight(handle, style, text, width)
    local _, measured = fontCatalogue.Measure(handle, text, width)
    if measured ~= nil then return measured end
    local charsPerLine = math.max(1, width / (style.size * CHAR_WIDTH_PER_SIZE))
    return math.ceil(#text / charsPerLine) * fontCatalogue.LineHeight(style.size)
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
---@param style HomeStyle
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

--- Adds one block as a text in the content at a height, wrapped at the
--- page's width; a bullet has its gold dot before it, or a dash if the
--- dot's image isn't loaded.
---@param content userdata
---@param style HomeStyle
---@param text string
---@param x number
---@param y number
---@param width number
---@param bulletImage userdata? The dot's image; nil if it isn't loaded.
---@return number height
local function addBlock(content, style, text, x, y, width, bulletImage)
    local handle = fontCatalogue.Resolve(style.font, style.size)
    local left = x + style.indent
    local shown = text
    if style.bullet and bulletImage ~= nil then
        addBulletDot(content, handle, style, bulletImage, left, y, width)
        left = left + BULLET_ROOM
    elseif style.bullet then
        shown = BULLET_MARK .. text
    end
    local blockWidth = width - (left - x)
    local height = textHeight(handle, style, shown, blockWidth)
    local component = ui.Text.new(content)
    -- Font first: assigning a font resets the colour.
    component.font = handle
    component.rgba = style.rgba
    component.maxLines = 0
    component.alignHorizontal = ui.AlignMode.TOPLEFT
    component.alignVertical = ui.AlignMode.TOPLEFT
    component.clickthrough = true
    component.content = shown
    component:SetPos(left, y)
    component:SetSize(blockWidth, height)
    return height
end

--- Fills a scroll view with the page: its texts, then a spacer as tall as
--- them, so the view scrolls through the whole page.
---@param view table A PrettyUI SimpleView, laid out from `startY`.
---@param x number Where the page's left edge is in the view's content.
---@param startY number Where the view's first row is.
---@param width number The page's width.
function homePage.Add(view, x, startY, width)
    local y = startY
    local bulletImage = gameApi.ResourceImage(BULLET_FOLDER, BULLET_NAME)
    for index, block in ipairs(PAGE) do
        local style = STYLES[block[1]]
        if index > 1 then y = y + style.gapBefore end
        y = y + addBlock(view.content, style, block[2], x, y, width, bulletImage)
    end
    view:AddText({ text = "", height = y - startY + BOTTOM_MARGIN })
end

return homePage
