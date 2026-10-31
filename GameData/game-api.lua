-- Guarded reads from the game's API. The client can update underneath the
-- plugin, renaming or removing configs, vars, interfaces or members, so
-- every read of game data goes through here: a read that errors returns nil
-- instead of breaking whatever called it.
--
-- Pass Read and Try a named function, not a closure, so nothing is
-- allocated per call; the helpers below cover the common reads. Native
-- methods are called with `:` inside them (see AGENTS.md).

local gameApi = {}

-- `what` labels already logged by Read.
local reported = {}

--- Logs a failed game read, the first time for each `what`.
---@param what string
---@param problem any The error.
local function report(what, problem)
    if reported[what] then return end
    reported[what] = true
    log("Rune Auras: couldn't read " .. what .. " (the game may have changed): " .. tostring(problem))
end

--- Runs a game read, logging the first failure of each kind (named by
--- `what`), so a read the game broke shows in the console once rather than
--- failing silently or flooding it every frame.
---@param what string What's being read, for the log ("a var's value").
---@param fn function Does the read; extra arguments are passed to it.
---@return any value fn's first result; nil if it errored.
---@return boolean ok Whether it ran without error.
function gameApi.Read(what, fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value, true end
    report(what, value)
    return nil, false
end

--- Read without the log, for reads expected to fail sometimes: a name that
--- may not exist, or config before entering the game.
---@param fn function Does the read; extra arguments are passed to it.
---@return any value nil if it errored.
---@return boolean ok
function gameApi.Try(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value, true end
    return nil, false
end

-- Lookup function to its cache of name to result.
local lookupCaches = {}

--- A by-name lookup (e.g. gameApi.VarClient, gameApi.Param), remembered
--- once found, so something read every frame skips it. A miss isn't
--- remembered: config may not be readable before entering the game.
---@param lookup fun(name: string): any
---@param name string
---@return any found nil if not found (yet).
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

--- A param config by name.
---@param name string
---@return userdata? param
function gameApi.Param(name) return (Try(param, name)) end
--- A struct config by name.
---@param name string
---@return userdata? struct
function gameApi.Struct(name) return (Try(struct, name)) end
--- An enum's `{ key, value }` list by name.
---@param name string
---@return table[]? values
function gameApi.EnumValues(name) return (Try(enumValues, name)) end
--- A struct config by id.
---@param structID integer
---@return userdata? struct
function gameApi.StructByID(structID) return (Try(structByID, structID)) end
--- A struct's name by id.
---@param structID integer
---@return string? name
function gameApi.StructName(structID) return (Try(structName, structID)) end

--- A walk of every struct, from pairs(id.Struct).
---@class StructWalk
---@field iterator any The native iterator, which keeps its own place.
---@field state any
---@field control any

local function structPairs() return pairs(id.Struct) end
local function nextStructs(walk) return walk.iterator(walk.state, walk.control) end

--- Starts a walk of every struct id that exists, in rising order. It can be
--- advanced over many Logic ticks.
---@return StructWalk? walk nil if pairs can't be used.
function gameApi.StructWalk()
    local ok, iterator, state, control = pcall(structPairs)
    if not ok then
        report("the list of structs", iterator)
        return nil
    end
    return { iterator = iterator, state = state, control = control }
end

--- The next struct in a walk.
---@param walk StructWalk
---@return integer? structID nil at the end.
---@return string? name
---@return boolean ok false if reading the next failed: the walk is incomplete.
function gameApi.NextStruct(walk)
    local ok, structID, name = pcall(nextStructs, walk)
    if not ok then
        report("the list of structs", structID)
        return nil, nil, false
    end
    walk.control = structID
    return structID, name, true
end

--- An interface component's combined id by name.
---@param name string
---@return integer? combinedID
function gameApi.ComponentID(name) return (Try(componentID, name)) end
--- A sprite's id by name.
---@param name string
---@return integer? spriteID
function gameApi.Sprite(name) return (Try(sprite, name)) end
--- A font handle by name. id.Font answers even for unknown names (see GameData/Catalogues/font-catalogue).
---@param name string
---@return integer? handle
function gameApi.Font(name) return (Try(font, name)) end
--- A cursor's id by name.
---@param name string
---@return integer? cursorID
function gameApi.Cursor(name) return (Try(cursor, name)) end
--- Whether a VarPlayer exists.
---@param name string
---@return boolean
function gameApi.VarExists(name) return Try(varExists, name) == true end
--- A VarPlayer's value.
---@param name string
---@return any value nil when it doesn't exist or can't be read.
function gameApi.VarPlayer(name) return (Try(varValue, name)) end

local function varPlayerConfig(name) return var.VarPlayer[name] end
--- A VarPlayer's config by name, for vars read often: look it up once and
--- read it with VarValue.
---@param name string
---@return userdata? varConfig nil if there's none.
function gameApi.VarPlayerConfig(name) return (Try(varPlayerConfig, name)) end

local function varClient(name) return var.VarClient[name] end
--- A VarClient's config by name: look it up once and read it with
--- VarValue, so frequent reads skip the name lookup.
---@param name string
---@return userdata? varConfig nil if there's none.
function gameApi.VarClient(name) return (Try(varClient, name)) end

local function configValue(varConfig) return varConfig.value end
--- The current value of a var config (VarClient or VarPlayer).
---@param varConfig userdata
---@return any
function gameApi.VarValue(varConfig) return (Read("a var's value", configValue, varConfig)) end

--- A VarPlayer's value through its cached config, for vars read every frame.
---@param name string
---@return any value nil when it doesn't exist (yet) or can't be read.
function gameApi.CachedVarPlayer(name)
    local varConfig = gameApi.Cached(gameApi.VarPlayerConfig, name)
    return varConfig and gameApi.VarValue(varConfig)
end

-- Members of configs the game handed us. These should always work, so a
-- failure is logged.
local function configName(object) return object.configName end
local function hasParam(object, param) return object:HasParam(param) end
local function paramValue(object, param) return object:GetParamValue(param) end
local function objectID(object) return object.id end

--- A config's name.
---@param object userdata
---@return string?
function gameApi.ConfigName(object) return (Read("a config's name", configName, object)) end
--- Whether a struct has a param.
---@param object userdata A struct config.
---@param param userdata A param config.
---@return boolean
function gameApi.HasParam(object, param) return Read("whether a struct has a param", hasParam, object, param) == true end
--- A struct's value for a param.
---@param object userdata A struct config.
---@param param userdata A param config.
---@return any
function gameApi.ParamValue(object, param) return (Read("a struct's param", paramValue, object, param)) end
--- A config's id.
---@param object userdata
---@return integer?
function gameApi.ID(object) return (Read("a config's id", objectID, object)) end
--- An item's id from a value that may be the id or the item's config: an
--- OBJ var or param gives the config, VarTransmit the id.
---@param value any
---@return integer? itemID nil for anything else.
function gameApi.ItemID(value)
    if type(value) == "number" then return value end
    if type(value) ~= "userdata" then return nil end
    return gameApi.ID(value)
end

local function component(name)
    local combinedID = id.Component[name]
    if combinedID == nil then return nil end
    return ui.Interfaces:GetComponent(combinedID)
end
local function componentByID(combinedID) return ui.Interfaces:GetComponent(combinedID) end

-- The game area: the interface plugins draw in.
local GAME_AREA = "TOPLEVEL_V2__GAME_AREA"

-- The game area is looked up every frame, so the labels are fixed rather
-- than built from the name.

--- An interface component by name.
---@param name string
---@return userdata? component
function gameApi.Component(name) return (Read("an interface component", component, name)) end
--- An interface component by combined id.
---@param combinedID integer
---@return userdata? component
function gameApi.ComponentByID(combinedID) return (Read("an interface component", componentByID, combinedID)) end

--- The game area component, which plugins draw in.
---@return userdata? area nil before it exists (e.g. at the login screen).
function gameApi.GameArea() return gameApi.Component(GAME_AREA) end

--- The game area's size, e.g. to keep an aura in place on screen as it
--- changes group.
---@return number? width nil if there's no game area.
---@return number? height
function gameApi.GameAreaSize()
    local area = gameApi.GameArea()
    if area == nil then return nil end
    return area.width, area.height
end

local function playerAvailable() return Player.IsAvailable() end
local function skillLevel(skill) return Player.GetLevelGameplay(skill) end

--- Whether a player is logged in and readable.
---@return boolean
function gameApi.PlayerAvailable() return Read("whether the player is available", playerAvailable) == true end
--- The player's level in a skill.
---@param skill integer A SkillType value.
---@return integer? level
function gameApi.SkillLevel(skill) return (Read("a skill level", skillLevel, skill)) end

-- Part of the client's error when an interface runs out of its 4,096
-- dynamic component ids (see AGENTS.md).
local COMPONENT_LIMIT_ERROR = "dynamic ID"

--- Whether an error from creating a UI component is the game's limit on
--- them, rather than a bug.
---@param problem any The error.
---@return boolean
function gameApi.IsComponentLimitError(problem)
    return tostring(problem):find(COMPONENT_LIMIT_ERROR, 1, true) ~= nil
end

local function eventVarName(event) return event.var.configName end
--- The var named in a VarTransmit event.
---@param event table
---@return string? name
function gameApi.EventVarName(event) return (Read("a var update", eventVarName, event)) end

return gameApi
