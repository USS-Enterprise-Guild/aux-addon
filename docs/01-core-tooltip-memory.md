# Core Tooltip Memory Analysis

## Overview

This document analyzes the memory-critical files in the aux-addon, specifically focusing on tooltip rendering and disenchant value calculations. The user reports high memory usage especially when tooltips are open and disenchant/value values are displayed.

**Files Analyzed:**
- `/core/tooltip.lua` - GameTooltip hooking and extension
- `/core/disenchant.lua` - Disenchant probability and value calculations
- `/core/history.lua` - Price history tracking and value calculations
- `/util/info.lua` - Item info retrieval and tooltip parsing (note: `cache.lua` appears to be misnamed/duplicated)
- `/libs/T.lua` - Table pooling library (critical for understanding memory patterns)

---

## 1. Summary - What Each File Does

### tooltip.lua
Hooks into WoW's GameTooltip system to add auction house pricing information to item tooltips. It intercepts various tooltip setter functions (SetBagItem, SetAuctionItem, SetMerchantItem, etc.) and calls `extend_tooltip()` to add:
- Disenchant distribution (probability of each enchanting material)
- Disenchant value (expected gold value)
- Vendor buy/sell prices
- Historical market value
- Daily market value

### disenchant.lua
Provides disenchant probability distributions and expected values for items based on:
- Equipment slot (armor vs weapon)
- Item quality (Uncommon/Rare/Epic)
- Item level

Returns tables of possible disenchant outcomes with probabilities, min/max quantities, and material item IDs.

### history.lua
Manages price history data persistence and retrieval:
- Stores daily minimum buyout prices per item
- Maintains up to 11 historical data points per item
- Calculates weighted median values for historical pricing
- Supports data sharing via the "LFT" chat channel

### info.lua (util)
Core item information utilities:
- Tooltip parsing and creation
- Item link parsing
- Container/auction item data extraction
- WoW database cache scanning

### T.lua (libs)
**Critical memory management library** that implements:
- Table pooling (reuse tables instead of creating new ones)
- Automatic garbage collection via frame OnUpdate
- `T.temp` - marks tables for automatic release
- `T.acquire`/`T.release` - manual pool management
- `T.map`, `T.list`, `T.set` - table creation helpers

---

## 2. Data Structures

### tooltip.lua
```lua
game_tooltip_hooks = {}      -- Table of hook functions keyed by tooltip method name
game_tooltip_money = 0       -- Tracks money display in tooltips
settings = {}                -- User tooltip display settings (from aux.character_data.tooltip)
```

### disenchant.lua
```lua
ARMOR = T.set(...)           -- Set of armor slot types (permanent, created once)
WEAPON = T.set(...)          -- Set of weapon slot types (permanent, created once)

-- Distribution return format (created per-call):
{
    { item_id=10940, min_quantity=1, max_quantity=2, probability=0.8 },
    { item_id=10938, min_quantity=1, max_quantity=2, probability=0.2 },
    ...
}
```

### history.lua
```lua
data = {}                    -- Reference to aux.faction_data.history (persisted)
value_cache = {}             -- Runtime cache: item_key -> {value=number, next_push=timestamp}

-- History record schema:
{
    next_push = timestamp,
    daily_min_buyout = number,
    data_points = [
        { value=number, time=timestamp },
        ...  -- up to 11 entries
    ]
}
```

### info.lua
```lua
-- Tooltip line format:
{
    left_text = string,
    left_color = {r, g, b},
    right_text = string or nil,
    right_color = {r, g, b}
}

-- Item info format (from GetItemInfo or cached):
{
    name, itemstring, quality, level, class, subclass, slot, max_stack, texture
}

-- Container/Auction item format (~25 fields):
{
    item_id, suffix_id, unique_id, enchant_id, link, itemstring, item_key,
    name, texture, level, type, subtype, slot, quality, max_stack,
    count, locked, readable, lootable, tooltip, tooltip_money,
    max_charges, charges, aux_quantity, ...
}
```

---

## 3. Memory Concerns

### HIGH PRIORITY: Tooltip Table Creation Storm

#### Problem: `extend_tooltip()` creates many temporary tables per hover

**File: `/core/tooltip.lua` lines 52-107**

Every time a tooltip is displayed, `extend_tooltip()` is called, which triggers:

1. **Line 55**: `T.temp-info.item(item_id)` - Creates a new item info table (9 fields)
2. **Line 57**: `disenchant.distribution(...)` - Creates 2-3 event tables nested inside a list table
3. **Line 67**: `disenchant.value(...)` - Iterates distribution again, calling `history.value()` multiple times
4. **Line 91**: `T.temp-info.tooltip(...)` - Creates tooltip table with nested tables per line
5. **Line 92**: String concatenation for item_key

