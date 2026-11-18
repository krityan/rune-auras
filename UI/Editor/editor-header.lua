-- The editor's header, above its tabs: the aura's icon and name, and its
-- Export, Duplicate and Delete buttons.

local auraStore = require("Auras/Store/aura-store")
local dataSources = require("Auras/Registries/data-sources")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local heroIcons = require("UI/Controls/hero-icons")
local uiConstants = require("UI/ui-constants")

local editorHeader = {}

--- What the header's controls do. A button whose handler is nil isn't shown.
---@class EditorHeaderHandlers
---@field onRename fun(name: string) The name was edited; never empty.
---@field onExport fun()?
---@field onDuplicate fun()?
---@field onDelete fun()?

local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local FIELD_HEIGHT = uiConstants.FIELD_HEIGHT
-- Its height: the name field, with a gap above and below.
editorHeader.HEIGHT = FIELD_HEIGHT + GAP * 2
local NAME_LENGTH = 32
-- The aura's icon, as tall as the name field beside it.
local ICON_SIZE = FIELD_HEIGHT
-- Lowers the buttons to the middle of the name field's row.
local BUTTON_OFFSET_Y = (FIELD_HEIGHT - BUTTON_SIZE) // 2

--- Trims spaces from both ends.
---@param value any
---@return string
local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

--- The header's buttons, rightmost first: Delete, Duplicate, Export.
---@param handlers EditorHeaderHandlers
---@return { sprite: string, tooltip: string, onClick: fun() }[]
local function buttonsFor(handlers)
    local buttons = {}
    if handlers.onDelete ~= nil then
        buttons[#buttons + 1] = { sprite = "trash", tooltip = "Delete", onClick = handlers.onDelete }
    end
    if handlers.onDuplicate ~= nil then
        buttons[#buttons + 1] = { sprite = "document-duplicate", tooltip = "Duplicate", onClick = handlers.onDuplicate }
    end
    if handlers.onExport ~= nil then
        buttons[#buttons + 1] = { sprite = "arrow-up-tray", tooltip = "Export", onClick = handlers.onExport }
    end
    return buttons
end

--- Adds the aura's data source icon at the header's left.
---@param view table
---@param aura Aura
---@return boolean added false without an icon (a group, or no source yet).
local function addIcon(view, aura)
    local _, spriteID, objectID = dataSources.Details(aura.source)
    local icon = SourceIcon.NewStill(view.content, spriteID, objectID, ICON_SIZE)
    if icon == nil then return false end
    icon:SetPos(PADDING, GAP)
    return true
end

--- Builds the header at the top of the editor's layer.
---@param prettyUI table
---@param parent userdata The editor's layer.
---@param aura Aura
---@param handlers EditorHeaderHandlers
---@return table view The header's PrettyUI SimpleView, to destroy with the editor.
function editorHeader.Build(prettyUI, parent, aura, handlers)
    local view = prettyUI.SimpleView.new(parent, {
        x = 0,
        y = 0,
        width = 0,
        widthAnchor = 1,
        height = editorHeader.HEIGHT,
        scrollable = false,
        layout = { startY = GAP, paddingLeft = PADDING, paddingRight = PADDING, rowGap = GAP, columnGap = GAP },
    })
    local nameX = PADDING
    if addIcon(view, aura) then nameX = PADDING + ICON_SIZE + GAP end
    local buttons = buttonsFor(handlers)
    local buttonsWidth = #buttons * (BUTTON_SIZE + GAP)
    local nameField
    nameField = view:AddTextField({
        x = nameX,
        width = -(nameX + buttonsWidth + PADDING),
        widthAnchor = 1,
        text = aura.name,
        placeholder = auraStore.IsGroup(aura) and "Group name" or "Aura name",
        maxLength = NAME_LENGTH,
        onChange = function()
            local name = trim(nameField:GetText())
            if name ~= "" then handlers.onRename(name) end
        end,
    })
    for index, button in ipairs(buttons) do
        heroIcons.Button(prettyUI, view.content, button.sprite, button.onClick, {
            x = -(PADDING + index * BUTTON_SIZE + (index - 1) * GAP),
            xAnchor = 1,
            y = GAP + BUTTON_OFFSET_Y,
            tooltip = button.tooltip,
            colour = button.sprite == "trash" and uiConstants.DANGER_RGBA or nil,
        })
    end
    return view
end

return editorHeader
