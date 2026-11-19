-- The preview of an import, an example or a pasted export: a window opened
-- beside the main window, drawing each aura it adds with sample values,
-- with Import and Cancel under them.

local displayModules = require("Auras/Displays/display-modules")
local segmentsOptions = require("Auras/Displays/Options/segments")
local dataSources = require("Auras/Registries/data-sources")
local auraStore = require("Auras/Store/aura-store")
local gameText = require("Auras/Helpers/game-text")
local heroIcons = require("UI/Controls/hero-icons")
local pageText = require("UI/Controls/page-text")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local windowRect = require("UI/Windows/window-rect")
local gameApi = require("GameData/game-api")

local importPreview = {}

---@class ImportPreviewOptions
---@field title string The example's name, or the pasted export's first aura's.
---@field description string
---@field auras Aura[] What importing it adds (see auraShare.Preview).
---@field beside Rect? The window it's opened from, to open beside; nil opens it in the middle of the game area.
---@field onImport fun() Called when Import is pressed, once the preview has closed.

local IMPORT_EVENT_ID = "runeAuras_importPreviewImport"
local CANCEL_EVENT_ID = "runeAuras_importPreviewCancel"
local RAISE_EVENT_ID = "runeAuras_importPreviewRaise"
-- The window's width, unless its previews need more, and its height.
local DEFAULT_WIDTH = 520
local WINDOW_HEIGHT = 440
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
-- PrettyUI's window frame, each side of its content.
local FRAME_WIDTH = 8
-- Kept clear on the right for the scroll view's scrollbar.
local SCROLLBAR_ROOM = 16
local START_Y = 10
-- The row of buttons along the bottom, and a button in it.
local BUTTON_ROW_HEIGHT = 46
local BUTTON_HEIGHT = 30
local BUTTON_TOP = (BUTTON_ROW_HEIGHT - BUTTON_HEIGHT) // 2
-- Room around each aura for texts drawn just outside its box. A text
-- offset further from its anchor gets its offset too, up to the most.
local AURA_MARGIN = 16
local MAX_TEXT_REACH = 200
-- The height an aura's layer has while it's made, before its size is known.
local MEASURING_HEIGHT = 400
-- How full the previews show: this share of a sample maximum, in seconds
-- for a timed source. A source's own values aren't used, as most are
-- empty out of combat.
local SAMPLE_SHARE = 0.6
local SAMPLE_SECONDS = 30
local SAMPLE_MAX = 100
-- Display options that would hide an aura at the sample values.
local HIDE_OPTIONS = { "hideWhenEmpty", "hideWhileInactive", "hideWhileActive" }
local NOTHING_TO_SHOW = "Nothing in it to draw."
local REST_NOT_SHOWN = "The rest can't be shown here."

local prettyUI = nil
local window = nil
-- The width the window is made at.
local windowWidth = DEFAULT_WIDTH
-- The widest any preview drawn needs the window's content to be.
local widestPreview = 0
---@type Display[] The previews drawn, for putting their parts in order next frame.
local displays = {}
-- Whether running out of interface parts has been logged this session.
local warnedLimit = false
-- Other errors logged this session, so each is logged once.
local loggedErrors = {}

--- How wide the previews and their texts can be.
---@return number
local function contentWidth()
    return windowWidth - FRAME_WIDTH * 2 - PADDING * 2 - SCROLLBAR_ROOM
end

--- Logs why a preview, or the window, couldn't be made: running out of
--- interface parts once a session, and any other error, a bug, once per
--- message.
---@param problem any The error.
local function reportFailure(problem)
    problem = tostring(problem)

    if gameApi.IsComponentLimitError(problem) then
        if warnedLimit then
            return
        end

        warnedLimit = true
        log("RuneAuras: an import's preview can't be shown in full: the game's limit on interface parts "
            .. "was reached. Disabling or deleting auras you don't use makes room.")
        return
    end

    if loggedErrors[problem] then
        return
    end

    loggedErrors[problem] = true
    log("[ERROR] RuneAuras: an import's preview couldn't be drawn: " .. problem)
end

--- Destroys a native component, for pcall.
---@param component userdata
local function destroyComponent(component)
    component:Destroy()
end

--- A copy of an aura to preview: centred in its layer, locked, and with
--- the options that would hide it turned off.
---@param aura Aura
---@return Aura
local function previewAura(aura)
    local copy = {}
    for key, value in pairs(aura) do
        copy[key] = value
    end

    copy.anchor, copy.x, copy.y = "centre", 0, 0
    copy.group, copy.unlocked = nil, false

    for _, option in ipairs(HIDE_OPTIONS) do
        copy[option] = false
    end

    return copy
end

--- The values a preview shows (see SAMPLE_SHARE). A Segmented bar fills by
--- stacks, so it gets that share of its segments.
---@param aura Aura
---@return number curr
---@return number max
---@return number? stacks
local function sampleValues(aura)
    if aura.display == "segments" then
        local count = segmentsOptions.RowOptions(aura)
        local stacks = math.max(1, math.floor(count * SAMPLE_SHARE + 0.5))
        return stacks, count, stacks
    end

    local source = dataSources.ForAura(aura)
    local isTimed = source ~= nil and source.timed == true
    local max = isTimed and SAMPLE_SECONDS or SAMPLE_MAX
    return math.floor(max * SAMPLE_SHARE), max, nil
