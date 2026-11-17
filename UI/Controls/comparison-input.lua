-- A comparison with a number: an operator (Below, At least, ...;
-- conditions.OPERATORS) and the number beside it, which takes decimals.
-- Conditions' checks put it on its own row under "Which is"; load options
-- that compare a number put it at the end of their row, after "is".

local conditions = require("Auras/Registries/conditions")
local choiceCombo = require("UI/Controls/choice-combo")
local uiConstants = require("UI/ui-constants")

local comparisonInput = {}

local GAP = uiConstants.GAP
local OPERATOR_WIDTH = 100
local VALUE_FIELD_LENGTH = 8

---@class ComparisonInputOptions
---@field op string? An OPERATORS id; anything else shows the first.
---@field value number?
---@field onOperator fun(operatorID: string)
---@field onValue fun(number: number) Called as a number is typed; text that isn't one is ignored.
---@field x number? Where the operator starts, on the row before it (with xAnchor); nil for a row of its own under "Which is".
---@field xAnchor number? The share of the row's width added to `x`.

--- Adds the field the number is typed in, allowing decimals (e.g. 0.2
--- seconds), which the number input doesn't. It sits just after the
--- operator box and fills the rest of the row.
---@param view EditorView
---@param operatorX number Where the operator starts, with xAnchor.
---@param xAnchor number
---@param value number?
---@param onChange fun(number: number)
local function addNumberField(view, operatorX, xAnchor, value, onChange)
    local padding = view.contentPadding
    local x = operatorX + OPERATOR_WIDTH + GAP
    view:AddTextField({
        inline = true,
        x = x,
        xAnchor = xAnchor,
        width = -(x + padding),
        widthAnchor = 1 - xAnchor,
        text = tostring(value or 0),
        maxLength = VALUE_FIELD_LENGTH,
        filterMode = ui.InputFieldFilterMode.NONE,
        onChange = function(_, _, content)
            local number = tonumber(content)
            if number ~= nil then onChange(number) end
        end,
    })
end

--- Adds the operator and the number to a view: on a row of their own under
--- "Which is", or after what's on the row before them (see options.x).
---@param view EditorView
---@param options ComparisonInputOptions
function comparisonInput.Add(view, options)
    local isOwnRow = options.x == nil
    local operatorX = options.x or view.contentPadding
    local xAnchor = options.xAnchor or 0
    choiceCombo.Add(view, {
        label = isOwnRow and "Which is" or nil,
        inline = not isOwnRow or nil,
        x = not isOwnRow and operatorX or nil,
        xAnchor = not isOwnRow and xAnchor or nil,
        choices = conditions.OPERATORS,
        value = options.op,
        width = OPERATOR_WIDTH,
        onChange = options.onOperator,
    })
    addNumberField(view, operatorX, xAnchor, options.value, options.onValue)
end

return comparisonInput
