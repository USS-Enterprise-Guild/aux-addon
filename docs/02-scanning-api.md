# Auction Scanning API Documentation

## Summary

The aux-addon scanning system consists of four primary files that work together to scan, process, and interact with the WoW 1.12.1 Auction House API.

### File Overview

| File | Purpose |
|------|---------|
| `core/scan.lua` | Core scanning engine - manages scan states, query submission, pagination, and result processing |
| `util/scan.lua` | Utility layer - provides high-level functions for finding specific auctions and building item queries |
| `core/post.lua` | Auction posting - handles creating auctions with auto-pricing logic |
| `core/stack.lua` | Stack management - splits and combines items to create desired stack sizes before posting |

### How They Work Together

```
User initiates search
        |
        v
tabs/search/results.lua (UI layer)
        |
        v
core/scan.lua (scan engine)
        |
        +---> util/info.lua (parse auction data)
        |
        +---> core/history.lua (track price history)
        |
        v
WoW API (QueryAuctionItems, GetAuctionItemInfo, etc.)
```

For posting auctions:
```
User clicks Post
        |
        v
core/post.lua (posting engine)
        |
        +---> core/stack.lua (prepare stack sizes)
        |
        +---> core/history.lua (auto-pricing data)
        |
        v
WoW API (StartAuction, ClickAuctionSellItemButton, etc.)
```

---

## Scanning Logic

### State Machine Architecture

The scanning system uses a cooperative threading model via `control.lua`. Key concepts:

1. **Threads** - Coroutine-like execution contexts managed via `aux.thread()`
2. **Signals** - Synchronization primitives via `aux.signal()` for async callbacks
3. **When** - Conditional waiting via `aux.when(condition, callback)`

### Scan State Structure

```lua
scan_states[type] = {
    id = thread_id,        -- Unique identifier for this scan thread
    params = {
        type = 'list',     -- 'list', 'bidder', or 'owner'
        queries = {...},   -- Array of query objects
        on_auction = fn,   -- Callback per auction found
        on_page_loaded = fn,
        on_complete = fn,
        on_abort = fn,
        ...
    },
    query_index = 1,       -- Current query being processed
    page = 0,              -- Current page number (0-indexed)
    total_auctions = n,    -- Total auctions in result set
    stopped = false,       -- Stop flag
    last_list_query = t,   -- Timestamp of last query (for throttling)
}
```

### Query Execution Flow

1. **`scan.start(params)`** - Entry point
   - Aborts any existing scan of the same type
   - Creates new thread via `aux.thread(scan)`
   - Returns thread ID for external abort capability

2. **`scan()`** - Main loop
   - Increments `query_index`
   - If query has `blizzard_query`, calls `submit_query()`
   - Otherwise processes in-memory results via `scan_page()`

3. **`submit_query()`** - API submission with throttling
   ```lua
   if get_state().params.type == 'list' then
       return aux.when(CanSendAuctionQuery, submit)
   else
       return submit()  -- bidder/owner queries not throttled
   end
   ```

4. **`submit()`** - Actual API call
   - For 'list' type: `QueryAuctionItems(name, minLevel, maxLevel, slot, class, subclass, page, usable, quality)`
   - For 'bidder' type: `GetBidderAuctionItems(page)`
   - For 'owner' type: `GetOwnerAuctionItems(page)`

5. **`wait_for_results()`** - Waits for API response
   - Listens for `AUCTION_ITEM_LIST_UPDATE` event
   - Has 5-second timeout with retry logic
   - Waits for `owner_data_complete()` before proceeding

6. **`scan_page(i)`** - Processes each auction (1 to PAGE_SIZE)
   - Calls `info.auction(i, type)` to get auction data
   - Calls `history.process_auction()` for price tracking
   - Applies validators and callbacks
   - Recursively calls `scan_page(i + 1)` until PAGE_SIZE reached

### Page Size and Pagination

