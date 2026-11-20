-- The key that opens and closes the main window: Ctrl + Shift + A unless the player
-- picks another (with Ctrl, Shift or Alt if held) or none, from the ribbon
-- panel. Saved in PersistentDB as "<game key>,<modifiers>", or "" for none.

local windowKeybind = {}

local EVENT_ID = "runeAuras_windowKeybind"
local STORAGE_KEY = "windowKeybind"
local NO_KEY = ""
local DEFAULT_KEY, DEFAULT_MODIFIERS = GameKey.A, ModifierKey.CONTROL | ModifierKey.SHIFT
-- The modifiers kept with a key: Ctrl, Shift and Alt, not Meta (the Windows or Command key).
local MODIFIER_BITS = ModifierKey.ANY

-- Keys that only modify another: pressed while choosing, they wait for it.
local MODIFIER_KEYS = { [GameKey.SHIFT] = true, [GameKey.CONTROL] = true, [GameKey.ALT] = true }
-- Cancels choosing a key, so it can't be the keybind.
local CANCEL_KEY = GameKey.ESCAPE
-- Removes the keybind, so it can't be the keybind either.
local CLEAR_KEY = GameKey.BACKSPACE

-- Each modifier's name, in the order they're written before the key.
local MODIFIER_NAMES = {
    { bit = ModifierKey.CONTROL, name = "Ctrl" },
    { bit = ModifierKey.SHIFT, name = "Shift" },
    { bit = ModifierKey.ALT, name = "Alt" },
}
-- Keys whose name is a symbol, or a word other than their GameKey name's.
local KEY_NAMES = {
    MINUS = "-", EQUALS = "=", LEFT_BRACKET = "[", RIGHT_BRACKET = "]", SEMICOLON = ";",
    APOSTROPHE = "'", HASH = "#", COMMA = ",", FULLSTOP = ".", SLASH = "/", BACKSLASH = "\\",
    NUMPAD_ADD = "Numpad +", NUMPAD_SUBTRACT = "Numpad -", NUMPAD_MULTIPLY = "Numpad *",
    NUMPAD_DIVIDE = "Numpad /", ESCAPE = "Esc", PAGE_UP = "Page Up",
    PAGE_DOWN = "Page Down",
}

-- Every GameKey's name. The client's GameKey can't be walked with pairs (it
-- gives nothing), so each is looked up by name.
local GAME_KEY_NAMES = {
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "ESCAPE",
    "_1", "_2", "_3", "_4", "_5", "_6", "_7", "_8", "_9", "_0", "MINUS", "EQUALS", "CONSOLE",
    "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "LEFT_BRACKET", "RIGHT_BRACKET",
    "A", "S", "D", "F", "G", "H", "J", "K", "L", "SEMICOLON", "APOSTROPHE", "HASH",
    "Z", "X", "C", "V", "B", "N", "M", "COMMA", "FULLSTOP", "SLASH", "BACKSLASH",
    "TAB", "SHIFT", "CONTROL", "SPACE", "ENTER", "BACKSPACE", "ALT",
    "NUMPAD_ADD", "NUMPAD_SUBTRACT", "NUMPAD_MULTIPLY", "NUMPAD_DIVIDE", "CLEAR",
    "LEFT", "RIGHT", "UP", "DOWN", "INSERT", "DELETE", "HOME", "END", "PAGE_UP", "PAGE_DOWN",
}

---@type table<integer, string> Each game key's GameKey name, e.g. HOME.
local gameKeyNames = {}
for _, name in ipairs(GAME_KEY_NAMES) do
    local ok, key = pcall(function() return GameKey[name] end)
    if ok and type(key) == "number" then
        gameKeyNames[key] = name
    end
end

---@class WindowKeybind
---@field key integer? A GameKey; nil for none.
---@field modifiers integer ModifierKey bits held with it.

---@type WindowKeybind? Read from PersistentDB on first use.
local binding = nil
---@type fun()? Opens or closes the window.
local onPressed = nil
---@type fun()? While choosing a key: called once it's chosen or choosing is cancelled.
local onChosen = nil

