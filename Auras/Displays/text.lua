-- Text display: the aura's text template on its own, filled with its data
-- source's values, so it can show a buff's time, a resource, a cast's
-- progress or a channel's name. The box sizes itself to the text.

local placement = require("Auras/Displays/Parts/placement")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local textTemplate = require("Auras/Helpers/text-template")
local maths = require("Auras/Helpers/maths")

local clamp = maths.Clamp

--- A text aura's own options. It uses the aura's own text fields (font,
--- size, colour, template, decimals), not text nodes.
---@class TextOptions: Aura
---@field maxWidth number The widest the box gets before the text wraps onto more lines.
---@field textAlign "left"|"centre"|"right" Where the lines sit when wrapped.
---@field textShadow boolean
---@field hideWhenEmpty boolean Hide while the value is 0 (an idle channel or buff, a ready cooldown), except while unlocked.
---@field showIcon boolean The source's icon at one end, a line tall.
---@field iconSide "left"|"right"

---@class TextDisplay: Placed
---@field background userdata Shown while unlocked.
---@field text userdata
---@field icon SourceIcon? Made when first shown.
---@field aura TextOptions Kept to place the box again from its anchor when it resizes.
local Text = {}
Text.__index = Text
placement.Install(Text)

-- The display sizes itself, so the editor reads its size from the aura
-- manager rather than the aura (see auraSize in UI/Editor/aura-editor).
Text.sizesItself = true

Text.defaults = {
    maxWidth = 300,
    -- Nominal size, for the store and editor; the display sizes itself to
    -- its text (see fit).
    width = 100,
    height = 24,
    textTemplate = "$name: $current",
    textAlign = "centre",
    textShadow = true,
    hideWhenEmpty = false,
    showIcon = false,
    iconSide = "left",
}

-- Shared with the editor controls (UI/Editor/Types/text).
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
-- As many lines as the wrapped text needs.
local UNLIMITED_LINES = 0

--- Creates a text display for an aura. The source icon is made when first
--- shown (Apply): the game has 4,096 interface parts for everything we
--- draw. If the game runs out of them partway (see the aura manager), the
--- root goes, taking whatever was made in it, and the error is raised again.
---@param parent userdata
---@param aura TextOptions
---@param groupPoint GroupPoint?
---@return TextDisplay
function Text.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Text)

    self.root = ui.Layer.new(parent)
    local ok, problem = pcall(function()
        self.background = ui.Rectangle.new(self.root)
        self.background.fill = true
        self.background.rgba = placement.UNLOCKED_BACKGROUND_RGBA
        self.background.clickthrough = true
        self.background:SetPos(0, 0)

        self.text = ui.Text.new(self.root)
        self.text.alignVertical = ui.AlignMode.CENTRE
        self.text.maxLines = UNLIMITED_LINES
        self.text.clickthrough = true

        self:bindDrag()
        self:Apply(aura)
    end)
    if not ok then
        self.root:Destroy()
        error(problem, 0)
    end
    return self
end

--- Restyles the text from its aura, then formats and measures it again.
---@param aura TextOptions
function Text:Apply(aura)
    self.aura = aura
    self.maxWidth = clamp(aura.maxWidth or Text.defaults.maxWidth, Text.limits.minWidth, Text.limits.maxWidth)
    -- A line's height: the box's least height, and the icon's size.
    self.lineHeight = fontCatalogue.LineHeight(aura.textSize)
    self.showIcon = aura.showIcon == true
    self.iconRight = aura.iconSide == "right"
    self.iconSize = self.showIcon and self.lineHeight or 0
    if self.showIcon and self.icon == nil then self.icon = SourceIcon.new(self.root) end
    if self.icon ~= nil then self.icon:SetHidden(not self.showIcon) end
    local iconOnLeft = self.showIcon and not self.iconRight
    self.text:SetPos(iconOnLeft and self.iconSize or 0, 0)

    -- Font first: assigning a font resets the text colour to the default.
    self.font = fontCatalogue.Resolve(aura.textFont, aura.textSize)
    self.text.font = self.font
    self.text.rgba = aura.textColour
    self.text.isShadowed = aura.textShadow ~= false
    self.text.alignHorizontal = ALIGN[aura.textAlign] or ALIGN.centre
    self.template = aura.textTemplate
    self.decimalsBelow = aura.limitDecimals and aura.decimalsBelow or nil
    self.hideWhenEmpty = aura.hideWhenEmpty == true

    self:setMovable(aura.unlocked)
    self.background.hidden = not self.movable
    self.textContent, self.width, self.height = nil, nil, nil
    self:redraw()
end

--- Sizes the box to the text: as wide as its widest line plus padding (and
--- the icon), wrapping at maxWidth, and as tall as its lines. Places it
--- again from its anchor, so a right-anchored text grows leftwards.
---@param content string
function Text:fit(content)
    local iconSize = self.iconSize
    local wrapWidth = math.max(1, self.maxWidth - iconSize - PAD_X * 2)
    local textWidth, textHeight = fontCatalogue.Measure(self.font, content, wrapWidth)
    if textWidth == nil then textWidth, textHeight = wrapWidth, self.lineHeight end
    local steppedWidth = math.ceil(textWidth / WIDTH_STEP) * WIDTH_STEP
    local boxWidth = math.min(steppedWidth, wrapWidth) + PAD_X * 2
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

--- The source's name and icon, for $name and the icon. Called every frame;
--- "Any channel" changes them with the channel.
---@param name string?
---@param spriteID integer?
---@param objectID integer?
function Text:SetDetails(name, spriteID, objectID)
    if self.icon ~= nil then self.icon:Set(spriteID, objectID) end
    if name ~= self.name then
        self.name = name
        self:redraw()
    end
end

--- Shows the source's values. The smoothed value isn't used: text shows the
--- rounded value.
---@param curr number?
---@param max number?
---@param stacks number?
function Text:SetValue(curr, max, _, stacks)
    if curr == self.curr and max == self.max and stacks == self.stacks then return end
    self.curr, self.max, self.stacks = curr, max, stacks
    self:redraw()
end

--- Formats the text, hiding it when empty, and refits the box when it changed.
function Text:redraw()
    local curr, max = self.curr, self.max
    local isEmpty = curr == nil or curr <= 0
    self:setHidden(self.hideWhenEmpty and not self.movable and isEmpty)
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

--- Destroys the display and everything in it.
function Text:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Text