```lua
local PAGE_SIZE = 50  -- Fixed by WoW API

function total_pages(total_auctions)
    return ceil(total_auctions / PAGE_SIZE)
end

function last_page(total_auctions)
    local last_page = max(total_pages(total_auctions) - 1, 0)
    local last_page_limit = get_query().blizzard_query.last_page or last_page
    return min(last_page_limit, last_page)
end
```

### Owner Data Completion Check

The scan waits until all owner data is loaded:

```lua
function owner_data_complete()
    for i = 1, PAGE_SIZE do
        local auction_info = info.auction(i, 'list')
        if auction_info and not auction_info.owner then
            return false
        end
    end
    return true
end
```

This is a **significant source of delay** - the server sends owner information asynchronously after the main auction data.

---

## API Interactions

### WoW APIs Called During Scanning

| API Function | Call Frequency | Purpose |
|--------------|----------------|---------|
| `CanSendAuctionQuery()` | Polled continuously | Check if rate limit allows new query |
| `QueryAuctionItems()` | Once per page (50 auctions) | Submit search query to server |
| `GetBidderAuctionItems()` | Once per page | Get player's bids |
| `GetOwnerAuctionItems()` | Once per page | Get player's auctions |
| `GetNumAuctionItems()` | Once per page load | Get total auction count |
| `GetAuctionItemLink()` | Once per auction | Get item link |
| `GetAuctionItemInfo()` | Once per auction | Get auction details |
| `GetAuctionItemTimeLeft()` | Once per auction | Get time remaining |

### API Call Calculation

For a full scan of 10,000 auctions:
- Pages: `ceil(10000 / 50) = 200 pages`
- `QueryAuctionItems`: 200 calls
- `GetAuctionItemLink`: 10,000 calls
- `GetAuctionItemInfo`: 10,000 calls
- `GetAuctionItemTimeLeft`: 10,000 calls
- **Total API calls**: ~30,200+

### Throttling Mechanism

The addon respects Blizzard's built-in rate limiting:

```lua
function submit_query()
    if get_state().params.type == 'list' then
        return aux.when(CanSendAuctionQuery, submit)
    end
end
```

`CanSendAuctionQuery()` is a WoW API that returns `true` when the server allows another query. This is approximately:
- **~1 query per 0.3-0.5 seconds** under normal conditions
- May be slower during high server load

### Tooltip Generation (Per Auction)

Each auction triggers tooltip parsing for detailed info:

```lua
function M.tooltip(setter, arg1, arg2)
    AuxTooltip:SetOwner(UIParent, 'ANCHOR_NONE')
    if setter == 'auction' then
        AuxTooltip:SetAuctionItem(arg1, arg2)  -- Server round-trip
    end
    -- ... parse tooltip lines
end
```

---

## Performance Issues

### 1. Sequential Page Processing

**Issue**: Pages are processed strictly sequentially. Each page must complete before the next is requested.

```lua
-- In scan_page, after processing all 50 auctions:
if get_state().page < last_page(get_state().total_auctions) then
    get_state().page = get_state().page + 1
    return submit_query()  -- Wait for next page
end
```

**Impact**: Total scan time = (number of pages) x (time per page + rate limit delay)

### 2. Owner Data Wait

**Issue**: The scan waits for owner data even when `ignore_owner` is true.

```lua
-- wait_for_list_results has this logic:
if updated and (ignore_owner or owner_data_complete()) then
    return true
end
```

The `ignore_owner` check short-circuits the wait, but this is only effective if set. By default, `ignore_owner = true` in `account_data`, but the wait still polls.

**Impact**: Additional 100-500ms per page waiting for owner data.

### 3. Tooltip Parsing Overhead

**Issue**: Every auction triggers tooltip creation and parsing:

```lua
function M.auction(index, query_type)
    -- ...
    local tooltip, tooltip_money = tooltip('auction', query_type, index)
    -- ...
end
```

`tooltip()` creates a hidden tooltip frame and parses every line:

