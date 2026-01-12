# Utilities and Libraries Analysis

This document provides a comprehensive analysis of the aux-addon utility modules and libraries, with a focus on memory management, performance considerations, and Lua 5.0 compatibility.

## 1. Summary

| File | Purpose | Lines | Complexity |
|------|---------|-------|------------|
| `libs/T.lua` | Table pooling and memory management library | 157 | High |
| `util.lua` | Core utility functions (copy, map, filter, split, etc.) | 188 | Medium |
| `util/info.lua` | Item information retrieval and tooltip handling | 443 | High |
| `util/filter.lua` | Auction filter parsing and validation system | 608 | Very High |
| `util/money.lua` | Gold/silver/copper conversion and formatting | 131 | Low |
| `util/persistence.lua` | Schema-based serialization/deserialization | 75 | Medium |
| `core/cache.lua` | Item database caching from WDB files | 212 | Medium |

---

## 2. T.lua Table Library (Critical for Memory)

### 2.1 Overview

`T.lua` is the **most critical module** for memory management in the addon. It implements a **table pooling system** that reuses table allocations to reduce garbage collection pressure.

### 2.2 Core Architecture

```lua
-- Pool configuration
local pool, pool_size, overflow_pool, auto_release = {}, 0, setmetatable({}, {__mode='k'}), {}
```

**Three-tier storage system:**
1. **Primary Pool** (`pool`): Fixed-size array of 50 reusable tables
2. **Overflow Pool** (`overflow_pool`): Weak-keyed table for excess tables
3. **Auto-release Set** (`auto_release`): Tables scheduled for end-of-frame cleanup

### 2.3 Key Functions

#### `T.acquire()` - Get a table from the pool
```lua
function acquire()
    if pool_size > 0 then
        pool_size = pool_size - 1
        return pool[pool_size + 1]  -- Pop from primary pool
    end
    local t = next(overflow_pool)
    if t then
        overflow_pool[t] = nil      -- Take from overflow
        return t
    end
    return {}                        -- Create new if exhausted
end
```

#### `T.release(t)` - Return a table to the pool
```lua
function release(t)
    wipe(t)                          -- Clear the table
    auto_release[t] = nil            -- Remove from auto-release
    if pool_size < 50 then
        pool_size = pool_size + 1
        pool[pool_size] = t          -- Return to primary pool
    else
        overflow_pool[t] = true      -- Overflow to weak table
    end
end
```

#### `T.wipe(t)` - Clear table contents
```lua
function wipe(t)
    setmetatable(t, nil)
    for k in t do
        t[k] = nil
    end
    t.reset, t.reset = nil, 1        -- Lua 5.0 trick to reset internal array part
    setn(t, 0)
end
```

### 2.4 Temporary Table System

The `T.temp` marker schedules tables for automatic release at end of frame:

```lua
-- Usage: T.temp-T.acquire() or T.temp-T.list(...)
M.temp = setmetatable({}, {
    __sub = function(_, v)           -- Overloads minus operator
        if v then
            autoRelease(v)           -- Schedule for OnUpdate cleanup
            return v
        end
    end,
})
```

**OnUpdate Cleanup:**
```lua
local function AuxGCFrame_OnUpdate()
    for t in auto_release do
        release(t)
    end
    wipe(auto_release)
    this:SetScript("OnUpdate", nil)  -- Disable until needed again
end
```

### 2.5 Vararg Helper

Custom vararg handling for Lua 5.0 (no `...` syntax):

```lua
-- Dynamically generated function supporting up to 99 parameters
M.vararg = setmetatable({}, {
    __sub = function(_, v)
        return vararg(v)             -- Wraps function to receive args as table
    end,
})
```

**Usage:**
```lua
M.select = T.vararg-function(arg)
    -- arg is a table containing all arguments
end
```

### 2.6 Convenience Constructors

| Function | Purpose | Example |
|----------|---------|---------|
| `T.list(...)` | Create array from arguments | `T.list(1, 2, 3)` |
| `T.set(...)` | Create set (value -> true) | `T.set('a', 'b')` |
| `T.map(...)` | Create key-value pairs | `T.map('key1', val1, 'key2', val2)` |

