-- Group display: a point on screen that everything in the group is placed
-- from (see auraStore.ScreenPoint), so the group moves as one, and the box
-- shown around its contents while it's unlocked, for dragging it. The aura
-- manager creates the contents as children of `root` and hands them `point`.

local Border = require("Auras/Displays/Parts/border")
local anchors = require("Auras/Helpers/anchors")
local gameText = require("Auras/Helpers/game-text")
local gameApi = require("GameData/game-api")

--- A box in the group's own coordinates (the screen's).
---@class Bounds
---@field left number
---@field top number
---@field right number
---@field bottom number

--- A group's display. Its layer is the size of the game area and stays at
--- 0, 0, so it shares the screen's coordinates; a group has no size of its
--- own. Dragging the box moves the layer; on release the new point is
--- reported, and the next Apply puts the layer back.
---@class Group: Display
---@field parent userdata
---@field groupPoint GroupPoint? Its parent group's point; nil at the top level.
---@field point GroupPoint Its own point, handed to its contents.
---@field handle userdata The box shown while unlocked; the only part that catches clicks.
---@field backdrop userdata
---@field frame Border
---@field label userdata The group's name, on the box.
---@field bounds Bounds? Its contents' box; nil for an empty group.
---@field movable boolean
---@field grab { x: number, y: number }?
---@field onMoved fun(movedX: number, movedY: number)?
local Group = {}
Group.__index = Group

-- Position only; see auraStore.CreateGroup.
Group.defaults = {}

local HANDLE_RGBA = 0x6B542050
local HANDLE_BORDER_RGBA = 0xF2C66DFF
local LABEL_RGBA = 0xF2C66DFF
local BORDER = 2
local LABEL_HEIGHT = 20
-- The label's gap below the border.
local LABEL_GAP = 2
-- Space around the contents, and the smallest box (an empty group's box).
local HANDLE_MARGIN = 6
local MIN_HANDLE_WIDTH, MIN_HANDLE_HEIGHT = 140, 28
-- A point has no size: passed to anchors as the width and height.
local NO_SIZE = 0

--- Creates a group's display. If the game runs out of interface parts
--- partway (see the aura manager), the root goes, taking whatever was made
--- in it, and the error is raised again.
---@param parent userdata
---@param aura Aura
---@param groupPoint GroupPoint?
---@param class table? The metatable, so a display built on this one (the dynamic group) can share it.
---@return Group
function Group.new(parent, aura, groupPoint, class)
    local self = setmetatable({ parent = parent, groupPoint = groupPoint }, class or Group)

    self.root = ui.Layer.new(parent)
    local ok, problem = pcall(function()
        -- The layer covers the whole parent, so it must never catch clicks
        -- itself; only the handle does, while unlocked.
        self.root.enabled = true
        self.root.clickthrough = true

        self.handle = ui.Layer.new(self.root)
        self.backdrop = ui.Rectangle.new(self.handle)
        self.backdrop.fill = true
        self.backdrop.rgba = HANDLE_RGBA
        self.backdrop.clickthrough = true
        self.backdrop:SetPos(0, 0)
        self.frame = Border.new(self.handle, HANDLE_BORDER_RGBA)
        self.label = ui.Text.new(self.handle)
        self.label.font = gameApi.Font("MUSEO_SANS_11PT_REGULAR")
        self.label.rgba = LABEL_RGBA
        self.label.isShadowed = true
        self.label.alignHorizontal = ui.AlignMode.CENTRE
        self.label.alignVertical = ui.AlignMode.TOPLEFT
        self.label.maxLines = 1
        self.label.clickthrough = true

        self:bindDrag()
        self:Apply(aura)
    end)
    if not ok then
        self.root:Destroy()
        error(problem, 0)
    end
    return self
end

--- Lets the box be dragged. The handle moves with the layer it's in, so
--- hook coordinates relative to it stay put under the cursor; only the
--- offset from the grab point matters.
function Group:bindDrag()
    local handle = self.handle
    handle:Subscribe(ui.Hook.ONCLICK, function(_, x, y)
        if not self.movable then return true end
        self.grab = { x = x, y = y }
        return false
    end)
    handle:Subscribe(ui.Hook.ONHOLD, function(_, x, y)
        if self.grab == nil then return true end
        local root = self.root
        root:SetPos(math.floor(root.x + x - self.grab.x), math.floor(root.y + y - self.grab.y))
        return false
    end)
    local function stopDrag()
        if self.grab == nil then return true end
        self.grab = nil
        if self.onMoved ~= nil then self.onMoved(self.root.x, self.root.y) end
        return false
    end
    handle:Subscribe(ui.Hook.ONRELEASE, stopDrag)
    handle:Subscribe(ui.Hook.ONDRAGCOMPLETE, stopDrag)
end

--- Sets what's called when a drag ends. A drag moves the layer from 0, 0,
--- so the group's point moved as far as the layer did.
---@param callback fun(x: number, y: number) Gets the group's new x, y: from its anchor, or its parent's point.
function Group:SetOnMoved(callback)
    self.onMoved = function(movedX, movedY)
        local x, y = self.point.x + movedX, self.point.y + movedY
        local outer = self.groupPoint
        if outer ~= nil then
            callback(x - outer.x, y - outer.y)
        else
            callback(anchors.FromScreen(self.anchor, x, y, NO_SIZE, NO_SIZE, self.width, self.height))
        end
    end
end

--- Places the group's point from its aura and restyles the box. At the top
--- level its anchor and x/y place the point as an aura's would (for a point
--- with no size); in another group, x/y is an offset from that group's point.
---@param aura Aura
function Group:Apply(aura)
    self.width, self.height = self.parent.width, self.parent.height
    self.root:SetSize(self.width, self.height)
    self.root:SetPos(0, 0)
    self.anchor = aura.anchor
    local x, y
    local outer = self.groupPoint
    if outer ~= nil then
        x, y = outer.x + (aura.x or 0), outer.y + (aura.y or 0)
    else
        x, y = anchors.ToScreen(aura.anchor, aura.x or 0, aura.y or 0, NO_SIZE, NO_SIZE, self.width, self.height)
    end
    -- A new table only when it moves: the manager re-places the contents
    -- when their group's point is a different table.
    if self.point == nil or self.point.x ~= x or self.point.y ~= y then self.point = { x = x, y = y } end
    self.label.content = gameText.Plain(aura.name)
    self.movable = aura.unlocked == true
    if not self.movable then self.grab = nil end
    self.handle.hidden = not self.movable
    self.handle.enabled = self.movable
    self.handle.clickthrough = not self.movable
    self:layoutHandle()
