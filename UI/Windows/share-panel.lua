-- The Import and Export panels, shown in the main window's editor area:
-- boxes to paste an export into, or to copy one from, and Import's list of
-- example auras. An example, or Custom's Import, opens its preview
-- (import-preview), which imports it. The export format belongs to
-- aura-share.

local auraShare = require("Auras/Sharing/aura-share")
local auraExamples = require("Auras/Sharing/examples")
local dataSources = require("Auras/Registries/data-sources")
local SourceIcon = require("Auras/Displays/Parts/source-icon")
local importPreview = require("UI/Windows/import-preview")
local buttonCursor = require("UI/Controls/button-cursor")
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
---@field windowBounds fun(): Rect? Where the main window is, to open an import's preview beside it.

local PADDING = uiConstants.PADDING
local PREVIEW_EVENT_ID = "runeAuras_sharePanelPreview"
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
-- How far a notch of the mouse wheel over an example scrolls the list.
local EXAMPLE_WHEEL_STEP = uiConstants.FIELD_HEIGHT
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

--- A count of things: "1 aura", "3 auras".
---@param count integer
---@param noun string
---@return string
local function countOf(count, noun)
    if count == 1 then return "1 " .. noun end
    return formatStr("{} {}s", count, noun)
end

--- What a pasted export adds, for its preview: "Adds 3 auras and 1 group."
---@param auras Aura[]
---@return string
local function addsSummary(auras)
    local groupCount = 0
    for _, aura in ipairs(auras) do
        if auraStore.IsGroup(aura) then groupCount = groupCount + 1 end
    end
    local parts = {}
    local auraCount = #auras - groupCount
    if auraCount > 0 then parts[#parts + 1] = countOf(auraCount, "aura") end
    if groupCount > 0 then parts[#parts + 1] = countOf(groupCount, "group") end
    return "Adds " .. table.concat(parts, " and ") .. "."
end

--- Shows what an export adds in the preview window, beside the main
--- window, whose Import adds it; if the window can't be made, it's added
--- straight away. One that can't be read opens Custom with what went wrong
--- and what was pasted, with as many boxes as a multi-part export needs.
---@param host SharePanelHost
---@param texts string[] What's in each box.
---@param title string? nil: the first aura's name.
---@param description string? nil: how many auras and groups it adds.
local function previewTexts(host, texts, title, description)
    local auras, problem, partsNeeded = auraShare.Preview(texts)
    if auras == nil then
        sharePanel.OpenImport(host, problem, texts, partsNeeded)
        return
    end
    local opened = importPreview.Open({
        title = title or auras[1].name,
        description = description or addsSummary(auras),
        auras = auras,
        beside = host.windowBounds(),
        onImport = function() importTexts(host, texts) end,
    })
    if not opened then importTexts(host, texts) end
end

--- Adds Import's Custom tab: a box (or one per part of a multi-part
--- export) to paste into, with what went wrong last time, and the Import
--- button under them, which previews it.
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
        -- Showing what went wrong replaces this panel, so after this callback.
        nextFrame.Run(PREVIEW_EVENT_ID, function() previewTexts(host, pasted) end)
    end, { width = IMPORT_BUTTON_WIDTH, variant = "positive" })
end

--- Adds an example row's clickable area over everything in it, which opens
--- its preview, shows the button pointer and lightens the row's fill while
--- the mouse is over it. It takes the mouse, so it passes the wheel on to
--- the list. Empty text, as that shows the pointer (see buttonCursor.Apply).
---@param host SharePanelHost
---@param view table The tab's page.
---@param fill userdata The row's fill, which the area covers.
---@param restingRGBA integer The fill's colour while the mouse isn't over it.
---@param example AuraExample
local function addExampleHit(host, view, fill, restingRGBA, example)
    local hit = ui.Text.new(view.content)
    hit.content = ""
    hit.enabled = true
    hit.clickthrough = false
    hit:SetPos(fill.x, fill.y)
    hit:SetSize(fill.width, fill.height)
    buttonCursor.Apply(hit)
    hit:Subscribe(ui.Hook.ONSCROLLWHEEL, function(_, delta)
        if type(delta) == "number" then view:SetScrollPosition((view.scrollY or 0) + delta * EXAMPLE_WHEEL_STEP) end
        return false
    end)
    hit:Subscribe(ui.Hook.ONMOUSEOVER, function()
        fill.rgba = uiConstants.LIST_HOVER_RGBA
        return false
    end)
    hit:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        fill.rgba = restingRGBA
        return false
    end)
    hit:Subscribe(ui.Hook.ONCLICK, function()
        -- Opening Custom instead replaces this row, so after this callback.
        nextFrame.Run(PREVIEW_EVENT_ID, function()
            previewTexts(host, { example.export }, example.name, example.description)
        end)
        return false
    end)
end

--- Adds one example's row: a fill, alternating down the list as the aura
--- list's rows do, that opens its preview, with its source's icon on the
--- left and its name and description beside it.
---@param host SharePanelHost
---@param view table The tab's page.
---@param example AuraExample
---@param index integer Its place in the list, for its fill.
---@param y number
---@param width number
---@return number height
local function addExample(host, view, example, index, y, width)
    local content = view.content
    -- Made first, so it draws behind the rest.
    local restingRGBA = uiConstants.LIST_ROW_RGBAS[index % 2 + 1]
    local fill = rectangles.Filled(content, restingRGBA)
    local top = y + EXAMPLE_ROW_PADDING
    local iconX = PADDING + EXAMPLE_ROW_PADDING
    local _, spriteID, objectID = dataSources.Details(example.iconSource)
    local icon = SourceIcon.NewStill(content, spriteID, objectID, EXAMPLE_ICON_SIZE)
    if icon ~= nil then icon:SetPos(iconX, top) end
    local textX = iconX + EXAMPLE_ICON_SIZE + EXAMPLE_GAP
    local textWidth = width - (textX - PADDING) - EXAMPLE_ROW_PADDING
    local textHeight = pageText.Add(content, "subheading", example.name, textX, top, textWidth)
    textHeight = textHeight + pageText.GapBefore("text")
    textHeight = textHeight + pageText.Add(content, "text", example.description, textX, top + textHeight, textWidth)
    local height = math.max(EXAMPLE_ICON_SIZE, textHeight) + EXAMPLE_ROW_PADDING * 2
    fill:SetPos(PADDING, y)
    fill:SetSize(width, height)
    -- Made last, so it's over the row's texts and icon.
    addExampleHit(host, view, fill, restingRGBA, example)
    return height
end

--- Adds Import's Examples tab: the example auras, one under another, each
--- opening its preview. The texts aren't in the view's layout, so a spacer
--- holds their room, for the view to scroll.
---@param host SharePanelHost
---@param view table The tab's page.
local function addExamplesTab(host, view)
    local top, width = host.textArea()
    local y = top
    for index, example in ipairs(auraExamples) do
        y = y + addExample(host, view, example, index, y, width)
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

--- Drops a preview waiting for the next frame, e.g. when the window closes.
function sharePanel.Cancel()
    nextFrame.Cancel(PREVIEW_EVENT_ID)
end

return sharePanel