---

## 3. Filter System

### 3.1 Architecture

The filter system implements a **domain-specific language (DSL)** for auction queries using prefix (Polish) notation.

```
Filter String: "weapon/rare/max-level/60/percent/50"
                  ^       ^      ^     ^     ^     ^
               class  quality  filter param filter param
```

### 3.2 Filter Categories

**Blizzard API Filters** (server-side):
- `name`, `class`, `subclass`, `slot`, `quality`
- `min_level`, `max_level`, `usable`, `exact`

**Post-Filters** (client-side validation):
- `tooltip`, `item`, `seller`, `stack`, `isgear`
- `price`, `bid-price`, `percent`, `bid-percent`
- `profit`, `bid-profit`, `vendor-profit`
- `disenchant-percent`, `disenchant-profit`
- `left` (time remaining), `rarity`, `utilizable`

### 3.3 Polish Notation Operators

```lua
function operator(str)
    local operator = str == 'not' and T.list('operator', 'not', 1)
    for name in T.temp-T.set('and', 'or') do
        local arity = aux.select(3, strfind(str, '^' .. name .. '(%d*)$'))
        if arity then
            arity = tonumber(arity)
            operator = not (arity and arity < 2) and T.list('operator', name, arity)
        end
    end
    return operator or nil
end
```

**Examples:**
- `not/epic` - Exclude epic items
- `and3/rare/weapon/max-level/60` - All three conditions must match
- `or2/sword/mace` - Either sword or mace

### 3.4 Filter Parsing Flow

```
parse_filter_string(str)
    |
    v
+-------------------+     +----------------------+
| Split by '/'      | --> | For each component:  |
+-------------------+     +----------------------+
                                    |
            +-----------------------+-----------------------+
            v                       v                       v
    +---------------+      +----------------+      +------------------+
    | Is operator?  |      | Is filter name?|      | Is Blizzard arg? |
    | (and/or/not)  |      | (price, etc.)  |      | (class, slot)    |
    +---------------+      +----------------+      +------------------+
            |                       |                       |
            v                       v                       v
    Add to post_filter     Parse parameter        Add to blizzard_filter
    and filter list        Add to both lists      Add to filter list
```

### 3.5 Validator Construction

The validator uses **reverse Polish notation evaluation** with a stack:

```lua
function validator(filter)
    local validators = T.acquire()
    -- Pre-compile filter functions
    for i, component in filter.post do
        if component[1] == 'filter' then
            validators[i] = filters[name].validator(parse_parameter(...))
        end
    end

    return function(record)
        local stack = T.temp-T.acquire()
        for i = getn(filter.post), 1, -1 do  -- Reverse iteration
            local type, name, param = unpack(filter.post[i])
            if type == 'operator' then
                -- Pop args, apply operator, push result
            elseif type == 'filter' then
                tinsert(stack, not not validators[i](record))
            end
        end
        return aux.all(stack)
    end
end
```

---

## 4. Info System

### 4.1 Item Information Retrieval

**Two-tier lookup:**
1. **Live API**: `GetItemInfo(itemstring)` - Requires item in cache
2. **Persisted Cache**: `aux.account_data.items[item_id]` - Stored in SavedVariables

```lua
function M.item(item_id, suffix_id)
    local name, itemstring, quality, ... = GetItemInfo(itemstring)
    return name and T.map(
        'name', name,
        'itemstring', itemstring,
        -- ... more fields
    ) or item_info(item_id)  -- Fallback to cache
end
```

### 4.2 Tooltip Extraction

```lua
function M.tooltip(setter, arg1, arg2)
    AuxTooltip:SetOwner(UIParent, 'ANCHOR_NONE')
    -- Set tooltip content based on setter type

    local tooltip = T.acquire()  -- NOTE: Not temporary - caller must release
    for i = 1, AuxTooltip:NumLines() do
        tinsert(tooltip, T.map(
            'left_text', _G['AuxTooltipTextLeft' .. i]:GetText(),
            'left_color', T.list(_G['AuxTooltipTextLeft' .. i]:GetTextColor()),
            -- ... right side
        ))
    end
    return tooltip, AuxTooltip.money
end
```

