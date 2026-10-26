-- The ribbon panel's debug options, for testing: actions that reset saved
-- state, so what a fresh session does (loading buffs, the struct walk) can
-- be watched again. Only in dev builds.

local buffCatalogue = require("GameData/Catalogues/buff-catalogue")

local debugOptions = {}

-- deploy.ps1 writes this module into the deployed copy; it's never in the
-- repo, so a release doesn't have it. It's in a folder, as the client runs
-- a .lua file at the plugin's root by itself at load.
local DEV_BUILD_MODULE = "UI/Windows/dev-build"
---@type boolean? nil until first asked.
local isDevBuild = nil

--- Whether this is a dev build (deployed with deploy.ps1), where the debug
--- options show. The module returns a table, as require gives nil for any
--- other value, and for a module that isn't there.
---@return boolean
function debugOptions.IsAvailable()
    if isDevBuild == nil then
        local found, value = pcall(require, DEV_BUILD_MODULE)
        isDevBuild = found and type(value) == "table" and value.isDevBuild == true
    end
    return isDevBuild
end

--- A debug action, shown as a button.
---@class DebugOption
---@field label string
---@field tooltip string
---@field run fun()

--- Forgets the saved buff list and says what to do next.
local function clearSavedBuffs()
    buffCatalogue.ClearSaved()
    log("Rune Auras: cleared the saved buff list. Reload the plugin (prl rune-auras) to watch the struct walk find every buff again.")
end

---@type DebugOption[]
local OPTIONS = {
    { label = "Clear saved buffs", tooltip = "Reload the plugin afterwards", run = clearSavedBuffs },
}

--- Adds a button per debug option to a panel view.
---@param view table A PrettyUI SimpleView.
---@param width integer The buttons' width in pixels.
function debugOptions.Add(view, width)
    for _, option in ipairs(OPTIONS) do
        view:AddSimpleButton(option.label, option.run, { width = width, tooltip = option.tooltip })
    end
end

return debugOptions
