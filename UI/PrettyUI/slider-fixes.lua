-- Fixes to PrettyUI's slider: its thumb drag, placing its thumb after a
-- resize, and changing its range. Uses its internals (_UpdateDrag,
-- _LayoutValue, _UpdateState, dragStart, track, thumb).

local maths = require("Auras/Helpers/maths")

local sliderFixes = {}

--- PrettyUI's record of a thumb drag, plus the fields this adds.
---@class SliderDrag
---@field mouseX number PrettyUI's: where the press was, in the slider's parent.
---@field thumbX number? Where the thumb's left edge was when the drag began.
---@field grabOffset number? How far along the thumb the pointer took hold.
---@field lastX number? The pointer's last position.

--- Notes where the thumb was taken hold of, on a drag's first reading.
---@param drag SliderDrag Changed in place.
---@param thumbLeft number The thumb's left edge, in the slider's parent.
local function rememberGrab(drag, thumbLeft)
    drag.thumbX = thumbLeft
    drag.lastX = drag.mouseX
    drag.grabOffset = drag.mouseX - thumbLeft
end

--- The pointer's position in the slider's parent. PrettyUI drives the drag
--- from both ONHOLD and ONDRAG, which report x in different frames: one
--- relative to the expanded drag area (at the parent's origin), the other
--- to where the thumb was when pressed. The pointer only moves a little per
--- frame, so the reading nearer its last position is the right one.
---@param drag SliderDrag Its lastX is updated.
---@param component userdata The component the hook fired on.
---@param x number The hook's x.
---@return number pointerX
local function pointerPosition(drag, component, x)
    local fromArea = (component.x or 0) + x
    local fromThumb = drag.thumbX + x
    local areaIsNearer = math.abs(fromArea - drag.lastX) <= math.abs(fromThumb - drag.lastX)
    local pointerX = areaIsNearer and fromArea or fromThumb
    drag.lastX = pointerX
    return pointerX
end

--- The value with the thumb's left edge at a place on the track.
---@param slider table
---@param thumbLeft number Pixels from the track's left edge.
---@return number
local function valueAt(slider, thumbLeft)
    local travel = math.max(1, slider.track.width - slider.thumb.width)
    local share = maths.Clamp(thumbLeft / travel, 0, 1)
    return slider.min + share * (slider.max - slider.min)
end

--- Replaces PrettyUI's thumb drag, whose two hooks' readings jumped the
--- value (to its minimum, as seen in game): keeps the thumb under the
--- pointer where it was taken hold of.
---@param slider table
---@param component userdata The component the hook fired on.
---@param x number
---@return boolean
local function updateThumbDrag(slider, component, x)
    local drag = slider.dragStart
    if slider.disabled or drag == nil or type(x) ~= "number" then return false end
    local trackLeft = slider.root.x + slider.track.x
    if drag.thumbX == nil then rememberGrab(drag, trackLeft + slider.thumb.x) end
    local pointerX = pointerPosition(drag, component, x)
    slider:SetValue(valueAt(slider, pointerX - drag.grabOffset - trackLeft))
    return false
end

--- Fixes a new slider: its thumb drag, and re-placing its thumb when it's
--- resized (PrettyUI places it once from its width).
---@param slider table A PrettyUI Slider.
function sliderFixes.Apply(slider)
    slider._UpdateDrag = updateThumbDrag
    slider.root:Subscribe(ui.Hook.ONRESIZE, function()
        if slider.root ~= nil then slider:_LayoutValue() end
        return true
    end)
end

--- Changes a slider's range, as PrettyUI's slider has no range setter, and
--- re-places its thumb.
---@param slider table A PrettyUI Slider.
---@param minimum number
---@param maximum number
function sliderFixes.SetRange(slider, minimum, maximum)
    slider.min, slider.max = minimum, maximum
    slider:_LayoutValue()
    slider:_UpdateState()
end

return sliderFixes
