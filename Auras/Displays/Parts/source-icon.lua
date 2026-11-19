-- A data source's icon, drawn beside something else (a bar's icon): a
-- sprite id or one of our images (a source's iconImage), or an item (a
-- source's iconObject), which isn't a plain sprite and is drawn by a sprite
-- of its own set from the object.
--
-- Wherever an icon is passed as `spriteID` it may be either a game sprite
-- id or an image (see dataSources.IsImageIcon). An image draws nothing on a
-- sprite still 0 by 0, so it's assigned (again) once the sprite is sized.

local dataSources = require("Auras/Registries/data-sources")
local gameApi = require("GameData/game-api")

-- The quantity an item is drawn at: stackable items (arrows, runes) pick
-- their icon by quantity, and one shows a single arrow where the game's
-- buff bar shows a bundle.
local STACK_QUANTITY = 1000

---@class SourceIcon
---@field sprite userdata Draws a sprite id or image.
---@field objectSprite userdata Draws an item's icon.
---@field spriteID integer|userdata? A sprite id or an image.
---@field objectID integer?
---@field hidden boolean
local SourceIcon = {}
SourceIcon.__index = SourceIcon

local function setImage(sprite, image) sprite.sprite = image end

--- Shows an icon on a sprite: a game sprite id, or one of our images
--- (guarded, as an image may not be loaded yet). Size the sprite first.
---@param sprite userdata
---@param icon integer|userdata? nil does nothing.
function SourceIcon.ShowSprite(sprite, icon)
    if icon == nil then return end
    if dataSources.IsImageIcon(icon) then
        gameApi.Read("an icon image", setImage, sprite, icon)
    else
        sprite.spriteID = icon
    end
end

--- Draws an item's icon on a sprite. It takes the object id alone, as a
--- whole number: the binding has no form with a quantity as well (sol
--- reported "no matching function call" for SetAssociatedObject(id, 1)).
--- The quantity label is hidden after, as setting the object may reset it.
---@param sprite userdata
---@param objectID integer
local function showObject(sprite, objectID)
    sprite:SetAssociatedObject(objectID)
    sprite.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
end

--- Draws an item as a stack (see STACK_QUANTITY).
---@param sprite userdata
local function showAsStack(sprite)
    sprite.associatedObjectQuantity = STACK_QUANTITY
end

--- Sets any sprite to an item's icon. The id comes from game config, so the
--- call is guarded: a bad one leaves the sprite blank (and logs once)
--- rather than breaking drawing.
---@param sprite userdata
---@param objectID number? nil does nothing.
function SourceIcon.ShowObject(sprite, objectID)
    objectID = objectID ~= nil and math.tointeger(objectID) or nil
    if objectID == nil then return end
    gameApi.Read("an item icon", showObject, sprite, objectID)
    -- Apart, so the icon still shows if the quantity can't be set.
    gameApi.Read("an item icon's quantity", showAsStack, sprite)
end

--- A hidden sprite that lets clicks through.
---@param parent userdata
---@return userdata
local function newSprite(parent)
    local sprite = ui.Sprite.new(parent)
    sprite.clickthrough = true
    sprite.hidden = true
    return sprite
end

--- A single square sprite showing an icon that's drawn once and never
--- changes (the aura list's, the editor header's), where SourceIcon's pair
--- would cost a component more. Sized before the icon is set, for an image.
---@param parent userdata
---@param spriteID integer|userdata? A sprite id or an image.
---@param objectID integer? An item, shown when there's no sprite id.
---@param size number
---@return userdata? sprite nil when there's nothing to show.
function SourceIcon.NewStill(parent, spriteID, objectID, size)
    if spriteID == nil and objectID == nil then return nil end
    local sprite = ui.Sprite.new(parent)
    sprite.clickthrough = true
    sprite:SetSize(size, size)
    if spriteID ~= nil then
        SourceIcon.ShowSprite(sprite, spriteID)
    else
        SourceIcon.ShowObject(sprite, objectID)
    end
    return sprite
end

--- Creates an empty icon (two components).
---@param parent userdata
---@return SourceIcon
function SourceIcon.new(parent)
    local self = setmetatable({}, SourceIcon)
    self.sprite = newSprite(parent)
    self.objectSprite = newSprite(parent)
    self.hidden = false
    return self
end

--- Places the icon as a square.
---@param x number
---@param y number
---@param size number
function SourceIcon:Layout(x, y, size)
    self.sprite:SetPos(x, y)
    self.sprite:SetSize(size, size)
    self.objectSprite:SetPos(x, y)
    self.objectSprite:SetSize(size, size)
    -- An image assigned while the sprite was 0 by 0 draws nothing.
    if dataSources.IsImageIcon(self.spriteID) then SourceIcon.ShowSprite(self.sprite, self.spriteID) end
end

--- Shows a sprite, or an item when there's no sprite. Only does anything
--- when the icon changes, so it can be called every frame.
---@param spriteID integer|userdata? A sprite id or an image.
---@param objectID integer?
function SourceIcon:Set(spriteID, objectID)
    if spriteID == self.spriteID and objectID == self.objectID then return end
    self.spriteID = spriteID
    SourceIcon.ShowSprite(self.sprite, spriteID)
    if objectID ~= self.objectID then
        self.objectID = objectID
        SourceIcon.ShowObject(self.objectSprite, objectID)
    end
    self:SetHidden(self.hidden)
end

--- Hides or shows the icon; with nothing to show it stays hidden.
---@param hidden boolean
function SourceIcon:SetHidden(hidden)
    self.hidden = hidden
    self.sprite.hidden = hidden or self.spriteID == nil
    self.objectSprite.hidden = hidden or self.spriteID ~= nil or self.objectID == nil
end

return SourceIcon