```lua
for i = 1, AuxTooltip:NumLines() do
    tinsert(tooltip, T.map(
        'left_text', _G['AuxTooltipTextLeft' .. i]:GetText(),
        'left_color', T.list(_G['AuxTooltipTextLeft' .. i]:GetTextColor()),
        'right_text', _G['AuxTooltipTextRight' .. i]:IsVisible() and _G['AuxTooltipTextRight' .. i]:GetText(),
        'right_color', T.list(_G['AuxTooltipTextRight' .. i]:GetTextColor())
    ))
end
```

**Impact**: String allocations and table creation for every auction.

### 4. History Processing Overhead

**Issue**: Every auction triggers history processing:

```lua
function M.process_auction(auction_record, pages)
    local item_record = read_record(auction_record.item_key)  -- Deserializes from string
    -- ... compare prices ...
    write_record(auction_record.item_key, item_record)  -- Serializes back to string
    -- ... potentially sends chat message
end
```

The `read_record` and `write_record` functions deserialize/serialize using the persistence schema on every call.

**Impact**:
- String parsing and table creation per auction
- Potential chat throttling delays when sharing data

### 5. Real-Time Scan Deduplication

**Issue**: Real-time scanning rebuilds the entire record map on each page:

```lua
-- In start_real_time_scan on_complete:
local map = T.temp-T.acquire()
for _, record in search.records do
    map[record.sniping_signature] = record
end
for _, record in new_records do
    map[record.sniping_signature] = record
end
```

**Impact**: O(n) map rebuild where n = total records seen.

### 6. Recursive scan_page Implementation

**Issue**: `scan_page` uses tail recursion:

```lua
function scan_page(i)
    -- process auction i
    return scan_page(i + 1)  -- Tail call
end
```

While Lua 5.0 supports tail call optimization, this pattern creates call overhead.

---

## Memory Concerns

### 1. Table Pooling System

The addon uses `T.lua` for table pooling to reduce GC pressure:

```lua
-- Acquire a pooled table
local t = T.acquire()

-- Mark for auto-release at end of frame
T.temp-T.acquire()  -- or T.temp(t)

-- Explicitly release
T.release(t)
```

**Concern**: The pool has a fixed size of 50:
```lua
if pool_size < 50 then
    pool_size = pool_size + 1
    pool[pool_size] = t
else
    overflow_pool[t] = true  -- Weak table, will be GC'd
end
```

During heavy scanning, tables may overflow the pool.

### 2. Per-Auction Table Allocations

Each auction creates multiple tables:

```lua
function M.auction(index, query_type)
    return T.map(
        'item_id', item_id,
        'suffix_id', suffix_id,
        -- ... 30+ fields ...
        'tooltip', tooltip,  -- Contains nested tables
    )
end
```

**Memory per auction**:
- Main record table: ~30 fields
- Tooltip table: ~5-20 line entries
- Each tooltip line: 4 fields
- Search signature string concatenation

**Estimated**: 50-100 table allocations per auction.

### 3. Record Accumulation

Search results accumulate up to 2,000 records:

```lua
if getn(search.records) < 2000 then
    tinsert(search.records, auction_record)
    if getn(search.records) == 2000 then
        StaticPopup_Show('AUX_SEARCH_TABLE_FULL')
    end
end
```

**Impact**: 2,000 records x ~2KB each = ~4MB memory for full results.

### 4. History Cache

Value cache stores computed history values:

```lua
local value_cache = {}

function M.value(item_key)
    if not value_cache[item_key] or value_cache[item_key].next_push <= time() then
        -- Recompute and cache
        value_cache[item_key] = T.map('value', value, 'next_push', item_record.next_push)
    end
    return value_cache[item_key].value
end
```

**Concern**: Cache grows unbounded during session.

### 5. Data Sharing via Chat

When sharing is enabled, messages are queued:

```lua
ChatThrottleLib:SendChatMessage("BULK", nil, "AuxData," .. item_key .."," .. unit_buyout_price, "CHANNEL", ...)
```

ChatThrottleLib queues messages, which can accumulate memory during scans.

