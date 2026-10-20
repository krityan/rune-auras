-- Group-specific settings for the aura editor (see UI/Windows/aura-editor).
-- A group only moves what's in it, so the editor drops the data source,
-- appearance, text and size sections for it, and its position is a plain
-- X/Y offset with no anchor.

local groupEditor = {}

groupEditor.usesSource = false
groupEditor.usesAppearance = false
groupEditor.usesText = false
groupEditor.usesAnchor = false

return groupEditor
