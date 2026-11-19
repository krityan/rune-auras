-- A comparison with a number: an operator (conditions.OPERATORS) and a number,
-- which takes decimals. It ends a row, after "is" (see split-row), in checks
-- and load options that compare a number.

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
---@field x number Where the operator starts on the row, with xAnchor.
---@field xAnchor number The share of the row's width added to `x`.

--- Adds the operator, and the field the number is typed in, which allows
--- decimals (e.g. 0.2 seconds), as the number input doesn't, on the row
--- before them. The field fills the rest of the row.
---@param view EditorView
---@param options ComparisonInputOptions
function comparisonInput.Add(view, options)
    choiceCombo.Add(view, {
        inline = true,
        x = options.x,
        xAnchor = options.xAnchor,
        choices = conditions.OPERATORS,
        value = options.op,
        width = OPERATOR_WIDTH,
        onChange = options.onOperator,
    })

    local fieldX = options.x + OPERATOR_WIDTH + GAP
    view:AddTextField({
        inline = true,
        x = fieldX,
        xAnchor = options.xAnchor,
        width = -(fieldX + view.contentPadding),
        widthAnchor = 1 - options.xAnchor,
        text = tostring(options.value or 0),
        maxLength = VALUE_FIELD_LENGTH,
        filterMode = ui.InputFieldFilterMode.NONE,
        onChange = function(_, _, content)
            local number = tonumber(content)
            if number ~= nil then
                options.onValue(number)
            end
        end,
    })
end

return comparisonInput
