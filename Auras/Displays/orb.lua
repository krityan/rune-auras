-- Orb display: a circle filled to curr/max, from the bottom up or as a
-- radial sweep from the top, with value texts (text nodes). Circles are a
-- white image of ours (resources/Shapes/circle.png) as a radial's mask,
-- tinted: the border is a ring, and the background a circle inset by its
-- thickness.

local dataSources = require("Auras/Registries/data-sources")
local placement = require("Auras/Displays/Parts/placement")
local radialFlags = require("Auras/Displays/Parts/radial-flags")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local TextNodes = require("Auras/Displays/Parts/text-nodes")
local gameApi = require("GameData/game-api")
local textTemplate = require("Auras/Helpers/text-template")
local maths = require("Auras/Helpers/maths")

local clamp = maths.Clamp

--- An orb aura's own options.
---@class OrbOptions: Aura
---@field fillStyle "vertical"|"radial"
---@field fillAnticlockwise boolean A radial fill's edge turns anticlockwise rather than clockwise.
---@field backgroundColour integer
---@field borderColour integer
---@field borderThickness integer
---@field invertFill boolean Fill as the value drops.
---@field smoothFill boolean Move the fill every frame for sources that extrapolate between server ticks.
---@field hideWhenEmpty boolean Hide while the value is 0, except while unlocked.
---@field showIcon boolean The source's icon in the middle, under the fill, which sweeps over it like the Icon display's swipe.
---@field dimWhileActive boolean Grey the icon while the value is above 0 (a buff: while inactive), as the Icon display does.

---@class Orb: Placed
---@field circle userdata? The circle image; nil until a plugin refresh loads it.
---@field frame userdata The border's ring (see ringFor and newCircle).
---@field background userdata
---@field clip userdata? A vertical fill's layer: as tall as the fill, so it shows that much of the circle in it.
---@field clipCircle userdata? The full circle the clip shows part of.
---@field radial userdata? A radial fill.
---@field startFlags table<userdata, integer> Each circle's Start flags, once masked and started (see shape).
---@field masks table<userdata, userdata> Each circle's mask image (see shape).
---@field icon SourceIcon? Made when first shown: square inside the circle, over the background and under the fill.
---@field greySprite userdata? The icon's grey copy, laid over it while dimmed; made when first needed.
---@field greyImage userdata? The image greySprite shows.
---@field iconGrey userdata? The icon's grey copy, if we ship one.
---@field iconSpriteID integer? The source's icon, from SetDetails.
---@field iconObjectID integer?
---@field partsMade boolean? A part was made or shown again, so the aura manager calls RaiseParts next frame.
---@field texts TextNodes
local Orb = {}
Orb.__index = Orb
placement.Mixin(Orb)
-- Its value texts are text nodes (see auraTexts.Ensure in Auras/Store/aura-texts).
Orb.usesTextNodes = true

Orb.defaults = {
    -- Kept equal; the editor offers a single size (see UI/Editor/Types/orb).
    width = 64,
    height = 64,
    fillStyle = "vertical",
    fillAnticlockwise = false,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000FF,
    borderThickness = 2,
    invertFill = false,
    smoothFill = false,
    hideWhenEmpty = false,
    showIcon = false,
    dimWhileActive = false,
}

Orb.FILL_STYLES = {
    { id = "vertical", label = "Vertical" },
    { id = "radial", label = "Radial" },
}

local MIN_SIZE, MAX_SIZE = 16, 256
local MAX_BORDER = 10
-- The border leaves at least this much orb inside it.
local MIN_INNER_SIZE = 4
-- Shared with the orb's editor controls (UI/Editor/Types/orb).
Orb.limits = { minSize = MIN_SIZE, maxSize = MAX_SIZE, maxBorder = MAX_BORDER }

local UNLOCKED_BACKGROUND_RGBA = placement.UNLOCKED_BACKGROUND_RGBA
-- A dimmed icon without a grey copy (an item, or a sprite we have none of)
-- is darkened instead, as the Icon display does.
local DIMMED_TINT = 0x6E6E6EFF
local NORMAL_TINT = 0xFFFFFFFF
-- The radial runs from 0 to 1. It draws what's left of the way round, so
-- curValue is the part not filled.
local RADIAL_END = 1

-- The border's rings (resources/Rings/ring_<k>.png): white rings whose
-- thickness is RING_BASE * RING_STEP^k of the image's width, k from 0.
local RING_BASE, RING_STEP, RING_COUNT = 0.004, 1.25, 22

local function setMaskImage(radial, image) radial.maskSprite.sprite = image end
local function setImage(sprite, image) sprite.sprite = image end

-- Whether the missing circle image has been reported.
local warnedNoCircle = false

