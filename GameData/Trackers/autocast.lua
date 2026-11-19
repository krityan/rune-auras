-- The spell the player has set to autocast (the Magic basic attack): whether
-- one is set, and its name and icon. AUTOCAST_SPELL holds the spell's
-- COMBATV2_ABILITY_ID, and 0 with none: clearing autocast leaves
-- AUTOCAST_SET at 1, so that doesn't say whether one is set. It's a varbit,
-- read through the var cache.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local varCache = require("GameData/Trackers/var-cache")

local autocast = {}

local SPELL_VAR = "AUTOCAST_SPELL"
-- Where the last spell set is saved, as its COMBATV2_ABILITY_ID.
local LAST_SPELL_STORAGE_KEY = "autocastSpell"

---@type table<integer, MagicSpell|false> Spell id to its name and icon once read, or false if the Magic enum doesn't list it.
local spells = {}
---@type integer|false|nil The last spell set, kept once autocast is turned off and between sessions; nil until loaded, false if none has been set.
local lastSpellID = nil

--- The last spell set, loaded once.
---@return integer? spellID nil if none has been set.
local function savedSpellID()
    if lastSpellID == nil then
        lastSpellID = math.tointeger(tonumber(PersistentDB:GetString(LAST_SPELL_STORAGE_KEY))) or false
    end

    return lastSpellID or nil
end

--- The spell set to autocast. A new one is saved as the last spell set.
---@return integer? spellID nil with none set.
local function setSpellID()
    local spellID = math.tointeger(varCache.VarPlayer(SPELL_VAR))
    if spellID == nil or spellID <= 0 then
        return nil
    end

    if spellID ~= savedSpellID() then
        lastSpellID = spellID
        PersistentDB:SetString(LAST_SPELL_STORAGE_KEY, tostring(spellID))
    end

    return spellID
end

--- Whether a spell is set to autocast, as 1 of 1 or 0 of 1.
---@return number curr
---@return number max
function autocast.Read()
    return setSpellID() ~= nil and 1 or 0, 1
end

--- The spell set to autocast, or the last one set once it's turned off. A
--- spell's name and icon are read once, as is a spell the Magic enum
--- doesn't list; while the enum can't be read, it's tried again next time.
---@return MagicSpell? spell nil if none has been set, or it can't be read.
function autocast.Spell()
    local spellID = setSpellID() or savedSpellID()
    if spellID == nil then
        return nil
    end

    local spell = spells[spellID]
    if spell == nil then
        spell = abilityCatalogue.MagicSpell(spellID)
        spells[spellID] = spell
    end

    return spell or nil
end

--- Forgets the spells read, on leaving the game. The last spell set is kept,
--- as it's saved.
function autocast.Reset()
    spells = {}
end

return autocast
