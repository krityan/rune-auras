-- Icon display: a square icon with a cooldown-style swipe over the part of
-- the value that remains, greyed out while the value is above 0, and value
-- texts (its aura's `texts`, see Auras/Displays/text-nodes). Built for ability cooldowns (remaining over total).
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
-- Start(initial, end, flags) sets curValue to initial, so progress starts
-- at 0. With the AUTOMATIC flag curValue then counts up in real seconds by
-- itself, so one Start per timer animates the whole swipe. To start partway
-- (a timer already running, or extended), curValue is written after Start
-- (confirmed in game); if that ever doesn't stick, the swipe runs over the
-- time left from full.

local Border = require("Auras/Displays/border")
local placement = require("Auras/Displays/placement")
local dataSources = require("Auras/Registries/data-sources")
local gameClock = require("GameData/Trackers/game-clock")
local TextNodes = require("Auras/Displays/text-nodes")
local gameApi = require("GameData/game-api")
local SourceIcon = require("Auras/Displays/source-icon")

local Icon = {}
Icon.__index = Icon
-- Its value texts are text nodes (see aura-store's ensureTexts).
Icon.usesTextNodes = true
placement.Install(Icon)

Icon.defaults = {
    -- Kept equal; the editor offers a single size (see UI/Editors/icon).
    width = 48,
    height = 48,
    swipeStyle = "radial",
    swipeColour = 0x000000B4,
    -- Multiplied into the icon (white leaves it as it is), e.g. blue while
    -- there's not enough adrenaline, through a condition.
    iconColour = 0xFFFFFFFF,
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
    -- Hide a buff's icon while it's active, e.g. to only show a missing
    -- buff. With showActiveBelow above 0 it shows again once the time left
    -- drops to that many seconds, as a reminder to refresh it.
    hideWhileActive = false,
    showActiveBelow = 0,
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

-- Two 0xRRGGBBAA colours multiplied channel by channel, so a darkened icon
-- keeps its tint.
local function multiplyColours(a, b)
    local result = 0
    for shift = 0, 24, 8 do
        local channel = ((a >> shift) & 0xFF) * ((b >> shift) & 0xFF) // 255
        result = result | (channel << shift)
    end
    return result
end
-- A rise in the time left bigger than this is a new or refreshed cooldown,
-- so the radial restarts.
local RADIAL_RESTART_SECONDS = 0.5
-- When the radial's own time left (endValue - curValue) and the source's
-- differ by more than this, e.g. a buff being extended, it's restarted to
-- match. Only when it can start partway: otherwise each restart would sweep
-- from full again.
local RADIAL_DRIFT_SECONDS = 0.5
-- A change in the timer's total bigger than this (a buff extended by a
-- tick adds 0.6s) restarts it partway too, so the swipe follows extensions
-- tick by tick.
local RADIAL_TOTAL_EPSILON = 0.05
-- With no data (e.g. a cooldown that can't be timed yet), show the plain
-- icon rather than a placeholder.
local EMPTY_TEXT = ""

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local PLACEHOLDER_SPRITE = gameApi.Sprite("RS3_ICON_INFO_21PX_2")

-- maskSprite itself is read-only, but the SpriteData it returns is live.
local function setMaskSprite(radial, spriteID)
    if spriteID == nil then return end
    radial.maskSprite.spriteID = spriteID
end

-- A Plugin.resources image may not be loaded yet (e.g. after a deploy,
-- before a refresh), so assigning it is guarded: without it the icon falls
-- back to the darkening tint.
local function setSpriteImage(sprite, image)
    sprite.sprite = image
end

local function radialFlagValue(name)
    return ui.RadialProgressOverlayFlag[name]
end

local function radialFlag(name, fallback)
    return tonumber((gameApi.Try(radialFlagValue, name))) or fallback
end
-- AUTOMATIC: count curValue up in seconds. REVERSE: draw what's left
-- rather than what's done, so the dark slice shrinks; left off when the
-- swipe is inverted.
local RADIAL_AUTOMATIC = radialFlag("AUTOMATIC", 1)
local RADIAL_REVERSE = radialFlag("REVERSE", 2)

local function greyImage(key)
    return Plugin.resources.GreyIcons[key]
end

-- The greyscale copy of a sprite, made offline and shipped as
-- resources/GreyIcons/icon_<id>.png, or nil if there isn't one.
-- Plugin.resources only has the GreyIcons folder once the client has loaded
-- it (a reload doesn't pick up new resources), so the read is guarded.
local function greyIcon(spriteID)
    if spriteID == nil then return nil end
    return (gameApi.Try(greyImage, "icon_" .. tostring(spriteID)))
end

local function newRectangle(parent, rgba)
    local rectangle = ui.Rectangle.new(parent)
    rectangle.fill = true
    rectangle.rgba = rgba
    rectangle.clickthrough = true
    return rectangle
end

function Icon.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Icon)

    self.root = ui.Layer.new(parent)
    -- The game can run out of interface parts partway through (see the
    -- aura manager); then the root goes, taking whatever was made in it,
    -- and the error is passed on.
    local ok, problem = pcall(function()
        self.backing = newRectangle(self.root, BACKING_RGBA)
        self.backing:SetPos(0, 0)
        self.sprite = ui.Sprite.new(self.root)
        self.sprite:SetPos(0, 0)
        self.sprite.clickthrough = true
        -- The border, the grey copy, the item sprite, the radial and the
        -- wipe are made when an aura first uses them (see ensurePart): the
        -- game has 4,096 interface parts for everything we draw.

        -- Value texts, over the icon and its swipe (see Auras/Displays/text-nodes).
        self.texts = TextNodes.new(self.root)

        self:bindDrag()
        self:Apply(aura)
    end)
    if not ok then
        self.root:Destroy()
        error(problem, 0)
    end
    return self
end

-- How each optional part is made, in stacking order (bottom first): the
-- grey copy (shown instead of the icon while dimmed, when there is one),
-- an item icon's own sprite, then the radial and the wipe over them.
local PARTS = {
    greySprite = function(root)
        local sprite = ui.Sprite.new(root)
        sprite.clickthrough = true
        sprite.hidden = true
        return sprite
    end,
    objectSprite = function(root)
        local sprite = ui.Sprite.new(root)
        sprite.clickthrough = true
        sprite.hidden = true
        sprite.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
        return sprite
    end,
    radial = function(root)
        local radial = ui.RadialProgressOverlay.new(root)
        radial.clickthrough = true
        radial.hidden = true
        return radial
    end,
    wipe = function(root)
        local wipe = newRectangle(root, 0)
        wipe.hidden = true
        return wipe
    end,
}
local PART_ORDER = { "greySprite", "objectSprite", "radial", "wipe" }

-- Makes an optional part the first time it's needed. Made last, it's on top
-- of everything, so the parts above it in PART_ORDER, and the texts, are
-- brought back over it. Ones made this frame (the texts, on the frame the
-- Icon is made) ignore that, so it's done again on the next frame too
-- (RaiseParts, from the aura manager's restack).
function Icon:ensurePart(name)
    if self[name] ~= nil then return self[name] end
    self[name] = PARTS[name](self.root)
    local above = false
    for _, partName in ipairs(PART_ORDER) do
        if partName == name then
            above = true
        elseif above and self[partName] ~= nil then
            self[partName]:MoveToFront()
        end
    end
    self.texts:MoveToFront()
    self.partsMade = true
    self.needsRestack = true
    return self[name]
end

-- Puts the optional parts back in PART_ORDER under the texts, after one was
-- made (see ensurePart).
function Icon:RaiseParts()
    if not self.partsMade then return end
    self.partsMade = false
    for _, partName in ipairs(PART_ORDER) do
        if self[partName] ~= nil then self[partName]:MoveToFront() end
    end
    self.texts:MoveToFront()
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
    -- The border's outline is only made once it has a thickness.
    if self.frame == nil and border > 0 then
        self.frame = Border.new(self.root, aura.borderColour)
        -- Made after the texts, so they're brought back over it.
        self.texts:MoveToFront()
    end
    if self.frame ~= nil then
        self.frame:Layout(size, size, border)
        self.frame:SetColour(aura.borderColour)
    end
    self.sprite:SetPos(border, border)
    self.sprite:SetSize(inner, inner)

    self.texts:Apply(aura.texts, size, size)
    self:place(aura)

    local source = dataSources.Get(aura.source)
    -- A cooldown is "on" while running; a buff or channel is active.
    self.isCooldown = source ~= nil and source.state == "cooldown"
    self.isBuff = source ~= nil and source.state == "active"
    -- Values in seconds (cooldowns, timed buffs, channels), which the radial
    -- can follow.
    self.isTimer = source ~= nil and source.timed == true
    if aura.source ~= self.source then
        self.source = aura.source
        -- A running radial is timed to the old source's cooldown.
        self:stopRadial()
        self.radialRemaining = nil
    end
    local object = source and source.iconObject or nil
    local sprite = source and source.icon or nil
    if sprite == nil and object == nil then sprite = PLACEHOLDER_SPRITE end
    if sprite ~= nil then self.sprite.spriteID = sprite end
    self.sprite.hidden = sprite == nil
    if object ~= nil then self:ensurePart("objectSprite") end
    if object ~= self.object then
        self.object = object
        if self.objectSprite ~= nil then SourceIcon.ShowObject(self.objectSprite, object) end
    end
    if self.objectSprite ~= nil then self.objectSprite.hidden = object == nil end
    local grey = source and greyIcon(source.icon) or nil
    if grey ~= nil then self:ensurePart("greySprite") end
    self.hasGrey = grey ~= nil and pcall(setSpriteImage, self.greySprite, grey)

    self.swipeStyle = aura.swipeStyle or Icon.defaults.swipeStyle
    -- The radial times itself in seconds, so it only suits timers, and it
    -- masks a sprite, so not item icons.
    if self.swipeStyle == "radial" and (not self.isTimer or sprite == nil) then
        self.swipeStyle = "vertical"
    end
    if self.swipeStyle == "radial" then self:ensurePart("radial") end
    if self.swipeStyle == "vertical" then self:ensurePart("wipe") end
    if self.wipe ~= nil then self.wipe.rgba = aura.swipeColour end
    if self.radial ~= nil then
        setMaskSprite(self.radial, sprite)
        self.radial.rgba = aura.swipeColour
    end
    -- The optional parts cover the icon inside the border.
    for _, name in ipairs({ "greySprite", "objectSprite", "radial" }) do
        local part = self[name]
        if part ~= nil then
            part:SetPos(border, border)
            part:SetSize(inner, inner)
        end
    end
    local invertSwipe = aura.invertSwipe == true
    if invertSwipe ~= self.invertSwipe then
        self.invertSwipe = invertSwipe
        -- The direction is a Start flag, so a running radial must restart.
        self:stopRadial()
    end
    self.tint = aura.iconColour or NORMAL_TINT
    self.dimWhileActive = aura.dimWhileActive ~= false
    -- Set by a condition (see Auras/Helpers/conditions), not saved on the
    -- aura: desaturated whatever the value.
    self.desaturate = aura.desaturate == true
    self.hideTextWhenReady = aura.hideTextWhenReady ~= false
    self.hideWhileInactive = aura.hideWhileInactive == true
    self.hideWhileActive = aura.hideWhileActive == true
    self.showActiveBelow = tonumber(aura.showActiveBelow) or 0


    self:setMovable(aura.unlocked)
    self.backing.rgba = self.movable and UNLOCKED_BACKING_RGBA or BACKING_RGBA

    -- Layout changed, so redraw everything. A running radial keeps going:
    -- restarting it would sweep from full again.
    self.swipeHeight, self.dimmed, self.rootHidden = nil, nil, nil
    self:redraw()
end

-- The source's name, for $name. Called every frame. (The icon itself comes
-- from the source in Apply.)
function Icon:SetDetails(name)
    if name ~= self.name then
        self.name = name
        self:redraw()
    end
end

-- fillCurr, when given, is a smoothed current value used only for the
-- swipe; the text always shows curr.
-- stacks is a buff's stack count, or an ability's charges ready (for
-- $stacks/$charges, and an ability with a charge left isn't dimmed).
function Icon:SetValue(curr, max, fillCurr, stacks)
    -- Only the vertical wipe draws the smoothed value; the radial animates
    -- itself, so for it a new fillCurr alone isn't worth a redraw.
    local fillChanged = fillCurr ~= self.fillCurr and self.swipeStyle == "vertical"
    self.fillCurr = fillCurr
    if curr == self.curr and max == self.max and stacks == self.stacks
        and not fillChanged then
        -- A running radial is still checked against the source once a server
        -- tick, even while the shown value stands still (e.g. a buff held up
        -- by extensions), so the swipe can't run ahead unnoticed.
        if self.radialRunning and gameClock.ServerTicks() ~= self.radialCheckedTick then
            self:redraw()
        end
        return
    end
    self.curr, self.max, self.stacks = curr, max, stacks
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
        wipeRatio = active and (self.invertSwipe and ratio or 1 - ratio) or 0
    else
        active = false
        wipeRatio = curr == nil and 0 or (self.invertSwipe and ratio or 1 - ratio)
    end
    local inset, inner = self.inset, self.innerSize
    local swipeHeight = self.swipeStyle == "vertical" and math.floor(inner * wipeRatio + 0.5) or 0
    if swipeHeight ~= self.swipeHeight and self.wipe ~= nil then
        self.swipeHeight = swipeHeight
        self.wipe:SetPos(inset, inset + inner - swipeHeight)
        self.wipe:SetSize(inner, swipeHeight)
        self.wipe.hidden = swipeHeight <= 0
    end

    self:updateRadial(swipeCurr, max, active)

    -- Shown while unlocked whatever the options, so it can still be moved.
    local hidden = false
    if self.isBuff and not self.movable then
        if not active then
            hidden = self.hideWhileInactive
        elseif self.hideWhileActive then
            local below = self.showActiveBelow
            hidden = not (below > 0 and curr <= below)
        end
    end
    self:setHidden(hidden)

    -- A cooldown is desaturated while running, a buff while it's not. An
    -- ability recharging a charge while it still has one (Surge) is usable,
    -- so it isn't dimmed; its swipe and text still show the recharge.
    local dimmed = self.dimWhileActive and active
        and not (self.isCooldown and self.stacks ~= nil and self.stacks > 0)
    if self.isBuff then dimmed = self.dimWhileActive and not active end
    dimmed = dimmed or self.desaturate
    if dimmed ~= self.dimmed then
        self.dimmed = dimmed
        local tint = self.tint
        local darkened = multiplyColours(tint, DIMMED_TINT)
        if self.hasGrey then
            -- Swap to the true greyscale copy.
            self.greySprite.hidden = not dimmed
            self.greySprite.rgba = tint
            self.sprite.hidden = dimmed
            self.sprite.rgba = tint
        else
            if self.greySprite ~= nil then self.greySprite.hidden = true end
            self.sprite.rgba = dimmed and darkened or tint
        end
        if self.objectSprite ~= nil then self.objectSprite.rgba = dimmed and darkened or tint end
    end

    -- Each text only reformats when its values change (see
    -- TextNodes:SetValues); a ready cooldown or inactive buff can blank them.
    local showText = active or not self.hideTextWhenReady or not (self.isCooldown or self.isBuff)
    self.texts:SetValues(curr, max, self.stacks, self.name, showText, EMPTY_TEXT)
end

-- Hides the radial so the next update starts it afresh if it's needed.
function Icon:stopRadial()
    self.radialRunning = false
    if self.radial ~= nil then self.radial.hidden = true end
end

-- Starts the radial when a cooldown begins (or is refreshed) and lets it
-- animate itself; hides it once the value runs out.
-- How much time the running radial thinks is left.
local function radialLeft(radial)
    return radial.endValue - radial.curValue
end

-- Starts the radial over the source's whole timer (total), then moves it on
-- to where the timer is now (remaining), so the swipe matches the value
-- rather than sweeping from full. Start sets curValue to its initial value,
-- but curValue can be written once it's running; if that ever doesn't
-- stick, the swipe runs over the time left alone.
function Icon:startRadial(remaining, total, flags)
    if total == nil or total < remaining then total = remaining end
    self.radial:Start(0, total, flags)
    self.radialTotal = total
    local done = total - remaining
    if done > 0 then
        self.radial.curValue = done
        self.radialPartial = math.abs(radialLeft(self.radial) - remaining) < RADIAL_DRIFT_SECONDS
        if not self.radialPartial then
            -- Can't start partway: run over what's left instead.
            self.radial:Start(0, remaining, flags)
        end
    end
end

-- Starts the radial when a cooldown begins (or is refreshed) and lets it
-- animate itself; hides it once the value runs out. While running it's
-- restarted when the source's time left jumps up (a new or refreshed
-- timer) or, if it can start partway, drifts from the radial's (a buff
-- being extended). The drift check runs once a server tick, just after the
-- source's value is refreshed: between ticks the source is extrapolated,
-- and a late tick (lag) would otherwise look like drift both ways.
function Icon:updateRadial(remaining, total, active)
    if self.swipeStyle ~= "radial" or self.radial == nil or not active or remaining == nil then
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
    -- Noted even when the drift check is skipped, so SetValue only redraws
    -- for it once a tick.
    local serverTick = gameClock.ServerTicks()
    local newTick = serverTick ~= self.radialCheckedTick
    self.radialCheckedTick = serverTick
    -- radialPartial is nil until a partway start has been tried; a drift
    -- restart is how it gets tried.
    if self.radialRunning and not restarted and self.radialPartial ~= false and newTick then
        restarted = math.abs(radialLeft(self.radial) - remaining) > RADIAL_DRIFT_SECONDS
            or (total ~= nil and self.radialTotal ~= nil and math.abs(total - self.radialTotal) > RADIAL_TOTAL_EPSILON)
    end
    if self.radialRunning and not restarted then return end
    -- A cooldown's dark slice shows what's left; a buff's shows what's gone.
    local reverse = self.invertSwipe
    if self.isCooldown then reverse = not self.invertSwipe end
    local flags = reverse and (RADIAL_AUTOMATIC | RADIAL_REVERSE) or RADIAL_AUTOMATIC
    self:startRadial(remaining, total, flags)
    self.radialRunning = true
    self.radial.hidden = false
end

function Icon:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Icon
