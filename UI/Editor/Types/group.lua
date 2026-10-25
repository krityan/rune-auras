-- Group editor settings (see TypeEditor in UI/Editor/aura-editor). A group
-- is only a point its contents are placed from, so the editor drops the
-- data source, appearance, text and size sections for it.

---@type TypeEditor
local groupEditor = {}

groupEditor.usesSource = false
groupEditor.usesAppearance = false
groupEditor.usesText = false

return groupEditor