---

## Optimization Opportunities

### Server-Side Limitations (Cannot Optimize)

These are fundamental to WoW 1.12.1's architecture:

1. **Query rate limit** - `CanSendAuctionQuery()` enforces ~2-3 queries/second
2. **50 auctions per page** - Fixed by server
3. **Owner data delay** - Server sends asynchronously
4. **No batch queries** - Each query is independent

### Client-Side Optimizations (Possible)

#### 1. Lazy Tooltip Parsing

**Current**: Tooltip parsed for every auction
**Proposed**: Only parse tooltip when needed (for auctionability check)

```lua
-- Only call tooltip() when checking durability for posting
if strict then
    tooltip = tooltip('auction', query_type, index)
    -- Check durability
end
```

**Potential savings**: 50-70% of tooltip overhead for read-only scans.

#### 2. History Processing Batching

**Current**: Read/write per auction
**Proposed**: Batch updates at page boundaries

```lua
local pending_updates = {}

function M.process_auction(auction_record)
    local key = auction_record.item_key
    local price = auction_record.unit_buyout_price

    if not pending_updates[key] or price < pending_updates[key] then
        pending_updates[key] = price
    end
end

function flush_updates()
    for key, price in pending_updates do
        -- Single read/write per item_key
    end
    wipe(pending_updates)
end
```

**Potential savings**: Reduce serialization from n to unique(n) items.

#### 3. Reduce String Allocations

**Current**: Signature strings built per auction
```lua
auction_record.search_signature = aux.join(T.temp-T.list(item_id, suffix_id, ...), ':')
```

**Proposed**: Use numeric hashing or structured keys

```lua
-- Avoid string concatenation in hot path
auction_record.search_signature = format("%d:%d:%d:%d", item_id, suffix_id, enchant_id, start_price)
```

`format()` is faster than `table.concat` for fixed formats.

#### 4. Incremental Real-Time Updates

**Current**: Rebuild entire map each page
**Proposed**: Maintain persistent map structure

```lua
-- Keep map persistent across pages
if not search.signature_map then
    search.signature_map = {}
end

for _, record in new_records do
    search.signature_map[record.sniping_signature] = record
end
```

**Potential savings**: O(n) to O(page_size) per update.

#### 5. Pool Size Increase

**Current**: 50 tables in pool
**Proposed**: Increase to 200-500 during active scanning

```lua
-- Dynamic pool sizing
local MIN_POOL = 50
local MAX_POOL = 500

function set_scan_mode(active)
    pool_max = active and MAX_POOL or MIN_POOL
end
```

#### 6. Skip Non-Essential Processing

When doing quick price checks:
- Skip `history.process_auction()` if only browsing
- Skip tooltip parsing if not posting
- Add "fast scan" mode option

#### 7. Async Owner Wait Optimization

**Current**: Polls `owner_data_complete()` which checks all 50 slots

**Proposed**: Track count of loaded owners:
```lua
local owners_loaded = 0
event_listener('AUCTION_ITEM_LIST_UPDATE', function()
    owners_loaded = count_loaded_owners()  -- Cache result
end)
```

### Configuration Recommendations

For faster scanning with current code:

1. **Enable `ignore_owner`** - Reduces wait time per page
2. **Disable `sharing`** - Reduces chat queue overhead
3. **Use specific searches** - Fewer pages to scan
4. **Limit page range** - Use first_page/last_page controls

---

## Benchmarking Reference

Expected performance characteristics:

| Metric | Value |
|--------|-------|
| Pages per minute | ~120-180 (rate limited) |
| Auctions per minute | ~6,000-9,000 |
| Full AH scan (10k items) | ~1-2 minutes |
| Memory per 1000 auctions | ~2-4 MB |
| API calls per page | ~150-200 |

**Key insight**: The primary bottleneck is the server-side rate limit on `QueryAuctionItems()`, not client-side processing. Code optimizations can reduce CPU/memory usage but cannot significantly reduce total scan time.