```lua
-- This runs EVERY tooltip hover:
local item_info = T.temp-info.item(item_id)  -- Creates table
local distribution = disenchant.distribution(...)  -- Creates 3-4 tables
...
local item_key = (item_id or 0) .. ':' .. (suffix_id or 0)  -- String creation
local value = history.value(item_key)  -- May create tables
local market_value = history.market_value(item_key)  -- Parses/creates tables
```

#### Problem: Disenchant distribution creates MANY nested temp tables

**File: `/core/disenchant.lua` lines 72-172**

```lua
return T.temp-T.list(
    T.temp-T.map('item_id', 10940, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.8, .2)),
    T.temp-T.map('item_id', 10938, 'min_quantity', 1, 'max_quantity', 2, 'probability', p(.2, .8))
)
```

Each call to `distribution()` creates:
- 1 outer list table
- 2-3 inner map tables (each with 4 key-value pairs)
- All marked with `T.temp` for deferred release

**But wait - the `value()` function iterates over these AND creates more tables:**

**File: `/core/disenchant.lua` lines 36-49**
```lua
function M.value(slot, quality, level, item_id)
    local expectation
    for _, event in distribution(slot, quality, level, item_id) do  -- Creates distribution tables
        local value = history.value(event.item_id .. ':' .. 0)      -- String concat + history lookup
        ...
        local market_value = history.market_value(event.item_id .. ':' .. 0)  -- Another string + lookup
    end
    return expectation
end
```

So a SINGLE tooltip with disenchant info creates:
- 1 item_info table
- 1 distribution list + 2-3 event tables (from distribution call)
- 2-3 string concatenations for item keys
- 2-3 history.value() calls (each may parse persistence)
- 2-3 history.market_value() calls

#### Problem: history.value() creates cached tables that may leak

**File: `/core/history.lua` lines 121-142**

```lua
function M.value(item_key)
    if not value_cache[item_key] or value_cache[item_key].next_push <= time() then
        local item_record, value
        item_record = read_record(item_key)  -- May parse and create tables
        if getn(item_record.data_points) > 0 then
            local total_weight, weighted_values = 0, T.temp-T.acquire()  -- TEMP table
            for _, data_point in item_record.data_points do
                ...
                tinsert(weighted_values, T.map('value', data_point.value, 'weight', weight))  -- NOT temp!
            end
            ...
        end
        value_cache[item_key] = T.map('value', value, 'next_push', item_record.next_push)  -- Persists in cache
    end
    return value_cache[item_key].value
end
```

**Bug Found**: Line 130 uses `T.map()` instead of `T.temp-T.map()`. These tables are inserted into `weighted_values` which IS marked temp, so they should be released together. However, if release fails or is delayed, these accumulate.

### MEDIUM PRIORITY: info.tooltip() table creation

**File: `/util/info.lua` lines 273-294**

```lua
function M.tooltip(setter, arg1, arg2)
    ...
    local tooltip = T.acquire()  -- NOT temp - caller must release!
    for i = 1, AuxTooltip:NumLines() do
        tinsert(tooltip, T.map(         -- These inner maps are NOT temp either
            'left_text', ...,
            'left_color', T.list(...),  -- Color lists are also NOT temp
            'right_text', ...,
            'right_color', T.list(...)  -- More non-temp color lists
        ))
    end
    return tooltip, AuxTooltip.money
end
```

Each tooltip line creates:
- 1 map table (4 fields)
- 2 color list tables (3 elements each)

A typical item tooltip has 8-15 lines = **24-45 tables per tooltip parse**.

These are NOT marked as temp, meaning the caller must manually release them. Looking at callers:

In `tooltip.lua` line 91:
```lua
local auctionable = not item_info or info.auctionable(T.temp-info.tooltip('link', item_info.itemstring), item_info.quality)
```

The outer table is marked temp, but **the nested color tables are not properly released** because they're inside a table hierarchy and `T.wipe` only clears the direct table contents, not nested tables.

### MEDIUM PRIORITY: String Concatenation in Hot Paths

**File: `/core/tooltip.lua`**
- Line 45: `color_code .. '|H' .. arg[1] .. '|h[' .. name .. ']|h' .. FONT_COLOR_CODE_CLOSE`
- Line 63: `format('  %s%% %s (%s-%s)', ...)`
- Line 92: `(item_id or 0) .. ':' .. (suffix_id or 0)`

**File: `/core/disenchant.lua`**
- Line 39: `event.item_id .. ':' .. 0`
- Line 43: `event.item_id .. ':' .. 0`

**File: `/core/history.lua`**
- Line 99: `"AuxData," .. item_key .."," .. unit_buyout_price`