end

--- Shows the source's details and the sample values on a display.
---@param display Display
---@param aura Aura
local function feedSample(display, aura)
    if display.SetDetails ~= nil then
        display:SetDetails(dataSources.Details(aura.source))
    end

    local curr, max, stacks = sampleValues(aura)
    display:SetValue(curr, max, nil, stacks)
end

--- How far an aura's texts are offset from their anchors, across and up
--- or down, at most MAX_TEXT_REACH.
---@param aura Aura
---@return number reachX
---@return number reachY
local function textReach(aura)
    local reachX, reachY = 0, 0
    for _, node in ipairs(aura.texts or {}) do
        reachX = math.max(reachX, math.abs(node.x or 0))
        reachY = math.max(reachY, math.abs(node.y or 0))
    end

    return math.min(reachX, MAX_TEXT_REACH), math.min(reachY, MAX_TEXT_REACH)
end

--- Draws an aura centred in a layer of its own, with room around it for
--- its texts, and notes how wide it needs the content. The layer is sized
--- once the display knows its size, and the display placed again in it.
---@param holder userdata
---@param aura Aura
---@param top number Where the layer starts in the holder.
---@return number height The layer's.
local function drawAura(holder, aura, top)
    local width = contentWidth()
    local layer = ui.Layer.new(holder)
    layer.clickthrough = true
    layer:SetPos(PADDING, top)
    layer:SetSize(width, MEASURING_HEIGHT)
    local shown = previewAura(aura)
    local display = displayModules[shown.display].new(layer, shown, nil)
    displays[#displays + 1] = display
    feedSample(display, shown)
    local reachX, reachY = textReach(aura)
    widestPreview = math.max(widestPreview, (display.width or 0) + (AURA_MARGIN + reachX) * 2)
    local height = (display.height or 0) + (AURA_MARGIN + reachY) * 2
    layer:SetSize(width, height)
    display:Apply(shown)
    return height
end

--- Fills a holder with an aura's name and its preview, and sizes it.
---@param holder userdata
---@param aura Aura
---@return number height
local function fillHolder(holder, aura)
    local labelHeight = pageText.Add(holder, "subheading", gameText.Plain(aura.name), PADDING, 0, contentWidth())
    local height = labelHeight + drawAura(holder, aura, labelHeight)
    holder:SetSize(contentWidth() + PADDING * 2, height)
    return height
end

--- Adds an aura's preview under its name, in a holder layer of its own,
--- so a preview that fails partway (the game running out of interface
--- parts) goes as a whole. The error is raised again.
---@param content userdata
---@param aura Aura
---@param y number
---@return number height
local function addAuraPreview(content, aura, y)
    local displayCount = #displays
    local holder = ui.Layer.new(content)
    holder.clickthrough = true
    holder:SetPos(0, y)
    holder:SetSize(contentWidth() + PADDING * 2, MEASURING_HEIGHT)
    local filled, result = pcall(fillHolder, holder, aura)
    if filled then
        return result
    end

    for index = #displays, displayCount + 1, -1 do
        displays[index] = nil
    end

    pcall(destroyComponent, holder)
    error(result, 0)
end

--- Puts each preview's parts back in order: some are made over the others
--- and ignore being moved the frame they're made (see Icon:RaiseParts).
local function raiseParts()
    for _, display in ipairs(displays) do
        if display.partsMade and display.RaiseParts ~= nil then
            display:RaiseParts()
        end
    end
end

--- Whether an aura gets a preview: it isn't a group, and its type is drawn.
---@param aura Aura
---@return boolean
local function isDrawable(aura)
    return not auraStore.IsGroup(aura) and displayModules[aura.display] ~= nil
end

--- The line under the previews saying what isn't shown, if anything.
---@param drawn integer
---@param failed boolean Whether one couldn't be drawn.
---@return string?
local function previewNote(drawn, failed)
    if failed then
        return REST_NOT_SHOWN
    end

    if drawn == 0 then
        return NOTHING_TO_SHOW
    end

    return nil
end

--- Adds the description and a preview of each aura that isn't a group,
--- placed by hand over a spacer that holds their height, for the view to
--- scroll. One that can't be drawn ends the previews, with a line saying so.
---@param view table
---@param previewOptions ImportPreviewOptions
local function buildPreviews(view, previewOptions)
    local content, width = view.content, contentWidth()
    local y = START_Y
    y = y + pageText.Add(content, "text", previewOptions.description, PADDING, y, width)
    local drawn, failed = 0, false
    for _, aura in ipairs(previewOptions.auras) do
        if isDrawable(aura) then
            local top = y + pageText.GapBefore("subheading")
            local added, result = pcall(addAuraPreview, content, aura, top)
            if not added then
                failed = true
                reportFailure(result)
                break
            end

            y, drawn = top + result, drawn + 1
        end
    end

    local note = previewNote(drawn, failed)
    if note ~= nil then
        y = y + pageText.GapBefore("text")
        y = y + pageText.Add(content, "text", note, PADDING, y, width, uiConstants.MUTED_RGBA)
    end

    view:AddText({ text = "", height = y - START_Y + GAP })
    nextFrame.Run(RAISE_EVENT_ID, raiseParts)
end

--- Adds Import and Cancel along the bottom, half the row each. Each acts
--- after its click's callback, as closing destroys the button.
---@param onImport fun()
local function buildButtons(onImport)
    local buttonWidth = (windowWidth - FRAME_WIDTH * 2 - PADDING * 2 - GAP) // 2
    local row = ui.Layer.new(window.content)
    row.enabled = true
    row.clickthrough = true
    row:SetPos(0, -BUTTON_ROW_HEIGHT, 0, 1)
    row:SetSize(0, BUTTON_ROW_HEIGHT, 1, 0)

    heroIcons.Button(prettyUI, row, "arrow-down-tray", function()
        nextFrame.Run(IMPORT_EVENT_ID, function()
            importPreview.Close()
            onImport()
        end)
    end, { x = PADDING, y = BUTTON_TOP, width = buttonWidth, height = BUTTON_HEIGHT, text = "Import" })

    prettyUI.SimpleButton.new(row, "Cancel", function()
        nextFrame.Run(CANCEL_EVENT_ID, importPreview.Close)
    end, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        x = PADDING + buttonWidth + GAP, y = BUTTON_TOP, width = buttonWidth, height = BUTTON_HEIGHT,
    })
