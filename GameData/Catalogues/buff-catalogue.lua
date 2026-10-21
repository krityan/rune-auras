-- Lists buffs from game config. Every buff and debuff the game's buff bars
-- can show is a struct with a COMBATV2_BUFF_TYPE param (0 buff, 1 debuff,
-- 2 a neutral "stat modified" marker), named by COMBATV2_ABILITY_NAME and
-- drawn with COMBATV2_ABILITY_ICON (a sprite) or COMBATV2_ABILITY_OBJECT (an
-- item). Many are ability structs, which carry the buff params too.
-- Nothing indexes these structs, so finding them means walking every struct
-- id. The ids found are saved (PersistentDB key buffStructIDs), so later loads
-- list buffs straight away from them, and the walk only runs in the
-- background, slowly and once per session, to catch game updates.
-- Usage:
--   local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
--   buffCatalogue.List()             --> { { id, structID, label, icon, object, kind, stacks, timed, duration }, ... }
--   buffCatalogue.Scan(onChanged)    -- walk the structs; onChanged() if the list changed
--   buffCatalogue.Stop()

local gameApi = require("GameData/game-api")

local buffCatalogue = {}

local CACHE_KEY = "buffStructIDs"
-- Buff icon sprite ids, for Tools/make-grey-icons.py.
local ICON_IDS_KEY = "buffIconIDs"
local EVENT_ID = "runeAuras_buffCatalogue"
-- Structs checked per Logic tick, and how many missing ids in a row mark
-- the end of the struct ids. Buffs are already listed from the saved ids,
-- so the walk can take its time: kept small so no frame does much of it.
-- (There's no clock to budget by time.)
local PER_TICK = 200
local MISS_LIMIT = 5000
local MAX_LABEL = 32

local KINDS = { [0] = "buff", [1] = "debuff", [2] = "buff" }
-- COMBATV2_ABILITY_EFFECT_DURATION is in server ticks.
local SECONDS_PER_TICK = 0.6

local params = nil
local entries = {}
local cachedIDs = nil

local function lookupParams()
    if params ~= nil then return params end
    local found = {}
    for key, name in pairs({
        type = "COMBATV2_BUFF_TYPE",
        name = "COMBATV2_ABILITY_NAME",
        icon = "COMBATV2_ABILITY_ICON",
        object = "COMBATV2_ABILITY_OBJECT",
        stacks = "COMBATV2_BUFF_USES_STACKS",
        timed = "COMBATV2_BUFF_USES_ABILITY_END",
        duration = "COMBATV2_ABILITY_EFFECT_DURATION",
    }) do
        local param = gameApi.Param(name)
        if param == nil then return nil end
        found[key] = param
    end
    params = found
    return params
end

-- A struct id's name, or nil past the last struct id (the walk runs on
-- until a long run of these) or if it can't be read.
local function nameOf(structID)
    local name = gameApi.StructName(structID)
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

-- A param's value, or nil if the struct doesn't set it (GetParamValue alone
-- would give the param's default, e.g. 0 for COMBATV2_BUFF_TYPE) or it
-- can't be read.
local function readParam(struct, param)
    if not gameApi.HasParam(struct, param) then return nil end
    return gameApi.ParamValue(struct, param)
end

-- "COMBATV2_BUFF_NECROMANCY_DEATH_ESSENCE" -> "Necromancy death essence".
local function nameFromStruct(structName)
    local name = structName
    for _, prefix in ipairs({ "COMBATV2_", "ABILITY_", "BUFF_" }) do
        if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1) end
    end
    name = name:gsub("_DUMMY_ABILITY$", ""):gsub("_DUMMY$", ""):gsub("_", " "):lower()
    return (name:gsub("^%l", string.upper))
end

