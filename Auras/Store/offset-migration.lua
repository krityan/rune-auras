-- Converts a saved or imported record's offsets from the old convention to
-- the current one, before auraRecord.FromSaved reads it. Offsets used to
-- count inwards from their anchor (right/bottom anchors leftwards/upwards,
-- the rest rightwards/downwards), and a group's offsets right and down; now
-- every offset counts right and up (see Auras/Helpers/anchors).

local anchors = require("Auras/Helpers/anchors")

local offsetMigration = {}

local PLAIN_GROUP_DISPLAY = "group"

--- A number with -0 made 0, so a flipped zero saves as it did.
---@param value number
---@return number
local function tidyZero(value)
    if value == 0 then
        return 0
    end

    return value
end

--- Converts an anchored offset counted inwards from its anchor, in place.
---@param holder table A record or text node, with anchor, x and y.
local function migrateInward(holder)
    local x, y = holder.x, holder.y
    if type(x) ~= "number" then
        x = 0
    end

    if type(y) ~= "number" then
        y = 0
    end

    x, y = anchors.FromInwardOffset(holder.anchor, x, y)

    if holder.x ~= nil then
        holder.x = tidyZero(x)
    end

    if holder.y ~= nil then
        holder.y = tidyZero(y)
    end
end

--- Converts a record's offsets, and its text nodes', in place. Not
--- idempotent: call it once per record, on what's known to be old.
---@param record any A saved record (anything else is left alone).
---@param oldGroupPositions boolean? The save is from before group points (see persistence's POSITIONS_VERSION): its grouped auras, but not nested plain groups, still measure from screen anchors.
function offsetMigration.MigrateRecord(record, oldGroupPositions)
    if type(record) ~= "table" then
        return
    end

    local grouped = record.group ~= nil
    local measuresFromAnchor = not grouped or (oldGroupPositions == true and record.display ~= PLAIN_GROUP_DISPLAY)
    if measuresFromAnchor then
        migrateInward(record)
    elseif type(record.y) == "number" then
        -- A plain offset from the group's point: only down becomes up.
        record.y = tidyZero(-record.y)
    end

    if type(record.texts) ~= "table" then
        return
    end

    for _, node in ipairs(record.texts) do
        if type(node) == "table" then
            migrateInward(node)
        end
    end
end

return offsetMigration
