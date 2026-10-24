-- Bar display: a filled bar showing curr/max, with optional value text, an
-- optional icon (the source's, at the left or right end, a square the
-- bar's height) and optional tick marks (one per 0.6s server tick, for
-- sources timed in seconds: a channel bar shows the game's ticks). When the
-- aura is unlocked the bar can be dragged around the game area.

local Border = require("Auras/Displays/border")
local placement = require("Auras/Displays/placement")
local SourceIcon = require("Auras/Displays/source-icon")
local dataSources = require("Auras/Registries/data-sources")
local gameClock = require("GameData/Trackers/game-clock")
local fonts = require("Auras/Helpers/fonts")
local textTemplate = require("Auras/Helpers/text-template")

local Bar = {}
Bar.__index = Bar
placement.Install(Bar)

Bar.defaults = {
    width = 200,
    height = 20,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000B4,
    borderThickness = 2,
    -- Fill as the value drops, e.g. a cooldown filling as it comes back.
    invertFill = false,
    -- Move the fill every frame for sources that can extrapolate between
    -- server ticks (e.g. cooldowns), rather than stepping each 0.6s.
    smoothFill = false,
    -- Hide the whole bar while the value is 0 (a channel or buff that isn't
    -- running, a cooldown that's ready), except while unlocked so it can
    -- still be moved.
    hideWhenEmpty = false,
    -- The source's icon at one end of the bar ("left" or "right").
    showIcon = false,
    iconSide = "left",
    -- Marks at each 0.6s server tick, for sources timed in seconds.
    showTicks = false,
    tickColour = 0x000000B4,
}

local MIN_WIDTH, MAX_WIDTH = 60, 600
local MIN_HEIGHT, MAX_HEIGHT = 8, 60
local MAX_BORDER = 10
-- Shared with the bar's editor controls (UI/Editors/bar).
Bar.limits = {
    minWidth = MIN_WIDTH, maxWidth = MAX_WIDTH,
    minHeight = MIN_HEIGHT, maxHeight = MAX_HEIGHT,
    maxBorder = MAX_BORDER,
}
local SECONDS_PER_TICK = gameClock.SECONDS_PER_SERVER_TICK
-- Tick marks closer than this (in pixels) would blur together, so none are
-- drawn; and never more than this many.
local MIN_TICK_SPACING = 4
local MAX_TICKS = 100
local TICK_WIDTH = 1
-- The bar's body beside an icon is never narrower than this.
local MIN_BODY_WIDTH = 20

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function newRectangle(parent, rgba)
    local rectangle = ui.Rectangle.new(parent)
    rectangle.fill = true
    rectangle.rgba = rgba
    rectangle.clickthrough = true
    return rectangle
end

function Bar.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Bar)

    self.root = ui.Layer.new(parent)
    -- Everything but the icon sits in the body, beside the icon if shown.
    self.body = ui.Layer.new(self.root)
    self.body.clickthrough = true
    self.frame = Border.new(self.body, aura.borderColour)
    self.background = newRectangle(self.body, aura.backgroundColour)
    self.fill = newRectangle(self.body, aura.colour)
    -- Tick marks, made as needed and reused.
    self.ticks = {}
    self.icon = SourceIcon.new(self.root)

    self.text = ui.Text.new(self.body)
    self.text.isShadowed = true
    self.text.alignHorizontal = ui.AlignMode.CENTRE
    self.text.alignVertical = ui.AlignMode.CENTRE
    self.text.maxLines = 1
    self.text.clickthrough = true

    self:bindDrag()
    self:Apply(aura)
    return self
end

function Bar:Apply(aura)
    self.width = clamp(aura.width or Bar.defaults.width, MIN_WIDTH, MAX_WIDTH)
    self.height = clamp(aura.height or Bar.defaults.height, MIN_HEIGHT, MAX_HEIGHT)
    self.root:SetSize(self.width, self.height)
    -- The icon is a square at one end; the body takes the rest.
    self.showIcon = aura.showIcon == true
    local iconSize = self.showIcon and math.min(self.height, self.width - MIN_BODY_WIDTH) or 0
    local iconRight = aura.iconSide == "right"
    self.bodyWidth = self.width - iconSize
    self.body:SetPos(self.showIcon and not iconRight and iconSize or 0, 0)
    self.body:SetSize(self.bodyWidth, self.height)
    self.icon:Layout(iconRight and self.bodyWidth or 0, 0, iconSize)
    self.icon:SetHidden(not self.showIcon)
    -- Leave at least a couple of pixels of bar inside the border.
    self.border = clamp(aura.borderThickness or Bar.defaults.borderThickness,
        0, math.min(MAX_BORDER, (self.height - 2) // 2))
    self:layoutFrame()
    -- The frame may have changed size, so the next redraw resizes the fill.
    self.fillWidth = nil
    self.invertFill = aura.invertFill == true
    self.smoothFill = aura.smoothFill == true
    -- Let text taller than the bar overflow evenly above and below it.
    local textHeight = math.max(self.height, fonts.LineHeight(aura.textSize))
    self.text:SetPos(0, (self.height - textHeight) // 2)
    self.text:SetSize(self.bodyWidth, textHeight)
    self:place(aura)

    self.fill.rgba = aura.colour
    self.frame:SetColour(aura.borderColour)
    self.showText = aura.showText ~= false
    self.text.hidden = not self.showText
    -- Font first: assigning a font resets the text colour to the default.
    self.text.font = fonts.Resolve(aura.textFont, aura.textSize)
    self.text.rgba = aura.textColour
    self.template = aura.textTemplate
    self.decimalsBelow = aura.limitDecimals and aura.decimalsBelow or nil

    self.hideWhenEmpty = aura.hideWhenEmpty == true
    -- Ticks only mean something when max is a time in seconds.
    local source = dataSources.Get(aura.source)
    self.showTicks = aura.showTicks == true and source ~= nil and source.timed == true
    self.tickColour = aura.tickColour or Bar.defaults.tickColour
    -- Laid out again for the new size and settings on the next redraw
    -- (false never matches a max, even no data's nil).
    self.ticksMax = false
    self:setMovable(aura.unlocked)
    self.background.rgba = self.movable and placement.UNLOCKED_BACKGROUND_RGBA or aura.backgroundColour

    self:redraw()
end

-- Places the border edges and the background inside them.
function Bar:layoutFrame()
    local width, height, border = self.bodyWidth, self.height, self.border
    self.frame:Layout(width, height, border)

    self.background:SetPos(border, border)
    self.background:SetSize(width - border * 2, height - border * 2)
    self.fill:SetPos(border, border)
end

-- The source's name and icon, for $name and the bar's icon. Called every
-- frame; "Any channel" changes them with the channel.
function Bar:SetDetails(name, spriteID, objectID)
    self.icon:Set(spriteID, objectID)
    if name ~= self.name then
        self.name = name
        if self.showText then self:redraw() end
    end
end

-- Lays one mark per server tick across the bar for a max of `max` seconds,
-- when there's room for them.
function Bar:layoutTicks(max)
    local innerWidth = self.bodyWidth - self.border * 2
    local count = 0
    if self.showTicks and max ~= nil and max > 0 then
        local segments = math.floor(max / SECONDS_PER_TICK + 0.5)
        if segments > 1 and segments <= MAX_TICKS and innerWidth / segments >= MIN_TICK_SPACING then
            count = segments - 1
            for index = 1, count do
                local tick = self.ticks[index]
                if tick == nil then
                    -- Over the fill, under the text.
                    tick = newRectangle(self.body, self.tickColour)
                    tick:MoveToFront()
                    self.text:MoveToFront()
                    self.ticks[index] = tick
                end
                tick.rgba = self.tickColour
                tick:SetPos(self.border + math.floor(innerWidth * index / segments), self.border)
                tick:SetSize(TICK_WIDTH, self.height - self.border * 2)
                tick.hidden = false
            end
        end
    end
    for index = count + 1, #self.ticks do self.ticks[index].hidden = true end
end

-- fillCurr, when given, is a smoothed current value used only for the fill;
-- the text always shows curr.
-- stacks is a buff's stack count, for $stacks.
function Bar:SetValue(curr, max, fillCurr, stacks)
    if not self.smoothFill then fillCurr = nil end
    if curr == self.curr and max == self.max and fillCurr == self.fillCurr and stacks == self.stacks then return end
    self.curr, self.max, self.fillCurr, self.stacks = curr, max, fillCurr, stacks
    self:redraw()
end

function Bar:redraw()
    local curr, max = self.curr, self.max
    self:setHidden(self.hideWhenEmpty and not self.movable and (curr == nil or curr <= 0))
    local fillCurr = self.fillCurr or curr
    local ratio = 0
    if fillCurr ~= nil and max ~= nil and max > 0 then
        ratio = clamp(fillCurr / max, 0, 1)
    end
    -- Inverted bars read as "full when there's nothing left", which also
    -- covers no data and a zero maximum (e.g. a never-used ability).
    if self.invertFill then ratio = 1 - ratio end
    if max ~= self.ticksMax then
        self.ticksMax = max
        self:layoutTicks(max)
    end
    local innerWidth = self.bodyWidth - self.border * 2
    local fillWidth = math.floor(innerWidth * ratio + 0.5)
    if fillWidth ~= self.fillWidth then
        self.fillWidth = fillWidth
        self.fill:SetSize(fillWidth, self.height - self.border * 2)
        self.fill.hidden = fillWidth <= 0
    end

    -- A smoothed fill redraws every frame, but the text only changes with
    -- curr, max or the template, so only format it then.
    -- Hidden text isn't formatted at all; showing it again goes through
    -- Apply, which redraws.
    if self.showText and (curr ~= self.textCurr or max ~= self.textMax or self.stacks ~= self.textStacks
        or self.template ~= self.textTemplate or self.decimalsBelow ~= self.textDecimals
        or self.name ~= self.textName) then
        self.textCurr, self.textMax, self.textTemplate = curr, max, self.template
        self.textDecimals, self.textStacks, self.textName = self.decimalsBelow, self.stacks, self.name
        local content = textTemplate.NO_DATA
        if curr ~= nil and max ~= nil then
            content = textTemplate.Format(self.template, curr, max, self.decimalsBelow, self.stacks, self.name)
        end
        if content ~= self.textContent then
            self.textContent = content
            self.text.content = content
        end
    end
end

function Bar:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Bar
