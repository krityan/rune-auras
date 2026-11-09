-- Converting auras from typed texts to fields: a text was once free text
-- with placeholders ("$current of $max"), and is now one or two fields (see
-- textTemplate). Runs once on a save made before fields, and on an export
-- made before them.

local textTemplate = require("Auras/Helpers/text-template")
local conditions = require("Auras/Registries/conditions")
local displayTypes = require("Auras/Registries/display-types")

local textMigration = {}

-- What a text was when left out, for a display without a text of its own.
local OLD_DEFAULT = "$current / $max"
-- Placeholders that were renamed, to the field they are now.
local RENAMED_FIELDS = { current = "value", arrow = "ammo", arrows = "ammo" }

-- Every placeholder a typed text could hold, longest first, so "$arrows"
-- isn't read as "$arrow" followed by "s".
local PLACEHOLDERS = {}
for _, field in ipairs(textTemplate.FIELDS) do PLACEHOLDERS[#PLACEHOLDERS + 1] = field.id end
for oldName in pairs(RENAMED_FIELDS) do PLACEHOLDERS[#PLACEHOLDERS + 1] = oldName end
table.sort(PLACEHOLDERS, function(first, second) return #first > #second end)

--- The first two fields in a typed text, with the text between them. A
--- placeholder may run into letters ("$maxHP").
---@param text string
---@return TextFieldID[] fields
---@return string? between
local function typedFields(text)
    local fields, between, afterFirst = {}, nil, nil
    for start, word in string.gmatch(text, "()%$(%a+)") do
        for _, name in ipairs(PLACEHOLDERS) do
            if string.sub(word, 1, #name) == name then
                if #fields == 1 then between = string.sub(text, afterFirst, start - 1) end
                fields[#fields + 1] = RENAMED_FIELDS[name] or name
                afterFirst = start + 1 + #name
                break
            end
        end
        if #fields == 2 then break end
    end
    return fields, between
end

--- A text without the spaces at either end.
---@param text string
---@return string
local function trimmed(text)
    return (text:match("^%s*(.-)%s*$"))
end

--- The separator matching what a typed text had between its fields, else
--- the pair's default.
---@param between string
---@param first TextFieldID
---@param second TextFieldID
---@return string
local function separatorFor(between, first, second)
    for _, choice in ipairs(textTemplate.SEPARATORS) do
        if trimmed(choice.id) == trimmed(between) then return choice.id end
    end
    return textTemplate.DefaultSeparator(first, second)
end

--- A typed text as a template: its first two fields, and the separator
--- between them if it's one of ours, losing the rest. With no fields it's
--- the default. Anything but a string is left for loading to check.
---@param text any
---@return any
local function migrateText(text)
    if type(text) ~= "string" or textTemplate.IsValid(text) then return text end
    local fields, between = typedFields(text)
    local first, second = fields[1], fields[2]
    if first == nil then return textTemplate.DEFAULT end
    if second == nil then return textTemplate.Join(first) end
    return textTemplate.Join(first, separatorFor(between, first, second), second)
end

--- Whether a display type has a default text of its own (the Text display).
---@param display any
---@return boolean
local function hasOwnText(display)
    local displayType = displayTypes.Get(display)
    return displayType ~= nil and (displayType.options.defaults or {}).textTemplate ~= nil
end

--- Converts the texts in a saved record from before fields: its own, its
--- text nodes' and its Text changes' values. A record with no text had the
--- old default; a text node with none takes the record's on load.
---@param record table An aura in saved form; changed in place.
function textMigration.MigrateRecord(record)
    if record.textTemplate == nil and not hasOwnText(record.display) then record.textTemplate = OLD_DEFAULT end
    record.textTemplate = migrateText(record.textTemplate)
    for _, node in ipairs(type(record.texts) == "table" and record.texts or {}) do
        if type(node) == "table" then node.textTemplate = migrateText(node.textTemplate) end
    end
    for _, condition in ipairs(type(record.conditions) == "table" and record.conditions or {}) do
        local changes = type(condition) == "table" and condition.changes or nil
        for _, change in ipairs(type(changes) == "table" and changes or {}) do
            local property = type(change) == "table" and conditions.Property(change.property) or nil
            if property ~= nil and property.kind == "text" then change.value = migrateText(change.value) end
        end
    end
end

return textMigration