end

--- Sets the box around the group's contents.
---@param left number? The contents' box, in the group's coordinates; nil for an empty group (its box then sits on its point).
---@param top number?
---@param right number?
---@param bottom number?
function Group:SetBounds(left, top, right, bottom)
    self.bounds = left ~= nil and { left = left, top = top, right = right, bottom = bottom } or nil
    self:layoutHandle()
end

--- The contents' box in the parent's coordinates, for a group around this one.
---@return number? left nil for an empty group.
---@return number? top
---@return number? right
---@return number? bottom
function Group:GetBounds()
    local bounds = self.bounds
    if bounds == nil then return nil end
    local x, y = self.root.x or 0, self.root.y or 0
    return bounds.left + x, bounds.top + y, bounds.right + x, bounds.bottom + y
end

--- Places the box around the contents (with room for the name above), or
--- on the point for an empty group.
function Group:layoutHandle()
    local left, top, right, bottom
    local bounds = self.bounds
    if bounds ~= nil then
        left, top = bounds.left - HANDLE_MARGIN, bounds.top - HANDLE_MARGIN - LABEL_HEIGHT
        right, bottom = bounds.right + HANDLE_MARGIN, bounds.bottom + HANDLE_MARGIN
    else
        left = self.point.x - MIN_HANDLE_WIDTH // 2
        top = self.point.y - MIN_HANDLE_HEIGHT // 2
        right, bottom = left + MIN_HANDLE_WIDTH, top + MIN_HANDLE_HEIGHT
    end
    local width = math.max(MIN_HANDLE_WIDTH, right - left)
    local height = math.max(MIN_HANDLE_HEIGHT, bottom - top)
    self.handle:SetPos(math.floor(left), math.floor(top))
    self.handle:SetSize(width, height)
    self.backdrop:SetSize(width, height)
    self.frame:Layout(width, height, BORDER)
    self.label:SetPos(0, BORDER + LABEL_GAP)
    self.label:SetSize(width, LABEL_HEIGHT)
end

--- Groups show no value.
function Group:SetValue()
end

--- Destroys the group's display. Its contents are in its layer, so they go too.
function Group:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Group
