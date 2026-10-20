-- Reads game vars, shared by the GameData modules.
-- Usage: local vars = require("GameData/vars")
--        vars.ReadVarPlayer("LIFEPOINTS") --> number, or nil

local vars = {}

local function readValue(name)
    return var.VarPlayer[name].value
end

-- Returns the var's value, or nil when it doesn't exist or can't be read.
-- A named function rather than a closure, as this runs every frame.
function vars.ReadVarPlayer(name)
    local found, value = pcall(readValue, name)
    return found and value or nil
end

return vars
