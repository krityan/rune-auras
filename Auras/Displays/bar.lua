-- Bar display: a bar filled to curr/max, with value texts (text nodes), an
-- optional icon (the source's icon, at one end, a square the bar's height) and
-- optional tick marks (one per 0.6s server tick, for sources timed in
-- seconds: a channel bar shows the game's ticks).

local Border = require("Auras/Displays/Parts/border")
local placement = require("Auras/Displays/Parts/placement")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local dataSources = require("Auras/Registries/data-sources")
local gameClock = require("GameData/Trackers/game-clock")
local TextNodes = require("Auras/Displays/Parts/text-nodes")
local textTemplate = require("Auras/Helpers/text-template")
local maths = require("Auras/Helpers/maths")
local rectangles = require("Auras/Displays/Parts/rectangles")

local clamp = maths.Clamp
local newRectangle = rectangles.Filled

--- A bar aura's own options.
---@class BarOptions: Aura
---@field backgroundColour integer
---@field borderColour integer
---@field borderThickness integer
---@field invertFill boolean Fill as the value drops, e.g. a cooldown filling as it comes back.
---@field smoothFill boolean Move the fill every frame for sources that extrapolate between server ticks, rather than stepping each 0.6s.
---@field hideWhenEmpty boolean Hide while the value is 0 (an idle channel or buff, a ready cooldown), except while unlocked.
---@field showIcon boolean The source's icon at one end.
---@field iconSide "left"|"right"
---@field showTicks boolean Marks at each 0.6s server tick, for timed sources.
---@field tickColour integer

---@class Bar: Placed
---@field body userdata Everything but the icon, beside the icon if shown.
---@field background userdata
---@field fill userdata
---@field frame Border? Made when it first has a thickness.
---@field icon SourceIcon? Made when first shown.
---@field tickLayer userdata? Made with the first tick.
---@field ticks userdata[] Tick marks, made as needed and reused.
---@field texts TextNodes
local Bar = {}
Bar.__index = Bar
placement.Mixin(Bar)
-- Its value texts are text nodes (see auraTexts.Ensure in Auras/Store/aura-texts).
Bar.usesTextNodes = true

Bar.defaults = {
    width = 200,
    height = 20,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000B4,
    borderThickness = 2,
    invertFill = false,
    smoothFill = false,
    hideWhenEmpty = false,
    showIcon = false,
    iconSide = "left",
    showTicks = false,
    tickColour = 0x000000B4,
}

local MIN_WIDTH, MAX_WIDTH = 60, 600
local MIN_HEIGHT, MAX_HEIGHT = 8, 60
local MAX_BORDER = 10
-- The border leaves at least this much bar inside it.
local MIN_INNER_HEIGHT = 2
-- Shared with the bar's editor controls (UI/Editor/Types/bar).
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

--- Creates a bar for an aura. The border and the source icon are made when
--- first used (layoutFrame, Apply): the game has 4,096 interface parts for
--- everything we draw. If the game runs out of them partway (see the aura
--- manager), the root goes, taking whatever was made in it, and the error
--- is raised again.
---@param parent userdata
---@param aura BarOptions
---@param groupPoint GroupPoint?
---@return Bar
function Bar.new(parent, aura, groupPoint)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, Bar)

    self.root = ui.Layer.new(parent)
    local ok, problem = pcall(function()
        self.body = ui.Layer.new(self.root)
        self.body.clickthrough = true
        self.background = newRectangle(self.body, aura.backgroundColour)
        self.fill = newRectangle(self.body, aura.colour)
        self.ticks = {}
        -- Laid out on the body (beside the icon), but drawn beside the root
        -- so they aren't clipped to the bar.
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

--- Sizes the root, and splits it into the icon (a square at one end) and
--- the body, which takes the rest.
---@param aura BarOptions
function Bar:layoutIcon(aura)
    self.width = clamp(aura.width or Bar.defaults.width, MIN_WIDTH, MAX_WIDTH)
    self.height = clamp(aura.height or Bar.defaults.height, MIN_HEIGHT, MAX_HEIGHT)
    self.root:SetSize(self.width, self.height)
    self.showIcon = aura.showIcon == true
    local iconSize = self.showIcon and math.min(self.height, self.width - MIN_BODY_WIDTH) or 0
    local iconOnRight = aura.iconSide == "right"
    self.bodyWidth = self.width - iconSize
    local iconOnLeft = self.showIcon and not iconOnRight
    self.overlayX = iconOnLeft and iconSize or 0
    self.body:SetPos(self.overlayX, 0)
    self.body:SetSize(self.bodyWidth, self.height)
    if self.tickLayer ~= nil then self.tickLayer:SetSize(self.bodyWidth, self.height) end
    if self.showIcon and self.icon == nil then self.icon = SourceIcon.new(self.root) end
    if self.icon ~= nil then
        self.icon:Layout(iconOnRight and self.bodyWidth or 0, 0, iconSize)
        self.icon:SetHidden(not self.showIcon)
    end
end

--- Restyles and places the bar from its aura.
---@param aura BarOptions
function Bar:Apply(aura)
    self:layoutIcon(aura)
    local thickestBorder = math.min(MAX_BORDER, (self.height - MIN_INNER_HEIGHT) // 2)
    self.border = clamp(aura.borderThickness or Bar.defaults.borderThickness, 0, thickestBorder)
    self:layoutFrame()
    -- The frame may have changed size, so the next redraw resizes the fill.
    self.fillWidth = nil
    self.invertFill = aura.invertFill == true
    self.smoothFill = aura.smoothFill == true
    self.texts:Apply(aura.texts, self.bodyWidth, self.height)
    self:place(aura)

    self.fill.rgba = aura.colour
    if self.frame ~= nil then self.frame:SetColour(aura.borderColour) end

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

--- Places the border and the background and fill inside it, making the
--- border when it first has a thickness.
function Bar:layoutFrame()
    local width, height, border = self.bodyWidth, self.height, self.border
    if self.frame == nil and border > 0 then
        self.frame = Border.new(self.body, 0)
    end
    if self.frame ~= nil then self.frame:Layout(width, height, border) end

    self.background:SetPos(border, border)
    self.background:SetSize(width - border * 2, height - border * 2)
    self.fill:SetPos(border, border)
end

--- The source's name and icon, for $name and the bar's icon. Called every
--- frame; "Any channel" changes them with the channel.
---@param name string?
---@param spriteID integer?
---@param objectID integer?
---@param arrow string? For $arrow.
function Bar:SetDetails(name, spriteID, objectID, arrow)
    if self.icon ~= nil then self.icon:Set(spriteID, objectID) end
    if name ~= self.name or arrow ~= self.arrow then
        self.name, self.arrow = name, arrow
        self:redraw()
    end
end

--- Makes the layer the ticks are drawn in. The texts are outside the bar,
--- over it, so ticks made later stay under them.
function Bar:makeTickLayer()
    self.tickLayer = ui.Layer.new(self.body)
    self.tickLayer.clickthrough = true
    self.tickLayer:SetSize(self.bodyWidth, self.height)
end

--- Lays one mark per server tick across the bar, when there's room for them.
---@param max number? The bar's max, in seconds.
function Bar:layoutTicks(max)
    local innerWidth = self.bodyWidth - self.border * 2
    local count = 0
    if self.showTicks and max ~= nil and max > 0 then
        local segments = math.floor(max / SECONDS_PER_TICK + 0.5)
        local hasRoom = innerWidth / segments >= MIN_TICK_SPACING
        if segments > 1 and segments <= MAX_TICKS and hasRoom then
            count = segments - 1
            if self.tickLayer == nil then self:makeTickLayer() end
            for index = 1, count do
                local tick = self.ticks[index]
                if tick == nil then
                    tick = newRectangle(self.tickLayer, self.tickColour)
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

--- Shows the source's values.
---@param curr number?
---@param max number?
---@param fillCurr number? A smoothed current value, used only for the fill (with Smooth fill on); the text always shows curr.
---@param stacks number? For $stacks.
function Bar:SetValue(curr, max, fillCurr, stacks)
    if not self.smoothFill then fillCurr = nil end
    if curr == self.curr and max == self.max and fillCurr == self.fillCurr and stacks == self.stacks then return end
    self.curr, self.max, self.fillCurr, self.stacks = curr, max, fillCurr, stacks
    self:redraw()
end

--- Draws the current values: hiding, fill, ticks and texts.
function Bar:redraw()
    local curr, max = self.curr, self.max
    local isEmpty = curr == nil or curr <= 0
    self:setHidden(self.hideWhenEmpty and not self.movable and isEmpty)
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

    -- A smoothed fill redraws every frame, but each text only reformats
    -- when its values change (see TextNodes:SetValues).
    local textShown = true
    self.texts:SetValues(curr, max, self.stacks, self.name, self.arrow, textShown, textTemplate.NO_DATA)
end

--- Destroys the bar and everything in it.
function Bar:Destroy()
    self.root:Destroy()
    self.root = nil
    self.texts:Destroy()
end

return Bar
