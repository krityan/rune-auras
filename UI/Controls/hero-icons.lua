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

--- Creates a tintable icon that lets mouse input through.
---@param parent userdata
---@param name string Heroicons filename without its extension.
---@return userdata sprite
function heroIcons.Sprite(parent, name)
    local sprite = ui.Sprite.new(parent)
    local image = gameApi.ResourceImage("HeroIcons", name)
    if image ~= nil then sprite.sprite = image end
    sprite.rgba = TEXT_COLOUR
    sprite.clickthrough = true
    return sprite
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
        local textWidth = fontCatalogue.Measure(button.content.font, options.text, width)
            or (width - INSET * 3 - ICON_SIZE)
        local iconX = math.max(INSET, (width - ICON_SIZE - INSET - textWidth) // 2)
        local icon = heroIcons.Sprite(button.root, name)
        icon:SetPos(iconX, (height - ICON_SIZE) // 2)
        icon:SetSize(ICON_SIZE, ICON_SIZE)
        icon.rgba = colour
        local labelX = iconX + ICON_SIZE + INSET
        button.content:SetPos(labelX, 0)
        button.content:SetSize(math.min(textWidth, width - labelX - INSET), height)
        button.content.clickthrough = true
    else
        local image = gameApi.ResourceImage("HeroIcons", name)
        if image ~= nil then button.content.sprite = image end
        button.content.rgba = colour
    end
    return button.root
end

return heroIcons
