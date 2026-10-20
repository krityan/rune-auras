-- Fills an aura's text template with its values.
-- Placeholders: $current (current value) and $max (maximum value).
-- Usage: local textTemplate = require("Auras/text-template")
--        textTemplate.Format("$current / $max", 57, 100) --> "57 / 100"

local textTemplate = {}

textTemplate.DEFAULT = "$current / $max"

local PLACEHOLDERS = { "current", "max" }

function textTemplate.Format(template, curr, max)
    local values = {
        current = tostring(curr),
        max = tostring(max),
    }
    -- A placeholder may run into letters ("$maxHP"); unknown ones such as
    -- "$foo" are left as written.
    local text = string.gsub(template or textTemplate.DEFAULT, "%$(%a+)", function(word)
        for _, name in ipairs(PLACEHOLDERS) do
            if word:sub(1, #name) == name then
                return values[name] .. word:sub(#name + 1)
            end
        end
    end)
    return text
end

return textTemplate
