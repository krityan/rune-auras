-- The Delete panel, shown in the main window's editor area when an aura's
-- bin is clicked, so a misclick can't delete anything. A group with
-- something in it can go alone (its contents move up a level) or with
-- everything in it.

local auraStore = require("Auras/Store/aura-store")
local gameText = require("Auras/Helpers/game-text")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local deletePanel = {}

--- What the panel needs from the main window.
---@class DeletePanelHost
---@field openPanel fun(title: string, build: fun(view: table)) Shows a panel in the editor's place.
---@field onDone fun(deleted: boolean) Called after deleting, or cancelling; closes the panel.

local DELETE_EVENT_ID = "runeAuras_deletePanel"
local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
-- As New's choices: a button with its description beside it, on one line.
local BUTTON_WIDTH = 180
local ROW_HEIGHT = 40
local TEXT_HEIGHT, TEXT_LINES = 40, 2

---@class DeleteChoice
---@field label string
---@field description string
---@field run fun()? What it does before the panel closes; nil for Cancel.

--- The choices for an aura or group: Delete for an aura or an empty group;
--- for a group with contents, it alone or with them. Cancel last.
---@param aura Aura
---@return DeleteChoice[]
local function choicesFor(aura)
    local auraID = aura.id
    local cancel = { label = "Cancel", description = "Keep it." }
    local contents = auraStore.IsGroup(aura) and auraStore.ContentsCount(auraID) or 0
    if contents == 0 then
        return {
            { label = "Delete", description = "This can't be undone.", run = function()
                auraStore.Delete(auraID, gameApi.GameAreaSize())
            end },
            cancel,
        }
    end
    local what = contents == 1 and "the 1 aura or group in it" or formatStr("the {} auras and groups in it", contents)
    return {
        { label = "Delete group only", description = "Its contents move up a level and stay where they are on screen.",
            run = function() auraStore.Delete(auraID, gameApi.GameAreaSize()) end },
        { label = "Delete everything", description = "Deletes the group and " .. what .. ". This can't be undone.",
            run = function() auraStore.DeleteWithContents(auraID) end },
        cancel,
    }
end

--- Adds a choice's button, with its description beside it.
---@param view table
---@param choice DeleteChoice
---@param host DeletePanelHost
local function addChoice(view, choice, host)
    view:AddSimpleButton(choice.label, function()
        -- Closing the panel destroys this button, so after its callback.
        nextFrame.Run(DELETE_EVENT_ID, function()
            if choice.run ~= nil then choice.run() end
            host.onDone(choice.run ~= nil)
        end)
    end, { width = BUTTON_WIDTH, height = ROW_HEIGHT })
    view:AddText({
        text = choice.description,
        inline = true,
        width = -(PADDING + BUTTON_WIDTH + GAP + PADDING),
        widthAnchor = 1,
        height = ROW_HEIGHT,
        maxLines = TEXT_LINES,
        colour = uiConstants.MUTED_RGBA,
    })
end

--- Shows the panel asking how to delete an aura or group.
---@param host DeletePanelHost
---@param auraID integer
function deletePanel.Open(host, auraID)
    local aura = auraStore.Get(auraID)
    if aura == nil then return end
    host.openPanel("Delete", function(view)
        view:AddText({
            text = formatStr("Delete \"{}\"?", gameText.Plain(aura.name)),
            height = TEXT_HEIGHT,
            maxLines = TEXT_LINES,
        })
        for _, choice in ipairs(choicesFor(aura)) do addChoice(view, choice, host) end
    end)
end

--- Drops a deletion waiting for the next frame, when the window goes.
function deletePanel.Cancel()
    nextFrame.Cancel(DELETE_EVENT_ID)
end

return deletePanel
