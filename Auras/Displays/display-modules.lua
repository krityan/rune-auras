-- Each display type's drawing code, by type, for what draws auras: the aura
-- manager, and Import's preview. The display-types registry holds
-- the types' options without loading this. A type missing here isn't drawn.

---@type table<DisplayID, { new: fun(parent: userdata, aura: Aura, groupPoint: GroupPoint?): Display }>
local displayModules = {
    bar = require("Auras/Displays/bar"),
    icon = require("Auras/Displays/icon"),
    text = require("Auras/Displays/text"),
    segments = require("Auras/Displays/segments"),
    orb = require("Auras/Displays/orb"),
    group = require("Auras/Displays/group"),
    dynamicGroup = require("Auras/Displays/dynamic-group"),
}

return displayModules
