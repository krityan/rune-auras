-- A data source's icon, drawn beside something else (the bar's icon): a
-- sprite id, or an item (a source's iconObject), which isn't a plain sprite
-- and is drawn by a sprite of its own set from the object.
-- Usage:
--   local SourceIcon = require("Auras/Displays/source-icon")
--   local icon = SourceIcon.new(parent)
--   icon:Layout(x, y, size)
--   icon:Set(spriteID, objectID)   -- either may be nil
--   icon:SetHidden(hidden)
--   SourceIcon.ShowObject(sprite, objectID)   -- sets any sprite to an item

local gameApi = require("GameData/game-api")

local SourceIcon = {}
SourceIcon.__index = SourceIcon

-- Draws an item's icon on a sprite. It takes the object id alone, as a
-- whole number: the binding has no form with a quantity as well (sol
-- reported "no matching function call" for SetAssociatedObject(id, 1)).
-- The quantity label is hidden after, as setting the object may reset it.
local function showObject(sprite, objectID)
    sprite:SetAssociatedObject(objectID)
    sprite.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
end

-- The id comes from game config, so the call is guarded: a bad one leaves
-- the sprite blank (and logs once) rather than breaking drawing.
function SourceIcon.ShowObject(sprite, objectID)
    objectID = objectID ~= nil and math.tointeger(objectID) or nil
    if objectID ~= nil then gameApi.Read("an item icon", showObject, sprite, objectID) end
end

local function newSprite(parent)
    local sprite = ui.Sprite.new(parent)
    sprite.clickthrough = true
    sprite.hidden = true
    return sprite
end

function SourceIcon.new(parent)
    local self = setmetatable({}, SourceIcon)
    self.sprite = newSprite(parent)
    self.objectSprite = newSprite(parent)
    self.hidden = false
    return self
end

function SourceIcon:Layout(x, y, size)
    for _, sprite in ipairs({ self.sprite, self.objectSprite }) do
        sprite:SetPos(x, y)
        sprite:SetSize(size, size)
    end
end

-- Only does anything when the icon changes, so it can be called every frame.
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

function SourceIcon:SetHidden(hidden)
    self.hidden = hidden
    self.sprite.hidden = hidden or self.spriteID == nil
    self.objectSprite.hidden = hidden or self.spriteID ~= nil or self.objectID == nil
end

return SourceIcon
