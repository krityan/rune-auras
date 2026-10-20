-- Icon display: a square icon with a cooldown-style swipe over the part of
-- the value that remains, greyed out while the value is above 0, and
-- optional value text. Built for ability cooldowns (remaining over total).
-- Buffs are the other way round: greyed out while inactive, with the swipe
-- covering the part of their time that's gone, like the game's buff bar.
-- Other sources (e.g. lifepoints) aren't "on cooldown": they're never greyed
-- out, their text always shows, and the vertical wipe covers what's missing,
-- like the game's orbs. The icon comes from the source's `icon` sprite id,
-- or its `iconObject` item.
-- The radial swipe is the client's RadialProgressOverlay. It reveals its
-- maskSprite radially by progress = (curValue - initialValue) / (endValue -
-- initialValue), tinted by its rgba; masking the icon itself with a dark
-- tint gives a darkened slice of the icon, like the game's own cooldowns.
-- Its values can only be set by Start(initial, end, flags), which sets
-- curValue to initial, so progress always starts at 0. With the AUTOMATIC
-- flag curValue then counts up in real seconds by itself, so one
-- Start(0, seconds) per cooldown animates the whole swipe. It can't start
-- partway, so a cooldown already running when the icon appears sweeps from
-- full over the time left.

local Border = require("Auras/Displays/border")
local placement = require("Auras/Displays/placement")
local dataSources = require("Auras/Registries/data-sources")
local fonts = require("Auras/Helpers/fonts")
local textTemplate = require("Auras/Helpers/text-template")

local Icon = {}
Icon.__index = Icon
placement.Install(Icon)

Icon.defaults = {
    -- Kept equal; the editor offers a single size (see UI/Editors/icon).
    width = 48,
    height = 48,
    swipeStyle = "radial",
    swipeColour = 0x000000B4,
    -- Drawn inside the icon's square; the icon is inset by its thickness.
    borderColour = 0x000000FF,
    borderThickness = 1,
    -- Cover what's done instead of what's left, so the swipe grows.
    invertSwipe = false,
    -- Darken the icon while the value is above 0. Sprites can only be
    -- tinted, not desaturated, so this is a grey tint.
    dimWhileActive = true,
    hideTextWhenReady = true,
    -- Hide a buff's icon entirely while it's inactive (shown while unlocked,
    -- so it can still be moved).
    hideWhileInactive = false,
    -- Show a buff's estimated timer for its first tick on the game's bar,
    -- before the bar shows its number (see GameData/Trackers/buff-bar).
    showInitialTick = true,
}

Icon.SWIPE_STYLES = {
    { id = "radial", label = "Radial" },
    { id = "vertical", label = "Vertical wipe" },
    { id = "none", label = "None" },
}

local MIN_SIZE, MAX_SIZE = 16, 128
local MAX_BORDER = 10
-- Shared with the icon's editor controls (UI/Editors/icon).
Icon.limits = { minSize = MIN_SIZE, maxSize = MAX_SIZE, maxBorder = MAX_BORDER }

