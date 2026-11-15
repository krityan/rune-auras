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
-- A box's height when there are several; a lone box takes the rest of the panel.
local SHARE_BOX_HEIGHT = 120
local TEXT_HEIGHT, TEXT_LINES = 60, 3
local IMPORT_BUTTON_WIDTH = 150
local EXPORT_HINT = "Other players can import your aura using the below string"
-- The most lines a box shows. An input field wraps only when its text may
-- take more than one line, and 0, which is unlimited for other text, keeps
-- it on one. This is the most `maxLines` holds.
local MAX_LINES = 255

--- Adds a box many lines tall, that scrolls: the native input field shows
--- a scrollbar when its text needs one, over the ends of its lines. Its
--- text wraps at the box's edge, between any two characters, so base64
--- needs no spaces to wrap.
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
        maxLength = math.max(auraShare.BOX_LIMIT, #(text or "")),
        onChange = onChange and function(_, _, content) onChange(content) end or nil,
    })
    local box = field.root
    if box ~= nil then
        box.text.maxLines = MAX_LINES
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
        if boxCount > 1 then addHint(view, "Paste each part into a box, in any order.") end
        -- The button and any problem go above the boxes.
        local fields = {}
        view:AddFancyButton("Import", function()
            local pasted = {}
            for index, field in ipairs(fields) do pasted[index] = field:GetText() end
            -- Importing replaces this panel, so after this callback.
            nextFrame.Run(IMPORT_EVENT_ID, function() importTexts(host, pasted) end)
        end, { width = IMPORT_BUTTON_WIDTH, variant = "positive" })
        if problem ~= nil then
            view:AddText({ text = problem, height = TEXT_HEIGHT, maxLines = TEXT_LINES, colour = uiConstants.DANGER_RGBA })
        end
        for index = 1, boxCount do
            if boxCount > 1 then view:AddText(formatStr("Box {}", index)) end
            local placeholder = index == 1 and "Paste the aura here" or "Paste another part here"
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
    if aura == nil then return end
    local parts = auraShare.Export(auraID, gameApi.GameAreaSize())
    if parts == nil then return end
    host.openPanel("Export", function(view)
        addHint(view, EXPORT_HINT)
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
