# Rune Auras code standards

The goal: **a function is understandable from its comment alone**, without reading its body or its callers. These standards apply alongside the conventions in `AGENTS.md`. The whole codebase follows them; keep it that way in new and changed code.

Doc comments use **LuaCATS annotations** (`---@param`, `---@return`, `---@class`), the format the Lua Language Server (LuaLS) reads. They're plain comments at runtime, so they cost nothing, and with this repo's `.luarc.json` they give hover docs, completion and type warnings in the editor.

## 1. Comments are concise

- **Lead with the point.** Use the fewest words that carry it. One sentence is normal and three is long.
- **Say what the code can't.** Explain the why, the units, the edge cases and what the caller must do. Don't narrate what the next line plainly does.
- **Use an example only when a rule is hard to state in words.** An offset measured inwards is one: `-- "topright" with x = 10 sits 10 px in from the right edge.`
- **Keep history out**, unless the code exists because of it. A migration function says what it converts from, but the code it replaced isn't described anywhere else.
- **Put game facts and pitfalls once**, where they're enforced. Write the full explanation at the code that handles the quirk. Give other places one line that points back to it (`-- See ensurePart: parts made late stack on top.`).
- **Inline comments explain one decision**, on the line before the code they're about, not trailing it.
- Use `TODO:` for missing work and `FIXME:` for known bugs. `DEBUG` code gets no comment, because it's removed.

## 2. Functions document themselves

Every function gets a doc block directly above it, with no blank line between them:

```lua
--- One-line summary: what it does, in the caller's terms.
--- Optional second paragraph: conditions, side effects, what it refuses.
---@param name type What it is (units, nil meaning, valid range).
---@return type name What comes back, and when it's nil or false.
function module.Name(name) ... end
```

- **Summary first.** Start with the effect ("Moves an aura into a group"), not the method ("Removes it from the list, then inserts...").
- **Every parameter and every return gets a line**, with its type. A description can be left off only when the name and type already say everything (`---@param auraID integer`).
- **Optional and nil:**
  - Write `integer?` for a value that may be nil, and say what nil means ("nil: the top level").
  - Write `name?` for a trailing argument that may be left out.
  - Repeat `---@return` once per value for multiple returns.
- **Side effects go in the summary or second paragraph:** saving, firing callbacks, creating components, mutating an argument.
- **Callbacks are typed:** `---@param onMoved fun(x: number, y: number)`.
- **Applies to local functions too.** A tiny local helper whose name and parameters say it all may have only the summary line and types.
- **Keep one source of truth.** A function's behaviour lives on the function, not in the file header. The header doesn't re-describe it.

### Types are defined once

- **Name each recurring table shape.** A record (an aura, a condition, a data source) or an option table passed between files gets a `---@class` with `---@field` lines.
- **Define it in the file that owns it:** the file that creates, validates or saves it. Put the definition near the top.
- **Elsewhere, refer to it by name:** `---@param aura Aura`. Don't re-list its fields. To point at a detail, name the field: `-- see Aura.group`.
- **Use `---@alias` for fixed sets of string ids,** with one `---|` line per value and its meaning:
  ```lua
  ---@alias AnchorID
  ---| "topleft"  # x/y measured right and down from the top-left corner
  ---| "centre"   # x/y measured right and down from the centre
  ```
- **Name types in PascalCase,** after the thing (`Aura`, `TextNode`, `LoadOptions`), unique across the workspace.
- **Mark optional fields:** `---@field group integer? Parent group's id; nil at the top level.`
- **A display type's extra options** (defaults added by a module) are a `---@class BarOptions: Aura` in that display's file.

### File headers

Write one to three lines, saying what area the file owns and, if it's easily confused, what it doesn't. Name its main types. Usage examples and `require` lines aren't needed, because the require path is the file path.

```lua
-- Saving and loading the auras in PersistentDB: one key per aura plus an
-- index. Holding them in memory is stored-auras' job.
```

## 3. Names are descriptive, not long

