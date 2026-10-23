-- Positioning shared by the display types: anchored placement inside the
-- game area, and dragging while the aura is unlocked.
-- A display installs these methods and keeps self.root, self.parent,
-- self.width and self.height up to date:
--   placement.Install(Display)
--   self:bindDrag()                 -- once, after creating self.root
--   self:place(aura)                -- in Apply, after sizing self.root
--   self:setMovable(aura.unlocked)  -- in Apply
--   self:setHidden(hidden)          -- a display hiding itself (e.g. while empty)
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
        if not self.movable then return true end
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
            self.onMoved(anchors.FromScreen(self.anchor, root.x, root.y,
                self.width, self.height, self.parent.width, self.parent.height))
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

-- Moves the display to the aura's anchored offset.
local function place(self, aura)
    self.anchor = aura.anchor
    self:moveTo(anchors.ToScreen(aura.anchor, aura.x or 0, aura.y or 0,
        self.width, self.height, self.parent.width, self.parent.height))
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
local function setHidden(self, hidden)
    if hidden == self.rootHidden then return end
    self.rootHidden = hidden
    self.root.hidden = hidden
    if not hidden then self.needsRestack = true end
end

-- onMoved receives the new x, y as offsets from the aura's anchor.
local function setOnMoved(self, callback)
    self.onMoved = callback
end

function placement.Install(class)
    class.bindDrag = bindDrag
    class.moveTo = moveTo
    class.place = place
    class.setMovable = setMovable
    class.setHidden = setHidden
    class.SetOnMoved = setOnMoved
end

return placement
