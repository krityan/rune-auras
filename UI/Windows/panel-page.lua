-- What the panels shown in the editor's place (New, Delete, Selection,
-- Export) are written with, so they look alike: a title and page text
-- under it, then choices, each a button with what it does beside it.

local pageText = require("UI/Controls/page-text")
local uiConstants = require("UI/ui-constants")

local panelPage = {}

--- A panel's title and the page text under it.
---@class PanelHeading
---@field title string
---@field intro PanelBlock[]? Under the title, in order.

--- A block of page text (see pageText).
---@class PanelBlock
---@field kind PageBlockKind
---@field text string

local PADDING = uiConstants.PADDING
local GAP = uiConstants.GAP
-- A choice's button width, its row's height, and the most lines its
-- description wraps to.
panelPage.BUTTON_WIDTH = 180
local ROW_HEIGHT = 40
local DESCRIPTION_LINES = 2
-- Extra room between a panel's page text and its first button.
panelPage.BUTTONS_GAP = 10

--- Writes a panel's title and the page text under it, placed by hand from
--- the top of the view's content, then a spacer that holds their room in
--- the view's layout, so the controls added next follow them.
---@param view table A PrettyUI SimpleView whose layout starts at `top`.
---@param heading PanelHeading
---@param top number Where the layout starts, in the view's content.
---@param width number How wide the text can be.
function panelPage.AddHeading(view, heading, top, width)
    local content = view.content
    local y = top + pageText.Add(content, "title", heading.title, PADDING, top, width)
    for _, block in ipairs(heading.intro or {}) do
        y = y + pageText.GapBefore(block.kind)
        y = y + pageText.Add(content, block.kind, block.text, PADDING, y, width)
    end

    view:AddText({ text = "", height = y - top + panelPage.BUTTONS_GAP })
end

--- Adds a choice: a button, with what it does beside it in muted text,
--- filling the rest of the row.
---@param view table
---@param label string
---@param description string
---@param onClick fun()
---@param buttonWidth number? nil for BUTTON_WIDTH.
function panelPage.AddChoice(view, label, description, onClick, buttonWidth)
    local width = buttonWidth or panelPage.BUTTON_WIDTH
    view:AddSimpleButton(label, onClick, { width = width, height = ROW_HEIGHT })

    view:AddText({
        text = description,
        inline = true,
        width = -(PADDING + width + GAP + PADDING),
        widthAnchor = 1,
        height = ROW_HEIGHT,
        maxLines = DESCRIPTION_LINES,
        colour = uiConstants.MUTED_RGBA,
    })
end

return panelPage
