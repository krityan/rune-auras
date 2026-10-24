-- Group display: moves everything in the group by the group's x/y. Its layer
-- is the size of its parent (the game area, or the group it sits in) and is
-- shifted by x/y, so the auras inside keep their own anchors and simply
-- follow it. The aura manager creates them as children of `root` (see
-- Auras/aura-manager).
-- A group has no size of its own. While it's unlocked it shows a box around
-- its contents (set by the manager through SetBounds) with its name, and
-- dragging the box moves the whole group.

local Border = require("Auras/Displays/border")
local gameApi = require("GameData/game-api")

local Group = {}
Group.__index = Group

-- Position only; see auraStore.CreateGroup.
Group.defaults = {}

local HANDLE_RGBA = 0x6B542050
local HANDLE_BORDER_RGBA = 0xF2C66DFF
local LABEL_RGBA = 0xF2C66DFF
local BORDER = 2
local LABEL_HEIGHT = 20
-- Space around the contents, and the smallest box (an empty group's).
local HANDLE_MARGIN = 6
local MIN_HANDLE_WIDTH, MIN_HANDLE_HEIGHT = 140, 28

-- `class` lets a display built on this one (the dynamic group) share it.
function Group.new(parent, aura, class)
    local self = setmetatable({ parent = parent }, class or Group)

    self.root = ui.Layer.new(parent)
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
    return self
end

-- The handle moves with the layer it's in, so hook coordinates relative to
-- it stay put under the cursor; only the offset from the grab point matters.
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

-- onMoved receives the group's new x, y.
function Group:SetOnMoved(callback)
    self.onMoved = callback
end

function Group:Apply(aura)
    self.width, self.height = self.parent.width, self.parent.height
    self.root:SetSize(self.width, self.height)
    self.root:SetPos(aura.x or 0, aura.y or 0)
    self.label.content = (tostring(aura.name or ""):gsub("[<>]", ""))
    self.movable = aura.unlocked == true
    if not self.movable then self.grab = nil end
    self.handle.hidden = not self.movable
    self.handle.enabled = self.movable
    self.handle.clickthrough = not self.movable
    self:layoutHandle()
end

-- The box around the group's contents, in the group's own coordinates, or
-- nil for an empty group (its box then sits in the middle).
function Group:SetBounds(left, top, right, bottom)
    self.bounds = left ~= nil and { left, top, right, bottom } or nil
    self:layoutHandle()
end

-- The contents' box in the parent's coordinates, for a group around this one.
function Group:GetBounds()
    if self.bounds == nil then return nil end
    local x, y = self.root.x or 0, self.root.y or 0
    return self.bounds[1] + x, self.bounds[2] + y, self.bounds[3] + x, self.bounds[4] + y
end

function Group:layoutHandle()
    local left, top, right, bottom
    if self.bounds ~= nil then
        left, top = self.bounds[1] - HANDLE_MARGIN, self.bounds[2] - HANDLE_MARGIN - LABEL_HEIGHT
        right, bottom = self.bounds[3] + HANDLE_MARGIN, self.bounds[4] + HANDLE_MARGIN
    else
        left = (self.width - MIN_HANDLE_WIDTH) // 2
        top = (self.height - MIN_HANDLE_HEIGHT) // 2
        right, bottom = left + MIN_HANDLE_WIDTH, top + MIN_HANDLE_HEIGHT
    end
    local width = math.max(MIN_HANDLE_WIDTH, right - left)
    local height = math.max(MIN_HANDLE_HEIGHT, bottom - top)
    self.handle:SetPos(math.floor(left), math.floor(top))
    self.handle:SetSize(width, height)
    self.backdrop:SetSize(width, height)
    self.frame:Layout(width, height, BORDER)
    self.label:SetPos(0, BORDER + 2)
    self.label:SetSize(width, LABEL_HEIGHT)
end

-- Groups show no value.
function Group:SetValue()
end

function Group:Destroy()
    self.root:Destroy()
    self.root = nil
end

return Group
