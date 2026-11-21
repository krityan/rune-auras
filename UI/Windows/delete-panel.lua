-- The Delete panel, shown in the editor area when an aura's bin is clicked
-- (or the selection's Delete), so a misclick can't delete anything. A group
-- can go alone (its contents move up a level) or with everything in it.

local auraStore = require("Auras/Store/aura-store")
local gameText = require("Auras/Helpers/game-text")
local nextFrame = require("UI/next-frame")
local uiConstants = require("UI/ui-constants")
local gameApi = require("GameData/game-api")

local deletePanel = {}

--- What the panel needs from the main window.
---@class DeletePanelHost
---@field openPanel fun(title: string?, build: fun(view: table, tabIndex: integer?), tabs: PanelTabs?) Shows a panel in the editor's place.
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
    local descendants = auraStore.IsGroup(aura) and auraStore.DescendantCount(auraID) or 0
    if descendants == 0 then
        return {
            { label = "Delete", description = "This can't be undone.", run = function()
                auraStore.Delete(auraID, gameApi.GameAreaSize())
            end },
            cancel,
        }
    end

    local what = descendants == 1 and "the 1 aura or group in it" or formatStr("the {} auras and groups in it", descendants)
    return {
        { label = "Delete group only", description = "Its contents move up a level and stay where they are on screen.",
            run = function() auraStore.Delete(auraID, gameApi.GameAreaSize()) end },
        { label = "Delete everything", description = "Deletes the group and " .. what .. ". This can't be undone.",
            run = function() auraStore.DeleteWithContents(auraID) end },
        cancel,
    }
end

--- The choices for several selected auras: Delete when none of the selected
--- groups has contents; otherwise the selection alone (what's in the groups
--- and not selected moves up a level) or with everything in its groups.
--- Cancel last.
---@param auraIDs integer[] Every selected aura.
---@param rootIDs integer[] Those not inside another selected group.
---@return DeleteChoice[]
local function choicesForMany(auraIDs, rootIDs)
    local cancel = { label = "Cancel", description = "Keep them." }

    local function deleteSelected()
        for _, auraID in ipairs(auraIDs) do
            auraStore.Delete(auraID, gameApi.GameAreaSize())
        end
    end

    local hasContents = false
    for _, auraID in ipairs(rootIDs) do
        local aura = auraStore.Get(auraID)
        if aura ~= nil and auraStore.IsGroup(aura) and auraStore.DescendantCount(auraID) > 0 then
            hasContents = true
        end
    end

    if not hasContents then
        return {
            { label = "Delete", description = "This can't be undone.", run = deleteSelected },
            cancel,
        }
    end

    return {
        { label = "Delete selected only", description = "What's in the groups and isn't selected moves up a level and stays where it is on screen.",
            run = deleteSelected },
        { label = "Delete everything", description = "Deletes them and everything in the selected groups. This can't be undone.",
            run = function()
                for _, auraID in ipairs(rootIDs) do
                    auraStore.DeleteWithContents(auraID)
                end
            end },
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
            if choice.run ~= nil then
                choice.run()
            end

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
    if aura == nil then
        return
    end

    host.openPanel("Delete", function(view)
        view:AddText({
            text = formatStr("Delete \"{}\"?", gameText.Plain(aura.name)),
            height = TEXT_HEIGHT,
            maxLines = TEXT_LINES,
        })

        for _, choice in ipairs(choicesFor(aura)) do
            addChoice(view, choice, host)
        end
    end)
end

--- Shows the panel asking how to delete several selected auras.
---@param host DeletePanelHost
---@param auraIDs integer[] Every selected aura.
---@param rootIDs integer[] Those not inside another selected group.
function deletePanel.OpenMany(host, auraIDs, rootIDs)
    if #auraIDs == 0 then
        return
    end

    local hasGroup = false
    for _, auraID in ipairs(auraIDs) do
        if auraStore.IsGroup(auraStore.Get(auraID)) then
            hasGroup = true
        end
    end

    local question = hasGroup and "Delete the {} selected auras and groups?" or "Delete the {} selected auras?"
    host.openPanel("Delete", function(view)
        view:AddText({
            text = formatStr(question, #auraIDs),
            height = TEXT_HEIGHT,
            maxLines = TEXT_LINES,
        })

        for _, choice in ipairs(choicesForMany(auraIDs, rootIDs)) do
            addChoice(view, choice, host)
        end
    end)
end

--- Drops a deletion waiting for the next frame, when the window goes.
function deletePanel.Cancel()
    nextFrame.Cancel(DELETE_EVENT_ID)
end

return deletePanel
