-- Keeps dragging a PrettyUI scrollbar's thumb once the mouse slips off it, as
-- PrettyUI's drag only hears the mouse over the thumb. An empty text over the
-- thumb takes the press before PrettyUI's handler (which stops later
-- listeners) and starts dragFollow, whose moves become scroll positions.

local dragFollow = require("Auras/Displays/Parts/drag-follow")
local uiConstants = require("UI/ui-constants")

local thumbDrag = {}

-- How far a notch of the mouse wheel over the thumb scrolls, in interface
-- units, for a view with no step of its own.
local WHEEL_STEP = uiConstants.FIELD_HEIGHT

--- Whether a scroll view has the PrettyUI parts the drag uses.
---@param scroll table?
---@return boolean
local function hasParts(scroll)
    return type(scroll) == "table" and type(scroll.thumb) == "userdata" and type(scroll.track) == "userdata"
        and type(scroll.SetScrollPosition) == "function"
end

--- How much of a scroll view's content shows at once.
---@param scroll table
---@return number
local function viewportHeight(scroll)
    if type(scroll._ViewportHeight) == "function" then
        return scroll:_ViewportHeight()
    end

    return scroll.viewport.height
end

--- The part of a scroll view's scrollbar that takes the mouse over the thumb:
--- in a scroll view, a layer over the thumb (the thumb itself lets the mouse
--- through); in a List, the thumb.
---@param scroll table
---@return userdata
local function grip(scroll)
    if type(scroll.thumbDrag) == "userdata" then
        return scroll.thumbDrag
    end

    return scroll.thumb
end

--- Scrolls a view to where its thumb's top would be.
---@param view table
---@param top number The thumb's top in the track, in interface units.
local function scrollToTop(view, top)
    local maxScroll = math.max(0, (view.contentHeight or 0) - viewportHeight(view))
    local travel = view.track.height - (view.thumbHeight or view.thumb.height)
    if maxScroll > 0 and travel > 0 then
        view:SetScrollPosition(math.max(0, math.min(maxScroll, top * maxScroll / travel)))
    end
end

--- Makes a scroll view's thumb follow the mouse while its button is down.
--- If that can't start, or the view lacks the parts it uses, PrettyUI's drag
--- stays.
---@param scroll table A PrettyUI scroll view or List.
---@param current (fun(): table?)? The scroll view to move, looked up on each move, so one rebuilt mid-drag (the aura list, as it scrolls past the rows it built) carries the drag on; nil: `scroll`.
---@return boolean patched
function thumbDrag.Follow(scroll, current)
    if prettyui == nil or type(prettyui.NewComponent) ~= "function" or not hasParts(scroll) then
        return false
    end

    current = current or function() return scroll end
    local thumb = scroll.thumb
    local hit

    --- Scrolls to where the thumb's top would be. A view that can't be
    --- scrolled any more (destroyed mid-drag) stops the drag.
    ---@param top number The thumb's top in the track, in interface units.
    local function scrollToThumb(_, top)
        local view = current()
        if not hasParts(view) or not pcall(scrollToTop, view, top) then
            dragFollow.Cancel(hit)
        end
    end

    local function onEnd() end

    -- Made through PrettyUI, inside its control: a plain component there
    -- can take an id the control's parts use, and crash the client.
    hit = prettyui.NewComponent(ui.Text, grip(scroll))
    hit:SetSize(0, 0, 1, 1)
    hit.content = ""
    hit.clickthrough = false

    hit:Subscribe(ui.Hook.ONCLICK, function(component, x)
        if not dragFollow.Start(thumb, component, x, scrollToThumb, onEnd) then
            hit.clickthrough = true
        end

        return false
    end)

    -- The hit takes the mouse, so it passes the wheel on: to a List's own
    -- handler, otherwise scrolling by the view's step a notch.
    hit:Subscribe(ui.Hook.ONSCROLLWHEEL, function(component, delta)
        local view = current()
        if not hasParts(view) then
            return false
        end

        if type(view._OnScrollWheel) == "function" then
            return view:_OnScrollWheel(component, delta)
        end

        local maxScroll = math.max(0, (view.contentHeight or 0) - viewportHeight(view))
        local target = (view.scrollY or 0) + delta * (view.scrollStep or WHEEL_STEP)
        view:SetScrollPosition(math.max(0, math.min(maxScroll, target)))
        return false
    end)

    return true
end

return thumbDrag
