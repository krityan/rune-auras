-- The Selection panel, shown in the editor area while several auras are
-- selected in the list: what's selected, and what can be done to all of them.

local auraStore = require("Auras/Store/aura-store")
local gameText = require("Auras/Helpers/game-text")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")

local selectionPanel = {}

--- What the panel needs from the main window.
---@class SelectionPanelHost
---@field openPanel fun(title: string?, build: fun(view: table, tabIndex: integer?), tabs: PanelTabs?) Shows a panel in the editor's place.
---@field onGroup fun() Puts the selection in a new group.
---@field onDelete fun() Asks how to delete the selection.

local ACTION_EVENT_ID = "runeAuras_selectionPanel"
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
-- As the Delete panel's choices: a button with its description beside it.
local BUTTON_WIDTH = 180
local ROW_HEIGHT = 40
local TEXT_HEIGHT, TEXT_LINES = 40, 2
local NAME_HEIGHT = 20
-- Names listed before the rest are summed up as "and N more".
local MAX_NAMES = 12
local HINT = "Ctrl+click a row to add or remove it, Shift+click to select a range."

--- Adds an action's button, with its description beside it. It runs after
--- the click's callback, as what it does replaces this panel.
---@param view table
---@param label string
---@param description string
---@param action fun()
local function addAction(view, label, description, action)
    view:AddSimpleButton(label, function()
        nextFrame.Run(ACTION_EVENT_ID, action)
    end, { width = BUTTON_WIDTH, height = ROW_HEIGHT })

    view:AddText({
        text = description,
        inline = true,
        width = -(PADDING + BUTTON_WIDTH + GAP + PADDING),
        widthAnchor = 1,
        height = ROW_HEIGHT,
        maxLines = TEXT_LINES,
        colour = uiConstants.MUTED_RGBA,
    })
end

--- Adds the selected auras' names, one a line, the rest summed up.
---@param view table
---@param auraIDs integer[]
local function addNames(view, auraIDs)
    local shown = 0
    for _, auraID in ipairs(auraIDs) do
        local aura = auraStore.Get(auraID)
        if aura ~= nil and shown < MAX_NAMES then
            shown = shown + 1
            view:AddText({ text = gameText.Plain(aura.name), height = NAME_HEIGHT, maxLines = 1 })
        end
    end

    local rest = #auraIDs - shown
    if rest > 0 then
        view:AddText({ text = formatStr("and {} more", rest), height = NAME_HEIGHT, colour = uiConstants.MUTED_RGBA })
    end
end

--- Shows the panel for several selected auras.
---@param host SelectionPanelHost
---@param auraIDs integer[] The selected auras.
function selectionPanel.Open(host, auraIDs)
    host.openPanel(formatStr("{} selected", #auraIDs), function(view)
        view:AddText({ text = HINT, height = TEXT_HEIGHT, maxLines = TEXT_LINES, colour = uiConstants.MUTED_RGBA })
        addNames(view, auraIDs)
        addAction(view, "Group them", "Puts them in a new group, keeping them where they are on screen.", host.onGroup)
        addAction(view, "Delete them", "Asks first.", host.onDelete)
    end)
end

--- Drops an action waiting for the next frame, when the window goes.
function selectionPanel.Cancel()
    nextFrame.Cancel(ACTION_EVENT_ID)
end

return selectionPanel
