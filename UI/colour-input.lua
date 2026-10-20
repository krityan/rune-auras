-- A colour control for PrettyUI views: a swatch that opens the colour
-- picker, a hex code field (#RRGGBBAA, or #RRGGBB for opaque), and Copy and
-- Paste buttons sharing one colour clipboard across the whole plugin. The
-- field also works with the system clipboard through Ctrl+C / Ctrl+V; the
-- plugin API has no clipboard access of its own, hence the buttons.
-- Usage:
--   local colourInput = require("UI/colour-input")
--   colourInput.Add(view, {
--       label = "Border colour", value = aura.borderColour,
--       windowTitle = "Bar border colour",
--       onChange = function(colour) ... end,
--   })   --> an input with :SetValue(colour), which doesn't call onChange

local uiConstants = require("UI/ui-constants")

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

local clipboard = nil
local clipboardLoaded = false

local function toHex(colour)
    return string.format("#%08X", colour & 0xFFFFFFFF)
end

-- Accepts RRGGBBAA or RRGGBB (opaque), with or without "#", any case.
-- Also returns how many digits it read (6 or 8).
function colourInput.ParseHex(text)
    local digits = tostring(text or ""):gsub("%s", ""):gsub("^#", "")
    if not digits:match("^%x+$") then return nil end
    if #digits == 6 then return (tonumber(digits, 16) << 8) | 0xFF, 6 end
    if #digits == 8 then return tonumber(digits, 16), 8 end
    return nil
end

local function loadClipboard()
    if clipboardLoaded then return end
    clipboardLoaded = true
    pcall(function()
        clipboard = colourInput.ParseHex(PersistentDB:GetString(CLIPBOARD_STORAGE_KEY))
    end)
end

local function saveClipboard(colour)
    clipboard = colour
    pcall(function() PersistentDB:SetString(CLIPBOARD_STORAGE_KEY, toHex(colour)) end)
end

-- options: label, value, windowTitle, tooltip, onChange(colour),
--          padding (default: view.contentPadding or 12)
function colourInput.Add(view, options)
    loadClipboard()
    local self = setmetatable({
        value = options.value or 0xFFFFFFFF,
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
        maxLength = 9,
        tooltip = "Hex code: #RRGGBBAA, or #RRGGBB for fully opaque. Ctrl+C / Ctrl+V work here.",
        onChange = function(_, reason, content)
            local colour, digits = colourInput.ParseHex(content)
            local submitted = reason == ui.InputFieldActionResult.SUBMIT
            -- Six digits may be on the way to eight (#RRGGBB then AA), so they
            -- only count once submitted; eight apply straight away.
            if colour ~= nil and (digits == 8 or submitted) then
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
        tooltip = "Copy this colour",
    })
    view:AddSpriteButton("IMPORT", function()
        if clipboard ~= nil then self:commit(clipboard, "paste") end
    end, {
        inline = true,
        x = -(padding + BUTTON_SIZE),
        xAnchor = 1,
        size = BUTTON_SIZE,
        offsetY = buttonOffset,
        tooltip = "Paste the copied colour",
    })
    return self
end

-- Brings the other controls in line with a change made through one of them.
function colourInput:commit(colour, from)
    if from ~= "picker" then self.picker:SetValue(colour, false) end
    -- Leave the field alone while it's being typed in.
    if from ~= "field" then self.field:SetText(toHex(colour)) end
    if colour == self.value then return end
    self.value = colour
    if self.onChange ~= nil then self.onChange(colour) end
end

function colourInput:SetValue(colour)
    self.value = colour
    self.picker:SetValue(colour, false)
    self.field:SetText(toHex(colour))
end

return colourInput
