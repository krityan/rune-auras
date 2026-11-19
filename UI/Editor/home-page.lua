-- The editor's home page, shown while no aura is selected: a welcome, how to
-- get started, where to find examples and help, and what display types,
-- data sources, groups, conditions and load conditions are, in page text
-- (UI/Controls/page-text), with one spacer giving the view the page's
-- height to scroll through.

local pageText = require("UI/Controls/page-text")

local homePage = {}

-- Room kept clear of the bottom, so the last line isn't against the edge.
local BOTTOM_MARGIN = 16

-- The page, top to bottom: each block's kind and text. It's regenerated
-- whole from the page's source text, so don't edit it by hand.
local PAGE = {
    { "title", "Welcome to RuneAuras" },

    { "heading", "Getting Started" },
    { "bullet", "Click new (in the top left)" },
    { "bullet", "Pick a display type (icon, bar, etc.)" },
    { "bullet", "Choose what data to display" },

    { "heading", "Need Inspiration?" },
    { "text", "To see some examples, hit the import button and pick from one of the included examples. "
        .. "Whether you want buff bars that exclusively show your consumables or simply a customisable "
        .. "adrenaline bar, examples can get you started." },

    { "heading", "Help/Feedback" },
    { "text", "The best place to get help or give feedback is in the RuneScape Plugin Portal discord, search "
        .. "the plugin forum for \"RuneAuras\" to find the thread for this specific plugin." },

    { "heading", "Concepts" },

    { "subheading", "Display Types" },
    { "text", "Display types are how you want to show the data, whether that be an icon with a radial swipe, "
        .. "or a bar counting down. All display types work for all data, so pick the one that works for "
        .. "you!" },
    { "text", "Currently Supported:" },
    { "bullet", "Icon" },
    { "bullet", "Bar" },
    { "bullet", "Segmented Bar" },
    { "bullet", "Orb" },
    { "bullet", "Text" },

    { "subheading", "Data Sources" },
    { "text", "A data source is what you are displaying via your chosen display type, this could be a "
        .. "resource like adrenaline, a buff, or even the special attack cooldown of your currently "
        .. "equipped weapon." },
    { "text", "Currently Supported:" },
    { "bullet", "Player" },
    { "subbullet", "Lifepoints" },
    { "subbullet", "Adrenaline" },
    { "subbullet", "Prayer Points" },
    { "subbullet", "Summoning Points" },
    { "subbullet", "Autocast Spell" },
    { "bullet", "Target" },
    { "subbullet", "Health" },
    { "bullet", "Buff" },
    { "bullet", "Debuff" },
    { "bullet", "Target Debuff" },
    { "subbullet", "Ability" },
    { "subbullet", "Hexes" },
    { "bullet", "Ability Cooldown" },
    { "bullet", "Special Attack Cooldown" },
    { "bullet", "Channel" },
    { "bullet", "Stalled Ability" },
    { "bullet", "Extra Action Button" },

    { "subheading", "Groups" },
    { "text", "Groups are nestable groups of auras, they offer some shared customisation of auras within the "
        .. "group such as position on screen and whether or not to show them (see load conditions below)." },

    { "subheading", "Dynamic groups" },
    { "text", "Dynamic groups are groups that grow dynamically rather than each aura having a fixed location. "
        .. "An example of this would be the ingame buff bar." },

    { "subheading", "Conditions" },
    { "text", "Conditions allow you to change some display options in response to a condition such as, do I "
        .. "have enough adrenaline to cast this ability?" },
    { "text", "An example of a condition would be changing your adrenaline bar to be red when you have 4 or "
        .. "more bloodlust stacks, just like the ingame adrenaline bar." },
    { "text", "Conditions are made up of checks and changes, with checks defining the condition that must be "
        .. "met for the changes to take effect." },

    { "subheading", "Load Conditions" },
    { "text", "Load conditions offer options to enable or disable your aura/group based on data not directly "
        .. "available to an aura, such as a certain weapon being equipped. You can also configure checks "
        .. "in the same way as conditions if you need more customisation." },
}

--- Fills a scroll view with the page: its texts, then a spacer as tall as
--- them, so the view scrolls through the whole page.
---@param view table A PrettyUI SimpleView, laid out from `startY`.
---@param x number Where the page's left edge is in the view's content.
---@param startY number Where the view's first row is.
---@param width number The page's width.
function homePage.Add(view, x, startY, width)
    local y = startY
    for index, block in ipairs(PAGE) do
        local kind = block[1]
        if index > 1 then y = y + pageText.GapBefore(kind) end
        y = y + pageText.Add(view.content, kind, block[2], x, y, width)
    end
    view:AddText({ text = "", height = y - startY + BOTTOM_MARGIN })
end

return homePage