Each string concatenation in Lua 5.0 creates intermediate string objects that must be garbage collected.

### LOW PRIORITY: T.lua Pool Size Limits

**File: `/libs/T.lua` lines 45-54**

```lua
function release(t)
    wipe(t)
    auto_release[t] = nil
    if pool_size < 50 then          -- Only 50 tables in fast pool
        pool_size = pool_size + 1
        pool[pool_size] = t
    else
        overflow_pool[t] = true     -- Weak table, may be GC'd
    end
end
```

The pool only holds 50 tables. In a tooltip storm (mousing over multiple items quickly), tables may:
1. Overflow to `overflow_pool` (weak table)
2. Get garbage collected
3. Require new allocation on next acquire

---

## 4. Performance Issues

### Issue 1: Redundant disenchant.distribution() calls

In `tooltip.lua` lines 57-69:
```lua
local distribution = disenchant.distribution(item_info.slot, item_info.quality, item_info.level, item_id)
if getn(distribution) > 0 then
    if settings.disenchant_distribution then
        -- Uses distribution
    end
    if settings.disenchant_value then
        local disenchant_value = disenchant.value(item_info.slot, item_info.quality, item_info.level, item_id)
        -- disenchant.value() calls distribution() AGAIN internally!
    end
end
```

`disenchant.distribution()` is called twice when both settings are enabled.

### Issue 2: Sorting on every tooltip display

**File: `/core/tooltip.lua` line 61**
```lua
sort(distribution, function(a,b) return a.probability > b.probability end)
```

Sorts the distribution table on every hover, even though the data is static.

### Issue 3: history.value() weighted median recalculation

**File: `/core/history.lua` lines 121-142**

The weighted median is recalculated from scratch when cache expires, including:
- Exponential weight calculations
- Creating weighted value tables
- Sorting for median

This happens for each enchanting material when calculating disenchant value.

### Issue 4: Tooltip parsing inefficiency

**File: `/util/info.lua` lines 273-294**

The `tooltip()` function creates a full table representation of the tooltip even when only checking for specific text (like bind status). The `auctionable()` check only needs to know about line 2, but parses all 15+ lines.

### Issue 5: T.vararg overhead

**File: `/libs/T.lua` lines 89-138**

The vararg implementation uses dynamically generated code with 100 parameter slots. Each vararg function call:
1. Creates a table via acquire
2. Marks it for auto-release
3. Calls the wrapped function

This adds overhead to every `T.list()`, `T.map()`, and `T.set()` call.

---

## 5. Lua 5.0 Notes

### No `...` in Function Bodies
Lua 5.0 does not support `...` syntax inside function bodies. The codebase uses the `T.vararg` wrapper to handle this:
```lua
aux.hook(name, GameTooltip, T.vararg-function(arg)
    -- arg is a table, not varargs
end)
```

### table.setn Required
Lua 5.0 requires explicit `table.setn()` to set array length. The T library handles this:
```lua
setn(t, n)  -- Sets the array length explicitly
```

### No Weak Mode Shorthand
The `overflow_pool` uses the full metatable syntax:
```lua
setmetatable({}, {__mode='k'})  -- Weak keys only
```

### Global setfenv/getfenv
The vararg code generation uses `setfenv()` which is Lua 5.0/5.1 specific:
```lua
setfenv(chunk, chunkEnv)
```

### No # Length Operator
All length calculations use `getn()`:
```lua
getn(distribution)  -- Instead of #distribution
```

### String Operations
Uses Lua 5.0 string functions:
- `strfind()` instead of `string.find()`
- `format()` instead of `string.format()`
- `gsub()` instead of `string.gsub()`

### for-in Iterator Differences
The `for k in t do` syntax (without `pairs`) works differently in 5.0 and may be intentional for performance.

---

## Recommendations Summary

1. **Cache disenchant distributions** - The distribution for a given (slot, quality, level) is static and should be computed once per session, not per hover.

2. **Pass distribution to value()** - Avoid calling `distribution()` twice by passing the already-computed distribution to `value()`.

3. **Pre-sort distributions** - Sort probability data once at addon load, not per hover.

4. **Fix nested table release** - The color tables in `info.tooltip()` need proper release handling, possibly by making them temp or using a different structure.

5. **Increase pool size** - Consider increasing the T.lua pool size from 50 to 200+ for tooltip-heavy usage.

6. **Add tooltip caching** - Cache the extended tooltip data per item_key for a short duration (e.g., 1 second) to avoid recalculation on re-hover.

7. **Lazy tooltip parsing** - Only parse needed tooltip lines for `auctionable()` check instead of full table creation.

8. **Pre-compute item keys** - Store item keys in item records instead of concatenating on every access.
