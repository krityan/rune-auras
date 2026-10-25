-- Fits a PrettyUI tab strip to its width. The tabs run off the right edge
-- when it's narrow, out of reach, so when they don't all fit, only those
-- that do are shown, between arrows at either end to scroll through them.
-- Patches PrettyUI internals (its tabs' `tabs` list, each with `visual`,
-- `hit` and `width`, and `tabGap`/`tabInset`), so it leaves the strip alone
-- if they aren't there; check in game when PrettyUI updates.

local uiConstants = require("UI/ui-constants")

local TabStrip = {}
TabStrip.__index = TabStrip

local ARROW_SIZE = 20
local ARROW_Y = 10
local GAP = uiConstants.GAP

---@class TabStrip
---@field prettyUI table
---@field firstTab integer The first tab shown while they don't all fit; kept across rebuilds.
---@field tabs table? The PrettyUI Tabs last fitted.
---@field width number
---@field activeIndex integer
---@field arrows { left: table, right: table }? Made in the tabs' layer, so they go with it.

--- Makes a strip fitter. One lasts across the editor's rebuilds, so the
--- tabs stay scrolled where they were.
---@param prettyUI table
---@return TabStrip
function TabStrip.new(prettyUI)
    return setmetatable({ prettyUI = prettyUI, firstTab = 1, width = 0, activeIndex = 1 }, TabStrip)
end

--- Shows a tab at a place on the strip, or hides it.
---@param tab table One of PrettyUI's tabs.
---@param x number
---@param shown boolean
local function placeTab(tab, x, shown)
    tab.visual.hidden = not shown
    tab.hit.hidden = not shown
    if shown then
        tab.visual:SetPos(x, tab.visual.y or 0)
        tab.hit:SetPos(x, 0)
    end
end

--- The last tab that fits on the strip, starting from one.
---@param list table[] PrettyUI's tabs.
---@param from integer The first tab shown.
---@param startX number Where the first tab starts.
---@param room number How far the tabs may reach.
---@param gap number
---@return integer last
local function lastFittingTab(list, from, startX, room, gap)
    local x, last = startX, from - 1
    for index = from, #list do
        if x + list[index].width > room and index > from then break end
        x, last = x + list[index].width + gap, index
    end
    return last
end

--- Whether PrettyUI's tabs have the internals this lays out.
---@param tabs table
---@return boolean
local function hasInternals(tabs)
    if type(tabs.tabs) ~= "table" then return false end
    for _, tab in ipairs(tabs.tabs) do
        if tab.visual == nil or tab.hit == nil or tab.width == nil then return false end
    end
    return true
end

local layout

--- Scrolls the strip by some tabs, leaving the active one where it falls.
---@param self TabStrip
---@param by integer
local function scrollBy(self, by)
    self.firstTab = self.firstTab + by
    local keepActive = false
    layout(self, keepActive)
end

--- Lays the tabs out from firstTab, with the arrows while they overflow.
---@param self TabStrip
---@param keepActive boolean Scroll the active tab into view (not when scrolling with the arrows).
function layout(self, keepActive)
    local tabs = self.tabs
    if tabs == nil or not hasInternals(tabs) then return end
    local list = tabs.tabs
    local gap, inset = tabs.tabGap or 0, tabs.tabInset or 0
    local width = self.width
    local total = inset - gap
    for _, tab in ipairs(list) do total = total + tab.width + gap end
    local overflowing = total > width
    -- With the arrows in, the tabs start after the left one and must end
    -- before the right one.
    local startX = overflowing and inset + ARROW_SIZE + GAP or inset
    local room = overflowing and width - (ARROW_SIZE + GAP) or width
    -- Keep the active tab in view, and don't scroll past the point where
    -- the last tab is already showing.
    local active = self.activeIndex
    if not overflowing then self.firstTab = 1 end
    if keepActive and active < self.firstTab then self.firstTab = active end
    self.firstTab = math.max(1, math.min(self.firstTab, #list))
    --- The last tab shown when starting from one.
    ---@param from integer
    ---@return integer
    local function lastShown(from) return lastFittingTab(list, from, startX, room, gap) end
    while keepActive and active > lastShown(self.firstTab) and self.firstTab < active do
        self.firstTab = self.firstTab + 1
    end
    while self.firstTab > 1 and lastShown(self.firstTab - 1) == #list do self.firstTab = self.firstTab - 1 end
    local last = lastShown(self.firstTab)
    local x = startX
    for index, tab in ipairs(list) do
        local shown = index >= self.firstTab and index <= last
        placeTab(tab, x, shown)
        if shown then x = x + tab.width + gap end
    end

    if self.arrows == nil then
        local spriteButton = self.prettyUI.SpriteButton
        self.arrows = {
            left = spriteButton.new(tabs.root, "ARROW_LEFT", function() scrollBy(self, -1) end, {
                x = inset, y = ARROW_Y, size = ARROW_SIZE,
            }),
            right = spriteButton.new(tabs.root, "ARROW_RIGHT", function() scrollBy(self, 1) end, {
                x = -ARROW_SIZE, xAnchor = 1, y = ARROW_Y, size = ARROW_SIZE,
            }),
        }
    end
    local arrows = self.arrows
    arrows.left.root.hidden = not overflowing
    arrows.right.root.hidden = not overflowing
    arrows.left:SetDisabled(self.firstTab <= 1)
    arrows.right:SetDisabled(last >= #list)
    -- Selecting a tab brings PrettyUI's strip to the front; keep them above.
    arrows.left.root:MoveToFront()
    arrows.right.root:MoveToFront()
end

--- Fits tabs to a width, keeping the active one in view. Call after
--- building and after each tab switch; the editor rebuilds when its width
--- changes, so once per build is enough for that.
---@param tabs table A PrettyUI Tabs.
---@param width number The strip's width.
---@param activeIndex integer
function TabStrip:Fit(tabs, width, activeIndex)
    if tabs ~= self.tabs then
        -- New tabs: the old arrows went with the old tabs' layer.
        self.tabs, self.arrows = tabs, nil
    end
    self.width, self.activeIndex = width, activeIndex
    local keepActive = true
    layout(self, keepActive)
end

--- Forgets the tabs, when they're destroyed (their arrows go with them).
function TabStrip:Forget()
    self.tabs, self.arrows = nil, nil
end

return TabStrip
