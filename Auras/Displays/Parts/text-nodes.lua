-- Text nodes: the value texts a Bar or Icon draws over itself, as many as
-- its aura's `texts` list holds. Draws them; the TextNode record, and
-- making and saving nodes, belong to Auras/Store/aura-texts.

local anchors = require("Auras/Helpers/anchors")
local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local textTemplate = require("Auras/Helpers/text-template")

--- A shown node's drawing state.
---@class DrawnTextNode
---@field component userdata
---@field template string
---@field decimalsBelow number? Set only with limitDecimals on.
---@field curr any The values it last formatted, so it only reformats when they change.
---@field max any
---@field stacks any
---@field name any
---@field shown boolean?
---@field content string?

---@class TextNodes
---@field parent userdata
---@field nodes DrawnTextNode[] The shown nodes, in order.
---@field components userdata[] Made as needed and kept, so Apply (every edit and condition change) only restyles them, and they stay older than anything the display makes later.
local TextNodes = {}
TextNodes.__index = TextNodes

-- How far past the box a text may run before it's cut short: a text is laid
-- out in a component this much bigger than the box on the sides it grows
-- towards (a left-anchored one grows right, a centred one both ways).
local SPREAD = 400
-- Anchor fractions at the near and far edges.
local NEAR_EDGE, FAR_EDGE = 0, 1

--- The client's alignment for an anchor's fraction along an axis.
---@param fraction number
---@return integer alignMode
local function alignFor(fraction)
    if fraction == NEAR_EDGE then return ui.AlignMode.TOPLEFT end
    if fraction == FAR_EDGE then return ui.AlignMode.BOTTOMRIGHT end
    return ui.AlignMode.CENTRE
end

--- Where a text's component starts and how long it is along one axis.
---@param fraction number The anchor's fraction along it.
---@param size number The box's size along it.
---@return number start
---@return number length
local function span(fraction, size)
    if fraction == NEAR_EDGE then return 0, size + SPREAD end
    if fraction == FAR_EDGE then return -SPREAD, size + SPREAD end
    return -SPREAD, size + SPREAD * 2
end

--- Creates the texts' holder; components are made when first needed.
---@param parent userdata The layer the texts are drawn in.
---@return TextNodes
function TextNodes.new(parent)
    return setmetatable({ parent = parent, nodes = {}, components = {} }, TextNodes)
end

--- The text component for a shown node's place, made if needed, and shown.
---@param index integer
---@return userdata
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

--- Styles a component for each shown text, in order (so later ones draw on
--- top), and places them on the box. Spare components are hidden. Call in
--- the display's Apply.
---@param texts TextNode[]?
---@param width number The display's box.
---@param height number
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
            component.font = fontCatalogue.Resolve(text.textFont, text.textSize)
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

--- Brings every component back over whatever the display made after them
--- (a border made once it has a thickness), in order.
function TextNodes:MoveToFront()
    for _, component in ipairs(self.components) do component:MoveToFront() end
end

--- The text a node shows for these values.
---@param node DrawnTextNode
---@return string
local function contentFor(node, curr, max, stacks, name, shown, noData)
    if not shown then return "" end
    if curr == nil or max == nil then return noData or "" end
    return textTemplate.Format(node.template, curr, max, node.decimalsBelow, stacks, name)
end

--- Fills every node from the source's values. Each only reformats when its
--- inputs change.
---@param curr number?
---@param max number?
---@param stacks number?
---@param name string?
---@param shown boolean false blanks them (an Icon hiding its text while ready).
---@param noData string? What shows with no value.
function TextNodes:SetValues(curr, max, stacks, name, shown, noData)
    for _, node in ipairs(self.nodes) do
        local inputsChanged = curr ~= node.curr or max ~= node.max or stacks ~= node.stacks or name ~= node.name
            or shown ~= node.shown or node.content == nil
        if inputsChanged then
            node.curr, node.max, node.stacks, node.name, node.shown = curr, max, stacks, name, shown
            local content = contentFor(node, curr, max, stacks, name, shown, noData)
            if content ~= node.content then
                node.content = content
                node.component.content = content
            end
        end
    end
end

return TextNodes
