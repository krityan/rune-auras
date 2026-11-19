-- Places editor labels beside their controls when the inspector is wide
-- enough, and gives every label one look, wide or stacked.

local fontCatalogue = require("GameData/Catalogues/font-catalogue")
local uiConstants = require("UI/ui-constants")

local formView = {}
local LABEL_WIDTH = 130
local LABEL_OFFSET = LABEL_WIDTH + uiConstants.GAP
local COLUMN_MIN_WIDTH = 480
local PADDING = uiConstants.PADDING

local OPTIONS_INDEX = {
    AddText = 1, AddTextField = 1, AddComboBox = 1, AddSlider = 1,
    AddColourPicker = 1, AddCheckboxButton = 2, AddSpriteButton = 3,
    AddFancyButton = 3, AddSimpleButton = 3, AddSprite = 2,
}
local FILL_WIDTH = { AddText = true, AddTextField = true, AddComboBox = true, AddSprite = true }
-- Every label's font and colour, beside its control or above it.
local LABEL_FONT, LABEL_SIZE = "museo_sans_regular", 13
local LABEL_RGBA = uiConstants.MUTED_RGBA

local function textFont(text) return text.font end
local function setTextLook(text, handle)
    -- Font first: assigning a font resets the colour.
    text.font = handle
    text.rgba = LABEL_RGBA
end

--- Gives a label PrettyUI made the labels' font and colour: PrettyUI's text
--- options take a colour but no font, so the font is set on its native text,
--- the control itself or its root (whichever reads a font).
-- TODO: check in game that one of them takes the font.
---@param control any What AddText returned.
local function styleLabel(control)
    if type(control) ~= "table" and type(control) ~= "userdata" then
        return
    end

    local handle = fontCatalogue.Resolve(LABEL_FONT, LABEL_SIZE)
    if handle == nil then
        return
    end

    for _, candidate in ipairs({ control, type(control) == "table" and control.root or nil }) do
        local isNative = type(candidate) == "userdata"
        local readsFont = isNative and select(2, pcall(textFont, candidate))
        if type(readsFont) == "number" then
            pcall(setTextLook, candidate, handle)
            return
        end
    end
end

--- Wraps a tab page with aligned label rows and a stacked layout at narrow widths.
---@param host table PrettyUI tab page.
---@param width number Inspector width in interface units.
---@return EditorView view
function formView.New(host, width)
    local columns = width >= COLUMN_MIN_WIDTH
    local labelPending, controlRow = false, false
    local view = { contentPadding = PADDING }
    for method, optionsIndex in pairs(OPTIONS_INDEX) do
        view[method] = function(_, ...)
            local args = table.pack(...)
            local options = args[optionsIndex]
            local plainLabel = method == "AddText" and type(options) == "string"
            if plainLabel then
                options = { text = options }
            end

            local placed = {}
            for key, value in pairs(options or {}) do
                placed[key] = value
            end

            local wasInline = placed.inline == true
            local isLabel = plainLabel or (method == "AddText" and placed.height == uiConstants.LABEL_HEIGHT)
            -- A row's own text can ask to look like a label (Icon: default)
            -- without being laid out as one.
            local looksLikeLabel = isLabel or (method == "AddText" and placed.label == true)
            placed.label = nil

            if placed.inline ~= true then
                controlRow = columns and labelPending and method ~= "AddText"
                labelPending = columns and isLabel
            end

            if looksLikeLabel then
                placed.colour = LABEL_RGBA
            end

            if columns and isLabel then
                placed.width = LABEL_WIDTH
                placed.height = uiConstants.FIELD_HEIGHT
                placed.maxLines = 1
            end

            local shift = controlRow and LABEL_OFFSET or 0

            if placed.inline ~= true and controlRow then
                placed.inline = true
            end

            local xAnchor = placed.xAnchor or 0
            if placed.x == nil and xAnchor == 0 and not wasInline then
                placed.x = PADDING
            end

            if placed.x ~= nil then
                placed.x = placed.x + shift * (1 - xAnchor)
            end

            if placed.width == nil and FILL_WIDTH[method] then
                placed.width = -PADDING * 2
                placed.widthAnchor = 1
            end

            if placed.width ~= nil then
                placed.width = placed.width - shift * (placed.widthAnchor or 0)
            end

            args[optionsIndex] = placed
            args.n = math.max(args.n, optionsIndex)
            local control = host[method](host, table.unpack(args, 1, args.n))
            if looksLikeLabel then
                styleLabel(control)
            end

            return control
        end
    end

    return view
end

return formView