--- A circle: a radial overlay masked with the circle image, all of it shown
--- (curValue 0). A plain sprite of our image draws untinted whatever its
--- rgba, but a radial tints its mask.
---@param parent userdata
---@return userdata
local function newCircle(parent)
    local circle = ui.RadialProgressOverlay.new(parent)
    circle.clickthrough = true
    return circle
end

--- Colours a circle. A radial takes rgba's colour but not its alpha byte,
--- which goes to its own alpha (0 to 1) instead.
---@param circle userdata
---@param rgba integer 0xRRGGBBAA.
local function tint(circle, rgba)
    circle.rgba = rgba
    circle.alpha = (rgba & 0xFF) / 0xFF
end

--- The ring closest to a border's thickness for an orb's size. A hole
--- can't be cut in a circle, so the border is a ring image, which a
--- see-through background shows through.
---@param thickness number
---@param size number
---@return userdata? image nil until a plugin refresh loads the rings.
local function ringFor(thickness, size)
    local step = math.log(thickness / size / RING_BASE) / math.log(RING_STEP)
    local index = clamp(math.floor(step + 0.5), 0, RING_COUNT - 1)
    return gameApi.ResourceImage("Rings", "ring_" .. index)
end

--- Shows or hides a part. One shown again loses its place in the stack
--- (it can drop behind the background), so the parts are put back in order
--- next frame (RaiseParts).
---@param part userdata
---@param shown boolean
function Orb:showPart(part, shown)
    local wasHidden = part.hidden == true
    part.hidden = not shown
    if shown and wasHidden then self.partsMade = true end
end

--- Masks a sized circle with an image and starts it with its Start flags,
--- again only if either changed: a mask assigned to a part still 0 by 0
--- draws nothing, and values written before Start are ignored.
---@param circle userdata
---@param flags integer
---@param image userdata? The mask; the circle image if nil.
function Orb:shape(circle, flags, image)
    image = image or self.circle
    if image == nil then return end
    if self.masks[circle] ~= image then
        if not pcall(setMaskImage, circle, image) then return end
        self.masks[circle] = image
        self.startFlags[circle] = nil
    end
    if self.startFlags[circle] == flags then return end
    circle:Start(0, RADIAL_END, flags)
    self.startFlags[circle] = flags
end

--- Creates an orb for an aura. The fill style's parts are made when first
--- used (the game has 4,096 interface parts in all). If the game
--- runs out of them partway (see the aura manager), the root goes, taking
--- whatever was made in it, and the error is raised again.
---@param parent userdata
---@param aura OrbOptions
---@param groupPoint GroupPoint?
---@return Orb
function Orb.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Orb)
    self.root = ui.Layer.new(parent)
    local ok, problem = pcall(function()
        self.circle = gameApi.ResourceImage("Shapes", "circle")
        if self.circle == nil and not warnedNoCircle then
            warnedNoCircle = true
            log("Rune Auras: orbs need resources/Shapes/circle.png; refresh the plugin (prf) to load it.")
        end
        self.startFlags, self.masks = {}, {}
        -- Made first, so it's behind: one made later would land on top.
        self.frame = newCircle(self.root)
        self.background = newCircle(self.root)
        -- Laid out on the orb, but drawn beside the root so they aren't
        -- clipped to it.
        self.texts = TextNodes.new(parent)
        self.overlay = self.texts
        self:bindDrag()
        self:Apply(aura)
    end)
    if not ok then
        self.root:Destroy()
        if self.texts ~= nil then self.texts:Destroy() end
        error(problem, 0)
    end
    return self
end

