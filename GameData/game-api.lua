-- Guarded reads from the game's API. The client can update underneath the
-- plugin, renaming or removing configs, vars, interfaces or members, so
-- every read of game data goes through here: a read that errors returns nil
-- instead of breaking whatever called it.
-- Read logs the first failure of each kind of read (named by `what`), so a
-- read the game broke shows in the console once, rather than failing
-- silently or flooding it every frame. Try stays quiet, for reads that are
-- expected to fail sometimes: a name that may not exist, or config before
-- entering the game.
-- Both pass their extra arguments on to fn, so give them a named function
-- rather than a closure and nothing is allocated per call; the helpers
-- below cover the common reads. Native methods are called with `:` inside
-- them (see AGENTS.md).
-- Usage:
--   local gameApi = require("GameData/game-api")
--   gameApi.VarPlayer("LIFEPOINTS")              --> value, or nil
--   gameApi.Component("TOPLEVEL_V2__GAME_AREA")  --> component, or nil
--   local value, ok = gameApi.Read("what it is", namedFunction, arg)

local gameApi = {}

local reported = {}

-- fn(...)'s first result, and whether it ran without error.
function gameApi.Read(what, fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value, true end
    if not reported[what] then
        reported[what] = true
        log("Rune Auras: couldn't read " .. what .. " (the game may have changed): " .. tostring(value))
    end
    return nil, false
end

-- Read without the log.
function gameApi.Try(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value, true end
    return nil, false
end

-- lookup(name) (e.g. gameApi.VarClient, gameApi.Param), remembered once
-- found, so something read every frame skips the by-name lookup. A miss
-- isn't remembered: config may not be readable before entering the game.
local lookupCaches = {}
function gameApi.Cached(lookup, name)
    local cache = lookupCaches[lookup]
    if cache == nil then
        cache = {}
        lookupCaches[lookup] = cache
    end
    local found = cache[name]
    if found == nil then
        found = lookup(name)
        cache[name] = found
    end
    return found
end

local Read, Try = gameApi.Read, gameApi.Try

-- Config and ids by name. Names can be missing (or config unreadable before
-- entering the game), so these are quiet.
local function param(name) return config.Param[name] end
local function struct(name) return config.Struct[name] end
local function enumValues(name) return config.Enum[name].values end
local function structByID(structID) return config.Struct.FromID(structID) end
local function structName(structID) return id.Struct.FromID(structID) end
local function componentID(name) return id.Component[name] end
local function sprite(name) return id.Sprite[name] end
local function font(name) return id.Font[name] end
local function cursor(name) return config.Cursor[name].id end
local function varExists(name) return var.VarPlayer[name] ~= nil end
local function varValue(name) return var.VarPlayer[name].value end

function gameApi.Param(name) return (Try(param, name)) end
function gameApi.Struct(name) return (Try(struct, name)) end
function gameApi.EnumValues(name) return (Try(enumValues, name)) end
function gameApi.StructByID(structID) return (Try(structByID, structID)) end
function gameApi.StructName(structID) return (Try(structName, structID)) end
function gameApi.ComponentID(name) return (Try(componentID, name)) end
function gameApi.Sprite(name) return (Try(sprite, name)) end
function gameApi.Font(name) return (Try(font, name)) end
function gameApi.Cursor(name) return (Try(cursor, name)) end
function gameApi.VarExists(name) return Try(varExists, name) == true end
-- A VarPlayer's value, or nil when it doesn't exist or can't be read.
function gameApi.VarPlayer(name) return (Try(varValue, name)) end

-- A VarPlayer's config by name, or nil if there's none: like VarClient,
-- for vars read often (read it with VarValue).
local function varPlayerConfig(name) return var.VarPlayer[name] end
function gameApi.VarPlayerConfig(name) return (Try(varPlayerConfig, name)) end

-- A VarClient's config by name, or nil if there's none: look it up once
-- and read it with VarValue, so frequent reads skip the name lookup.
local function varClient(name) return var.VarClient[name] end
function gameApi.VarClient(name) return (Try(varClient, name)) end

-- The current value of a var config (VarClient or VarPlayer).
local function configValue(varConfig) return varConfig.value end
function gameApi.VarValue(varConfig) return (Read("a var's value", configValue, varConfig)) end

-- Members of configs the game handed us. These should always work, so a
-- failure is logged.
local function configName(object) return object.configName end
local function hasParam(object, p) return object:HasParam(p) end
local function paramValue(object, p) return object:GetParamValue(p) end
local function objectID(object) return object.id end

function gameApi.ConfigName(object) return (Read("a config's name", configName, object)) end
function gameApi.HasParam(object, p) return Read("whether a struct has a param", hasParam, object, p) == true end
function gameApi.ParamValue(object, p) return (Read("a struct's param", paramValue, object, p)) end
function gameApi.ID(object) return (Read("a config's id", objectID, object)) end

-- Interfaces, by component name.
local function component(name)
    local combinedID = id.Component[name]
    if combinedID == nil then return nil end
    return ui.Interfaces:GetComponent(combinedID)
end
local function componentByID(combinedID) return ui.Interfaces:GetComponent(combinedID) end

-- The game area is looked up every frame, so the label is fixed rather than
-- built from the name.
function gameApi.Component(name) return (Read("an interface component", component, name)) end
function gameApi.ComponentByID(combinedID) return (Read("an interface component", componentByID, combinedID)) end

-- The player.
local function playerAvailable() return Player.IsAvailable() end
local function skillLevel(skill) return Player.GetLevelGameplay(skill) end

function gameApi.PlayerAvailable() return Read("whether the player is available", playerAvailable) == true end
function gameApi.SkillLevel(skill) return (Read("a skill level", skillLevel, skill)) end

-- The var named in a VarTransmit event, or nil.
local function eventVarName(event) return event.var.configName end
function gameApi.EventVarName(event) return (Read("a var update", eventVarName, event)) end

return gameApi
