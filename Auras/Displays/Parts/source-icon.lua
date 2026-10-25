-- A data source's icon, drawn beside something else (a bar's icon): a
-- sprite id, or an item (a source's iconObject), which isn't a plain sprite
-- and is drawn by a sprite of its own set from the object.

local gameApi = require("GameData/game-api")

---@class SourceIcon
---@field sprite userdata Draws a sprite id.
---@field objectSprite userdata Draws an item's icon.
---@field spriteID integer?
---@field objectID integer?
---@field hidden boolean
local SourceIcon = {}
SourceIcon.__index = SourceIcon

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

--- Sets any sprite to an item's icon. The id comes from game config, so the
--- call is guarded: a bad one leaves the sprite blank (and logs once)
--- rather than breaking drawing.
---@param sprite userdata
---@param objectID number? nil does nothing.
function SourceIcon.ShowObject(sprite, objectID)
    objectID = objectID ~= nil and math.tointeger(objectID) or nil
    if objectID ~= nil then gameApi.Read("an item icon", showObject, sprite, objectID) end
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
end

--- Shows a sprite, or an item when there's no sprite. Only does anything
--- when the icon changes, so it can be called every frame.
---@param spriteID integer?
---@param objectID integer?
function SourceIcon:Set(spriteID, objectID)
    if spriteID == self.spriteID and objectID == self.objectID then return end
    self.spriteID = spriteID
    if spriteID ~= nil then self.sprite.spriteID = spriteID end
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
