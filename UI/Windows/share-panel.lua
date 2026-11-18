-- The Import and Export panels, shown in the main window's editor area:
-- boxes to paste an export into, or to copy one from, and Import's list of
-- example auras. The export format belongs to aura-share.

local auraShare = require("Auras/Sharing/aura-share")
local auraExamples = require("Auras/Sharing/examples")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local pageText = require("UI/Controls/page-text")
local rectangles = require("Auras/Displays/Parts/rectangles")
local auraStore = require("Auras/Store/aura-store")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local sharePanel = {}

--- What the panels need from the main window.
---@class SharePanelHost
---@field openPanel fun(title: string?, build: fun(view: table, tabIndex: integer?), tabs: PanelTabs?) Shows a panel in the editor's place.
---@field textArea fun(): number, number Where a panel's own text starts (its top) and how wide it can be.
---@field onImported fun(made: Aura[]) Called with the auras an import made.

local PADDING = uiConstants.PADDING
local IMPORT_EVENT_ID = "runeAuras_sharePanelImport"
-- A box's height: Export's when there are several (a lone box takes the
-- rest of the panel), and Import's.
local SHARE_BOX_HEIGHT = 120
local IMPORT_BOX_HEIGHT = 200
-- Import's tabs, and the one it shows: kept for the session, so it opens
-- on the tab last used.
local EXAMPLES_TAB, CUSTOM_TAB = 1, 2
---@type PanelTabs
local importTabs = { names = { "Examples", "Custom" }, active = EXAMPLES_TAB }
-- An example's icon, the space between it and its text, and the space
-- inside its row, around them.
local EXAMPLE_ICON_SIZE = 32
local EXAMPLE_GAP = 14
local EXAMPLE_ROW_PADDING = 8
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
---@param height number? Its height, if not SHARE_BOX_HEIGHT.
---@return table field The PrettyUI text field.
local function addShareBox(view, text, placeholder, fill, onChange, height)
    local field = view:AddTextField({
        width = -(PADDING * 2),
        widthAnchor = 1,
        height = height or SHARE_BOX_HEIGHT,
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

--- Adds Import's Custom tab: a box (or one per part of a multi-part
--- export) to paste into, with what went wrong last time, and the Import
--- button under them.
---@param host SharePanelHost
---@param view table The tab's page.
---@param problem string?
---@param texts string[] What's in each box, kept as it changes.
---@param boxCount integer
local function addCustomTab(host, view, problem, texts, boxCount)
    if boxCount > 1 then addHint(view, "Paste each part into a box, in any order.") end
    if problem ~= nil then
        view:AddText({ text = problem, height = TEXT_HEIGHT, maxLines = TEXT_LINES, colour = uiConstants.DANGER_RGBA })
    end
    local fields = {}
    for index = 1, boxCount do
        if boxCount > 1 then view:AddText(formatStr("Box {}", index)) end
        local placeholder = index == 1 and "Paste the aura here" or "Paste another part here"
        local height = boxCount == 1 and IMPORT_BOX_HEIGHT or SHARE_BOX_HEIGHT
        -- Kept in `texts`, so the panel built again (for a new width, or
        -- after a tab change) keeps it.
        fields[index] = addShareBox(view, texts[index], placeholder, false, function(content)
            texts[index] = content
        end, height)
    end
    view:AddFancyButton("Import", function()
        local pasted = {}
        for index, field in ipairs(fields) do pasted[index] = field:GetText() end
        -- Importing replaces this panel, so after this callback.
        nextFrame.Run(IMPORT_EVENT_ID, function() importTexts(host, pasted) end)
    end, { width = IMPORT_BUTTON_WIDTH, variant = "positive" })
end

--- Adds one example's row: a fill, alternating down the list as the aura
--- list's rows do, with its icon on the left and its name and description
--- beside it.
---@param content userdata
---@param example AuraExample
---@param index integer Its place in the list, for its fill.
---@param y number
---@param width number
---@return number height
local function addExample(content, example, index, y, width)
    -- Made first, so it draws behind the rest.
    local fill = rectangles.Filled(content, uiConstants.LIST_ROW_RGBAS[index % 2 + 1])
    local top = y + EXAMPLE_ROW_PADDING
    local iconX = PADDING + EXAMPLE_ROW_PADDING
    local icon = SourceIcon.NewStill(content, nil, example.objectID)
    if icon ~= nil then
        icon:SetPos(iconX, top)
        icon:SetSize(EXAMPLE_ICON_SIZE, EXAMPLE_ICON_SIZE)
    end
    local textX = iconX + EXAMPLE_ICON_SIZE + EXAMPLE_GAP
    local textWidth = width - (textX - PADDING) - EXAMPLE_ROW_PADDING
    local textHeight = pageText.Add(content, "subheading", example.name, textX, top, textWidth)
    textHeight = textHeight + pageText.GapBefore("text")
    textHeight = textHeight + pageText.Add(content, "text", example.description, textX, top + textHeight, textWidth)
    local height = math.max(EXAMPLE_ICON_SIZE, textHeight) + EXAMPLE_ROW_PADDING * 2
    fill:SetPos(PADDING, y)
    fill:SetSize(width, height)
    return height
end

--- Adds Import's Examples tab: the example auras, one under another. The
--- texts aren't in the view's layout, so a spacer holds their room, for the
--- view to scroll.
---@param host SharePanelHost
---@param view table The tab's page.
local function addExamplesTab(host, view)
    -- TODO: an example does nothing when clicked until it has an export.
    local top, width = host.textArea()
    local content = view.content
    local y = top
    for index, example in ipairs(auraExamples) do
        y = y + addExample(content, example, index, y, width)
    end
    view:AddText({ text = "", height = y - top })
end

--- Shows Import's panel, in two tabs: Examples, the example auras, and
--- Custom, a box (or one per part of a multi-part export) to paste into.
--- After a failed import it opens on Custom, with what went wrong and what
--- was pasted.
---@param host SharePanelHost
---@param problem string? Why the last import failed.
---@param texts string[]? What was pasted.
---@param boxCount integer? How many boxes; at least one per pasted text.
function sharePanel.OpenImport(host, problem, texts, boxCount)
    texts = texts or {}
    boxCount = math.max(1, boxCount or 1, #texts)
    if problem ~= nil or #texts > 0 then importTabs.active = CUSTOM_TAB end
    host.openPanel(nil, function(view, tabIndex)
        if tabIndex == CUSTOM_TAB then
            addCustomTab(host, view, problem, texts, boxCount)
        else
            addExamplesTab(host, view)
        end
    end, importTabs)
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