-- The tooltip name, which is sometimes "Name - what it does" or a whole
-- sentence; those fall back to the struct's own name.
local function cleanLabel(raw, structName)
    local label = tostring(raw or ""):gsub("<[^>]*>", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local short = label:match("^(.-)%s+%-%s+")
    if short ~= nil and short ~= "" then label = short end
    if label == "" or #label > MAX_LABEL or label:sub(-1) == "." then
        return nameFromStruct(structName)
    end
    return label
end

-- COMBATV2_ABILITY_OBJECT is an ObjType config (or an id).
local function objectID(value)
    if type(value) == "number" then return value end
    return value ~= nil and gameApi.ID(value) or nil
end

-- The entry for one struct id, or nil if it isn't a buff.
local function readEntry(structID)
    local p = lookupParams()
    if p == nil then return nil end
    local struct = gameApi.StructByID(structID)
    if struct == nil then return nil end
    local buffType = readParam(struct, p.type)
    local kind = buffType ~= nil and KINDS[buffType] or nil
    if kind == nil then return nil end
    local structName = tostring(gameApi.ConfigName(struct) or structID)
    local icon = readParam(struct, p.icon)
    local duration = readParam(struct, p.duration)
    return {
        id = "buff_" .. structName:lower(),
        structID = structID,
        structName = structName,
        label = cleanLabel(readParam(struct, p.name), structName),
        icon = (type(icon) == "number" and icon >= 0) and icon or nil,
        object = objectID(readParam(struct, p.object)),
        kind = kind,
        stacks = readParam(struct, p.stacks) == true,
        -- Counts down to an end time, so the bar shows a number for it.
        timed = readParam(struct, p.timed) == true,
        -- Seconds, for buffs from abilities (Death's Swiftness: 30); nil
        -- for most others.
        duration = (type(duration) == "number" and duration > 0) and duration * SECONDS_PER_TICK or nil,
    }
end

-- Labels that clash get the struct's own name added, so the picker can
-- tell them apart.
local function finish(list)
    local counts = {}
    for _, entry in ipairs(list) do counts[entry.label] = (counts[entry.label] or 0) + 1 end
    for _, entry in ipairs(list) do
        if counts[entry.label] > 1 then
            entry.label = entry.label .. " (" .. nameFromStruct(entry.structName) .. ")"
        end
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    return list
end

-- Saves the buffs' sprite ids so their grey copies can be made offline.
-- Item icons have none: they aren't plain sprites.
local function saveIconIDs(list)
    local ids, seen = {}, {}
    for _, entry in ipairs(list) do
        if entry.kind == "buff" and entry.icon ~= nil and not seen[entry.icon] then
            seen[entry.icon] = true
            ids[#ids + 1] = entry.icon
        end
    end
    table.sort(ids)
    local value = table.concat(ids, ",")
    if PersistentDB:GetString(ICON_IDS_KEY) ~= value then
        PersistentDB:SetString(ICON_IDS_KEY, value)
    end
end

local function idString(list)
    local ids = {}
    for _, entry in ipairs(list) do ids[#ids + 1] = entry.structID end
    table.sort(ids)
    for index, value in ipairs(ids) do ids[index] = tostring(value) end
    return table.concat(ids, ",")
end

-- Builds the list from the saved struct ids, if there are any and config
-- can be read. Returns whether the list changed.
function buffCatalogue.LoadCached()
    if #entries > 0 or lookupParams() == nil then return false end
    cachedIDs = cachedIDs or PersistentDB:GetString(CACHE_KEY) or ""
    local list = {}
    for value in string.gmatch(cachedIDs, "%d+") do
        local structID = tonumber(value)
        -- A saved id may be gone after a game update, and this runs at
        -- plugin load, so check it still has a name (as the walk does)
        -- before reading the struct.
        if nameOf(structID) ~= nil then
            local entry = readEntry(structID)
            if entry ~= nil then list[#list + 1] = entry end
        end
    end
    if #list == 0 then return false end
    entries = finish(list)
    saveIconIDs(entries)
    return true
end

local scanning = false
-- Whether a walk has finished this session. Game config doesn't change while
-- the client runs, so world hops and lobby returns don't walk again.
local scanned = false

-- Walks every struct id in the background, once per session (a walk cut
-- short by Stop starts over next time). When it's done and the buffs differ
-- from the current list, the list is replaced, saved, and onChanged() is
-- called.
function buffCatalogue.Scan(onChanged)
    if scanned or scanning or lookupParams() == nil then return end
    scanning = true
    local found, nextID, misses = {}, 0, 0
    Event.Logic.Subscribe(EVENT_ID, function()
        for _ = 1, PER_TICK do
            local structID = nextID
            nextID = nextID + 1
            if nameOf(structID) ~= nil then
                misses = 0
                local entry = readEntry(structID)
                if entry ~= nil then found[#found + 1] = entry end
            else
                misses = misses + 1
                if misses >= MISS_LIMIT then
                    Event.Logic.Unsubscribe(EVENT_ID)
                    scanning = false
                    scanned = true
                    local ids = idString(found)
                    if ids ~= idString(entries) then
                        entries = finish(found)
                        saveIconIDs(entries)
                        cachedIDs = ids
                        PersistentDB:SetString(CACHE_KEY, ids)
                        if onChanged ~= nil then onChanged() end
                    end
                    return
                end
            end
        end
    end)
end

function buffCatalogue.Stop()
    if scanning then
        Event.Logic.Unsubscribe(EVENT_ID)
        scanning = false
    end
end

function buffCatalogue.List()
    return entries
end

return buffCatalogue
