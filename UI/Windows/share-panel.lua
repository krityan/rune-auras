-- The Import and Export panels, shown in the main window's editor area:
-- boxes to paste an export into, or to copy one from. The export format
-- belongs to aura-share.

local auraShare = require("Auras/Sharing/aura-share")
local auraStore = require("Auras/Store/aura-store")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local sharePanel = {}

--- What the panels need from the main window.
---@class SharePanelHost
---@field openPanel fun(title: string, build: fun(view: table)) Shows a panel in the editor's place.
---@field onImported fun(made: Aura[]) Called with the auras an import made.

local PADDING = uiConstants.PADDING
local IMPORT_EVENT_ID = "runeAuras_sharePanelImport"
-- The most the game's input fields take, however much is asked for (seen
-- in game: a paste is cut off here). The Export box is filled in code, so
-- it shows more, but Import can't take more back.
local SHARE_MAX_LENGTH = 9999
local SHARE_ERROR_RGBA = 0xE07060FF
-- A box's height when there are several; a lone box takes the rest of the panel.
local SHARE_BOX_HEIGHT = 120
local TEXT_HEIGHT, TEXT_LINES = 40, 2
local IMPORT_BUTTON_WIDTH = 150
-- As many lines as the text needs.
local UNLIMITED_LINES = 0

--- Adds a box many lines tall, that scrolls: the native input field shows
--- a scrollbar when its text needs one. Its text wraps at the spaces an
--- export is broken up with (see auraShare.Export).
---@param view table
---@param text string?
---@param placeholder string?
---@param fill boolean Take the rest of the panel (a lone box).
---@param onChange fun(content: string)? Called with its text as it changes.
---@return table field The PrettyUI text field.
local function addShareBox(view, text, placeholder, fill, onChange)
    local field = view:AddTextField({
        width = -(PADDING * 2),
        widthAnchor = 1,
        height = SHARE_BOX_HEIGHT,
        text = text or "",
        placeholder = placeholder,
        maxLength = math.max(SHARE_MAX_LENGTH, #(text or "")),
        onChange = onChange and function(_, _, content) onChange(content) end or nil,
    })
    local box = field.root
    if box ~= nil then
        box.text.maxLines = UNLIMITED_LINES
        box.text.alignVertical = ui.AlignMode.TOPLEFT
        -- Down to the bottom of the panel, whatever's above it.
        if fill then box:SetSize(-(PADDING * 2), -((box.y or 0) + PADDING), 1, 1) end
    end
    return field
end

--- Adds muted explanatory text.
---@param view table
---@param text string
local function addHint(view, text)
    view:AddText({ text = text, height = TEXT_HEIGHT, maxLines = TEXT_LINES, colour = uiConstants.MUTED_RGBA })
end

--- Adds the pasted auras, or shows why it couldn't, with as many boxes as a
--- multi-part export needs.
---@param host SharePanelHost
---@param texts string[] What's in each box.
local function importTexts(host, texts)
    local made, problem, partsNeeded = auraShare.Import(texts)
    if made == nil then
        sharePanel.OpenImport(host, problem, texts, partsNeeded)
        return
    end
    host.onImported(made)
end

--- Shows Import's panel: a box (or one per part of a multi-part export) to
--- paste into, with what went wrong last time and what was pasted.
---@param host SharePanelHost
---@param problem string? Why the last import failed.
---@param texts string[]? What was pasted.
---@param boxCount integer? How many boxes; at least one per pasted text.
function sharePanel.OpenImport(host, problem, texts, boxCount)
    texts = texts or {}
    boxCount = math.max(1, boxCount or 1, #texts)
    host.openPanel("Import", function(view)
        addHint(view, boxCount > 1
            and "This export comes in parts: paste each into a box (Ctrl+V), in any order, then Import."
            or "Paste an export (Ctrl+V) into the box, then Import. It's added at the top level, where it was on screen.")
        -- The button and any problem go above the boxes.
        local fields = {}
        view:AddFancyButton("Import", function()
            local pasted = {}
            for index, field in ipairs(fields) do pasted[index] = field:GetText() end
            -- Importing replaces this panel, so after this callback.
            nextFrame.Run(IMPORT_EVENT_ID, function() importTexts(host, pasted) end)
        end, { width = IMPORT_BUTTON_WIDTH, variant = "positive" })
        if problem ~= nil then
            view:AddText({ text = problem, height = TEXT_HEIGHT, maxLines = TEXT_LINES, colour = SHARE_ERROR_RGBA })
        end
        for index = 1, boxCount do
            if boxCount > 1 then view:AddText(formatStr("Box {}", index)) end
            local placeholder = index == 1 and "RA1:..." or "RAP1:..."
            local fillsPanel = boxCount == 1
            -- Kept in `texts`, so the panel built again for a new width keeps it.
            fields[index] = addShareBox(view, texts[index], placeholder, fillsPanel, function(content)
                texts[index] = content
            end)
        end
    end)
end

--- Shows Export's panel: the aura's export in a box to copy, or one box per
--- part if it's too long for one.
---@param host SharePanelHost
---@param auraID integer
function sharePanel.OpenExport(host, auraID)
    local aura = auraStore.Get(auraID)
    local parts = aura and auraShare.Export(auraID, gameApi.GameAreaSize())
    if parts == nil then return end
    host.openPanel("Export", function(view)
        local holds = auraStore.IsGroup(aura) and "It holds the group and everything in it." or "It holds the aura."
        addHint(view, #parts > 1
            and formatStr("Too long for one box, so it's in {} parts. Copy each (click it, Ctrl+A, Ctrl+C) into its own box on Import. {}", #parts, holds)
            or "Click the box, then Ctrl+A and Ctrl+C to copy it. " .. holds)
        for index, part in ipairs(parts) do
            if #parts > 1 then view:AddText(formatStr("Part {} of {}", index, #parts)) end
            addShareBox(view, part, nil, #parts == 1)
        end
    end)
end

--- Drops an import waiting for the next frame, e.g. when the window closes.
function sharePanel.Cancel()
    nextFrame.Cancel(IMPORT_EVENT_ID)
end

return sharePanel
