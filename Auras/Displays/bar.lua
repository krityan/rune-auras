-- Bar display: a filled bar showing curr/max, with optional value text.
-- When the aura is unlocked the bar can be dragged around the game area.

local Border = require("Auras/Displays/border")
local placement = require("Auras/Displays/placement")
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
-- Tinted background so an unlocked (draggable) bar is easy to spot.
local UNLOCKED_BACKGROUND_RGBA = 0x6B5420D0
local EMPTY_TEXT = "No data"
-- Extra height around a font's point size so its glyphs aren't clipped.
local TEXT_LINE_PADDING = 8

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

function Bar.new(parent, aura)
    local self = setmetatable({ parent = parent }, Bar)

    self.root = ui.Layer.new(parent)
    self.frame = Border.new(self.root, aura.borderColour)
    self.background = newRectangle(self.root, aura.backgroundColour)
    self.fill = newRectangle(self.root, aura.colour)

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

function Bar:Apply(aura)
    self.width = clamp(aura.width or Bar.defaults.width, MIN_WIDTH, MAX_WIDTH)
    self.height = clamp(aura.height or Bar.defaults.height, MIN_HEIGHT, MAX_HEIGHT)
    self.root:SetSize(self.width, self.height)
    -- Leave at least a couple of pixels of bar inside the border.
    self.border = clamp(aura.borderThickness or Bar.defaults.borderThickness,
        0, math.min(MAX_BORDER, (self.height - 2) // 2))
    self:layoutFrame()
    -- The frame may have changed size, so the next redraw resizes the fill.
    self.fillWidth = nil
    self.invertFill = aura.invertFill == true
    self.smoothFill = aura.smoothFill == true
    -- Let text taller than the bar overflow evenly above and below it.
    local textHeight = math.max(self.height, (aura.textSize or fonts.DEFAULT_SIZE) + TEXT_LINE_PADDING)
    self.text:SetPos(0, (self.height - textHeight) // 2)
    self.text:SetSize(self.width, textHeight)
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

    self:setMovable(aura.unlocked)
    self.background.rgba = self.movable and UNLOCKED_BACKGROUND_RGBA or aura.backgroundColour

    self:redraw()
end

-- Places the border edges and the background inside them.
function Bar:layoutFrame()
    local width, height, border = self.width, self.height, self.border
    self.frame:Layout(width, height, border)

    self.background:SetPos(border, border)
    self.background:SetSize(width - border * 2, height - border * 2)
    self.fill:SetPos(border, border)
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
    local fillCurr = self.fillCurr or curr
    local ratio = 0
    if fillCurr ~= nil and max ~= nil and max > 0 then
        ratio = clamp(fillCurr / max, 0, 1)
    end
    -- Inverted bars read as "full when there's nothing left", which also
    -- covers no data and a zero maximum (e.g. a never-used ability).
    if self.invertFill then ratio = 1 - ratio end
    local innerWidth = self.width - self.border * 2
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
        or self.template ~= self.textTemplate or self.decimalsBelow ~= self.textDecimals) then
        self.textCurr, self.textMax, self.textTemplate = curr, max, self.template
        self.textDecimals, self.textStacks = self.decimalsBelow, self.stacks
        local content = EMPTY_TEXT
        if curr ~= nil and max ~= nil then
            content = textTemplate.Format(self.template, curr, max, self.decimalsBelow, self.stacks)
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