local BACKING_RGBA = 0x000000FF
local UNLOCKED_BACKING_RGBA = 0x6B5420FF
local NORMAL_TINT = 0xFFFFFFFF
-- Fallback for icons with no grey image: darken, as sprites can be tinted
-- but not desaturated.
local DIMMED_TINT = 0x6E6E6EFF
-- A rise in the time left bigger than this is a new or refreshed cooldown,
-- so the radial restarts.
local RADIAL_RESTART_SECONDS = 0.5
-- With no data (e.g. a cooldown that can't be timed yet), show the plain
-- icon rather than a placeholder.
local EMPTY_TEXT = ""
local TEXT_LINE_PADDING = 8

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

-- Native properties this display relies on but can't confirm offline are
-- set through here, so a missing one doesn't break the aura.
local function trySet(component, key, value)
    if component == nil then return false end
    return (pcall(function() component[key] = value end))
end

local PLACEHOLDER_SPRITE = (function()
    local found, sprite = pcall(function() return id.Sprite.RS3_ICON_INFO_21PX_2 end)
    return found and sprite or nil
end)()

-- maskSprite itself is read-only, but the SpriteData it returns is live.
local function setMaskSprite(radial, spriteID)
    if radial == nil or spriteID == nil then return end
    pcall(function() radial.maskSprite.spriteID = spriteID end)
end

local function radialFlag(name, fallback)
    local found, value = pcall(function() return ui.RadialProgressOverlayFlag[name] end)
    return found and tonumber(value) or fallback
end
-- AUTOMATIC: count curValue up in seconds. REVERSE: draw what's left
-- rather than what's done, so the dark slice shrinks; left off when the
-- swipe is inverted.
local RADIAL_AUTOMATIC = radialFlag("AUTOMATIC", 1)
local RADIAL_REVERSE = radialFlag("REVERSE", 2)

-- The greyscale copy of a sprite, made by Tools/make-grey-icons.py and
-- shipped as resources/GreyIcons/icon_<id>.png, or nil if there isn't one.
local function greyIcon(spriteID)
    if spriteID == nil then return nil end
    local found, image = pcall(function()
        return Plugin.resources.GreyIcons["icon_" .. tostring(spriteID)]
    end)
    return found and image or nil
end

local function newRectangle(parent, rgba)
    local rectangle = ui.Rectangle.new(parent)
    rectangle.fill = true
    rectangle.rgba = rgba
    rectangle.clickthrough = true
    return rectangle
end

function Icon.new(parent, aura)
    local self = setmetatable({ parent = parent }, Icon)

    self.root = ui.Layer.new(parent)
    self.backing = newRectangle(self.root, BACKING_RGBA)
    self.backing:SetPos(0, 0)
    self.frame = Border.new(self.root, aura.borderColour)

    self.sprite = ui.Sprite.new(self.root)
    self.sprite:SetPos(0, 0)
    self.sprite.clickthrough = true
    -- Shown instead of the icon while on cooldown, when there's a grey copy.
    self.greySprite = ui.Sprite.new(self.root)
    self.greySprite.clickthrough = true
    self.greySprite.hidden = true
    -- Item icons (a source's iconObject) are drawn by their own sprite.
    self.objectSprite = ui.Sprite.new(self.root)
    self.objectSprite.clickthrough = true
    self.objectSprite.hidden = true
    pcall(function() self.objectSprite.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER end)

    -- RadialProgressOverlay is native to the client; fall back to the
    -- vertical wipe if it can't be created.
    local created, radial = pcall(function() return ui.RadialProgressOverlay.new(self.root) end)
    if created and radial ~= nil then
        self.radial = radial
        self.radial:SetPos(0, 0)
        trySet(self.radial, "clickthrough", true)
        self.radial.hidden = true
    end
    self.wipe = newRectangle(self.root, aura.swipeColour)
    self.wipe:SetPos(0, 0)

    self.text = ui.Text.new(self.root)
    self.text.isShadowed = true
    self.text.alignHorizontal = ui.AlignMode.CENTRE
    self.text.alignVertical = ui.AlignMode.CENTRE
    self.text.maxLines = 1
    self.text.clickthrough = true

    self:bindDrag()
    self:Apply(aura)
    return self
end

function Icon:Apply(aura)
    local size = clamp(aura.width or Icon.defaults.width, MIN_SIZE, MAX_SIZE)
    self.width, self.height = size, size
    self.root:SetSize(size, size)
    self.backing:SetSize(size, size)
    -- Leave at least a few pixels of icon inside the border.
    local border = clamp(aura.borderThickness or Icon.defaults.borderThickness,
        0, math.min(MAX_BORDER, (size - 4) // 2))
    local inner = size - border * 2
    self.inset, self.innerSize = border, inner
    self.frame:Layout(size, size, border)
    self.frame:SetColour(aura.borderColour)
    self.sprite:SetPos(border, border)
    self.sprite:SetSize(inner, inner)
    self.greySprite:SetPos(border, border)
    self.greySprite:SetSize(inner, inner)
    self.objectSprite:SetPos(border, border)
    self.objectSprite:SetSize(inner, inner)
    if self.radial ~= nil then
        self.radial:SetPos(border, border)
        self.radial:SetSize(inner, inner)
    end

    local textHeight = math.max(size, (aura.textSize or fonts.DEFAULT_SIZE) + TEXT_LINE_PADDING)
    self.text:SetPos(0, (size - textHeight) // 2)
    self.text:SetSize(size, textHeight)
    self:place(aura)

    local source = dataSources.Get(aura.source)
    self.isCooldown = source ~= nil and source.type == "cooldown"
    self.isBuff = source ~= nil and source.type == "buff"
    -- Cooldowns and timed buffs count down in seconds, which the radial can
    -- follow.
    self.isTimer = self.isCooldown or (self.isBuff and source.smooth == true)
    if aura.source ~= self.source then
        self.source = aura.source
        -- A running radial is timed to the old source's cooldown.
        self:stopRadial()
        self.radialRemaining = nil
    end
    local object = source and source.iconObject or nil
    local sprite = source and source.icon or nil
    if sprite == nil and object == nil then sprite = PLACEHOLDER_SPRITE end
    if sprite ~= nil then trySet(self.sprite, "spriteID", sprite) end
    self.sprite.hidden = sprite == nil
    if object ~= self.object then
        self.object = object
        if object ~= nil then pcall(function() self.objectSprite:SetAssociatedObject(object, 1) end) end
    end
    self.objectSprite.hidden = object == nil
    local grey = source and greyIcon(source.icon) or nil
    self.hasGrey = grey ~= nil and trySet(self.greySprite, "sprite", grey)

    self.swipeStyle = aura.swipeStyle or Icon.defaults.swipeStyle
    -- The radial times itself in seconds, so it only suits timers, and it
    -- masks a sprite, so not item icons.
    if self.swipeStyle == "radial" and (self.radial == nil or not self.isTimer or sprite == nil) then
        self.swipeStyle = "vertical"
    end
    self.wipe.rgba = aura.swipeColour
    setMaskSprite(self.radial, sprite)
    trySet(self.radial, "rgba", aura.swipeColour)
    local invertSwipe = aura.invertSwipe == true
    if invertSwipe ~= self.invertSwipe then
        self.invertSwipe = invertSwipe
        -- The direction is a Start flag, so a running radial must restart.
        self:stopRadial()
    end
    self.dimWhileActive = aura.dimWhileActive ~= false
    self.hideTextWhenReady = aura.hideTextWhenReady ~= false
    self.hideWhileInactive = aura.hideWhileInactive == true
    self.showInitialTick = aura.showInitialTick ~= false

    self.textVisible = aura.showText ~= false
    self.text.hidden = not self.textVisible
    -- Font first: assigning a font resets the text colour to the default.
    self.text.font = fonts.Resolve(aura.textFont, aura.textSize)
    self.text.rgba = aura.textColour
    self.template = aura.textTemplate
    self.decimalsBelow = aura.limitDecimals and aura.decimalsBelow or nil

    self:setMovable(aura.unlocked)
    self.backing.rgba = self.movable and UNLOCKED_BACKING_RGBA or BACKING_RGBA

    -- Layout changed, so redraw everything. A running radial keeps going:
    -- restarting it would sweep from full again.
    self.swipeHeight, self.dimmed, self.hiddenInactive = nil, nil, nil
    self:redraw()
end

-- fillCurr, when given, is a smoothed current value used only for the
-- swipe; the text always shows curr.
-- untimed means the value has no number worth showing (e.g. a buff with no
-- timer), so the text is left out.
function Icon:SetValue(curr, max, fillCurr, untimed, initial)
    if initial and not self.showInitialTick then curr, max, fillCurr, untimed = 0, 0, nil, false end
    -- Only the vertical wipe draws the smoothed value; the radial animates
    -- itself, so for it a new fillCurr alone isn't worth a redraw.
    local fillChanged = fillCurr ~= self.fillCurr and self.swipeStyle == "vertical"
    self.fillCurr = fillCurr
    untimed = untimed == true
    if curr == self.curr and max == self.max and untimed == self.untimed and not fillChanged then return end
    self.curr, self.max, self.untimed = curr, max, untimed
    self:redraw()
end

function Icon:redraw()
    local curr, max = self.curr, self.max
    local swipeCurr = self.fillCurr or curr
    -- The swipe covers the part of the value that remains.
    local ratio = 0
    if swipeCurr ~= nil and max ~= nil and max > 0 then
        ratio = clamp(swipeCurr / max, 0, 1)
    end
    -- Vertical wipe: for a cooldown it shrinks from the top down as the time
    -- runs out, or grows when inverted (but stays clear once ready). For
    -- other values it covers what's missing, or what's left when inverted.
    local active, wipeRatio
    if self.isCooldown then
        active = curr ~= nil and curr > 0
        wipeRatio = (self.invertSwipe and active) and 1 - ratio or ratio
    elseif self.isBuff then
        -- The wipe grows as the buff's time runs out (or shrinks, inverted).
        active = curr ~= nil and curr > 0
        wipeRatio = (active and not self.untimed) and (self.invertSwipe and ratio or 1 - ratio) or 0
    else
        active = false
        wipeRatio = curr == nil and 0 or (self.invertSwipe and ratio or 1 - ratio)
    end
    local inset, inner = self.inset, self.innerSize
    local swipeHeight = self.swipeStyle == "vertical" and math.floor(inner * wipeRatio + 0.5) or 0
    if swipeHeight ~= self.swipeHeight then
        self.swipeHeight = swipeHeight
        self.wipe:SetPos(inset, inset + inner - swipeHeight)
        self.wipe:SetSize(inner, swipeHeight)
        self.wipe.hidden = swipeHeight <= 0
    end

    if self.radial ~= nil then self:updateRadial(swipeCurr, active and not self.untimed) end

    local hidden = self.hideWhileInactive and self.isBuff and not active and not self.movable
    if hidden ~= self.hiddenInactive then
        self.hiddenInactive = hidden
        self.root.hidden = hidden
    end

    -- A cooldown is desaturated while running, a buff while it's not.
    local dimmed = self.dimWhileActive and active
    if self.isBuff then dimmed = self.dimWhileActive and not active end
    if dimmed ~= self.dimmed then
        self.dimmed = dimmed
        if self.hasGrey then
            -- Swap to the true greyscale copy.
            self.greySprite.hidden = not dimmed
            self.sprite.hidden = dimmed
            trySet(self.sprite, "rgba", NORMAL_TINT)
        else
            self.greySprite.hidden = true
            trySet(self.sprite, "rgba", dimmed and DIMMED_TINT or NORMAL_TINT)
        end
        trySet(self.objectSprite, "rgba", dimmed and DIMMED_TINT or NORMAL_TINT)
    end

    -- Only format the text when what it shows could have changed.
    local showText = active or not self.hideTextWhenReady or not (self.isCooldown or self.isBuff)
    if self.untimed then showText = false end
    -- Hidden text isn't formatted at all; showing it again goes through
    -- Apply, which redraws.
    if self.textVisible and (curr ~= self.textCurr or max ~= self.textMax or self.template ~= self.textTemplate
        or showText ~= self.textShown or self.decimalsBelow ~= self.textDecimals) then
        self.textCurr, self.textMax, self.textTemplate, self.textShown = curr, max, self.template, showText
        self.textDecimals = self.decimalsBelow
        local content = EMPTY_TEXT
        if curr ~= nil and max ~= nil then
            content = showText and textTemplate.Format(self.template, curr, max, self.decimalsBelow) or ""
        end
        if content ~= self.textContent then
            self.textContent = content
            self.text.content = content
        end
    end
end

-- Hides the radial so the next update starts it afresh if it's needed.
function Icon:stopRadial()
    self.radialRunning = false
    if self.radial ~= nil then self.radial.hidden = true end
end

-- Starts the radial when a cooldown begins (or is refreshed) and lets it
-- animate itself; hides it once the value runs out.
function Icon:updateRadial(remaining, active)
    if self.swipeStyle ~= "radial" or not active or remaining == nil then
        if self.radialRunning then
            self.radialRunning = false
            self.radial.hidden = true
        end
        self.radialRemaining = nil
        return
    end
    local restarted = self.radialRemaining ~= nil
        and remaining > self.radialRemaining + RADIAL_RESTART_SECONDS
    self.radialRemaining = remaining
    if self.radialRunning and not restarted then return end
    -- A cooldown's dark slice shows what's left; a buff's shows what's gone.
    local reverse = self.invertSwipe
    if self.isCooldown then reverse = not self.invertSwipe end
    local flags = reverse and (RADIAL_AUTOMATIC | RADIAL_REVERSE) or RADIAL_AUTOMATIC
    if pcall(function() self.radial:Start(0, remaining, flags) end) then
        self.radialRunning = true
        self.radial.hidden = false
    else
        -- The overlay exists but won't start, so use the vertical wipe for
        -- the rest of this display's life; the next redraw draws it.
        self.radial.hidden = true
        self.radial = nil
        self.radialRunning = false
        self.swipeStyle = "vertical"
        self.swipeHeight = nil
    end
end

function Icon:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Icon
