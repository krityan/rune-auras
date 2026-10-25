-- Text the game draws: "<" starts a markup tag (<col=ff0000>), so text the
-- player typed is made plain before it's shown.

local gameText = {}

--- Text with its angle brackets removed, so it can't add markup.
---@param text any Turned into a string; nil gives "".
---@return string
function gameText.Plain(text)
    return (tostring(text or ""):gsub("[<>]", ""))
end

return gameText