### 4.3 Cache Population (core/cache.lua)

```lua
function scan_wdb(item_id)
    -- Process 100 items per frame to avoid freezing
    while processed <= 100 and item_id <= MAX_ITEM_ID do
        local name, _, quality, level, ... = GetItemInfo('item:' .. item_id)
        if name and not aux.account_data.item_ids[strlower(name)] then
            aux.account_data.item_ids[strlower(name)] = item_id
            aux.account_data.items[item_id] = persistence.write(items_schema, ...)
        end
        item_id = item_id + 1
    end

    -- Continue in next frame
    if item_id <= MAX_ITEM_ID then
        aux.thread(aux.when, aux.later(.5), scan_wdb, item_id)
    end
end
```

---

## 5. Memory Concerns

### 5.1 Critical Issues

#### Issue 1: Unpooled Table Returns from `tooltip()`
**Location:** `util/info.lua:285-294`

```lua
function M.tooltip(setter, arg1, arg2)
    local tooltip = T.acquire()  -- Acquired but NOT marked as temp
    for i = 1, AuxTooltip:NumLines() do
        tinsert(tooltip, T.map(  -- Inner tables also not temp
            'left_text', ...,
            'left_color', T.list(...),  -- Not temp
            'right_color', T.list(...)   -- Not temp
        ))
    end
    return tooltip  -- Caller must manually release
end
```

**Impact:** Each tooltip extraction creates 1 + (N * 3) tables where N = number of lines. These leak if caller forgets to release.

#### Issue 2: Closure Creation in Filters
**Location:** `util/filter.lua:24-251`

Every filter validator creates a new closure:
```lua
['price'] = {
    input_type = 'money',
    validator = function(amount)
        return function(auction_record)  -- New closure per query
            return auction_record.buyout_price > 0
                   and auction_record.unit_buyout_price <= amount
        end
    end
},
```

**Impact:** Each parsed filter creates closures that persist until query is released.

#### Issue 3: Suggestions Array Rebuilding
**Location:** `util/filter.lua:424-468`

```lua
function suggestions(filter)
    local suggestions = T.acquire()
    -- 5+ loops inserting strings
    for key in filters do tinsert(suggestions, key) end
    for _, class in ipairs(T.temp-T.list(GetAuctionItemClasses())) do
        tinsert(suggestions, class)
    end
    -- ... more loops
    return suggestions  -- Large table returned
end
```

**Impact:** Autocomplete suggestions array rebuilt on every keystroke.

#### Issue 4: String Concatenation in Signatures
**Location:** `util/info.lua:127-128`

```lua
'search_signature', aux.join(T.temp-T.list(item_id, suffix_id, enchant_id,
    start_price, buyout_price, bid_price, aux_quantity, duration, ...), ':'),
```

**Impact:** Creates temporary list plus performs string concatenation for every auction record.

### 5.2 Table Creation Frequency

| Operation | Tables Created | Frequency |
|-----------|---------------|-----------|
| `container_item()` | 1 map | Per inventory slot scan |
| `auction()` | 1 map + 2 lists | Per auction record |
| `tooltip()` | 1 + N*3 tables | Per tooltip extraction |
| `parse_filter_string()` | 3+ tables | Per filter parse |
| `suggestions()` | 6+ temp tables | Per autocomplete |
| `validator()` | 1 stack per record | Per record validation |

### 5.3 Memory-Safe Patterns

**Good:** Temporary table with `T.temp-`
```lua
for _, key in ipairs(T.temp-T.list('min_level', 'max_level')) do
```

**Good:** Explicit release when done
```lua
local parts = aux.split(str, separator)
-- use parts
T.release(parts)
```

**Problematic:** Returned tables without temp marker
```lua
function M.keys(t)
    local keys = T.acquire()
    for k in t do tinsert(keys, k) end
    return keys  -- Caller must release
end
```