--- The keybind, read from PersistentDB the first time.
---@return WindowKeybind
local function current()
    if binding ~= nil then
        return binding
    end

    local saved = PersistentDB:GetString(STORAGE_KEY)
    binding = { key = DEFAULT_KEY, modifiers = DEFAULT_MODIFIERS }

    if saved == NO_KEY then
        binding = { key = nil, modifiers = 0 }
    elseif type(saved) == "string" then
        local key, modifiers = saved:match("^(%d+),(%d+)$")
        key, modifiers = tonumber(key), tonumber(modifiers)

        -- Any key the game reported, named or not (see Name).
        if key ~= nil and key > 0 then
            binding = { key = key, modifiers = modifiers & MODIFIER_BITS }
        end
    end

    return binding
end

--- Sets and saves the keybind.
---@param key integer? A GameKey; nil for none.
---@param modifiers integer
local function save(key, modifiers)
    binding = { key = key, modifiers = key ~= nil and modifiers or 0 }
    local text = key ~= nil and formatStr("{},{}", key, binding.modifiers) or NO_KEY
    PersistentDB:SetString(STORAGE_KEY, text)
end

--- Ends choosing a key, telling whoever started it.
local function finishChoosing()
    local done = onChosen
    onChosen = nil

    if done ~= nil then
        done()
    end
end

--- The key pressed, the modifiers held with it, and whether it's a repeat
--- from holding it, for pcall.
---@param event KeyDownEventPayload
---@return integer key A GameKey.
---@return integer modifiers ModifierKey bits; only those kept (MODIFIER_BITS).
---@return boolean isRepeat
local function readKeyDown(event)
    return event.gameKey, (event.modifiers or 0) & MODIFIER_BITS, event.isRepeat == true
end

--- Chooses the key pressed while choosing, or opens or closes the window
--- when the keybind is pressed. Repeats from holding a key, and events that
--- can't be read, are ignored.
---@param event KeyDownEventPayload
local function onKeyDown(event)
    local ok, key, modifiers, isRepeat = pcall(readKeyDown, event)
    if not ok or isRepeat or type(key) ~= "number" then
        return
    end

    if onChosen ~= nil then
        if MODIFIER_KEYS[key] then
            return
        end

        if key == CLEAR_KEY then
            save(nil, 0)
        elseif key ~= CANCEL_KEY then
            save(key, modifiers)
        end

        finishChoosing()
        return
    end

    local bound = current()
    if key == bound.key and modifiers == bound.modifiers and onPressed ~= nil then
        onPressed()
    end
end

--- Starts listening for the keybind.
---@param toggleWindow fun() Opens or closes the main window.
function windowKeybind.Start(toggleWindow)
    onPressed = toggleWindow
    Event.KeyDown.Subscribe(EVENT_ID, onKeyDown)
end

--- Stops listening, and stops choosing a key.
function windowKeybind.Stop()
    Event.KeyDown.Unsubscribe(EVENT_ID)
    onPressed, onChosen = nil, nil
end

--- The keybind as the player reads it, e.g. "Ctrl + Home", or "None".
---@return string
function windowKeybind.Name()
    local bound = current()
    if bound.key == nil then
        return "None"
    end

    local parts = {}
    for _, modifier in ipairs(MODIFIER_NAMES) do
        if (bound.modifiers & modifier.bit) ~= 0 then
            parts[#parts + 1] = modifier.name
        end
    end

    -- HOME reads Home and _1 reads 1; symbols and the rest from KEY_NAMES.
    local name = gameKeyNames[bound.key]
    local keyName = formatStr("Key {}", bound.key)
    if name ~= nil then
        keyName = KEY_NAMES[name] or name:gsub("^_", ""):gsub("_", " ")

        if KEY_NAMES[name] == nil and #keyName > 1 then
            keyName = keyName:sub(1, 1) .. keyName:sub(2):lower()
        end
    end

    parts[#parts + 1] = keyName
    return table.concat(parts, " + ")
end

--- Whether there's a keybind (not cleared).
---@return boolean
function windowKeybind.IsSet()
    return current().key ~= nil
end

--- Whether the next key pressed will become the keybind.
---@return boolean
function windowKeybind.IsChoosing()
    return onChosen ~= nil
end

--- Makes the next key pressed (with any of Ctrl, Shift and Alt held) the
--- keybind; Esc cancels, and Backspace removes it.
---@param done fun() Called once a key is chosen or choosing is cancelled.
function windowKeybind.Choose(done)
    onChosen = done
end

--- Stops choosing a key without changing it.
function windowKeybind.CancelChoosing()
    finishChoosing()
end

return windowKeybind