- **No single-letter names**, whatever the scope. Write `local params = lookupParams()`, not `local p = ...`, and `for _, aura in ipairs(auras)`, not `for _, a in ...`. The only exceptions:
  - `i`/`j` as a plain numeric loop counter;
  - `_` for an unused value;
  - `x`/`y` as coordinates, where they're the domain word.

  For byte or character values, name what they are (`first, second, third`, not `a, b, c`).
- **Length follows scope.** A short loop's variable can be one plain word (`aura`, `node`). A module-level or public name says exactly what it holds.
- **Aim for one to three words.** If a fourth word seems needed, the thing it names probably wants splitting, or the scope is too wide.
- **Put units in the name when they're ambiguous:** `endTick`, `secondsLeft`, `durationTicks`, `widthPx` (not `endTime`, `duration`).
- **Booleans read as states or questions:** `enabled`, `unlocked`, `isGroup`, `hasCharges`. Avoid negatives (`notHidden`).
- **Functions that act are verbs** (`Move`, `Save`). A function that only returns a thing may be named after that thing (`ScreenPoint`). Predicates are `Is…`/`Has…`/`Can…`.
- **Use the same word for the same thing everywhere.** If it's `aura` in one file, it's not `record` or `item` in another. Pick the domain word and keep it.
- **Abbreviate only where it's universal** (`id`, `x`, `y`, `min`, `max`, `rgba`). Write `areaWidth`, not `aw`.
- **Casing:** `camelCase` locals, `PascalCase` public module functions, `UPPER_SNAKE` constants, and a module table named after its file.

## 4. Code explains itself

Doc comments say what a function promises. The code inside should read without comments: a comment there explains a decision, never what the code does.

- **If a block needs a comment to say what it does, make it a function** named after what it does. `-- After the group's last item` above a search loop becomes `local to = afterLastInGroup(groupID)`.
- **Name a value before testing it.** A compound condition reads better as a named local than as a comment:
  ```lua
  local isEmpty = (curr or 0) <= 0
  local hideNow = aura.hideWhenEmpty and isEmpty and not aura.unlocked
  if hideNow then ... end
  ```
- **No magic numbers.** A number that means something is a named constant with its unit (`LOGIC_TICKS_PER_SECOND`, `MAX_WRITES_PER_SAVE`, `DUPLICATE_OFFSET`). Plain arithmetic `0`, `1` and `2` (halving, `+ 1` for the next index) can stay.
- **Return early.** Check for bad input and nothing-to-do at the top and return, so the main path isn't nested inside `if`s:
  ```lua
  local aura = auraStore.Get(auraID)
  if aura == nil then return false end
  ```
