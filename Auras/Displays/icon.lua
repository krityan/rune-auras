-- Icon display: the source's icon with a swipe and value texts (text
-- nodes). A cooldown is greyed out while running, with the swipe over the
-- time left; a buff is the other way round, greyed out while inactive, with
-- the swipe over the time gone, like the game's buff bar. Other sources
-- (e.g. lifepoints) are never greyed out, and their vertical wipe covers
-- what's missing, like the game's orbs.

local Border = require("Auras/Displays/Parts/border")
local placement = require("Auras/Displays/Parts/placement")
local radialFlags = require("Auras/Displays/Parts/radial-flags")
local dataSources = require("Auras/Registries/data-sources")
local gameClock = require("GameData/Trackers/game-clock")
local TextNodes = require("Auras/Displays/Parts/text-nodes")
local gameApi = require("GameData/game-api")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local maths = require("Auras/Helpers/maths")
local rectangles = require("Auras/Displays/Parts/rectangles")

local clamp = maths.Clamp
local newRectangle = rectangles.Filled

--- An icon aura's own options.
---@class IconOptions: Aura
---@field swipeStyle "radial"|"vertical"|"none"
---@field swipeColour integer
---@field iconColour integer Multiplied into the icon (white leaves it as it is), e.g. blue while there's not enough adrenaline, through a condition.
---@field backgroundColour integer Behind the icon: shows through its transparent parts (an item's edges).
---@field borderColour integer Drawn inside the icon's square; the icon is inset by its thickness.
---@field borderThickness integer
---@field invertSwipe boolean Cover what's done instead of what's left, so the swipe grows.
---@field swipeAnticlockwise boolean The radial's edge turns anticlockwise rather than clockwise.
---@field dimWhileActive boolean Grey the icon while the value is above 0 (a buff: while inactive).
---@field hideTextWhenReady boolean
---@field hideWhileInactive boolean Hide a buff's icon while it's inactive.
---@field hideWhileActive boolean Hide a buff's icon while it's active, e.g. to only show a missing buff.
---@field showActiveBelow number With hideWhileActive, show again once the time left drops to this many seconds (0: stays hidden).
---@field desaturate boolean? Set only by a condition: greyed whatever the value.

---@class Icon: Placed
---@field backing userdata
---@field sprite userdata The icon.
---@field frame Border? Made when it first has a thickness.
---@field greySprite userdata? Optional parts, made when first used (see ensurePart).
---@field objectSprite userdata?
---@field radial userdata?
---@field wipe userdata?
---@field texts TextNodes
---@field partsMade boolean? A part was made or shown again, so the aura manager calls RaiseParts next frame.
local Icon = {}
Icon.__index = Icon
-- Its value texts are text nodes (see auraTexts.Ensure in Auras/Store/aura-texts).
Icon.usesTextNodes = true
placement.Mixin(Icon)

Icon.defaults = {
    -- Kept equal; the editor offers a single size (see UI/Editor/Types/icon).
    width = 48,
    height = 48,
    swipeStyle = "radial",
    swipeColour = 0x000000B4,
    iconColour = 0xFFFFFFFF,
    backgroundColour = 0x000000FF,
    borderColour = 0x000000FF,
    borderThickness = 1,
    invertSwipe = false,
    swipeAnticlockwise = false,
    dimWhileActive = true,
    hideTextWhenReady = true,
    hideWhileInactive = false,
    hideWhileActive = false,
    showActiveBelow = 0,
}

Icon.SWIPE_STYLES = {
    { id = "radial", label = "Radial" },
    { id = "vertical", label = "Vertical wipe" },
    { id = "none", label = "None" },
}

--- Whether a swipe style can be drawn for a source. The radial times itself
--- in seconds, so it only suits timers. An on/off source has no amount for
--- either to show.
---@param style string A SWIPE_STYLES id.
---@param source DataSource?
---@return boolean
local function swipeFits(style, source)
    if style == "none" then return true end
    if source ~= nil and source.onOff then return false end
    if style == "radial" then return source ~= nil and source.timed == true end
    return true
end

--- The swipe styles a source can be drawn with, for the editor.
---@param source DataSource?
---@return { id: string, label: string }[]
function Icon.SwipeStylesFor(source)
    local styles = {}
    for _, style in ipairs(Icon.SWIPE_STYLES) do
        if swipeFits(style.id, source) then styles[#styles + 1] = style end
    end
    return styles
end

--- The swipe style drawn: the aura's, or the first after it that fits the
--- source (radial falls back to the vertical wipe, then none).
---@param style string? The aura's swipeStyle.
---@param source DataSource?
---@return string
function Icon.DrawnSwipe(style, source)
    style = style or Icon.defaults.swipeStyle
    local reached = false
    for _, candidate in ipairs(Icon.SWIPE_STYLES) do
        reached = reached or candidate.id == style
        if reached and swipeFits(candidate.id, source) then return candidate.id end
    end
    return "none"
end

local MIN_SIZE, MAX_SIZE = 16, 128
local MAX_BORDER = 10
-- The border leaves at least this much icon inside it.
local MIN_INNER_SIZE = 4
-- Shared with the icon's editor controls (UI/Editor/Types/icon).
Icon.limits = { minSize = MIN_SIZE, maxSize = MAX_SIZE, maxBorder = MAX_BORDER }

local UNLOCKED_BACKING_RGBA = 0x6B5420FF
local NORMAL_TINT = 0xFFFFFFFF
-- Fallback for icons with no grey image: darken, as sprites can be tinted
-- but not desaturated.
local DIMMED_TINT = 0x6E6E6EFF
local CHANNEL_BITS = 0xFF
local CHANNEL_MAX = 255
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
-- Shown for a source with no icon of either kind.
local PLACEHOLDER_SPRITE = gameApi.Sprite("RS3_ICON_INFO_21PX_2")

--- Two 0xRRGGBBAA colours multiplied channel by channel, so a darkened icon
--- keeps its tint.
---@param first integer
---@param second integer
---@return integer
local function multiplyColours(first, second)
    local result = 0
    for shift = 0, 24, 8 do
        local channel = ((first >> shift) & CHANNEL_BITS) * ((second >> shift) & CHANNEL_BITS) // CHANNEL_MAX
        result = result | (channel << shift)
    end
    return result
end

--- Sets the sprite the radial reveals. maskSprite itself is read-only, but
--- the SpriteData it returns is live.
---@param radial userdata
---@param spriteID integer
local function setMaskSprite(radial, spriteID)
    radial.maskSprite.spriteID = spriteID
end

--- Masks the radial with one of our images.
---@param radial userdata
---@param image userdata
local function setMaskImage(radial, image)
    radial.maskSprite.sprite = image
end

--- Masks the radial with the icon's sprite, or for an item icon, which has
--- no sprite id, with a plain square (resources/Shapes/pixel.png), so it
--- sweeps the whole square.
---@param radial userdata
---@param spriteID integer? nil for an item icon.
---@return boolean masked false if the square couldn't be used.
local function maskRadial(radial, spriteID)
    if spriteID ~= nil then
        setMaskSprite(radial, spriteID)
        return true
    end
    local square = gameApi.ResourceImage("Shapes", "pixel")
    return square ~= nil and pcall(setMaskImage, radial, square)
end

--- Assigns an image to a sprite, for pcall: a Plugin.resources image may
--- not be loaded yet (e.g. after a deploy, before a refresh), and without it
--- the icon falls back to the darkening tint.
---@param sprite userdata
---@param image userdata
local function setSpriteImage(sprite, image)
    sprite.sprite = image
end

local RADIAL_AUTOMATIC = radialFlags.AUTOMATIC
local RADIAL_REVERSE = radialFlags.REVERSE
local RADIAL_FLIP_HORIZONTAL = radialFlags.FLIP_HORIZONTAL

--- The greyscale copy of a sprite, made offline and shipped as
--- resources/GreyIcons/icon_<id>.png. Plugin.resources only has the
--- GreyIcons folder once the client has loaded it (a reload doesn't pick up
--- new resources), so the read is guarded.
---@param spriteID integer?
---@return userdata? image nil if there isn't one.
local function greyIcon(spriteID)
    if spriteID == nil then return nil end
    return gameApi.ResourceImage("GreyIcons", "icon_" .. tostring(spriteID))
end

--- Creates an icon for an aura. The border and the optional parts are made
--- when an aura first uses them (see ensurePart): the game has 4,096
--- interface parts for everything we draw. If the game runs out of them
--- partway (see the aura manager), the root goes, taking whatever was made
--- in it, and the error is raised again.
---@param parent userdata
---@param aura IconOptions
---@param groupPoint GroupPoint?
---@return Icon
function Icon.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Icon)

    self.root = ui.Layer.new(parent)
    local ok, problem = pcall(function()
        self.backing = newRectangle(self.root, aura.backgroundColour or Icon.defaults.backgroundColour)
        self.backing:SetPos(0, 0)
        self.sprite = ui.Sprite.new(self.root)
        self.sprite:SetPos(0, 0)
        self.sprite.clickthrough = true
        -- Value texts, beside the root so they aren't clipped to the icon.
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

--- A hidden sprite that lets clicks through.
---@param root userdata
---@return userdata
local function newHiddenSprite(root)
    local sprite = ui.Sprite.new(root)
    sprite.clickthrough = true
    sprite.hidden = true
    return sprite
end

-- How each optional part is made: the grey copy (shown instead of the icon
-- while dimmed, when there is one), an item icon's own sprite, then the
-- radial and the wipe over them.
local PARTS = {
    greySprite = newHiddenSprite,
    objectSprite = function(root)
        local sprite = newHiddenSprite(root)
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
-- Stacking order, bottom first.
local PART_ORDER = { "greySprite", "objectSprite", "radial", "wipe" }
-- The parts that cover the icon inside the border.
local ICON_COVERING_PARTS = { "greySprite", "objectSprite", "radial" }
local COVERS_ICON = {}
for _, name in ipairs(ICON_COVERING_PARTS) do COVERS_ICON[name] = true end

--- Places a part over the icon, inside the border. Parts are sized before
--- an image or mask is assigned to them, as they were when made up front:
--- assigned to a part still 0 by 0, the grey copy drew nothing (a black
--- box) and the radial no swipe, in game.
---@param part userdata
function Icon:coverIcon(part)
    part:SetPos(self.inset, self.inset)
    part:SetSize(self.innerSize, self.innerSize)
end

--- An optional part, made the first time it's needed. Made last, it's on
--- top of everything, so the parts above it in PART_ORDER are brought back
--- over it. Ones made this frame ignore that, so it's done again on the
--- next frame too (RaiseParts, called by the aura manager).
---@param name string A PARTS key.
---@return userdata part
function Icon:ensurePart(name)
    if self[name] ~= nil then return self[name] end
    self[name] = PARTS[name](self.root)
    if COVERS_ICON[name] then self:coverIcon(self[name]) end
    local isAbove = false
    for _, partName in ipairs(PART_ORDER) do
        if partName == name then
            isAbove = true
        elseif isAbove and self[partName] ~= nil then
            self[partName]:MoveToFront()
        end
    end
    self.partsMade = true
    return self[name]
end

--- Puts everything over the backing back in order (the icon, its border,
--- then the optional parts in PART_ORDER), after a part was made or shown
--- again. The aura manager calls it next frame (see partsMade).
function Icon:RaiseParts()
    if not self.partsMade then return end
    self.partsMade = false
    self.sprite:MoveToFront()
    if self.frame ~= nil then self.frame.outline:MoveToFront() end
    for _, partName in ipairs(PART_ORDER) do
        if self[partName] ~= nil then self[partName]:MoveToFront() end
    end
end

--- Shows or hides a part. A part shown again loses its place in the stack,
--- so the parts are put back in order next frame (RaiseParts).
---@param part userdata?
---@param shown boolean
function Icon:showPart(part, shown)
    if part == nil then return end
    local wasHidden = part.hidden == true
    part.hidden = not shown
    if shown and wasHidden then self.partsMade = true end
end

--- Sizes the square and its border, with the icon inset by the border's
--- thickness. The border is only made once it has a thickness.
---@param aura IconOptions
function Icon:layoutFrame(aura)
    local size = clamp(aura.width or Icon.defaults.width, MIN_SIZE, MAX_SIZE)
    self.width, self.height = size, size
    self.root:SetSize(size, size)
    self.backing:SetSize(size, size)
    local thickestBorder = math.min(MAX_BORDER, (size - MIN_INNER_SIZE) // 2)
    local border = clamp(aura.borderThickness or Icon.defaults.borderThickness, 0, thickestBorder)
    local inner = size - border * 2
    self.inset, self.innerSize = border, inner
    if self.frame == nil and border > 0 then
        self.frame = Border.new(self.root, aura.borderColour)
    end
    if self.frame ~= nil then
        self.frame:Layout(size, size, border)
        self.frame:SetColour(aura.borderColour)
    end
    self.sprite:SetPos(border, border)
    self.sprite:SetSize(inner, inner)
    for _, name in ipairs(ICON_COVERING_PARTS) do
        if self[name] ~= nil then self:coverIcon(self[name]) end
    end
end

--- Shows the source's icon: its sprite, or its item, or the placeholder,
--- and notes the grey copy if there is one.
---@param source DataSource?
---@return integer? spriteID The sprite shown; nil for an item icon.
function Icon:applySourceIcon(source)
    -- The item from the source's details, which can differ from its own
    -- (the quiver's ammo; see SetDetails).
    local object = nil
    if source ~= nil then object = select(3, dataSources.Details(source.id)) end
    local sprite = source and source.icon or nil
    if sprite == nil and object == nil then sprite = PLACEHOLDER_SPRITE end
    if sprite ~= nil then self.sprite.spriteID = sprite end
    self:showPart(self.sprite, sprite ~= nil)
    if object ~= nil then self:ensurePart("objectSprite") end
    if object ~= self.object then
        self.object = object
        if self.objectSprite ~= nil then SourceIcon.ShowObject(self.objectSprite, object) end
    end
    self:showPart(self.objectSprite, object ~= nil)
    local grey = source and greyIcon(source.icon) or nil
    if grey ~= nil then self:ensurePart("greySprite") end
    self.hasGrey = grey ~= nil and pcall(setSpriteImage, self.greySprite, grey)
    return sprite
end

--- Sets up the swipe the source can be drawn with (see DrawnSwipe).
---@param aura IconOptions
---@param source DataSource?
---@param sprite integer? The sprite shown (see applySourceIcon).
function Icon:applySwipe(aura, source, sprite)
    self.swipeStyle = Icon.DrawnSwipe(aura.swipeStyle, source)
    if self.swipeStyle == "radial" then
        self:ensurePart("radial")
        if not maskRadial(self.radial, sprite) then self.swipeStyle = "vertical" end
    end
    if self.swipeStyle == "vertical" then self:ensurePart("wipe") end
    if self.wipe ~= nil then self.wipe.rgba = aura.swipeColour end
    if self.radial ~= nil then self.radial.rgba = aura.swipeColour end
    local invertSwipe = aura.invertSwipe == true
    local anticlockwise = aura.swipeAnticlockwise == true
    if invertSwipe ~= self.invertSwipe or anticlockwise ~= self.swipeAnticlockwise then
        self.invertSwipe, self.swipeAnticlockwise = invertSwipe, anticlockwise
        -- The direction is a Start flag, so a running radial must restart.
        self:stopRadial()
    end
end

--- Restyles and places the icon from its aura. A running radial keeps
--- going: restarting it would sweep from full again.
---@param aura IconOptions
function Icon:Apply(aura)
    self:layoutFrame(aura)
    self.texts:Apply(aura.texts, self.width, self.height)
    self:place(aura)

    local source = dataSources.Get(aura.source)
    -- A cooldown is "on" while running; a buff or channel is active.
    self.isCooldown = source ~= nil and source.state == "cooldown"
    self.isBuff = source ~= nil and source.state == "active"
    -- Values in seconds (cooldowns, timed buffs, channels), which the radial
    -- can follow.
    if aura.source ~= self.source then
        self.source = aura.source
        -- A running radial is timed to the old source's cooldown.
        self:stopRadial()
        self.radialRemaining = nil
    end
    local sprite = self:applySourceIcon(source)
    self:applySwipe(aura, source, sprite)

    self.tint = aura.iconColour or NORMAL_TINT
    self.dimWhileActive = aura.dimWhileActive ~= false
    self.desaturate = aura.desaturate == true
    self.hideTextWhenReady = aura.hideTextWhenReady ~= false
    self.hideWhileInactive = aura.hideWhileInactive == true
    self.hideWhileActive = aura.hideWhileActive == true
    self.showActiveBelow = tonumber(aura.showActiveBelow) or 0

    self:setMovable(aura.unlocked)
    self.backing.rgba = self.movable and UNLOCKED_BACKING_RGBA or aura.backgroundColour or Icon.defaults.backgroundColour

    -- Layout changed, so redraw everything.
    self.swipeHeight, self.dimmed, self.rootHidden = nil, nil, nil
    self:redraw()
end

--- The source's name, for $name, and its item icon, which can change while
--- it runs (the quiver's ammo, also named for $arrow). Called every frame.
--- (Whether it shows a sprite or an item comes from the source in Apply.)
---@param name string?
---@param spriteID integer?
---@param objectID integer?
---@param arrow string? For $arrow.
function Icon:SetDetails(name, spriteID, objectID, arrow)
    if self.object ~= nil and objectID ~= nil and objectID ~= self.object then
        self.object = objectID
        SourceIcon.ShowObject(self.objectSprite, objectID)
    end
    if name ~= self.name or arrow ~= self.arrow then
        self.name, self.arrow = name, arrow
        self:redraw()
    end
end

--- Shows the source's values.
---@param curr number?
---@param max number?
---@param fillCurr number? A smoothed current value, used only for the swipe; the text always shows curr.
---@param stacks number? A buff's stacks, or an ability's charges ready (for $stacks/$charges; an ability with a charge left isn't dimmed).
function Icon:SetValue(curr, max, fillCurr, stacks)
    -- Only the vertical wipe draws the smoothed value; the radial animates
    -- itself, so for it a new fillCurr alone isn't worth a redraw.
    local fillChanged = fillCurr ~= self.fillCurr and self.swipeStyle == "vertical"
    self.fillCurr = fillCurr
    local unchanged = curr == self.curr and max == self.max and stacks == self.stacks and not fillChanged
    if unchanged then
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

--- Whether the value is running (a cooldown on cooldown, a buff up), and
--- how much of the icon the vertical wipe covers.
---@param ratio number swipe value / max, 0 to 1.
---@return boolean active
---@return number wipeRatio 0 to 1.
function Icon:wipeFor(ratio)
    local curr = self.curr
    local isRunning = curr ~= nil and curr > 0
    if self.isCooldown then
        -- Shrinks from the top down as the time runs out, or grows when
        -- inverted (but stays clear once ready).
        return isRunning, (self.invertSwipe and isRunning) and 1 - ratio or ratio
    end
    if self.isBuff then
        -- Grows as the buff's time runs out (or shrinks, inverted).
        local wipeRatio = isRunning and (self.invertSwipe and ratio or 1 - ratio) or 0
        return isRunning, wipeRatio
    end
    -- Other values: covers what's missing, or what's left when inverted.
    return false, curr == nil and 0 or (self.invertSwipe and ratio or 1 - ratio)
end

--- Whether a buff's hide options hide it now. Shown while unlocked whatever
--- the options, so it can still be moved.
---@param active boolean
---@return boolean
function Icon:hiddenByOptions(active)
    if not self.isBuff or self.movable then return false end
    if not active then return self.hideWhileInactive end
    if not self.hideWhileActive then return false end
    local below = self.showActiveBelow
    local isRunningOut = below > 0 and self.curr <= below
    return not isRunningOut
end

--- Whether the icon is greyed now. A cooldown is greyed while running, a
--- buff while it's not. An ability recharging a charge while it still has
--- one (Surge) is usable, so it isn't greyed; its swipe and text still show
--- the recharge.
---@param active boolean
---@return boolean
function Icon:isDimmed(active)
    local hasChargeLeft = self.isCooldown and self.stacks ~= nil and self.stacks > 0
    local dimmed = self.dimWhileActive and active and not hasChargeLeft
    if self.isBuff then dimmed = self.dimWhileActive and not active end
    return dimmed or self.desaturate
end

--- Greys or ungreys the icon: swaps to the true greyscale copy when there is
--- one, else darkens it. The tint applies either way.
---@param dimmed boolean
function Icon:applyDimmed(dimmed)
    local tint = self.tint
    local darkened = multiplyColours(tint, DIMMED_TINT)
    if self.hasGrey then
        self:showPart(self.greySprite, dimmed)
        self.greySprite.rgba = tint
        self:showPart(self.sprite, not dimmed)
        self.sprite.rgba = tint
    else
        self:showPart(self.greySprite, false)
        self.sprite.rgba = dimmed and darkened or tint
    end
    if self.objectSprite ~= nil then self.objectSprite.rgba = dimmed and darkened or tint end
end

--- Draws the current values: swipe, hiding, greying and texts.
function Icon:redraw()
    local curr, max = self.curr, self.max
    local swipeCurr = self.fillCurr or curr
    local ratio = 0
    if swipeCurr ~= nil and max ~= nil and max > 0 then
        ratio = clamp(swipeCurr / max, 0, 1)
    end
    local active, wipeRatio = self:wipeFor(ratio)
    local inset, inner = self.inset, self.innerSize
    local swipeHeight = self.swipeStyle == "vertical" and math.floor(inner * wipeRatio + 0.5) or 0
    if swipeHeight ~= self.swipeHeight and self.wipe ~= nil then
        self.swipeHeight = swipeHeight
        self.wipe:SetPos(inset, inset + inner - swipeHeight)
        self.wipe:SetSize(inner, swipeHeight)
        self:showPart(self.wipe, swipeHeight > 0)
    end

    self:updateRadial(swipeCurr, max, active)
    self:setHidden(self:hiddenByOptions(active))

    local dimmed = self:isDimmed(active)
    if dimmed ~= self.dimmed then
        self.dimmed = dimmed
        self:applyDimmed(dimmed)
    end

    -- Each text only reformats when its values change (see
    -- TextNodes:SetValues); a ready cooldown or inactive buff can blank them.
    local hasOnOff = self.isCooldown or self.isBuff
    local showText = active or not self.hideTextWhenReady or not hasOnOff
    self.texts:SetValues(curr, max, self.stacks, self.name, self.arrow, showText, EMPTY_TEXT)
end

--- Hides the radial so the next update starts it afresh if it's needed.
function Icon:stopRadial()
    self.radialRunning = false
    if self.radial ~= nil then self.radial.hidden = true end
end

--- How much time the running radial thinks is left.
---@param radial userdata
---@return number seconds
local function radialLeft(radial)
    return radial.endValue - radial.curValue
end

--- Starts the radial over the source's whole timer, then moves it on to
--- where the timer is now, so the swipe matches the value rather than
--- sweeping from full. The radial (RadialProgressOverlay) reveals its mask
--- by progress = (curValue - initialValue) / (endValue - initialValue);
--- Start sets curValue to initialValue, and with AUTOMATIC it then counts
--- up in real seconds by itself. curValue can be written once it's running
--- (confirmed in game); if that ever doesn't stick, the swipe runs over the
--- time left alone.
---@param remaining number Seconds left.
---@param total number? The timer's length.
---@param flags integer Start flags.
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

--- Whether a running radial needs restarting: the source's time left jumped
--- up (a new or refreshed timer), or, if it can start partway, it drifted
--- from the radial's or the timer's length changed (a buff being extended).
--- The drift check runs once a server tick, just after the source's value
--- is refreshed: between ticks the source is extrapolated, and a late tick
--- (lag) would otherwise look like drift both ways.
---@param remaining number
---@param total number?
---@param jumpedUp boolean
---@param isNewTick boolean
---@return boolean
function Icon:radialNeedsRestart(remaining, total, jumpedUp, isNewTick)
    if jumpedUp then return true end
    -- radialPartial is nil until a partway start has been tried; a drift
    -- restart is how it gets tried.
    if self.radialPartial == false or not isNewTick then return false end
    local drifted = math.abs(radialLeft(self.radial) - remaining) > RADIAL_DRIFT_SECONDS
    local totalChanged = total ~= nil and self.radialTotal ~= nil
        and math.abs(total - self.radialTotal) > RADIAL_TOTAL_EPSILON
    return drifted or totalChanged
end

--- Starts the radial when a timer begins (or is refreshed) and lets it
--- animate itself; hides it once the value runs out.
---@param remaining number? Seconds left.
---@param total number?
---@param active boolean
function Icon:updateRadial(remaining, total, active)
    if self.swipeStyle ~= "radial" or self.radial == nil or not active or remaining == nil then
        if self.radialRunning then
            self.radialRunning = false
            self.radial.hidden = true
        end
        self.radialRemaining = nil
        return
    end
    local jumpedUp = self.radialRemaining ~= nil and remaining > self.radialRemaining + RADIAL_RESTART_SECONDS
    self.radialRemaining = remaining
    -- Noted even when the drift check is skipped, so SetValue only redraws
    -- for it once a tick.
    local serverTick = gameClock.ServerTicks()
    local isNewTick = serverTick ~= self.radialCheckedTick
    self.radialCheckedTick = serverTick
    if self.radialRunning and not self:radialNeedsRestart(remaining, total, jumpedUp, isNewTick) then return end
    -- A cooldown's dark slice shows what's left; a buff's shows what's gone.
    local coversLeft = self.isCooldown ~= self.invertSwipe
    -- The slice is drawn clockwise from the top, so its edge turns clockwise
    -- as what's gone grows, and anticlockwise as what's left shrinks; the
    -- flip draws it anticlockwise, turning the edge the other way.
    local flipped = coversLeft ~= self.swipeAnticlockwise
    local flags = RADIAL_AUTOMATIC
    if coversLeft then flags = flags | RADIAL_REVERSE end
    if flipped then flags = flags | RADIAL_FLIP_HORIZONTAL end
    self:startRadial(remaining, total, flags)
    self.radialRunning = true
    self:showPart(self.radial, true)
end

--- Destroys the icon and everything in it.
function Icon:Destroy()
    self.root:Destroy()
    self.root = nil
    self.texts:Destroy()
end

return Icon
