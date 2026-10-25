-- A whole-number control: a field, optionally with a slider. Typing applies
-- valid in-range values straight away; Enter clamps and tidies the field.

local uiConstants = require("UI/ui-constants")
local maths = require("Auras/Helpers/maths")
local sliderFixes = require("UI/PrettyUI/slider-fixes")

local clamp = maths.Clamp

---@class NumberInputOptions
---@field label string
---@field value number?
---@field min number?
---@field max number?
---@field step number? The slider snaps to it; typed values don't.
---@field tooltip string?
---@field slider boolean? Show a slider (needs min < max; otherwise just the field).
---@field negative boolean? Allow negative numbers (turns off the digits-only filter).
---@field padding number? The view's left/right padding; the view's contentPadding or the default if nil.
---@field onChange fun(value: number)?

---@class NumberInput
---@field min number?
---@field max number?
---@field value number
---@field onChange fun(value: number)?
---@field slider table? PrettyUI slider.
---@field field table PrettyUI text field.
local numberInput = {}
numberInput.__index = numberInput

local FIELD_WIDTH = 80
local FIELD_LENGTH = 6
local GAP = uiConstants.GAP
-- The host view's left/right layout padding, unless the view reports its
-- own through `contentPadding` (see the aura editor's sections).
local DEFAULT_PADDING = uiConstants.PADDING

--- A typed number, rounded to whole.
---@param text string
---@return integer? value nil if it isn't a number.
local function parse(text)
    local number = tonumber(text)
    if number == nil then return nil end
    return math.floor(number + 0.5)
end

--- Adds a slider that takes whatever the field, pinned right, leaves.
---@param self NumberInput
---@param view EditorView
---@param options NumberInputOptions
---@param padding number
local function addSlider(self, view, options, padding)
    self.slider = view:AddSlider({
        width = -(padding * 2 + FIELD_WIDTH + GAP),
        widthAnchor = 1,
        min = options.min,
        max = options.max,
        step = options.step or 1,
        value = self.value,
        tooltip = options.tooltip,
        onChange = function(_, value)
            self:commit(math.floor(value + 0.5), "slider")
        end,
    })
    sliderFixes.Apply(self.slider)
end

--- Adds the control (label, slider, field) to a view.
---@param view EditorView
---@param options NumberInputOptions
---@return NumberInput input Its SetValue updates the controls without calling onChange.
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
    view:AddText({ text = options.label, height = uiConstants.LABEL_HEIGHT, maxLines = 1, tooltip = options.tooltip })
    if hasSlider then addSlider(self, view, options, padding) end

    self.field = view:AddTextField({
        inline = hasSlider,
        x = hasSlider and -(padding + FIELD_WIDTH) or nil,
        xAnchor = hasSlider and 1 or nil,
        width = FIELD_WIDTH,
        text = tostring(self.value),
        maxLength = FIELD_LENGTH,
        -- Digits only, unless negative numbers need a "-".
        filterMode = options.negative and ui.InputFieldFilterMode.NONE or ui.InputFieldFilterMode.NUMERIC,
        tooltip = options.tooltip,
        onChange = function(_, reason, content)
            local value = parse(content)
            if reason == ui.InputFieldActionResult.SUBMIT then
                self:commit(clamp(value or self.value, self.min, self.max), "field")
                self.field:SetText(tostring(self.value))
            elseif value ~= nil and value == clamp(value, self.min, self.max) then
                -- Leave the text alone mid-typing (e.g. "1" on the way to "150").
                self:commit(value, "field")
            end
        end,
    })
    return self
end

--- Brings the other control in line with a change made through one of
--- them, and reports it if the value changed.
---@param value number
---@param from "slider"|"field" The control it was made through, which already shows it.
function numberInput:commit(value, from)
    if from == "slider" then
        self.field:SetText(tostring(value))
    elseif self.slider ~= nil then
        self.slider:SetValue(value, false)
    end
    if value == self.value then return end
    self.value = value
    if self.onChange ~= nil then self.onChange(value) end
end

--- Shows a value without calling onChange.
---@param value number
function numberInput:SetValue(value)
    self.value = value
    self.field:SetText(tostring(value))
    if self.slider ~= nil then self.slider:SetValue(value, false) end
end

--- Changes the allowed range without touching the value; follow with
--- SetValue if it may now be out of range.
---@param minimum number?
---@param maximum number?
function numberInput:SetRange(minimum, maximum)
    self.min, self.max = minimum, maximum
    local slider = self.slider
    local isValidRange = minimum ~= nil and maximum ~= nil and maximum > minimum
    if slider == nil or slider.root == nil or not isValidRange then return end
    sliderFixes.SetRange(slider, minimum, maximum)
end

return numberInput
