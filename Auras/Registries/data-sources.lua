-- Data sources: the game values an aura can show, grouped by data type
-- (player, target, cooldowns, ...) for picking in the editor. Owns the
-- DataSource record, the list of every source and looking them up. Each
-- type's sources are built in Auras/Registries/Sources, which only this
-- uses; the values themselves are read by GameData/Trackers, and the sets
-- of abilities and buffs come from GameData/Catalogues.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local gameApi = require("GameData/game-api")
local player = require("Auras/Registries/Sources/player")
local target = require("Auras/Registries/Sources/target")
local cooldowns = require("Auras/Registries/Sources/cooldowns")
local specialAttacks = require("Auras/Registries/Sources/special-attacks")
local buffs = require("Auras/Registries/Sources/buffs")
local targetDebuffSources = require("Auras/Registries/Sources/target-debuffs")
local channels = require("Auras/Registries/Sources/channels")
local stalledAbilitySources = require("Auras/Registries/Sources/stalled-ability")
local extraActions = require("Auras/Registries/Sources/extra-actions")

local dataSources = {}

--- A game value an aura can show. Every source reads a current and max
--- value, so any display type can show it as a fraction.
---@class DataSource
---@field id string Stable: named after game config, so saved auras keep working.
---@field type string A data type id (see Types).
---@field label string Shown in the picker; may say more than `name` to tell sources apart.
---@field name string? What auras show as $name, when it differs from `label`.
---@field colour integer Default fill (0xRRGGBBAA) when an aura picks this source.
---@field icon integer? Sprite id, for the Icon display.
---@field iconObject integer? An item whose icon is shown instead.
---@field read fun(): number?, number?, number?, number? Returns curr, max, the unrounded curr (smooth sources), and stacks or charges.
---@field smooth boolean? `read` rounds its current value, and gives the unrounded one third, for a bar's Smooth fill.
---@field timed boolean? Values are times in seconds (cooldowns, timed buffs, channels), which bar ticks and the radial swipe need.
---@field state "cooldown"|"active"|nil Whether running means on cooldown or active (buffs, debuffs, channels), for the Icon display's dimming and hiding; nil for values with no on/off.
---@field onOff boolean? Only on or off (a toggled buff: 1 of 1), so a swipe has nothing to show.
---@field hasStacks boolean? A buff that reports its stack count, for $stacks.
---@field hasAmmo boolean? Reports its ammo from `details`, for $ammo.
---@field hasTarget boolean? About the player's target: reports its details from `details`, for $target, $level, $hitChance and $weakness.
---@field details fun(): string?, integer?, integer?, string?, TargetInfo? | nil Name, sprite icon, item icon, $ammo and the target's details right now, instead of the fields (see Details).
---@field category string? A category id of its type's (see DataType.categories); nil for a type without them.
---@field readTimed fun(seconds: number): number, number, number | nil For an on/off source that can count down a length the player sets from when it comes on: the time left, the length and the unrounded time left (see WithDuration).
---@field movedFrom string[]? Ids it used to have, so auras saved with them follow it.
---@field ability AbilityEntry? Its ability, so a greater icon swap can be picked up (ApplyGreaterIcons).

--- A group of a data type's sources, picked before the source.
---@class DataCategory
---@field id string Stable: sources name it.
---@field label string

---@class DataType
---@field id string
---@field label string
---@field categories DataCategory[]? Its sources' groups, in the picker's order; nil to list them all together.

---@type DataType[]
local TYPES = {
    { id = "player", label = "Player" },
    { id = "target", label = "Target" },
    { id = "cooldown", label = "Ability cooldown" },
    { id = "specialAttack", label = "Special attack cooldown" },
    { id = "buff", label = "Buff" },
    { id = "debuff", label = "Debuff" },
    { id = "targetDebuff", label = "Target debuff", categories = targetDebuffSources.CATEGORIES },
    { id = "channel", label = "Channel" },
    { id = "stalledAbility", label = "Stalled ability" },
    { id = "extraAction", label = "Extra action button" },
}

dataSources.EQUIPPED_SPECIAL_ID = specialAttacks.EQUIPPED_ID

