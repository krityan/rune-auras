-- Positioning shared by the display types: anchored placement inside the
-- game area, and dragging while the aura is unlocked.
-- A display installs these methods and keeps self.root, self.parent,
-- self.width and self.height up to date:
--   placement.Install(Display)
--   self:bindDrag()                 -- once, after creating self.root
--   self:place(aura)                -- in Apply, after sizing self.root
--   self:setMovable(aura.unlocked)  -- in Apply
--   self:setHidden(hidden)          -- a display hiding itself (e.g. while empty)
-- The aura manager passes a condition's Hide with SetConditionHidden: when
-- a passing condition sets it (true or false) it decides, over the
-- display's own hide options (so "Hide: No" shows an icon its "Hide while
-- active" would hide); when none does (nil), the display's own decide.
-- A display in a group is given `groupPoint` ({ x, y }, the group's point
-- on screen) by the aura manager, through `new(parent, aura, groupPoint)`:
-- it's placed from that point (see anchors.FromPoint) rather than the
-- screen's anchors. One in a dynamic group has
-- `layoutManaged` instead: the group positions it (SetLayoutPos), so its own
-- anchor and dragging are ignored.
-- Usage: local placement = require("Auras/Displays/placement")

local anchors = require("Auras/Helpers/anchors")

local placement = {}

-- Tinted backing for an unlocked (draggable) display, so it's easy to find.
placement.UNLOCKED_BACKGROUND_RGBA = 0x6B5420D0

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

-- Hook coordinates are relative to the display, so keeping the grab point
-- under the cursor only needs the offset from where the drag started.
local function bindDrag(self)
    local root = self.root
    root:Subscribe(ui.Hook.ONCLICK, function(_, x, y)
        if not self.movable or self.layoutManaged then return true end
        self.grab = { x = x, y = y }
        root:MoveToFront()
        return false
    end)
    root:Subscribe(ui.Hook.ONHOLD, function(_, x, y)
        if self.grab == nil then return true end
        self:moveTo(root.x + x - self.grab.x, root.y + y - self.grab.y)
        return false
    end)
    local function stopDrag()
        if self.grab == nil then return true end
        self.grab = nil
        if self.onMoved ~= nil then
            local point = self.groupPoint
            if point ~= nil then
                self.onMoved(anchors.ToPoint(self.anchor, root.x, root.y, self.width, self.height, point.x, point.y))
            else
                self.onMoved(anchors.FromScreen(self.anchor, root.x, root.y,
                    self.width, self.height, self.parent.width, self.parent.height))
            end
        end
        return false
    end
    root:Subscribe(ui.Hook.ONRELEASE, stopDrag)
    root:Subscribe(ui.Hook.ONDRAGCOMPLETE, stopDrag)
end

-- Places the display's top-left corner, keeping it inside the game area.
local function moveTo(self, left, top)
    left = math.floor(clamp(left, 0, math.max(0, self.parent.width - self.width)))
    top = math.floor(clamp(top, 0, math.max(0, self.parent.height - self.height)))
    if left ~= self.root.x or top ~= self.root.y then
        self.root:SetPos(left, top)
    end
end

-- Moves the display to the aura's anchored offset (from its group's point,
-- in a group), unless a dynamic group places it.
local function place(self, aura)
    if self.layoutManaged then return end
    self.anchor = aura.anchor
    local point = self.groupPoint
    if point ~= nil then
        self:moveTo(anchors.FromPoint(aura.anchor, aura.x or 0, aura.y or 0, self.width, self.height, point.x, point.y))
    else
        self:moveTo(anchors.ToScreen(aura.anchor, aura.x or 0, aura.y or 0,
            self.width, self.height, self.parent.width, self.parent.height))
    end
end

-- An unlocked display catches clicks so it can be dragged; a locked one
-- lets them through to the game.
local function setMovable(self, movable)
    self.movable = movable == true
    self.root.enabled = self.movable
    self.root.clickthrough = not self.movable
    if not self.movable then self.grab = nil end
end

-- Hides or shows the whole display. Shown again, it loses its place in the
-- stack, so it asks the aura manager to restack (`needsRestack`).
local function updateHidden(self)
    local hidden = self.conditionHidden
    if hidden == nil then hidden = self.selfHidden == true end
    if hidden == self.rootHidden then return end
    self.rootHidden = hidden
    self.root.hidden = hidden
    if not hidden then self.needsRestack = true end
end

local function setHidden(self, hidden)
    self.selfHidden = hidden
    updateHidden(self)
end

local function setConditionHidden(self, hidden)
    self.conditionHidden = hidden
    updateHidden(self)
end

-- Puts the display's top-left corner at x, y in its parent, for a dynamic
-- group laying out its contents.
local function setLayoutPos(self, x, y)
    x, y = math.floor(x), math.floor(y)
    if x ~= self.root.x or y ~= self.root.y then self.root:SetPos(x, y) end
end

-- onMoved receives the new x, y as offsets from the aura's anchor (or its
-- group's point).
local function setOnMoved(self, callback)
    self.onMoved = callback
end

function placement.Install(class)
    class.bindDrag = bindDrag
    class.moveTo = moveTo
    class.place = place
    class.setMovable = setMovable
    class.setHidden = setHidden
    class.SetConditionHidden = setConditionHidden
    class.SetLayoutPos = setLayoutPos
    class.SetOnMoved = setOnMoved
end

return placement
