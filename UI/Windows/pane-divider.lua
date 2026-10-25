-- The divider between the main window's list and editor: dragged to change
-- the list's width, which it saves (as mainListWidth). While it's dragged
-- only its line follows the mouse; the window lays the panes out on release.

local uiConstants = require("UI/ui-constants")

local PaneDivider = {}
PaneDivider.__index = PaneDivider

-- The gap between the panes, which is the divider's hit area.
PaneDivider.WIDTH = uiConstants.GAP
local LINE_WIDTH = 2
local IDLE_RGBA = uiConstants.WithAlpha(uiConstants.MUTED_RGBA, 0x40)
local STORAGE_KEY = "mainListWidth"

---@class PaneDividerOptions
---@field top number Where the panes start, below the window's header.
---@field clamp fun(width: number): integer Keeps a list width usable.
---@field onReleased fun(width: integer?) After a drag: the new list width, saved; nil if it didn't change.

---@class PaneDivider
---@field hit userdata The layer that takes the mouse.
---@field line userdata The line drawn for it.
---@field options PaneDividerOptions
---@field width number? The list width it was last placed for.
---@field drag { grab: number, expanded: boolean?, width: number? }? A drag in progress; `grab` is x within the divider.

--- The list width the player last chose.
---@return number? width nil if they never have.
function PaneDivider.SavedWidth()
    return tonumber(PersistentDB:GetString(STORAGE_KEY) or "")
end

--- Puts the line beside a list width.
---@param self PaneDivider
---@param width number
local function placeLine(self, width)
    self.line:SetPos(width + (PaneDivider.WIDTH - LINE_WIDTH) // 2, self.options.top)
end

--- Ends a drag, saving the list's new width if it changed.
---@param self PaneDivider
---@return boolean
local function finishDrag(self)
    local finished = self.drag
    self.drag = nil
    if finished == nil then return false end
    self.line.rgba = IDLE_RGBA
    local newWidth = finished.width
    if newWidth ~= nil and newWidth ~= self.width then
        PersistentDB:SetString(STORAGE_KEY, tostring(newWidth))
        self.options.onReleased(newWidth)
    else
        self.options.onReleased(nil)
    end
    return false
end

--- Makes the divider in a window's content.
---@param content userdata
---@param options PaneDividerOptions
---@return PaneDivider
function PaneDivider.new(content, options)
    local self = setmetatable({ options = options }, PaneDivider)
    local line = ui.Rectangle.new(content)
    line.fill = true
    line.rgba = IDLE_RGBA
    line.clickthrough = true
    line:SetSize(LINE_WIDTH, -options.top, 0, 1)
    self.line = line

    local hit = ui.Layer.new(content)
    hit.enabled = true
    hit.clickthrough = false
    hit:Subscribe(ui.Hook.ONMOUSEOVER, function()
        line.rgba = uiConstants.ACCENT_RGBA
        return false
    end)
    hit:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        if self.drag == nil then line.rgba = IDLE_RGBA end
        return false
    end)
    hit:Subscribe(ui.Hook.ONCLICK, function(_, x)
        self.drag = { grab = x }
        return false
    end)
    hit:Subscribe(ui.Hook.ONHOLD, function(component, x)
        local drag = self.drag
        if drag == nil then return false end
        -- Hook coordinates are relative to the divider until it's expanded
        -- over the window (so the hold keeps reporting), then they're relative
        -- to the window.
        local contentX = drag.expanded and x or ((component.x or 0) + x)
        if not drag.expanded then
            drag.expanded = true
            component:SetPos(0, 0)
            component:SetSize(0, 0, 1, 1)
            component:MoveToFront()
        end
        drag.width = options.clamp(contentX - drag.grab)
        line.rgba = uiConstants.ACCENT_RGBA
        placeLine(self, drag.width)
        return false
    end)
    local function release() return finishDrag(self) end
    hit:Subscribe(ui.Hook.ONRELEASE, release)
    hit:Subscribe(ui.Hook.ONDRAGCOMPLETE, release)
    self.hit = hit
    return self
end

--- Places the divider beside a list width (shrinking it back from covering
--- the window after a drag).
---@param width number The list's width.
function PaneDivider:Place(width)
    self.width = width
    self.hit:SetPos(width, self.options.top)
    self.hit:SetSize(PaneDivider.WIDTH, -self.options.top, 0, 1)
    placeLine(self, width)
end

--- Shows or hides it (the single view has no divider).
---@param shown boolean
function PaneDivider:SetShown(shown)
    self.hit.hidden = not shown
    self.line.hidden = not shown
end

--- Whether it's being dragged, so the window holds off laying out again.
---@return boolean
function PaneDivider:IsDragging()
    return self.drag ~= nil
end

return PaneDivider
