-- Text display: the aura's text template on its own, filled with its data
-- source's values ($current, $max, $stacks, $name), so it can show a buff's
-- time, a resource, a cast's progress or a channel's name. Font, size and
-- colour are the aura's text options. The box grows to fit the text, up to
-- `maxWidth`, past which the text wraps onto more lines; an optional icon
-- (the source's) sits at either end. The box is measured whenever the text
-- changes and placed again from its anchor, so a right-anchored text grows
-- leftwards. When the aura is unlocked it can be dragged around.

local placement = require("Auras/Displays/placement")
local SourceIcon = require("Auras/Displays/source-icon")
local fonts = require("Auras/Helpers/fonts")
local textTemplate = require("Auras/Helpers/text-template")

local Text = {}
Text.__index = Text
placement.Install(Text)

-- The display sizes itself, so the editor reads its size from the aura
-- manager rather than the aura (see auraSize in UI/Windows/aura-editor).
Text.sizesItself = true

Text.defaults = {
    -- The widest the box gets before the text wraps.
    maxWidth = 300,
    -- Nominal size, for the store and editor; the display sizes itself to
    -- its text (see fit), which the editor reads from the aura manager.
    width = 100,
    height = 24,
    textTemplate = "$name: $current",
    -- "left", "centre" or "right": where the lines sit when wrapped.
    textAlign = "centre",
    textShadow = true,
    -- Hide while the value is 0 (a channel or buff that isn't running, a
    -- cooldown that's ready), except while unlocked so it can be moved.
    hideWhenEmpty = false,
    -- The source's icon at one end ("left" or "right"), a line tall.
    showIcon = false,
    iconSide = "left",
}

-- Shared with the editor controls (UI/Editors/text).
Text.limits = { minWidth = 40, maxWidth = 800 }
-- Space around the text inside its box.
local PAD_X, PAD_Y = 4, 2
-- The box's width is rounded up to this, so a ticking timer (whose digits
-- vary in width) doesn't resize and re-place it on every change.
local WIDTH_STEP = 4
local ALIGN = {
    left = ui.AlignMode.TOPLEFT,
    centre = ui.AlignMode.CENTRE,
    right = ui.AlignMode.BOTTOMRIGHT,
}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function Text.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Text)

    self.root = ui.Layer.new(parent)
    self.background = ui.Rectangle.new(self.root)
    self.background.fill = true
    self.background.rgba = placement.UNLOCKED_BACKGROUND_RGBA
    self.background.clickthrough = true
    self.background:SetPos(0, 0)
    self.icon = SourceIcon.new(self.root)

    self.text = ui.Text.new(self.root)
    self.text.alignVertical = ui.AlignMode.CENTRE
    -- As many lines as the wrapped text needs.
    self.text.maxLines = 0
    self.text.clickthrough = true

    self:bindDrag()
    self:Apply(aura)
    return self
end

function Text:Apply(aura)
    -- Kept to place the box again from its anchor when it resizes.
    self.aura = aura
    self.maxWidth = clamp(aura.maxWidth or Text.defaults.maxWidth, Text.limits.minWidth, Text.limits.maxWidth)
    -- A line's height: the box's least height, and the icon's size.
    self.lineHeight = fonts.LineHeight(aura.textSize)
    self.showIcon = aura.showIcon == true
    self.iconRight = aura.iconSide == "right"
    self.iconSize = self.showIcon and self.lineHeight or 0
    self.icon:SetHidden(not self.showIcon)
    self.text:SetPos(self.showIcon and not self.iconRight and self.iconSize or 0, 0)

    -- Font first: assigning a font resets the text colour to the default.
    self.font = fonts.Resolve(aura.textFont, aura.textSize)
    self.text.font = self.font
    self.text.rgba = aura.textColour
    self.text.isShadowed = aura.textShadow ~= false
    self.text.alignHorizontal = ALIGN[aura.textAlign] or ALIGN.centre
    self.template = aura.textTemplate
    self.decimalsBelow = aura.limitDecimals and aura.decimalsBelow or nil
    self.hideWhenEmpty = aura.hideWhenEmpty == true

    self:setMovable(aura.unlocked)
    self.background.hidden = not self.movable
    -- Format and measure again with the new settings.
    self.textContent, self.width, self.height = nil, nil, nil
    self:redraw()
end

-- Sizes the box to the text: as wide as its widest line plus padding (and
-- the icon), wrapping at maxWidth, and as tall as its lines.
function Text:fit(content)
    local iconSize = self.iconSize
    local wrapWidth = math.max(1, self.maxWidth - iconSize - PAD_X * 2)
    local textWidth, textHeight = fonts.Measure(self.font, content, wrapWidth)
    if textWidth == nil then textWidth, textHeight = wrapWidth, self.lineHeight end
    local boxWidth = math.min(math.ceil(textWidth / WIDTH_STEP) * WIDTH_STEP, wrapWidth) + PAD_X * 2
    local height = math.max(textHeight + PAD_Y * 2, self.lineHeight)
    local width = boxWidth + iconSize
    if width == self.width and height == self.height then return end
    self.width, self.height = width, height
    self.root:SetSize(width, height)
    self.background:SetSize(width, height)
    if self.showIcon then
        self.icon:Layout(self.iconRight and boxWidth or 0, (height - iconSize) // 2, iconSize)
    end
    self.text:SetSize(boxWidth, height)
    self:place(self.aura)
end

-- The source's name and icon, for $name and the icon. Called every frame;
-- "Any channel" changes them with the channel.
function Text:SetDetails(name, spriteID, objectID)
    self.icon:Set(spriteID, objectID)
    if name ~= self.name then
        self.name = name
        self:redraw()
    end
end

-- fillCurr (a smoothed value) isn't used: text shows the rounded value.
function Text:SetValue(curr, max, _, stacks)
    if curr == self.curr and max == self.max and stacks == self.stacks then return end
    self.curr, self.max, self.stacks = curr, max, stacks
    self:redraw()
end

function Text:redraw()
    local curr, max = self.curr, self.max
    self:setHidden(self.hideWhenEmpty and not self.movable and (curr == nil or curr <= 0))
    local content = textTemplate.NO_DATA
    if curr ~= nil and max ~= nil then
        content = textTemplate.Format(self.template, curr, max, self.decimalsBelow, self.stacks, self.name)
    end
    if content ~= self.textContent then
        self.textContent = content
        self.text.content = content
        self:fit(content)
    end
end

function Text:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Text