end

--- Forgets the window and stops its work; the window itself is closed or
--- destroyed by the caller.
local function teardown()
    nextFrame.Cancel(IMPORT_EVENT_ID)
    nextFrame.Cancel(CANCEL_EVENT_ID)
    nextFrame.Cancel(RAISE_EVENT_ID)
    window, displays = nil, {}
end

--- Makes the window at windowWidth (see windowRect.Beside): the buttons
--- first, so Import works however much of the previews can be drawn, then
--- the previews in a scroll view above them.
---@param area userdata The game area.
---@param previewOptions ImportPreviewOptions
local function openWindow(area, previewOptions)
    local areaWidth, areaHeight = gameApi.GameAreaSize()
    local x, y = windowRect.Beside(previewOptions.beside, windowWidth, WINDOW_HEIGHT,
        areaWidth or windowWidth, areaHeight or WINDOW_HEIGHT)
    local opened
    opened = prettyUI.Window.new(area, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        title = gameText.Plain(previewOptions.title),
        x = x,
        y = y,
        width = windowWidth,
        height = WINDOW_HEIGHT,
        resizable = false,
        -- Movable while the player's interface is locked too.
        respectInterfaceLock = false,
        scrollable = false,
        destroyOnClose = true,
        -- Runs for the title bar's close button as well as Close.
        onClose = function()
            if window == opened then
                teardown()
            end
        end,
    })
    window = opened
    buildButtons(previewOptions.onImport)
    local view = prettyUI.SimpleView.new(window.content, {
        categoryID = uiConstants.PRETTYUI_CATEGORY,
        x = 0,
        y = 0,
        width = 0,
        widthAnchor = 1,
        height = -BUTTON_ROW_HEIGHT,
        heightAnchor = 1,
        layout = { startY = START_Y, paddingLeft = PADDING, paddingRight = PADDING, rowGap = 0 },
    })
    buildPreviews(view, previewOptions)
end

--- Makes the window at a width, or if that fails, removes what was made of
--- it and logs why.
---@param area userdata
---@param previewOptions ImportPreviewOptions
---@param width number
---@return boolean opened
local function tryOpen(area, previewOptions, width)
    windowWidth, widestPreview = width, 0
    local opened, problem = pcall(openWindow, area, previewOptions)
    if opened then
        return true
    end

    importPreview.Close()
    reportFailure(problem)
    return false
end

--- Opens an import's preview, closing one already open, as wide as its
--- previews need, within the game area.
---@param previewOptions ImportPreviewOptions
---@return boolean opened false if the window couldn't be made (no PrettyUI or game area, or the game ran out of interface parts), so the caller can import without it.
function importPreview.Open(previewOptions)
    importPreview.Close()
    prettyUI = prettyui
    local area = gameApi.GameArea()
    if prettyUI == nil or area == nil then
        return false
    end

    if not tryOpen(area, previewOptions, DEFAULT_WIDTH) then
        return false
    end

    local areaWidth = gameApi.GameAreaSize() or DEFAULT_WIDTH
    local neededWidth = math.min(areaWidth, math.ceil(widestPreview + windowWidth - contentWidth()))
    if neededWidth <= windowWidth then
        return true
    end

    -- The window and its contents are laid out for the width they're made
    -- at, so it's made again at the wider one.
    importPreview.Close()
    return tryOpen(area, previewOptions, neededWidth)
end

--- Closes the preview, if it's open, without importing.
function importPreview.Close()
    local closing = window
    teardown()

    if closing ~= nil and closing.root ~= nil then
        closing:Destroy()
    end
end

return importPreview