--- Sizes the orb, its border and background, and the fill's place inside
--- the border.
---@param aura OrbOptions
function Orb:layoutCircles(aura)
    local size = clamp(aura.width or Orb.defaults.width, MIN_SIZE, MAX_SIZE)
    self.width, self.height = size, size
    self.root:SetSize(size, size)
    local thickestBorder = math.min(MAX_BORDER, (size - MIN_INNER_SIZE) // 2)
    local border = clamp(aura.borderThickness or Orb.defaults.borderThickness, 0, thickestBorder)
    self.frame:SetSize(size, size)
    if border > 0 then self:shape(self.frame, 0, ringFor(border, size)) end
    tint(self.frame, aura.borderColour)
    self:showPart(self.frame, border > 0)
    self.inset, self.innerSize = border, size - border * 2
    self.background:SetPos(border, border)
    self.background:SetSize(self.innerSize, self.innerSize)
    self:shape(self.background, 0)
end

--- Sets up the fill style's parts, making them when first used and hiding
--- the other style's.
---@param aura OrbOptions
function Orb:applyFill(aura)
    self.fillStyle = aura.fillStyle == "radial" and "radial" or "vertical"
    local inset, inner = self.inset, self.innerSize
    local isRadial = self.fillStyle == "radial"
    if not isRadial and self.clip == nil then
        self.clip = ui.Layer.new(self.root)
        self.clip.clickthrough = true
        self.clipCircle = newCircle(self.clip)
    end
    if isRadial and self.radial == nil then
        self.radial = ui.RadialProgressOverlay.new(self.root)
        self.radial.clickthrough = true
    end
    if self.clip ~= nil then
        self:showPart(self.clip, not isRadial)
        self.clipCircle:SetSize(inner, inner)
        self:shape(self.clipCircle, 0)
        tint(self.clipCircle, aura.colour)
    end
    if self.radial ~= nil then
        self:showPart(self.radial, isRadial)
        self.radial:SetPos(inset, inset)
        self.radial:SetSize(inner, inner)
        tint(self.radial, aura.colour)
        -- The direction is a Start flag. Its value is written to curValue, so
        -- it isn't AUTOMATIC.
        local flags = aura.fillAnticlockwise == true and radialFlags.FLIP_HORIZONTAL or 0
        if isRadial then self:shape(self.radial, flags) end
    end
end

--- Whether the icon is showing either of its sprites.
---@return boolean
function Orb:iconShowing()
    local icon = self.icon
    return icon ~= nil and not (icon.sprite.hidden and icon.objectSprite.hidden)
end

--- Shows the source's icon as the largest square inside the circle: an
--- image can't be masked to a shape in the client. Made or shown again, it
--- lands out of place, so the parts are put back in order next frame
--- (RaiseParts).
function Orb:drawIcon()
    if self.icon == nil then return end
    local wasShowing = self:iconShowing()
    self.icon:Set(self.iconSpriteID, self.iconObjectID)
    self.icon:SetHidden(not self.showIcon)
    if self:iconShowing() and not wasShowing then self.partsMade = true end
    -- The icon, so its grey copy, may have changed (looked up once here,
    -- not with every value).
    local spriteID = self.iconSpriteID
    self.iconGrey = spriteID ~= nil and gameApi.ResourceImage("GreyIcons", "icon_" .. spriteID) or nil
    self.drawnDimmed = nil
    self:applyDimmed()
end

--- Whether the icon should be greyed now: a cooldown while running, a buff
--- while inactive, as the Icon display.
---@return boolean
function Orb:isDimmed()
    if not (self.showIcon and self.dimWhileActive) then return false end
    local isRunning = self.curr ~= nil and self.curr > 0
    return (self.isCooldown and isRunning) or (self.isBuff and not isRunning)
end

--- Greys the icon while dimmed: its grey copy laid over it (same shape, so
--- it covers it), else a darkening tint. Only does anything when that
--- changed, so redraw can call it with every value.
function Orb:applyDimmed()
    if self.icon == nil then return end
    local dimmed = self:isDimmed()
    local grey = dimmed and self.iconGrey or nil
    if dimmed == self.drawnDimmed and grey == self.drawnGrey then return end
    self.drawnDimmed, self.drawnGrey = dimmed, grey
    if grey ~= nil and self.greySprite == nil then
        self.greySprite = ui.Sprite.new(self.root)
        self.greySprite.clickthrough = true
        self:layoutGrey()
        self.partsMade = true
    end
    -- Assigned once sized: at 0 by 0 it draws nothing.
    if grey ~= nil and grey ~= self.greyImage then
        self.greyImage = pcall(setImage, self.greySprite, grey) and grey or nil
    end
    if self.greySprite ~= nil then self:showPart(self.greySprite, grey ~= nil and grey == self.greyImage) end
    local tintColour = (dimmed and grey == nil) and DIMMED_TINT or NORMAL_TINT
    self.icon.sprite.rgba = tintColour
    self.icon.objectSprite.rgba = tintColour
end

--- Places the grey copy over the icon.
function Orb:layoutGrey()
    if self.greySprite == nil then return end
    self.greySprite:SetPos(self.iconOffset, self.iconOffset)
    self.greySprite:SetSize(self.iconSize, self.iconSize)
end

--- Places the icon, making it the first time it's wanted.
---@param aura OrbOptions
function Orb:applyIcon(aura)
    self.showIcon = aura.showIcon == true
    if not self.showIcon and self.icon == nil then return end
    if self.icon == nil then self.icon = SourceIcon.new(self.root) end
    self.iconSize = math.floor(self.innerSize / math.sqrt(2))
    self.iconOffset = (self.width - self.iconSize) // 2
    self.icon:Layout(self.iconOffset, self.iconOffset, self.iconSize)
    self:layoutGrey()
    self:drawIcon()
end

--- Puts the parts back in order, the frame after one was made or shown
--- again (see partsMade): border, background, icon, then the fill.
function Orb:RaiseParts()
    if not self.partsMade then return end
    self.partsMade = false
    self.frame:MoveToFront()
    self.background:MoveToFront()
    if self.icon ~= nil then
        self.icon.sprite:MoveToFront()
        self.icon.objectSprite:MoveToFront()
    end
    if self.greySprite ~= nil then self.greySprite:MoveToFront() end
    if self.clip ~= nil then self.clip:MoveToFront() end
    if self.radial ~= nil then self.radial:MoveToFront() end
end

--- Restyles and places the orb from its aura.
---@param aura OrbOptions
function Orb:Apply(aura)
    local source = dataSources.Get(aura.source)
    -- A cooldown is "on" while running; a buff or channel is active.
    self.isCooldown = source ~= nil and source.state == "cooldown"
    self.isBuff = source ~= nil and source.state == "active"
    self.dimWhileActive = aura.dimWhileActive == true
    self:layoutCircles(aura)
    self:applyFill(aura)
    self:applyIcon(aura)
    self.invertFill = aura.invertFill == true
    self.smoothFill = aura.smoothFill == true
    self.hideWhenEmpty = aura.hideWhenEmpty == true
    self.texts:Apply(aura.texts, self.width, self.height)
    self:place(aura)
    self:setMovable(aura.unlocked)
    tint(self.background, self.movable and UNLOCKED_BACKGROUND_RGBA or aura.backgroundColour)
    -- Redrawn for the new layout.
    self.drawnRatio = nil
    self:redraw()
end

--- The source's name, for $name and $arrow, and its icon. Called every
--- frame; "Any channel" changes them with the channel.
---@param name string?
---@param spriteID integer?
---@param objectID integer?
---@param arrow string?
function Orb:SetDetails(name, spriteID, objectID, arrow)
    if spriteID ~= self.iconSpriteID or objectID ~= self.iconObjectID then
        self.iconSpriteID, self.iconObjectID = spriteID, objectID
        self:drawIcon()
    end
    if name == self.name and arrow == self.arrow then return end
    self.name, self.arrow = name, arrow
    self:redraw()
end

--- Shows the source's values.
---@param curr number?
---@param max number?
---@param fillCurr number? A smoothed current value, used only for the fill (with Smooth fill on).
---@param stacks number? For $stacks.
function Orb:SetValue(curr, max, fillCurr, stacks)
    if not self.smoothFill then fillCurr = nil end
    if curr == self.curr and max == self.max and fillCurr == self.fillCurr and stacks == self.stacks then return end
    self.curr, self.max, self.fillCurr, self.stacks = curr, max, fillCurr, stacks
    self:redraw()
end

--- Fills the orb to a ratio: a vertical fill shows the bottom of a full
--- circle through a layer as tall as the fill; a radial one sets how far
--- round it has swept.
---@param ratio number 0 to 1.
function Orb:drawFill(ratio)
    local inset, inner = self.inset, self.innerSize
    if self.fillStyle == "radial" then
        self.radial.curValue = (1 - ratio) * RADIAL_END
        return
    end
    local fillHeight = math.floor(inner * ratio + 0.5)
    self.clip:SetPos(inset, inset + inner - fillHeight)
    self.clip:SetSize(inner, fillHeight)
    self.clipCircle:SetPos(0, fillHeight - inner)
    self:showPart(self.clip, fillHeight > 0)
end

--- Draws the current values: hiding, fill and texts.
function Orb:redraw()
    local curr, max = self.curr, self.max
    local isEmpty = curr == nil or curr <= 0
    self:setHidden(self.hideWhenEmpty and not self.movable and isEmpty)
    local fillCurr = self.fillCurr or curr
    local ratio = 0
    if fillCurr ~= nil and max ~= nil and max > 0 then ratio = clamp(fillCurr / max, 0, 1) end
    -- Inverted reads as "full when there's nothing left", which also covers
    -- no data and a zero maximum (e.g. a never-used ability).
    if self.invertFill then ratio = 1 - ratio end
    if ratio ~= self.drawnRatio then
        self.drawnRatio = ratio
        self:drawFill(ratio)
    end
    self:applyDimmed()
    -- Each text only reformats when its values change (see TextNodes:SetValues).
    local textShown = true
    self.texts:SetValues(curr, max, self.stacks, self.name, self.arrow, textShown, textTemplate.NO_DATA)
end

--- Destroys the orb and everything in it.
function Orb:Destroy()
    self.root:Destroy()
    self.root = nil
    self.texts:Destroy()
end

return Orb