-- Data types that were renamed or split, to the one a check saved with the
-- old id moves to when it has no source picked (see CurrentType).
local RENAMED_TYPES = { resource = "player" }

---@type DataSource[] Every source, in the picker's order (see rebuildSources).
local SOURCES = {}
---@type table<string, string> Every old id to its current one: cooldowns.RENAMED_IDS plus the sources' movedFrom (a buff's duplicates, a channel's old buff id). Rebuilt with the sources.
local MOVED_IDS = {}

-- Each type's sources. All but the player's, the target's, the target
-- debuffs and the stalled ability are rebuilt from game config as it
-- becomes readable.
local playerList = player.Build()
local targetList = target.Build()
local cooldownList = {}
local specialAttackList = {}
local buffList = {}
local debuffList = {}
local targetDebuffList = targetDebuffSources.Build()
local channelList = {}
local stalledAbilityList = stalledAbilitySources.Build()
local extraActionList = {}
---@type table<string, DataSource>
local SOURCES_BY_ID = {}
-- Whether the cooldowns came from the ability catalogue rather than FALLBACK.
local usingCatalogue = false

--- Rebuilds SOURCES, the id lookup and MOVED_IDS from the lists.
local function rebuildSources()
    for index = #SOURCES, 1, -1 do SOURCES[index] = nil end
    local lists = { playerList, targetList, cooldownList, specialAttackList, buffList, debuffList,
        targetDebuffList, channelList, stalledAbilityList, extraActionList }
    for _, list in ipairs(lists) do
        for _, source in ipairs(list) do SOURCES[#SOURCES + 1] = source end
    end
    for key in pairs(SOURCES_BY_ID) do SOURCES_BY_ID[key] = nil end
    for _, source in ipairs(SOURCES) do
        SOURCES_BY_ID[source.id] = source
    end
    MOVED_IDS = {}
    for oldID, sourceID in pairs(cooldowns.RENAMED_IDS) do MOVED_IDS[oldID] = sourceID end
    for _, source in ipairs(SOURCES) do
        for _, oldID in ipairs(source.movedFrom or {}) do
            MOVED_IDS[oldID] = source.id
            -- Auras still saved with it read the source in its place.
            if SOURCES_BY_ID[oldID] == nil then SOURCES_BY_ID[oldID] = source end
        end
    end
end

--- Builds what else comes from the ability catalogue, once the cooldowns
--- are built: the buffs (which link to their abilities' greater icons), the
--- channels and the stalled ability's names.
local function buildFromAbilities()
    buffList, debuffList = buffs.Build(cooldownList)
    channelList = channels.Build(usingCatalogue)
    stalledAbilitySources.MapAbilities(usingCatalogue)
end

-- Buffs and extra action buttons come in later: their catalogues load in
-- the background once in game (see Auras/source-sync), then RefreshBuffs
-- and RefreshExtraActions list them.
cooldownList, usingCatalogue = cooldowns.Build()
specialAttackList = specialAttacks.Build()
buildFromAbilities()
extraActionList = extraActions.Build()
rebuildSources()

--- Tries the ability catalogue again if it couldn't be read before, e.g. on
--- entering the game, rebuilding everything built from it.
---@return boolean changed Whether the sources changed, so displays showing them (names, icons) need refreshing.
function dataSources.Refresh()
    if usingCatalogue then return false end
    cooldownList, usingCatalogue = cooldowns.Build()
    if not usingCatalogue then return false end
    buildFromAbilities()
    rebuildSources()
    return true
end

--- Rebuilds the buff and debuff sources, and the special attacks found with
--- them, after the buff catalogue changed (its background scan found different
--- buffs).
function dataSources.RefreshBuffs()
    specialAttackList = specialAttacks.Build()
    buffList, debuffList = buffs.Build(cooldownList)
    rebuildSources()
end

--- Rebuilds the extra action button sources, once their catalogue has loaded.
function dataSources.RefreshExtraActions()
    extraActionList = extraActions.Build()
    rebuildSources()
end

--- The special source "Equipped weapon" stands for now: the worn weapon's,
--- else, when remembering, the last one worn this session.
---@param remember boolean
---@return string? sourceID nil if there's none.
function dataSources.EquippedSpecialID(remember)
    return specialAttacks.EquippedSpecialID(remember)
end

--- Copies each source's ability icon onto it, after greater unlocks changed.
local function syncAbilityIcons()
    for _, source in ipairs(SOURCES) do
        if source.ability ~= nil then source.icon = source.ability.icon end
    end
end

--- Switches unlocked greater abilities to their greater icons (see
--- ability-catalogue).
---@return boolean changed Whether any icon changed, so displays showing them need refreshing.
---@return boolean complete false while some unlock flags haven't arrived.
function dataSources.ApplyGreaterIcons()
    if not usingCatalogue then return false, false end
    local changed, complete = abilityCatalogue.ApplyGreaterUnlocks()
    if changed then syncAbilityIcons() end
    return changed, complete
end

--- Follows a var update that may be a greater unlock flag.
---@param name string The var's name.
---@param value any
---@return boolean changed Whether any icon changed.
function dataSources.OnVarChanged(name, value)
    if not usingCatalogue or not abilityCatalogue.OnVarChanged(name, value) then return false end
    syncAbilityIcons()
    return true
end

--- Lets the next login check greater unlocks again.
function dataSources.ResetGreaterIcons()
    abilityCatalogue.Reset()
end

--- Every data type, in the picker's order.
---@return DataType[]
function dataSources.Types()
    return TYPES
end

--- A data type's categories (see DataType.categories).
---@param typeID string
---@return DataCategory[]? categories nil for a type without them, or an unknown one.
function dataSources.Categories(typeID)
    for _, dataType in ipairs(TYPES) do
        if dataType.id == typeID then return dataType.categories end
    end
    return nil
end

--- The sources of one data type, or of one of its categories, in registry order.
---@param typeID string
---@param categoryID string? nil for all of the type's.
---@return DataSource[]
function dataSources.ListByType(typeID, categoryID)
    local list = {}
    for _, source in ipairs(SOURCES) do
        local isInCategory = categoryID == nil or source.category == categoryID
        if source.type == typeID and isInCategory then list[#list + 1] = source end
    end
    return list
end

--- Every source.
---@return DataSource[]
function dataSources.List()
    return SOURCES
end

--- The current id for a saved source id, which may predate a rename.
---@param sourceID string
---@return string
function dataSources.CurrentID(sourceID)
    return MOVED_IDS[sourceID] or sourceID
end

--- The data type a saved check should name: its source's, when the source
--- is known (a source can move to another type, e.g. Resource splitting into
--- Player and Target), else the type it names, or what that type became.
---@param typeID string? nil for the aura's own source.
---@param sourceID string?
---@return string?
function dataSources.CurrentType(typeID, sourceID)
    if typeID == nil then return nil end
    local source = sourceID ~= nil and dataSources.Get(dataSources.CurrentID(sourceID)) or nil
    if source ~= nil then return source.type end
    return RENAMED_TYPES[typeID] or typeID
end

-- Between a source's id and a length in its timed variant's id (see WithDuration).
local DURATION_SEPARATOR = "@"
---@type table<string, DataSource> Timed variants by id, made as auras ask for them. Never saved: an aura keeps its source's id.
local timedVariants = {}
---@type table<string, table<number, string>> A source's id (as asked for) to its timed variants' ids by length, so asking every frame builds no string.
local variantIDs = {}

--- A source by id (or an old id it moved from, or a timed variant's).
---@param sourceID string?
---@return DataSource? source nil if unknown.
function dataSources.Get(sourceID)
    if sourceID == nil then return nil end
    return SOURCES_BY_ID[sourceID] or timedVariants[sourceID]
end

--- The id of a copy of an on/off source that counts down a set length from
--- when it comes on (see DataSource.readTimed), made the first time it's asked for.
---@param sourceID string?
---@param seconds number The length.
---@return string? sourceID The variant's id; sourceID itself for a source that can't be timed.
function dataSources.WithDuration(sourceID, seconds)
    local byLength = variantIDs[sourceID]
    local cachedID = byLength and byLength[seconds]
    if cachedID ~= nil then return cachedID end
    local source = SOURCES_BY_ID[sourceID]
    if source == nil or source.readTimed == nil then return sourceID end
    local readTimed = source.readTimed
    local id = source.id .. DURATION_SEPARATOR .. tostring(seconds)
    local variant = {}
    for key, value in pairs(source) do variant[key] = value end
    variant.id, variant.readTimed = id, nil
    variant.onOff, variant.timed, variant.smooth = nil, true, true
    variant.read = function() return readTimed(seconds) end
    timedVariants[id] = variant
    byLength = byLength or {}
    byLength[seconds] = id
    variantIDs[sourceID] = byLength
    return id
end

--- The source an aura reads: its own, or a timed variant of it when its
--- source options set a length (see SourceOptions.durationSeconds).
---@param aura Aura
---@return string? sourceID
function dataSources.AuraSourceID(aura)
    local options = aura.sourceOptions
    local seconds = options and options.durationSeconds
    if seconds == nil then return aura.source end
    return dataSources.WithDuration(aura.source, seconds)
end

--- The source an aura reads (see AuraSourceID), for what it decides about
--- the display (timed, on/off, smooth).
---@param aura Aura
---@return DataSource? source nil if unknown.
function dataSources.ForAura(aura)
    return dataSources.Get(dataSources.AuraSourceID(aura))
end

--- A source's name, sprite icon and item icon as they are now: its own,
--- except "Any channel", which takes whatever is being channelled,
--- "Equipped weapon", which takes the worn weapon's special, an ability
--- with recast stages, which takes its current stage, the quiver, which
--- shows its ammo, and the "Any" extra action button, which takes the button's.
---@param sourceID string?
---@return string? name nil if the source is unknown.
---@return integer? spriteID
---@return integer? objectID
---@return string? ammo The quiver's ammo, for $ammo; nil for every other source.
---@return TargetInfo? target The target's details, for a target source's target fields; nil for every other source.
function dataSources.Details(sourceID)
    local source = dataSources.Get(sourceID)
    if source == nil then return nil end
    if source.details ~= nil then return source.details() end
    return source.name or source.label, source.icon, source.iconObject
end

-- Text fields every source fills.
local COMMON_TEXT_FIELDS = { value = true, max = true, percent = true, name = true }
-- Text fields about the player's target, which target sources fill.
local TARGET_TEXT_FIELDS = { target = true, level = true, hitChance = true, weakness = true }

--- Whether a source fills a text field: every source has $value, $max,
--- $percent and $name; $charges is an ability's, $stacks a stacking buff's,
--- $ammo the quiver's, and the target fields a target source's (a target
--- debuff's, or the target's lifepoints).
---@param sourceID string?
---@param field TextFieldID
---@return boolean
function dataSources.FillsTextField(sourceID, field)
    if COMMON_TEXT_FIELDS[field] then return true end
    local source = dataSources.Get(sourceID)
    if source == nil then return false end
    if field == "charges" then return source.type == "cooldown" end
    if field == "stacks" then return source.hasStacks == true end
    if field == "ammo" then return source.hasAmmo == true end
    return TARGET_TEXT_FIELDS[field] == true and source.hasTarget == true
end

--- A source's values now (see DataSource.read).
---@param sourceID string?
---@return number? curr nil when the source is unknown or no player is logged in.
---@return number? max
---@return number? unroundedCurr
---@return number? stacks
function dataSources.Read(sourceID)
    if not gameApi.PlayerAvailable() then return nil end
    return dataSources.ReadAvailable(sourceID)
end

--- Read, for a caller that has already checked the player is available (the
--- aura manager checks once a frame rather than once per source).
---@param sourceID string?
---@return number? curr nil when the source is unknown.
---@return number? max
---@return number? unroundedCurr
---@return number? stacks
function dataSources.ReadAvailable(sourceID)
    local source = dataSources.Get(sourceID)
    if source == nil then return nil end
    return source.read()
end

return dataSources
