-- Where windows open: the main window where the player last left it (saved
-- as mainWindowRect, so also after reloading the plugin), kept inside the
-- game area, or centred near the top the first time; and windows opened
-- from it (the icon picker, Import's preview) beside it.

local maths = require("Auras/Helpers/maths")
local uiConstants = require("UI/ui-constants")

local windowRect = {}

---@class Rect
---@field x number
---@field y number
---@field width number
---@field height number

windowRect.DEFAULT_WIDTH = 900
local DEFAULT_HEIGHT = 600
windowRect.MIN_WIDTH = 640
windowRect.MIN_HEIGHT = 360
-- The first time, the window sits this far below the top (and at most this
-- close to the bottom).
local MARGIN = 60
-- Saved as "x,y,width,height".
local STORAGE_KEY = "mainWindowRect"
-- Between a window opened beside another and that window.
local BESIDE_GAP = uiConstants.GAP

---@type Rect?
local saved = nil
local loaded = false

--- Loads where the window was left, once.
local function load()
    if loaded then
        return
    end

    loaded = true
    local text = PersistentDB:GetString(STORAGE_KEY)
    local x, y, width, height = tostring(text or ""):match("^(-?%d+),(-?%d+),(%d+),(%d+)$")
    if x == nil then
        return
    end

    saved = { x = tonumber(x), y = tonumber(y), width = tonumber(width), height = tonumber(height) }
end

--- Keeps a remembered window inside the game area, which may have shrunk
--- since it was saved.
---@param rect Rect
---@param area userdata The game area.
---@return Rect
local function fit(rect, area)
    local width = math.max(windowRect.MIN_WIDTH, math.min(rect.width, area.width))
    local height = math.max(windowRect.MIN_HEIGHT, math.min(rect.height, area.height))
    return {
        x = math.max(0, math.min(rect.x, area.width - width)),
        y = math.max(0, math.min(rect.y, area.height - height)),
        width = width,
        height = height,
    }
end

--- Where the window opens the first time: centred, near the top.
---@param area userdata The game area.
---@return Rect
local function default(area)
    return {
        x = math.max(0, (area.width - windowRect.DEFAULT_WIDTH) // 2),
        y = MARGIN,
        width = math.min(windowRect.DEFAULT_WIDTH, area.width),
        height = math.max(windowRect.MIN_HEIGHT, math.min(DEFAULT_HEIGHT, area.height - MARGIN * 2)),
    }
end

--- Where to open the window: where it was left, inside the game area, or
--- the default the first time.
---@param area userdata The game area.
---@return Rect
function windowRect.Opening(area)
    load()
    return saved and fit(saved, area) or default(area)
end

--- Where a window opened from another opens (the icon picker, an example's
--- preview): beside it, level with its middle and a gap away, on its right,
--- or its left if there's no room there. With room on neither side, or no
--- window, it's in the middle of the game area. Always kept inside it.
---@param beside Rect?
---@param width number The new window's size.
---@param height number
---@param areaWidth number
---@param areaHeight number
---@return number x
---@return number y
function windowRect.Beside(beside, width, height, areaWidth, areaHeight)
    local maxX, maxY = math.max(0, areaWidth - width), math.max(0, areaHeight - height)
    local centreX, centreY = maxX // 2, maxY // 2
    if beside == nil then
        return centreX, centreY
    end

    local right = beside.x + beside.width + BESIDE_GAP
    local left = beside.x - BESIDE_GAP - width
    local x
    if right <= maxX then
        x = right
    elseif left >= 0 then
        x = left
    else
        return centreX, centreY
    end

    local levelY = beside.y + (beside.height - height) // 2
    return x, maths.Clamp(levelY, 0, maxY)
end

--- Saves where a window is now.
---@param root userdata The window's root component.
function windowRect.Remember(root)
    saved = {
        x = math.floor(root.x),
        y = math.floor(root.y),
        width = math.floor(root.width),
        height = math.floor(root.height),
    }
    loaded = true
    PersistentDB:SetString(STORAGE_KEY, formatStr("{},{},{},{}",
        tostring(saved.x), tostring(saved.y), tostring(saved.width), tostring(saved.height)))
end

return windowRect
