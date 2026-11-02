-- Drags that follow the cursor, for placement and groups. ONHOLD and
-- ONRELEASE only follow the cursor over the held component, so a fast cursor
-- slips off a thin display and the drag drops. Instead, while a display is
-- dragged, an invisible catcher covers the game area: the cursor can't leave
-- it, so its ONHOLDs come every Logic tick while the button is down, which
-- the API can't otherwise tell. Each one moves the display to the cursor,
-- so it stops where the button went up.

local rectangles = require("Auras/Displays/Parts/rectangles")
local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")

local dragFollow = {}

local EVENT_ID = "runeAurasDragFollow"
-- Logic ticks without a catcher ONHOLD that mean the button went up, and the
-- drag is saved.
local RELEASE_GAP_TICKS = 2
-- Nearly transparent: invisible, but taking the mouse.
local CATCHER_RGBA = 0x00000001
-- Window pixels per interface unit outside which a measurement is wrong.
local MIN_SCALE, MAX_SCALE = 0.25, 4

---@class DragState
---@field clicked userdata The component that was clicked: root, or a group's handle.
---@field catcher userdata The layer over the game area whose ONHOLDs mean the button is down.
---@field start { x: number, y: number } The moved component's position when the drag started.
---@field mouse userdata Mouse position in window pixels when the drag started.
---@field scale number Window pixels per interface unit.
---@field lastHold integer Logic tick of the catcher's last ONHOLD, or of the click.
---@field onMove fun(left: number, top: number)
---@field onEnd fun()

---@type DragState? The live drag. There's only ever one: while it's live, the
--- catcher takes every click, so a click within the release gap carries it on.
local active = nil

--- Window pixels per interface unit, from where the grab point is in each.
--- The mouse position has no UI scaling applied, while positions do.
---@param clicked userdata
---@param grabX number ONCLICK's x, relative to `clicked`.
---@param mouse userdata The mouse position at the click.
---@return number scale 1 if it can't be measured.
local function measureScale(clicked, grabX, mouse)
    local unitsX = clicked.xyGlobal.x + grabX
    if unitsX <= 0 then return 1 end
    local scale = mouse.x / unitsX
    if scale < MIN_SCALE or scale > MAX_SCALE then return 1 end
    return scale
end

--- Destroys a component, for pcall. Its method is called with `:`, never
--- read as a field (see AGENTS.md).
---@param component userdata
local function destroyComponent(component)
    component:Destroy()
end

--- Stops following and removes the catcher, if the drag is the live one.
--- The catcher is already gone if the game area was rebuilt or left.
---@param drag DragState
---@return boolean stopped
local function stopFollowing(drag)
    if active ~= drag then return false end
    active = nil
    Event.Logic.Unsubscribe(EVENT_ID)
    pcall(destroyComponent, drag.catcher)
    return true
end

--- Each Logic tick: ends the drag once the catcher's ONHOLDs have stopped.
---@param event table A Logic event.
local function checkReleased(event)
    local drag = active
    if event.logicTick - drag.lastHold <= RELEASE_GAP_TICKS then return end
    stopFollowing(drag)
    drag.onEnd()
end

--- Moves the display to the cursor.
---@param drag DragState
local function moveToCursor(drag)
    local mouse = gameApi.MousePosition()
    if mouse == nil then return end
    drag.onMove(drag.start.x + (mouse.x - drag.mouse.x) / drag.scale,
        drag.start.y + (mouse.y - drag.mouse.y) / drag.scale)
end

--- Makes the catcher: a layer over the game area that takes the mouse, and
--- moves the display on each ONHOLD. It's made last, so it's on top.
---@param drag DragState
---@param area userdata The game area.
---@return userdata catcher
local function newCatcher(drag, area)
    local catcher = rectangles.Filled(area, CATCHER_RGBA)
    catcher.enabled, catcher.clickthrough = true, false
    catcher:SetSize(area.width, area.height)
    catcher:Subscribe(ui.Hook.ONHOLD, function()
        drag.lastHold = gameClock.LogicTick()
        moveToCursor(drag)
        return false
    end)
    return catcher
end

--- Starts moving a display with the cursor, until the button goes up.
---@param root userdata The component that moves.
---@param clicked userdata The component that was clicked.
---@param grabX number ONCLICK's x, relative to `clicked`.
---@param onMove fun(left: number, top: number) Moves root, in unrounded interface units.
---@param onEnd fun() The caller's end of drag, called once the button is up.
---@return boolean started false without a mouse (mobile) or game area, or at the game's limit on interface parts: the caller moves it from ONHOLD instead.
function dragFollow.Start(root, clicked, grabX, onMove, onEnd)
    local mouse = gameApi.MousePosition()
    local area = gameApi.GameArea()
    local tick = gameClock.LogicTick()
    if mouse == nil or area == nil or tick == nil then return false end
    local drag = {
        clicked = clicked, onMove = onMove, onEnd = onEnd, start = { x = root.x, y = root.y },
        mouse = mouse, scale = measureScale(clicked, grabX, mouse), lastHold = tick,
    }
    -- At the limit, the drag falls back to ONHOLD; anything else is a bug.
    local made, catcher = pcall(newCatcher, drag, area)
    if not made then
        if not gameApi.IsComponentLimitError(catcher) then error(catcher, 0) end
        return false
    end
    drag.catcher = catcher
    active = drag
    Event.Logic.Subscribe(EVENT_ID, checkReleased)
    return true
end

--- Whether a component's drag follows the cursor.
---@param clicked userdata
---@return boolean
function dragFollow.IsFollowing(clicked)
    return active ~= nil and active.clicked == clicked
end

--- Stops the live drag without ending it on the caller's side, e.g. when
--- it's locked mid-drag or on leaving the game.
---@param clicked userdata? Only if it's this component's drag; nil: whichever is live.
function dragFollow.Cancel(clicked)
    if active == nil then return end
    if clicked == nil or active.clicked == clicked then stopFollowing(active) end
end

--- Wraps a drag's ONRELEASE/ONDRAGCOMPLETE handler to ignore releases while
--- following: the client reports one whenever the cursor leaves the
--- component's outline, button down or not.
---@param clicked userdata The component the hooks are on.
---@param stopDrag fun(): boolean? The caller's end of drag.
---@return fun(): boolean? handler
function dragFollow.ReleaseHandler(clicked, stopDrag)
    return function()
        if dragFollow.IsFollowing(clicked) then return false end
        return stopDrag()
    end
end

return dragFollow
