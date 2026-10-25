-- A colour control: a swatch that opens the colour picker, a hex code field
-- (#RRGGBBAA, or #RRGGBB for opaque), and Copy and Paste buttons sharing one
-- colour clipboard across the whole plugin. The plugin API has no clipboard
-- access of its own, hence the buttons; the field also works with the
-- system clipboard through Ctrl+C / Ctrl+V.

local uiConstants = require("UI/ui-constants")

---@class ColourInputOptions
---@field label string
---@field value integer? 0xRRGGBBAA; white if nil.
---@field windowTitle string? The picker window's title; the label if nil.
---@field tooltip string?
---@field padding number? The view's left/right padding; the view's contentPadding or the default if nil.
---@field onChange fun(colour: integer)?

---@class ColourInput
---@field value integer
---@field onChange fun(colour: integer)?
---@field picker table PrettyUI colour picker.
---@field field table PrettyUI text field.
local colourInput = {}
colourInput.__index = colourInput

local SWATCH_WIDTH, SWATCH_HEIGHT = 40, 32
local FIELD_HEIGHT = uiConstants.FIELD_HEIGHT
local BUTTON_SIZE = uiConstants.BUTTON_SIZE
local GAP = uiConstants.GAP
-- The host view's left/right layout padding, unless the view reports its
-- own through `contentPadding` (see the aura editor's sections).
local DEFAULT_PADDING = uiConstants.PADDING
-- The copied colour, kept between sessions as hex.
local CLIPBOARD_STORAGE_KEY = "colourClipboard"
local DEFAULT_COLOUR = 0xFFFFFFFF
local COLOUR_BITS = 0xFFFFFFFF
local OPAQUE_ALPHA = 0xFF
-- "#" and eight digits.
local HEX_FIELD_LENGTH = 9
local OPAQUE_DIGITS, FULL_DIGITS = 6, 8

local clipboard = nil
local clipboardLoaded = false

--- A colour as "#RRGGBBAA".
---@param colour integer
---@return string
local function toHex(colour)
    return string.format("#%08X", colour & COLOUR_BITS)
end

--- Reads a hex colour: RRGGBBAA, or RRGGBB (opaque), with or without "#",
--- any case.
---@param text any
---@return integer? colour nil if it isn't one.
---@return integer? digits How many digits it read (6 or 8).
function colourInput.ParseHex(text)
    local digits = tostring(text or ""):gsub("%s", ""):gsub("^#", "")
    if not digits:match("^%x+$") then return nil end
    if #digits == OPAQUE_DIGITS then return (tonumber(digits, 16) << 8) | OPAQUE_ALPHA, OPAQUE_DIGITS end
    if #digits == FULL_DIGITS then return tonumber(digits, 16), FULL_DIGITS end
    return nil
end

--- Loads the copied colour, once.
local function loadClipboard()
    if clipboardLoaded then return end
    clipboardLoaded = true
    clipboard = colourInput.ParseHex(PersistentDB:GetString(CLIPBOARD_STORAGE_KEY))
end

--- Copies a colour, and saves it.
---@param colour integer
local function saveClipboard(colour)
    clipboard = colour
    PersistentDB:SetString(CLIPBOARD_STORAGE_KEY, toHex(colour))
end

--- Adds the control (label, swatch, field, Copy and Paste) to a view.
---@param view EditorView
---@param options ColourInputOptions
---@return ColourInput input Its SetValue updates the controls without calling onChange.
function colourInput.Add(view, options)
    loadClipboard()
    local self = setmetatable({
        value = options.value or DEFAULT_COLOUR,
        onChange = options.onChange,
    }, colourInput)
    local padding = options.padding or view.contentPadding or DEFAULT_PADDING

    view:AddText({ text = options.label, height = uiConstants.LABEL_HEIGHT, maxLines = 1, tooltip = options.tooltip })
    self.picker = view:AddColourPicker({
        width = SWATCH_WIDTH,
        height = SWATCH_HEIGHT,
        value = self.value,
        alphaSlider = true,
        windowTitle = options.windowTitle or options.label,
        tooltip = options.tooltip,
        onChange = function(_, colour)
            self:commit(colour, "picker")
        end,
    })
    -- The field fills the space between the swatch and the two buttons.
    local fieldX = padding + SWATCH_WIDTH + GAP
    self.field = view:AddTextField({
        inline = true,
        x = fieldX,
        width = -(fieldX + padding + (BUTTON_SIZE + GAP) * 2),
        widthAnchor = 1,
        height = FIELD_HEIGHT,
        offsetY = (SWATCH_HEIGHT - FIELD_HEIGHT) // 2,
        text = toHex(self.value),
        placeholder = "#RRGGBBAA",
        maxLength = HEX_FIELD_LENGTH,
        tooltip = "#RRGGBBAA or #RRGGBB",
        onChange = function(_, reason, content)
            local colour, digits = colourInput.ParseHex(content)
            local submitted = reason == ui.InputFieldActionResult.SUBMIT
            -- Six digits may be on the way to eight (#RRGGBB then AA), so they
            -- only count once submitted; eight apply straight away.
            if colour ~= nil and (digits == FULL_DIGITS or submitted) then
                self:commit(colour, "field")
            elseif submitted then
                -- An unfinished code goes back to the current colour.
                self.field:SetText(toHex(self.value))
            end
        end,
    })
    local buttonOffset = (SWATCH_HEIGHT - BUTTON_SIZE) // 2
    view:AddSpriteButton("EXPORT", function()
        saveClipboard(self.value)
    end, {
        inline = true,
        x = -(padding + BUTTON_SIZE + BUTTON_SIZE + GAP),
        xAnchor = 1,
        size = BUTTON_SIZE,
        offsetY = buttonOffset,
        tooltip = "Copy",
    })
    view:AddSpriteButton("IMPORT", function()
        if clipboard ~= nil then self:commit(clipboard, "paste") end
    end, {
        inline = true,
        x = -(padding + BUTTON_SIZE),
        xAnchor = 1,
        size = BUTTON_SIZE,
        offsetY = buttonOffset,
        tooltip = "Paste",
    })
    return self
end

--- Brings the other controls in line with a change made through one of
--- them, and reports it if the colour changed.
---@param colour integer
---@param from "picker"|"field"|"paste" The control it came from, left alone.
function colourInput:commit(colour, from)
    if from ~= "picker" then self.picker:SetValue(colour, false) end
    -- Leave the field alone while it's being typed in.
    if from ~= "field" then self.field:SetText(toHex(colour)) end
    if colour == self.value then return end
    self.value = colour
    if self.onChange ~= nil then self.onChange(colour) end
end

--- Shows a colour without calling onChange.
---@param colour integer
function colourInput:SetValue(colour)
    self.value = colour
    self.picker:SetValue(colour, false)
    self.field:SetText(toHex(colour))
end

return colourInput
