-- The example auras Import's Examples tab lists, each with an icon, a name
-- and a description.
-- TODO: these are placeholders: replace them with real examples and their
-- exports.

---@class AuraExample
---@field name string
---@field description string
---@field objectID integer An item whose icon shows beside it.
---@field export string? The aura's export; nil while it's a placeholder.

---@type AuraExample[]
local EXAMPLES = {
    {
        name = "Example one",
        description = "A placeholder example, to see how the list looks. Real examples will replace it.",
        objectID = 4151,
    },
    {
        name = "Example two",
        description = "A placeholder example with a longer description, to see how the text wraps when it runs over more than one line in a narrow window.",
        objectID = 2434,
    },
    {
        name = "Example three",
        description = "A placeholder example.",
        objectID = 385,
    },
    {
        name = "Example four",
        description = "A placeholder example, to see how the list looks. Real examples will replace it.",
        objectID = 995,
    },
    {
        name = "Example five",
        description = "A placeholder example, to see how the list looks. Real examples will replace it.",
        objectID = 1052,
    },
}

return EXAMPLES
