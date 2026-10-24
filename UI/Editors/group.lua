-- Group-specific settings for the aura editor (see UI/Windows/aura-editor).
-- A group is only a point its contents are placed from, so the editor drops
-- the data source, appearance, text and size sections for it.

local groupEditor = {}

groupEditor.usesSource = false
groupEditor.usesAppearance = false
groupEditor.usesText = false

return groupEditor
