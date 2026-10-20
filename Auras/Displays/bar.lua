-- Bar display: a filled bar showing curr/max, with optional value text.
-- When the aura is unlocked the bar can be dragged around the game area.

local anchors = require("Auras/anchors")
local fonts = require("Auras/fonts")
local textTemplate = require("Auras/text-template")

local Bar = {}
Bar.__index = Bar

Bar.defaults = {
    width = 200,
    height = 20,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000B4,
    borderThickness = 2,
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
    -- The border is four separate edges so a translucent border and
    -- background don't stack where they would overlap.
    self.edges = {}
    for index = 1, 4 do
        self.edges[index] = newRectangle(self.root, aura.borderColour)
    end
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

-- Hook coordinates are relative to the bar, so keeping the grab point under
-- the cursor only needs the offset from where the drag started.
function Bar:bindDrag()
    local root = self.root
    root:Subscribe(ui.Hook.ONCLICK, function(_, x, y)
        if not self.movable then return true end
        self.grab = { x = x, y = y }
        root:MoveToFront()
        return false
    end)
    root:Subscribe(ui.Hook.ONHOLD, function(_, x, y)
        if self.grab == nil then return true end
        self:moveTo(root.x + x - self.grab.x, root.y + y - self.grab.y)
        return false
    end)
    local function stopDrag()
        if self.grab == nil then return true end
        self.grab = nil
        if self.onMoved ~= nil then
            self.onMoved(anchors.FromScreen(self.anchor, root.x, root.y,
                self.width, self.height, self.parent.width, self.parent.height))
        end
        return false
    end
    root:Subscribe(ui.Hook.ONRELEASE, stopDrag)
    root:Subscribe(ui.Hook.ONDRAGCOMPLETE, stopDrag)
end

-- Places the bar's top-left corner, keeping it inside the game area.
function Bar:moveTo(left, top)
    left = math.floor(clamp(left, 0, math.max(0, self.parent.width - self.width)))
    top = math.floor(clamp(top, 0, math.max(0, self.parent.height - self.height)))
    if left ~= self.root.x or top ~= self.root.y then
        self.root:SetPos(left, top)
    end
end

-- onMoved receives the new x, y as offsets from the aura's anchor.
function Bar:SetOnMoved(callback)
    self.onMoved = callback
end

function Bar:Apply(aura)
    self.width = clamp(aura.width or Bar.defaults.width, MIN_WIDTH, MAX_WIDTH)
    self.height = clamp(aura.height or Bar.defaults.height, MIN_HEIGHT, MAX_HEIGHT)
    self.root:SetSize(self.width, self.height)
    -- Leave at least a couple of pixels of bar inside the border.
    self.border = clamp(aura.borderThickness or Bar.defaults.borderThickness,
        0, math.min(MAX_BORDER, (self.height - 2) // 2))
    self:layoutFrame()
    -- Let text taller than the bar overflow evenly above and below it.
    local textHeight = math.max(self.height, (aura.textSize or fonts.DEFAULT_SIZE) + TEXT_LINE_PADDING)
    self.text:SetPos(0, (self.height - textHeight) // 2)
    self.text:SetSize(self.width, textHeight)
    self.anchor = aura.anchor
    self:moveTo(anchors.ToScreen(aura.anchor, aura.x or 0, aura.y or 0,
        self.width, self.height, self.parent.width, self.parent.height))

    self.fill.rgba = aura.colour
    for _, edge in ipairs(self.edges) do edge.rgba = aura.borderColour end
    self.text.hidden = aura.showText == false
    -- Font first: assigning a font resets the text colour to the default.
    self.text.font = fonts.Resolve(aura.textFont, aura.textSize)
    self.text.rgba = aura.textColour
    self.template = aura.textTemplate

    self.movable = aura.unlocked == true
    self.root.enabled = self.movable
    self.root.clickthrough = not self.movable
    self.background.rgba = self.movable and UNLOCKED_BACKGROUND_RGBA or aura.backgroundColour
    if not self.movable then self.grab = nil end

    self:redraw()
end

-- Places the border edges and the background inside them.
function Bar:layoutFrame()
    local width, height, border = self.width, self.height, self.border
    local top, bottom, left, right = self.edges[1], self.edges[2], self.edges[3], self.edges[4]
    top:SetPos(0, 0)
    top:SetSize(width, border)
    bottom:SetPos(0, height - border)
    bottom:SetSize(width, border)
    left:SetPos(0, border)
    left:SetSize(border, height - border * 2)
    right:SetPos(width - border, border)
    right:SetSize(border, height - border * 2)
    for _, edge in ipairs(self.edges) do edge.hidden = border <= 0 end

    self.background:SetPos(border, border)
    self.background:SetSize(width - border * 2, height - border * 2)
    self.fill:SetPos(border, border)
end

function Bar:SetValue(curr, max)
    if curr == self.curr and max == self.max then return end
    self.curr, self.max = curr, max
    self:redraw()
end

function Bar:redraw()
    local curr, max = self.curr, self.max
    local ratio = 0
    if curr ~= nil and max ~= nil and max > 0 then
        ratio = clamp(curr / max, 0, 1)
    end
    local innerWidth = self.width - self.border * 2
    local fillWidth = math.floor(innerWidth * ratio + 0.5)
    self.fill:SetSize(fillWidth, self.height - self.border * 2)
    self.fill.hidden = fillWidth <= 0

    if curr == nil or max == nil then
        self.text.content = EMPTY_TEXT
    else
        self.text.content = textTemplate.Format(self.template, curr, max)
    end
end

function Bar:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Bar