---

## 6. Performance Issues

### 6.1 O(N) Lookups

#### Linear Search for Item Classes
```lua
function M.item_class_index(item_class)
    for i, class in T.temp-T.list(GetAuctionItemClasses()) do
        if strupper(class) == strupper(item_class) then
            return i, class
        end
    end
end
```
**Issue:** Linear search on every filter component parse. Could be O(1) with prebuilt lookup table.

#### Linear Player Character Check
```lua
function M.is_player(name)
    return not not characters[name]  -- O(1) - this is fine
end
```
This one is actually O(1) using hash lookup.

### 6.2 Repeated String Operations

#### Case Conversion
```lua
-- In filter.lua, called for every comparison
if strupper(class) == strupper(item_class) then
```
**Issue:** `strupper()` called multiple times on same strings. No memoization.

#### Tooltip Pattern Matching
```lua
local pattern = '^' .. gsub(gsub(ITEM_SPELL_CHARGES_P1, '%%d', '(%%d+)'), ...)
```
**Issue:** Pattern compiled once (good), but `strfind()` called for every tooltip line.

### 6.3 Validator Stack Operations

```lua
for i = getn(filter.post), 1, -1 do
    if type == 'operator' then
        local args = T.temp-T.acquire()
        while (not param or param > 0) and getn(stack) > 0 do
            tinsert(args, tremove(stack))  -- Pop from end
            param = param and param - 1
        end
    end
end
```
**Issue:** `getn(stack)` called in loop condition. In Lua 5.0, `getn()` may not be O(1) for tables without explicit size tracking.

### 6.4 Suggestions Computation

```lua
function suggestions(filter)
    -- Called on every keystroke for autocomplete
    -- Builds large array with many iterations
end
```
**Issue:** No caching. Same suggestions rebuilt repeatedly.

---

## 7. Lua 5.0 Compatibility Patterns

### 7.1 No Vararg Syntax

Lua 5.0 lacks `...` in function definitions. The addon uses a code-generation approach:

```lua
local code = [[
    return function(a1,a2,a3,...,a99,overflow)
        if overflow ~= nil then error("T-vararg overflow.", 2) end
        -- Detect actual argument count
        -- Build table from arguments
    end
]]
local chunk = loadstring(code)
```

### 7.2 Table Size Manipulation

```lua
-- Lua 5.0 table.setn() to set array size
table.setn(t, 0)

-- Hack to reset internal array part
t.reset, t.reset = nil, 1
```

### 7.3 No `table.wipe()`

Lua 5.0 lacks `table.wipe()`. Custom implementation:
```lua
function wipe(t)
    setmetatable(t, nil)
    for k in t do
        t[k] = nil
    end
    setn(t, 0)
end
```

### 7.4 Global Functions

Lua 5.0 uses global functions instead of methods:
```lua
-- Lua 5.0 style
getn(t)           -- not #t
setn(t, n)        -- not t.n = n
tinsert(t, v)     -- same in 5.1
tremove(t)        -- same in 5.1
```

### 7.5 `for k in t` Iteration

Without `pairs()`:
```lua
for k in t do         -- Iterates keys (like pairs without value)
for k, v in t do      -- Key-value iteration
for _, v in ipairs(t) do  -- Array iteration
```

### 7.6 `getfenv/setfenv`

Used for sandboxing dynamically generated code:
```lua
local chunkEnv = {setn=setn, acquire=acquire, ...}
setfenv(chunk, chunkEnv)
```

---

## 8. Recommendations Summary

### High Priority
1. **Mark tooltip returns as temp** or document that callers must release
2. **Cache item class/subclass lookups** instead of linear search
3. **Memoize suggestions** based on filter state

### Medium Priority
4. Pre-compile regex patterns once at module load
5. Avoid repeated `strupper()` calls on same strings
6. Consider pooling closure objects for filters

### Low Priority
7. Replace `getn()` in loops with cached length variable
8. Batch tooltip table creation where possible
