-- A buff's name: buff-data's hand-written one, else its tooltip name
-- cleaned, else one made from its struct's name.

local buffData = require("GameData/Catalogues/Buffs/buff-data")

local buffNaming = {}

-- A tooltip name longer than this is a sentence, not a name.
local MAX_NAME = 34
-- Words at the end of a struct's name that only say how the game keeps the
-- buff. "_COOLDOWN" isn't one: "Vengeance" alone would read as the buff.
local STRUCT_NAME_ENDINGS = { "_TRACKER", "_TIMER", "_ACTIVE", "_EFFECT", "_BUFF", "_DEBUFF" }
-- How a cooldown debuff's tooltip sentence names what's cooling down
-- ("Your Crackling perk will not activate while this is up.").
local COOLDOWN_SENTENCES = {
    "^Your (.-) will not activate",
    "^Your (.-) is on cooldown",
    "^Your (.-) is cooling down",
    "^Your (.-) has recently activated",
    "^(.-) is on cooldown%.?$",
}
-- Words after what's cooling down that only say what kind of thing it is.
local COOLDOWN_SUBJECT_ENDINGS = { "%s+perk$", "%s+effect$", "%s+ability$" }

--- Drops STRUCT_NAME_ENDINGS from the end of a name, however many there are.
---@param name string
---@return string
local function withoutEndings(name)
    local changed = true
    while changed do
        changed = false
        for _, ending in ipairs(STRUCT_NAME_ENDINGS) do
            if #name > #ending and name:sub(-#ending) == ending then
                name = name:sub(1, -#ending - 1)
                changed = true
            end
        end
    end
    return name
end

--- A readable name made from a struct's name, without the words that only
--- name how the game keeps it ("COMBATV2_GOD_BOOK_TIMER_DUMMY_ABILITY" gives
--- "God book"). "COMBATV2_BUFF_NECROMANCY_DEATH_ESSENCE" gives
--- "Necromancy death essence".
---@param structName string
---@return string
function buffNaming.FromStruct(structName)
    local name = structName
    for _, prefix in ipairs({ "COMBATV2_", "ABILITY_", "BUFF_", "DEBUFF_" }) do
        if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1) end
    end
    name = withoutEndings((name:gsub("_DUMMY_ABILITY", ""):gsub("_DUMMY", "")))
    name = name:gsub("_", " "):lower()
    return (name:gsub("^%l", string.upper))
end

--- Whether text works as a buff's name: short, and not a sentence.
---@param text string
---@return boolean
local function isUsable(text)
    return text ~= "" and #text <= MAX_NAME and text:sub(-1) ~= "."
end

--- A tooltip name up to its first line break ("Enlightenment<br>- Better
--- rewards ..." gives "Enlightenment"), or all of it when nothing comes before one.
---@param text string
---@return string
local function firstLine(text)
    local beforeBreak = text:match("^(.-)<br>")
    if beforeBreak == nil then return text end
    local hasText = beforeBreak:gsub("<[^>]*>", ""):find("%S") ~= nil
    if not hasText then return text end
    return beforeBreak
end

--- A cooldown debuff's name from its tooltip sentence: what's cooling down
--- and "cooldown" ("Crackling cooldown").
---@param sentence string
---@return string? name nil if the sentence isn't one of COOLDOWN_SENTENCES, or the name would be too long.
local function cooldownName(sentence)
    for _, pattern in ipairs(COOLDOWN_SENTENCES) do
        local subject = sentence:match(pattern)
        if subject ~= nil then
            for _, ending in ipairs(COOLDOWN_SUBJECT_ENDINGS) do subject = subject:gsub(ending, "") end
            local name = subject:gsub("^%l", string.upper) .. " cooldown"
            if isUsable(name) then return name end
            return nil
        end
    end
    return nil
end

--- A buff's name. The tooltip name is sometimes "Name - what it does", a
--- name then a description on the next line, "Name Active", or a whole
--- sentence; a cooldown's sentence names what's cooling down, and any other
--- sentence falls back to the struct's own name.
---@param structName string
---@param tooltip any The COMBATV2_ABILITY_NAME param.
---@return string
function buffNaming.For(structName, tooltip)
    local handWritten = buffData.NAMES[structName]
    if handWritten ~= nil then return handWritten end
    local name = firstLine(tostring(tooltip or "")):gsub("<[^>]*>", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local beforeDash = name:match("^(.-)%s+%-%s+")
    if beforeDash ~= nil and beforeDash ~= "" then name = beforeDash end
    -- "Guam Incense:" loses its colon, and "Locate Active." its last word.
    name = name:gsub("%s*:$", ""):gsub("%s+[Aa]ctive%.?$", "")
    if isUsable(name) then return name end
    -- "Icy Chill: At 10 stacks ..." is a name then a sentence, so it's cut
    -- there; "Legendary Pet Ability: High Level Alchemy" isn't, as the part
    -- after the colon is what tells the pets apart.
    local beforeColon, afterColon = name:match("^(.-):%s+(.*)$")
    if beforeColon ~= nil and isUsable(beforeColon) and not isUsable(afterColon) then return beforeColon end
    return cooldownName(name) or buffNaming.FromStruct(structName)
end

return buffNaming
