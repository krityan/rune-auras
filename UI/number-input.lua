-- A number field for PrettyUI views, optionally paired with a slider. Typing
-- applies valid in-range values straight away; Enter clamps and tidies the
-- field.
-- Usage:
--   local numberInput = require("UI/number-input")
--   local input = numberInput.Add(view, {
--       label = "Width", value = 200, min = 60, max = 600, step = 10,
--       slider = true, onChange = function(value) ... end,
--   })
--   input:SetValue(250)   -- updates the controls without calling onChange

local numberInput = {}
numberInput.__index = numberInput

local FIELD_WIDTH = 80
local GAP = 8
-- The host view's left/right layout padding, unless the view reports its
-- own through `contentPadding` (see the aura editor's sections).
local DEFAULT_PADDING = 12

-- Only allows digits; falls back to no filter if the client lacks it.
local function numericFilter()
    local found, mode = pcall(function() return ui.InputFieldFilterMode.NUMERIC end)
    return found and mode or ui.InputFieldFilterMode.NONE
end

local function clamp(value, minimum, maximum)
    if minimum ~= nil then value = math.max(minimum, value) end
    if maximum ~= nil then value = math.min(maximum, value) end
    return value
end

-- Numbers are whole; the slider snaps to `step`, typed values don't.
local function parse(text)
    local number = tonumber(text)
    if number == nil then return nil end
    return math.floor(number + 0.5)
end

-- options:
--   label, value, min, max, step, tooltip
--   slider    show a slider (needs min < max; otherwise just the field)
--   negative  allow negative numbers (disables the digits-only filter)
--   padding   the view's left/right padding (default: view.contentPadding or 12)
--   onChange  called with the new value
function numberInput.Add(view, options)
    local self = setmetatable({
        min = options.min,
        max = options.max,
        value = options.value or options.min or 0,
        onChange = options.onChange,
    }, numberInput)

    -- PrettyUI's slider errors unless max > min, which an empty range (e.g.
    -- an aura as big as its parent) doesn't give, so that gets a plain field.
    local hasSlider = options.slider == true and options.min ~= nil and options.max ~= nil
        and options.max > options.min
    local padding = options.padding or view.contentPadding or DEFAULT_PADDING
    -- Label on its own row above the controls, like every editor option.
    view:AddText({ text = options.label, height = 24, maxLines = 1, tooltip = options.tooltip })
    if hasSlider then
        -- The slider takes whatever the field, pinned right, leaves.
        self.slider = view:AddSlider({
            width = -(padding * 2 + FIELD_WIDTH + GAP),
            widthAnchor = 1,
            min = options.min,
            max = options.max,
            step = options.step or 1,
            value = self.value,
            tooltip = options.tooltip,
            onChange = function(_, value)
                self:commit(math.floor(value + 0.5), true)
            end,
        })
        -- PrettyUI's slider places its thumb once from its width, so redo it
        -- when the window is resized.
        local slider = self.slider
        slider.root:Subscribe(ui.Hook.ONRESIZE, function()
            if slider.root ~= nil then slider:_LayoutValue() end
            return true
        end)
    end

    self.field = view:AddTextField({
        inline = hasSlider,
        x = hasSlider and -(padding + FIELD_WIDTH) or nil,
        xAnchor = hasSlider and 1 or nil,
        width = FIELD_WIDTH,
        text = tostring(self.value),
        maxLength = 6,
        filterMode = options.negative and ui.InputFieldFilterMode.NONE or numericFilter(),
        tooltip = options.tooltip,
        onChange = function(_, reason, content)
            local value = parse(content)
            if reason == ui.InputFieldActionResult.SUBMIT then
                self:commit(clamp(value or self.value, self.min, self.max), false)
                self.field:SetText(tostring(self.value))
            elseif value ~= nil and value == clamp(value, self.min, self.max) then
                -- Leave the text alone mid-typing (e.g. "1" on the way to "150").
                self:commit(value, false)
            end
        end,
    })
    return self
end

function numberInput:commit(value, fromSlider)
    if fromSlider then
        self.field:SetText(tostring(value))
    elseif self.slider ~= nil then
        self.slider:SetValue(value, false)
    end
    if value == self.value then return end
    self.value = value
    if self.onChange ~= nil then self.onChange(value) end
end

function numberInput:SetValue(value)
    self.value = value
    self.field:SetText(tostring(value))
    if self.slider ~= nil then self.slider:SetValue(value, false) end
end

-- Changes the allowed range without touching the value; follow with
-- SetValue if it may now be out of range. PrettyUI's slider has no range
-- setter, so this sets its min/max and re-places the thumb itself.
function numberInput:SetRange(minimum, maximum)
    self.min, self.max = minimum, maximum
    local slider = self.slider
    if slider == nil or slider.root == nil or minimum == nil or maximum == nil
        or maximum <= minimum then return end
    slider.min, slider.max = minimum, maximum
    slider:_LayoutValue()
    slider:_UpdateState()
end

return numberInput
