-- The Selection panel, shown in the editor area while several auras are
-- selected in the list: what's selected, and what can be done to all of them.

local auraStore = require("Auras/Store/aura-store")
local gameText = require("Auras/Helpers/game-text")
local nextFrame = require("UI/next-frame")
local panelPage = require("UI/Windows/panel-page")

local selectionPanel = {}

--- What the panel needs from the main window.
---@class SelectionPanelHost
---@field openPanel fun(heading: PanelHeading?, build: fun(view: table, tabIndex: integer?), tabs: PanelTabs?) Shows a panel in the editor's place.
---@field onGroup fun() Puts the selection in a new group.
---@field onDelete fun() Asks how to delete the selection.

local ACTION_EVENT_ID = "runeAuras_selectionPanel"
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
    panelPage.AddChoice(view, label, description, function()
        nextFrame.Run(ACTION_EVENT_ID, action)
    end)
end

--- The page text under the title: how to change the selection, then the
--- selected auras' names, one a bullet, the rest summed up.
---@param auraIDs integer[]
---@return PanelBlock[]
local function introFor(auraIDs)
    local intro = { { kind = "text", text = HINT } }
    local shown = 0
    for _, auraID in ipairs(auraIDs) do
        local aura = auraStore.Get(auraID)
        if aura ~= nil and shown < MAX_NAMES then
            shown = shown + 1
            intro[#intro + 1] = { kind = "bullet", text = gameText.Plain(aura.name) }
        end
    end

    local rest = #auraIDs - shown
    if rest > 0 then
        intro[#intro + 1] = { kind = "text", text = formatStr("and {} more", rest) }
    end

    return intro
end

--- Shows the panel for several selected auras.
---@param host SelectionPanelHost
---@param auraIDs integer[] The selected auras.
function selectionPanel.Open(host, auraIDs)
    local heading = { title = formatStr("{} selected", #auraIDs), intro = introFor(auraIDs) }
    host.openPanel(heading, function(view)
        addAction(view, "Group them", "Makes a new group for the selected auras", host.onGroup)
        addAction(view, "Delete them", "Delete everything selected", host.onDelete)
    end)
end

--- Drops an action waiting for the next frame, when the window goes.
function selectionPanel.Cancel()
    nextFrame.Cancel(ACTION_EVENT_ID)
end

return selectionPanel
