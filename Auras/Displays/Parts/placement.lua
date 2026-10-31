-- Placement shared by the display types: anchored positioning inside the
-- game area (or from a group's point), dragging while unlocked, and hiding.

local anchors = require("Auras/Helpers/anchors")
local maths = require("Auras/Helpers/maths")

local clamp = maths.Clamp

local placement = {}

-- Tinted backing for an unlocked (draggable) display, so it's easy to find.
placement.UNLOCKED_BACKGROUND_RGBA = 0x6B5420D0

--- The fields placement reads and writes on a display. The display keeps
--- root, parent, width and height up to date; the rest are placement's own.
---@class Placed: Display
---@field parent userdata The layer it's drawn in.
---@field width number
---@field height number
---@field groupPoint GroupPoint? Its group's point; nil at the top level.
---@field layoutManaged boolean? In a dynamic group, which positions it (SetLayoutPos), so its own anchor and dragging are ignored.
---@field anchor AnchorID? The anchor it was last placed from.
---@field movable boolean? Whether it's unlocked and can be dragged.
---@field grab { x: number, y: number }? Where a drag took hold of it, relative to it.
---@field onMoved fun(x: number, y: number)? Called with the new offset when a drag ends.
---@field selfHidden boolean? The display hiding itself (e.g. while empty).
---@field conditionHidden boolean? A condition's Hide; nil when none sets it.
---@field rootHidden boolean? Whether the root is hidden now.
---@field needsRestack boolean? Set when it's shown again; the aura manager restacks from it and clears it.
---@field overlay TextNodes? Drawn beside the root rather than in it, so it isn't clipped to the box (value texts); moved, hidden and raised with the root.
---@field overlayX number? Where the overlay's box starts in the root (a Bar's body beside its icon).

--- Moves the overlay to the root's place. A newly made overlay layer lands
--- on top of everything, so it asks to be restacked.
---@param self Placed
local function syncOverlay(self)
    local overlay = self.overlay
    if overlay == nil then return end
    overlay:MoveTo(self.root.x + (self.overlayX or 0), self.root.y)
    if overlay.layerMade then
        overlay.layerMade = nil
        self.needsRestack = true
    end
end

--- Brings the display to the front, its overlay with it.
---@param self Placed
local function raise(self)
    self.root:MoveToFront()
    if self.overlay ~= nil then self.overlay:MoveToFront() end
end

--- The offset a display's position is from its anchor (or its group's
--- point), to report when a drag ends.
---@param self Placed
---@return integer x
---@return integer y
local function draggedOffset(self)
    local root = self.root
    local point = self.groupPoint
    if point ~= nil then
        return anchors.ToPoint(self.anchor, root.x, root.y, self.width, self.height, point.x, point.y)
    end
    return anchors.FromScreen(self.anchor, root.x, root.y, self.width, self.height, self.parent.width,
        self.parent.height)
end

--- Lets an unlocked display be dragged. Hook coordinates are relative to the
--- display, so keeping the grab point under the cursor only needs the
--- offset from where the drag started. Call once, after creating self.root.
---@param self Placed
local function bindDrag(self)
    local root = self.root
    root:Subscribe(ui.Hook.ONCLICK, function(_, x, y)
        if not self.movable or self.layoutManaged then return true end
        self.grab = { x = x, y = y }
        raise(self)
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
        if self.onMoved ~= nil then self.onMoved(draggedOffset(self)) end
        return false
    end
    root:Subscribe(ui.Hook.ONRELEASE, stopDrag)
    root:Subscribe(ui.Hook.ONDRAGCOMPLETE, stopDrag)
end

--- Places the display's top-left corner, keeping it inside the game area.
---@param self Placed
---@param left number
---@param top number
local function moveTo(self, left, top)
    left = math.floor(clamp(left, 0, math.max(0, self.parent.width - self.width)))
    top = math.floor(clamp(top, 0, math.max(0, self.parent.height - self.height)))
    if left ~= self.root.x or top ~= self.root.y then
        self.root:SetPos(left, top)
    end
    -- Also when only the overlay's place in the root moved.
    syncOverlay(self)
end

--- Moves the display to the aura's anchored offset (from its group's point,
--- in a group), unless a dynamic group places it. Call in Apply, after
--- sizing self.root.
---@param self Placed
---@param aura Aura
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

--- Unlocks or locks the display. An unlocked one catches clicks so it can be
--- dragged; a locked one lets them through to the game. Call in Apply.
---@param self Placed
---@param movable boolean?
local function setMovable(self, movable)
    self.movable = movable == true
    self.root.enabled = self.movable
    self.root.clickthrough = not self.movable
    if not self.movable then self.grab = nil end
end

--- Hides or shows the whole display: a condition's Hide decides when one
--- sets it, else the display's own. Shown again, it loses its place in the
--- stack, so it asks the aura manager to restack (`needsRestack`).
---@param self Placed
local function updateHidden(self)
    local hidden = self.conditionHidden
    if hidden == nil then hidden = self.selfHidden == true end
    if hidden == self.rootHidden then return end
    self.rootHidden = hidden
    self.root.hidden = hidden
    if self.overlay ~= nil then self.overlay:SetHidden(hidden) end
    if not hidden then self.needsRestack = true end
end

--- The display hiding itself (e.g. while empty).
---@param self Placed
---@param hidden boolean
local function setHidden(self, hidden)
    self.selfHidden = hidden
    updateHidden(self)
end

--- A passing condition's Hide, from the aura manager: true or false decides
--- over the display's own hide options (so "Hide: No" shows an icon its
--- "Hide while active" would hide); nil leaves them to decide.
---@param self Placed
---@param hidden boolean?
local function setConditionHidden(self, hidden)
    self.conditionHidden = hidden
    updateHidden(self)
end

--- Puts the display's top-left corner at x, y in its parent, for a dynamic
--- group laying out its contents.
---@param self Placed
---@param x number
---@param y number
local function setLayoutPos(self, x, y)
    x, y = math.floor(x), math.floor(y)
    if x ~= self.root.x or y ~= self.root.y then self.root:SetPos(x, y) end
    syncOverlay(self)
end

--- Sets what's called when a drag ends.
---@param self Placed
---@param callback fun(x: number, y: number) Gets the new offset from the aura's anchor (or its group's point).
local function setOnMoved(self, callback)
    self.onMoved = callback
end

--- Mixes the placement methods into a display class: bindDrag, moveTo, place,
--- setMovable and setHidden for the display's own use, and
--- SetConditionHidden, SetLayoutPos and SetOnMoved for the aura manager.
---@param class table The display's metatable.
function placement.Mixin(class)
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