- **One meaning per variable.** Don't reuse a local for a different thing partway through a function; make a new one with its own name. Rebinding the same thing is fine (`aura = group` walking up through groups).
- **Arguments are clear at the call site.** A bare `true` or `nil` whose meaning only the definition knows is a smell: `CreateGroup(groupID, true)` became `CreateDynamicGroup(groupID)`. Prefer a separate function, a named constant (`convertConditions(list, DECODE)`) or an options table (`{ dynamic = true }`). Where a positional flag stays, name it in a local first (`local dynamic = true`).
- **Structures have named fields.** Use `{ x = 10, y = 20 }`, not `{ 10, 20 }`. Positional tables are for real lists.
- **Keep `a and b or c` for simple choices.** It returns `c` when `b` is false or nil, which has hidden bugs here before (a colour that didn't decode fell through to the encoder). When `b` can be false or nil, write the `if`.
- **One way to say a thing.** Don't mix `x == nil` and `not x` for the same test in one function. Use `not x` only when false and nil mean the same.
- **Lua specifics:**
  - Everything is `local`; there are no new globals.
  - Use `ipairs` for lists and `pairs` for maps.
  - A module returns one table named after its file.
  - Functions are declared `local function name()`, not `local name = function()`.

## 5. Code does only what it needs to

The aim is the least code that's correct. Every line is something to read, check in game and keep working.

- **Do exactly what the task needs.** Don't add options, parameters, hooks or generality for cases that don't exist yet. Add them when a second use turns up.
- **Pick the simplest approach that's correct:** a plain loop over a clever abstraction, a direct call over indirection. Splitting a long function into named steps is still good (see section 4), even when each step has one caller.
- **Guard real failure points only.** Game reads go through `game-api`, and pasted imports are checked, because those can fail. Don't check our own invariants: a nil check for something that's never nil adds noise and hides the bug that broke it.
- **Reuse before adding.** Use an existing helper (`game-api`, `maths`, the store's operations) rather than writing a near copy.
- **Remove what a change leaves unused**, in the same change: dead code, unused parameters and fields, fallbacks nothing reaches any more.
- **Simpler, not shorter.** Don't squeeze code into one-liners or `and`/`or` chains to save lines; readable and correct beats a low line count. Extra code is worth it for a real cost (per-frame paths, the component limit), with a comment saying which.

## 6. One area per file

- **A file owns one area** and is named after it (`persistence.lua` owns saving and loading the auras). Its area should be guessable from the name, and the Layout table in `AGENTS.md` should map each area to its file.
- **The owner holds the area's type definitions, rules and state.** Other files go through its functions. They don't edit its tables or repeat its rules. If two files enforce the same rule, one of them is wrong about whose job it is.
- **Put a new concern in a new file** when it has its own state or rules, even if it's small. Add it to the layout table.
- **Signs a file owns two areas:**
  - its header needs "and";
  - its functions form two groups that don't call each other;
  - two kinds of state;
  - finding something means scrolling past an unrelated half.

  Size alone isn't the test, but a long file usually shows one of these.
- **Keep pure logic in pure helper files**, separate from game reads and from UI. That keeps it testable and keeps UI out of data files.

## Example

Before: one long prose comment, with types and nil meanings left to the reader.

```lua
-- Moves an aura or group into a group (nil: the top level), before one of
-- that group's contents (`beforeID`) or after them all (nil). Order is the
-- order of the store's list, which Children follows. Changing group keeps
-- it where it is on screen. Refuses a group that doesn't exist, moving a
-- group into itself or its own contents, and a `beforeID` that isn't in
-- the group. areaWidth/areaHeight, the game area's size if known, are
-- needed to keep it in place. Returns whether anything changed.
function auraStore.Move(auraID, groupID, beforeID, areaWidth, areaHeight)
```

After:

```lua
--- Moves an aura or group to a new place in the list, keeping it where it is on screen.
--- Refuses a missing group, a group that can't hold it, a cycle, or a `beforeID` outside the group. Saves on change.
---@param auraID integer
---@param groupID integer? Destination group; nil for the top level.
---@param beforeID integer? Item in that group to go before; nil for after them all.
---@param areaWidth number? Game area width. Without the size, it's regrouped but not kept in place.
---@param areaHeight number?
---@return boolean moved
function auraStore.Move(auraID, groupID, beforeID, areaWidth, areaHeight)
```

The shared type, defined once in `Auras/Store/aura-record.lua`:

```lua
---@class Aura
---@field id integer
---@field name string Shown in the aura list.
---@field display DisplayID
---@field source string? Data source id; nil until chosen.
---@field anchor AnchorID Screen point x/y measure from; in a group, the aura's own attach point.
---@field x number Offset from the anchor, inwards (see AnchorID).
---@field y number
---@field group integer? Parent group's id; nil at the top level.
---@field conditions Condition[]?
```

## Reviewing against these standards

- Every new or changed function has a summary, a typed `@param` for each parameter and a `@return` for each value.
- No table shape is described twice: each refers to its `@class`.
- Comments are short and say why, with no narration and no history.
- Names have units where needed, don't get abbreviated beyond the usual ones, and use one word per concept. There are no single-letter names outside loop counters and coordinates.
- Code inside functions reads without comments:
  - blocks that need a "what" comment become named functions;
  - compound conditions become named locals;
  - meaningful numbers become constants;
  - early returns replace deep nesting;
  - call sites have no unexplained `true`, `false` or `nil`.
- The change does only what was needed: no unused options or code paths, no checks for cases that can't happen, no near copies of an existing helper, and nothing it made unused left behind.
- New code sits in the file that owns its area, and nothing reaches into another file's state.
