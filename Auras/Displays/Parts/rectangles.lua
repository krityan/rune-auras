-- Plain rectangles that let clicks through: the parts displays, borders and
-- the aura list are drawn with.

local rectangles = {}

--- A filled rectangle that lets clicks through.
---@param parent userdata
---@param rgba integer?
---@return userdata
function rectangles.Filled(parent, rgba)
    local rectangle = ui.Rectangle.new(parent)
    rectangle.fill = true
    rectangle.rgba = rgba
    rectangle.clickthrough = true
    return rectangle
end

--- An outline that lets clicks through, drawn inwards by its outlineThickness.
---@param parent userdata
---@param rgba integer?
---@return userdata
function rectangles.Outline(parent, rgba)
    local rectangle = ui.Rectangle.new(parent)
    rectangle.fill = false
    rectangle.rgba = rgba
    rectangle.clickthrough = true
    return rectangle
end

return rectangles
