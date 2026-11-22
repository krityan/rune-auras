-- The Delete panel, shown in the editor area when an aura's bin is clicked
-- (or the selection's Delete), so a misclick can't delete anything. A group
-- can go alone (its contents move up a level) or with everything in it.

local auraStore = require("Auras/Store/aura-store")
local gameText = require("Auras/Helpers/game-text")
local nextFrame = require("UI/next-frame")
local panelPage = require("UI/Windows/panel-page")
local gameApi = require("GameData/game-api")

local deletePanel = {}

--- What the panel needs from the main window.
---@class DeletePanelHost
---@field openPanel fun(heading: PanelHeading?, build: fun(view: table, tabIndex: integer?), tabs: PanelTabs?) Shows a panel in the editor's place.
---@field onDone fun(deleted: boolean) Called after deleting, or cancelling; closes the panel.

local DELETE_EVENT_ID = "runeAuras_deletePanel"

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
    local cancel = { label = "Cancel", description = "Keep it" }
    local descendants = auraStore.IsGroup(aura) and auraStore.DescendantCount(auraID) or 0
    if descendants == 0 then
        return {
            { label = "Delete", description = "This can't be undone", run = function()
                auraStore.Delete(auraID, gameApi.GameAreaSize())
            end },
            cancel,
        }
    end

    return {
        { label = "Group Only", description = "Its contents move up a level",
            run = function() auraStore.Delete(auraID, gameApi.GameAreaSize()) end },
        { label = "Everything", description = "Deletes everything inside the group as well",
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
    local cancel = { label = "Cancel", description = "Keep them" }

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
            { label = "Delete", description = "This can't be undone", run = deleteSelected },
            cancel,
        }
    end

    return {
        { label = "Delete selected only", description = "What's in the groups and isn't selected moves up a level",
            run = deleteSelected },
        { label = "Delete everything", description = "Deletes them and everything in the selected groups, this can't be undone",
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
    panelPage.AddChoice(view, choice.label, choice.description, function()
        -- Closing the panel destroys this button, so after its callback.
        nextFrame.Run(DELETE_EVENT_ID, function()
            if choice.run ~= nil then
                choice.run()
            end

            host.onDone(choice.run ~= nil)
        end)
    end)
end

--- Shows the panel asking how to delete an aura or group.
---@param host DeletePanelHost
---@param auraID integer
function deletePanel.Open(host, auraID)
    local aura = auraStore.Get(auraID)
    if aura == nil then
        return
    end

    local question = formatStr("Delete \"{}\"?", gameText.Plain(aura.name))
    host.openPanel({ title = "Delete", intro = { { kind = "text", text = question } } }, function(view)
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
    local heading = { title = "Delete", intro = { { kind = "text", text = formatStr(question, #auraIDs) } } }
    host.openPanel(heading, function(view)
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
