-- Text nodes: the value texts a Bar or Icon draws over itself, as many as
-- its aura's `texts` list holds. Each is a text template placed at one of
-- the nine anchor points of the display's box (see Auras/Helpers/anchors),
-- offset inwards from it by x/y as an aura is from the screen's edges, and
-- drawn in list order, so a later one sits over an earlier one. A node:
--   key         stable id, for conditions that change one (see
--               Auras/Helpers/conditions)
--   showText    whether it's drawn
--   textTemplate, textColour, textFont, textSize, limitDecimals,
--   decimalsBelow  as the aura's own text fields (see Auras/aura-store)
--   anchor, x, y   where it sits on the display
-- Usage (in a display):
--   self.texts = TextNodes.new(layer)               -- once
--   self.texts:Apply(aura.texts, width, height)     -- in Apply
--   self.texts:SetValues(curr, max, stacks, name, shown, noData)
--   self.texts:MoveToFront()   -- back over a part the display made later

local anchors = require("Auras/Helpers/anchors")
local fonts = require("Auras/Helpers/fonts")
local textTemplate = require("Auras/Helpers/text-template")

local TextNodes = {}
TextNodes.__index = TextNodes

-- How far past the box a text may run before it's cut short: a text is laid
-- out in a component this much bigger than the box on the sides it grows
-- towards (a left-anchored one grows right, a centred one both ways).
local SPREAD = 400

-- Anchor fraction -> the client's alignment.
local function alignFor(fraction)
    if fraction == 0 then return ui.AlignMode.TOPLEFT end
    if fraction == 1 then return ui.AlignMode.BOTTOMRIGHT end
    return ui.AlignMode.CENTRE
end

-- Where a component starts and how long it is along one axis, for a box of
-- `size` and the anchor's fraction along it.
local function span(fraction, size)
    if fraction == 0 then return 0, size + SPREAD end
    if fraction == 1 then return -SPREAD, size + SPREAD end
    return -SPREAD, size + SPREAD * 2
end

function TextNodes.new(parent)
    -- `components` are made as needed and kept, so Apply (every edit and
    -- condition change) only restyles them, and they stay older than
    -- anything the display makes later.
    return setmetatable({ parent = parent, nodes = {}, components = {} }, TextNodes)
end

function TextNodes:component(index)
    local component = self.components[index]
    if component == nil then
        component = ui.Text.new(self.parent)
        component.isShadowed = true
        component.maxLines = 1
        component.clickthrough = true
        self.components[index] = component
    end
    component.hidden = false
    return component
end

-- Styles a component for each shown text of `texts` (in order, so later
-- ones draw on top) and places them on a box `width` by `height`. Spare
-- components are hidden.
function TextNodes:Apply(texts, width, height)
    self.nodes = {}
    for _, text in ipairs(texts or {}) do
        if text.showText ~= false then
            local component = self:component(#self.nodes + 1)
            local anchor = anchors.Get(text.anchor)
            local directionX, directionY = anchors.Direction(text.anchor)
            component.alignHorizontal = alignFor(anchor.h)
            component.alignVertical = alignFor(anchor.v)
            local left, componentWidth = span(anchor.h, width)
            local top, componentHeight = span(anchor.v, height)
            -- Offsets point inwards from the anchor's edges.
            component:SetPos(left + directionX * (text.x or 0), top + directionY * (text.y or 0))
            component:SetSize(componentWidth, componentHeight)
            -- Font first: assigning a font resets the text colour.
            component.font = fonts.Resolve(text.textFont, text.textSize)
            component.rgba = text.textColour
            -- Its content is written again on the next SetValues.
            component.content = ""
            self.nodes[#self.nodes + 1] = {
                component = component,
                template = text.textTemplate,
                decimalsBelow = text.limitDecimals and text.decimalsBelow or nil,
            }
        end
    end
    for index = #self.nodes + 1, #self.components do self.components[index].hidden = true end
end

-- Brings every component back over whatever the display made after them
-- (a border made once it has a thickness), in order.
function TextNodes:MoveToFront()
    for _, component in ipairs(self.components) do component:MoveToFront() end
end

-- Fills every node from the source's values. `shown` false blanks them (an
-- Icon hiding its text while ready); `noData` is what shows with no value.
-- Each only reformats when its inputs change.
function TextNodes:SetValues(curr, max, stacks, name, shown, noData)
    for _, node in ipairs(self.nodes) do
        if curr ~= node.curr or max ~= node.max or stacks ~= node.stacks or name ~= node.name
            or shown ~= node.shown or node.content == nil then
            node.curr, node.max, node.stacks, node.name, node.shown = curr, max, stacks, name, shown
            local content = ""
            if shown then
                content = noData or ""
                if curr ~= nil and max ~= nil then
                    content = textTemplate.Format(node.template, curr, max, node.decimalsBelow, stacks, name)
                end
            end
            if content ~= node.content then
                node.content = content
                node.component.content = content
            end
        end
    end
end

return TextNodes
