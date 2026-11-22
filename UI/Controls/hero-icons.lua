-- Heroicons for window actions, loaded from this plugin's bundled images.

local gameApi = require("GameData/game-api")
local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local uiConstants = require("UI/ui-constants")

local heroIcons = {}

---@class HeroButtonOptions
---@field x number?
---@field y number?
---@field xAnchor number?
---@field width number?
---@field height number?
---@field text string? A label beside the icon.
---@field tooltip string?
---@field colour integer?

local ICON_SIZE = 16
local INSET = 6
local TEXT_COLOUR = 0xE7D7B0FF
-- Where the images are: resources/HeroIcons/HeroIcons_<name>.png, with
-- the name's dashes as underscores.
local IMAGE_FOLDER = "HeroIcons"
local IMAGE_PREFIX = "HeroIcons_"

--- A Heroicon's image.
---@param name string Heroicons' name for it ("folder-plus").
---@return userdata? image
local function heroImage(name)
    return gameApi.ResourceImage(IMAGE_FOLDER, IMAGE_PREFIX .. name:gsub("-", "_"))
end

--- Shows a Heroicon in a sprite, tintable, letting mouse input through.
---@param sprite userdata
---@param name string Heroicons filename without its extension.
---@return userdata sprite
local function showIcon(sprite, name)
    local image = heroImage(name)
    if image ~= nil then
        sprite.sprite = image
    end

    sprite.rgba = TEXT_COLOUR
    sprite.clickthrough = true
    return sprite
end

--- Creates a tintable icon that lets mouse input through.
---@param parent userdata Not part of a PrettyUI control.
---@param name string Heroicons filename without its extension.
---@return userdata sprite
function heroIcons.Sprite(parent, name)
    return showIcon(ui.Sprite.new(parent), name)
end

--- Adds a PrettyUI button with a Heroicon and an optional text label.
---@param prettyUI table
---@param parent userdata
---@param name string
---@param onClick fun()
---@param options HeroButtonOptions
---@return userdata root Destroying the parent also destroys the button.
function heroIcons.Button(prettyUI, parent, name, onClick, options)
    local width = options.width or uiConstants.BUTTON_SIZE
    local height = options.height or uiConstants.BUTTON_SIZE
    local content = options.text or gameApi.Sprite("RS3_ICON_ACTION_16PX_2")
    local colour = options.colour or TEXT_COLOUR
    local button = prettyUI.SimpleButton.new(parent, content, onClick, {
        x = options.x or 0,
        y = options.y or 0,
        xAnchor = options.xAnchor or 0,
        width = width,
        height = height,
        iconSize = ICON_SIZE,
        colour = colour,
        tooltip = options.tooltip,
    })

    if options.text ~= nil then
        local maxTextWidth = width - INSET - ICON_SIZE - INSET - INSET
        local textWidth = fontCatalogue.Measure(button.content.font, options.text, width) or maxTextWidth
        local iconX = math.max(INSET, (width - ICON_SIZE - INSET - textWidth) // 2)

        -- Made through PrettyUI, inside its button: a plain component there
        -- can take an id the button's parts use, and crash the client.
        -- A PrettyUI without NewComponent (before 1.3) only makes plain ones.
        local newComponent = prettyUI.NewComponent
        local sprite = newComponent ~= nil and newComponent(ui.Sprite, button.root) or ui.Sprite.new(button.root)
        local icon = showIcon(sprite, name)
        icon:SetPos(iconX, (height - ICON_SIZE) // 2)
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon.rgba = colour

        local labelX = iconX + ICON_SIZE + INSET
        button.content:SetPos(labelX, 0)
        button.content:SetSize(math.min(textWidth, width - labelX - INSET), height)
        button.content.clickthrough = true
    else
        local image = heroImage(name)
        if image ~= nil then
            button.content.sprite = image
        end

        button.content.rgba = colour
    end

    return button.root
end

--- Adds a Heroicon button to a view's layout, inline after the control
--- before it, through the view's AddSimpleButton (so it's placed and
--- shifted as the view's other controls are), centred on that row.
---@param view table A view with AddSimpleButton (an EditorView).
---@param name string
---@param onClick fun()
---@param options { x: number, xAnchor: number?, rowHeight: number, tooltip: string?, colour: integer? }
---@return table? button
function heroIcons.AddInline(view, name, onClick, options)
    local size = uiConstants.BUTTON_SIZE
    local colour = options.colour or TEXT_COLOUR
    local button = view:AddSimpleButton(gameApi.Sprite("RS3_ICON_ACTION_16PX_2"), onClick, {
        inline = true,
        x = options.x,
        xAnchor = options.xAnchor or 0,
        width = size,
        height = size,
        offsetY = (options.rowHeight - size) // 2,
        iconSize = ICON_SIZE,
        colour = colour,
        tooltip = options.tooltip,
    })
    -- The image is ours, so it's set from here (PrettyUI can't assign it).
    local image = heroImage(name)
    local content = type(button) == "table" and button.content or nil
    if content ~= nil and image ~= nil then
        content.sprite = image
        content.rgba = colour
    end

    return button
end

return heroIcons
