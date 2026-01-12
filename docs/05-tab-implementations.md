# Tab Implementations Analysis

This document analyzes the tab implementation code in aux-addon, focusing on memory management, performance patterns, and data flow.

## 1. Summary

### Tab Overview

| Tab | Purpose | Files | Lines (approx) |
|-----|---------|-------|----------------|
| **Search** | Search AH, view results, bid/buyout | 5 files | ~1,687 |
| **Post** | Post items for sale | 2 files | ~1,013 |
| **Auctions** | Manage player's active auctions | 1 file | ~101 |
| **Bids** | Manage player's active bids | 1 file | ~125 |

### File Structure

```
tabs/
  search/
    core.lua      - Tab registration, subtab switching, popup dialogs
    frame.lua     - UI creation, search box, filter builder UI
    results.lua   - Search execution, scan management, result handling
    filter.lua    - Filter builder logic, blizzard_query proxy
    saved.lua     - Recent/favorite searches, auto-buy/bid validators
  post/
    core.lua      - Posting logic, inventory management, pricing
    frame.lua     - UI creation, sliders, listings
  auctions/
    core.lua      - Owner auction scanning and cancellation
  bids/
    core.lua      - Bidder auction scanning and bid management
```

## 2. Search Tab

### Architecture

The search tab is the most complex, split across 5 files with three subtabs:
1. **Search Results** - Displays auction scan results
2. **Saved Searches** - Recent and favorite searches
3. **Filter Builder** - Visual filter construction

### Search Workflow

```
User Input -> Filter Parsing -> Query Generation -> Scan Execution -> Result Display
     |              |                 |                  |               |
search_box    filter_util.queries   blizzard_query    scan.start     auction_listing
```

#### Step-by-Step Flow

1. **Filter Input** (`frame.lua:162-183`)
   - User types filter string in `search_box`
   - Input is auto-completed via `completion.complete_filter`
   - Formatter validates and prettifies the query

2. **Execution** (`results.lua:294-360`)
   ```lua
   function M.execute(resume, real_time)
       local queries, error = filter_util.queries(filter_string)
       -- Validates and parses filter string into query objects

       if not resume then
           if filter_string ~= current_search().filter_string then
               new_search(filter_string, first_page, last_page, real_time)
           else
               search.records = T.acquire()  -- Reset records
               search.table:Reset()
               search.table:SetDatabase(search.records)
           end
       end

       if real_time then
           start_real_time_scan(queries[1], nil, continuation)
       else
           start_search(queries, continuation)
       end
   end
   ```

3. **Scan Processing** (`results.lua:209-292`)
   - `start_search()` initiates the scan with callbacks
   - `on_auction` callback receives each auction record
   - Records are inserted into `search.records` array
   - **Hard limit of 2000 records** enforced

4. **Result Display** (`auction_listing.lua`)
   - `SetDatabase()` receives the records array
   - `UpdateRowInfo()` groups and sorts records by `search_signature`
   - `UpdateRows()` renders visible rows

### Search State Management

Multiple concurrent searches are supported (up to 5):

```lua
-- results.lua:29-92
local searches = {}
local search_index = 1

function new_search(filter_string, first_page, last_page, real_time)
    while getn(searches) > search_index do
        tremove(searches)  -- Remove forward history
    end
    local search = T.map(
        'records', T.acquire(),
        'filter_string', filter_string,
        'first_page', first_page,
        ...
    )
    tinsert(searches, search)
    if getn(searches) > 5 then
        tremove(searches, 1)  -- Oldest search dropped
        -- Status bars and tables are recycled via rotation
        tinsert(status_bars, tremove(status_bars, 1))
        tinsert(tables, tremove(tables, 1))
    end
end
```

### Real-Time Scanning

A special "sniping" mode that continuously scans the last page:

```lua
-- results.lua:139-207
function start_real_time_scan(query, search, continuation)
    -- Scans last page repeatedly
    -- Merges new results by sniping_signature
    -- Limits to 2000 records with warning popup

    on_complete = function()
        -- Merge old and new records using signature map
        local map = T.temp-T.acquire()
        for _, record in search.records do
            map[record.sniping_signature] = record
        end
        for _, record in new_records do
            map[record.sniping_signature] = record
        end
        T.release(new_records)
        new_records = aux.values(map)

        -- Recursively continue scanning
        start_real_time_scan(query, search)
    end
end
```

## 3. Post Tab

### Architecture

The post tab manages inventory display, price lookup, and auction posting.

### Posting Workflow

```
Inventory Scan -> Item Selection -> Price Scan -> Configuration -> Post
       |               |                |              |            |
update_inventory   update_item    refresh_entries   on_update    post.start
```

### Key Data Structures

```lua
-- post/core.lua:21
local scan_id, inventory_records, bid_records, buyout_records = 0, {}, {}, {}
```

- **inventory_records** - Array of auctionable items from player's bags
- **bid_records[item_key]** - Grouped bid prices for each item
- **buyout_records[item_key]** - Grouped buyout prices for each item

### Inventory Management

```lua
-- post/core.lua:493-531
function update_inventory_records()
    local auctionable_map = T.temp-T.acquire()
    for slot in info.inventory() do
        T.temp(slot)
        local item_info = T.temp-info.container_item(unpack(slot))
        if item_info then
            if info.auctionable(item_info.tooltip, nil, true) and not item_info.lootable then
                if not auctionable_map[item_info.item_key] then
                    local availability = T.acquire()
                    -- Track charge counts (0-10)
                    for i = 0, 10 do availability[i] = 0 end
                    auctionable_map[item_info.item_key] = T.map(...)
                else
                    -- Aggregate quantities
                    auctionable.aux_quantity = auctionable.aux_quantity + (item_info.charges or item_info.count)
                end
            end
        end
    end
    T.release(inventory_records)
    inventory_records = aux.values(auctionable_map)
end
```

### Price Scanning

```lua
-- post/core.lua:533-577
function refresh_entries()
    if selected_item then
        local item_key = selected_item.key
        bid_records[item_key], buyout_records[item_key] = nil, nil

        scan_id = scan.start{
            type = 'list',
            ignore_owner = true,
            queries = T.list(query),
            on_auction = function(auction_record)
                if auction_record.item_key == item_key then
                    record_auction(...)
                end
            end,
            on_complete = function()
                bid_records[item_key] = bid_records[item_key] or T.acquire()
                buyout_records[item_key] = buyout_records[item_key] or T.acquire()
            end,
        }
    end
end
```

## 4. Data Storage

### Search Results Storage

**Location**: `search.records` array per search instance

**Structure**: Each record contains:
- `item_id`, `item_key`, `suffix_id`
- `name`, `link`, `texture`, `quality`, `level`
- `aux_quantity`, `duration`, `owner`
- `bid_price`, `buyout_price`, `unit_bid_price`, `unit_buyout_price`
- `search_signature`, `sniping_signature` (for grouping/deduplication)
- `tooltip` (array of tooltip lines)
- `slot` (auction house slot index)

**Grouping**: `auction_listing.lua` groups by `item_key` and `search_signature`:
```lua
-- auction_listing.lua:656-675
sort(records, function(a, b)
    return a.search_signature < b.search_signature
        or a.search_signature == b.search_signature
        and tostring(a) < tostring(b)
end)

for i = 1, getn(records) do
    local record = records[i]
    if prevRecord and record.search_signature == prevRecord.search_signature then
        -- Same auction, increment count
    elseif not single_item and prevRecord and record.item_key == prevRecord.item_key then
        -- Same item, add child
    else
        -- New item group
        tinsert(self.rowInfo, T.map('item_key', record.item_key, ...))
    end
end
```

### Post Tab Storage

**bid_records / buyout_records**: Keyed by `item_key`
```lua
-- post/core.lua:579-609
entry = T.map(
    'stack_size', aux_quantity,
    'unit_price', unit_blizzard_bid,
    'duration', duration,
    'own', info.is_player(owner),
    'count', 0
)
```

### Saved Searches

**Location**: `aux.realm_data.recent_searches` and `aux.realm_data.favorite_searches`

```lua
-- saved.lua:38-52
function new_recent_search(filter_string, prettified)
    for i = getn(recent_searches), 1, -1 do
        if recent_searches[i].filter_string == filter_string then
            tremove(recent_searches, i)  -- Remove duplicates
        end
    end
    tinsert(recent_searches, 1, T.map(
        'filter_string', filter_string,
        'prettified', prettified
    ))
    while getn(recent_searches) > 50 do
        tremove(recent_searches)  -- Cap at 50 entries
    end
end
```

### Persistent Settings

**Post settings**: Stored per item in `aux.faction_data.post`
```lua
-- post/core.lua:19-44
local settings_schema = {'tuple', '#',
    {duration='number'},
    {start_price='number'},
    {buyout_price='number'},
    {hidden='boolean'},
    {stack_size='number'}
}
```

## 5. Memory Concerns

### Critical Issues

#### 5.1 Search Records Accumulation

**Problem**: Search records accumulate up to 2000 entries per search, with 5 searches possible.

```lua
-- results.lua:256-262
on_auction = function(auction_record, ctrl)
    if getn(search.records) < 2000 then
        tinsert(search.records, auction_record)
        if getn(search.records) == 2000 then
            StaticPopup_Show('AUX_SEARCH_TABLE_FULL')
        end
    end
end
```

**Impact**: Maximum ~10,000 auction records in memory simultaneously.

**Issue**: Records are not released when:
- Switching searches (old records retained)
- Closing AH (records persist until addon reload)

#### 5.2 rowInfo Temporary Table Churn

**Problem**: `UpdateRowInfo()` creates many temporary tables on every database update.

```lua
-- auction_listing.lua:637-687
function UpdateRowInfo(self)
    -- Release old entries
    for _, v in ipairs(self.rowInfo) do
        if type(v) == 'table' then
            for _, child in v.children do
                T.release(child)
            end
            T.release(v.children)
            T.release(v)
        end
    end
    T.wipe(self.rowInfo)

    -- Create new entries - one per item group
    for i = 1, getn(records) do
        -- Creates T.map for each group and T.map for each child
        tinsert(self.rowInfo, T.map('item_key', record.item_key,
            'expandKey', record.item_key,
            'children', T.list(T.map('count', 1, 'record', record))))
    end
end
```

**Impact**: With 2000 records, could create hundreds of temporary tables per update.

#### 5.3 Tooltip Storage

**Problem**: Each auction record stores the full tooltip as an array.

```lua
-- info.auction() stores:
record.tooltip = { line1, line2, line3, ... }
```

**Impact**: Tooltip data (8-20 lines per item) is duplicated per auction.

#### 5.4 Post Tab Price Records Never Cleared

**Problem**: `bid_records` and `buyout_records` are module-level and only cleared per-item.

```lua
-- post/core.lua:21
local scan_id, inventory_records, bid_records, buyout_records = 0, {}, {}, {}
```

**Impact**: Price data for every item ever viewed accumulates until reload.

#### 5.5 Validator Function Closures

**Problem**: Auto-buy/bid validators create new closures on each search execution.

```lua
-- saved.lua:94-109
function get_auto_buy_validator()
    local validators = T.acquire()  -- Never released!
    for _, search in favorite_searches do
        if search.auto_buy then
            local queries, error = filter_util.queries(search.filter_string)
            if queries then
                tinsert(validators, queries[1].validator)  -- Closure retained
            end
        end
    end
    return function(record)
        return aux.any(validators, function(validator) return validator(record) end)
    end
end
```

### Memory Pool Analysis

The `T` module implements table pooling:

```lua
-- T.lua:6
local pool, pool_size, overflow_pool, auto_release = {}, 0, setmetatable({}, {__mode='k'}), {}

-- Pool is limited to 50 tables
function release(t)
    wipe(t)
    auto_release[t] = nil
    if pool_size < 50 then
        pool_size = pool_size + 1
        pool[pool_size] = t
    else
        overflow_pool[t] = true  -- Weak reference, will be GC'd
    end
end
```

**Issue**: Pool size of 50 is too small for the table churn in `UpdateRowInfo()`.

## 6. Performance Issues

### 6.1 Sorting on Every Update

**Problem**: `SetDatabase()` triggers `UpdateRowInfo()` which sorts all records.

```lua
-- auction_listing.lua:656
sort(records, function(a, b)
    return a.search_signature < b.search_signature
        or a.search_signature == b.search_signature
        and tostring(a) < tostring(b)
end)
```

**Impact**: O(n log n) sort on every auction received during page scan.

#### Workaround Attempt
```lua
-- auction_listing.lua:250
on_page_scanned = function()
    search.table:SetDatabase()  -- Deferred to page completion
end
```

But `SetDatabase()` without args still triggers full rebuild.

### 6.2 Linear Record Removal

**Problem**: `RemoveAuctionRecord()` uses linear search.

```lua
-- auction_listing.lua:863-869
RemoveAuctionRecord = function(self, record)
    local index = aux.key(self.records, record)  -- O(n) search
    if index then
        tremove(self.records, index)  -- O(n) shift
    end
    self:SetDatabase()  -- O(n log n) rebuild
end
```

**Impact**: O(n^2) worst case for bulk removals.

### 6.3 Continuous OnUpdate Processing

**Problem**: `on_update()` runs every frame when tab is visible.

```lua
-- results.lua:423-443
function on_update()
    if state == IDLE or state == SEARCHING then
        buyout_button:Disable()
        bid_button:Disable()
    end
    if state == SEARCHING then return end

    local selection = current_search().table:GetSelection()
    if not selection then
        state = IDLE
    elseif selection and state == IDLE then
        find_auction(selection.record)  -- Triggers scan
    elseif state == FOUND and not scan_util.test(selection.record, found_index) then
        -- ...
    end
end
```

**Issue**: `scan_util.test()` called every frame when auction found.

### 6.4 Filter Builder Display Recalculation

**Problem**: `update_filter_display()` recalculates HTML on every component change.

```lua
-- filter.lua:291-310
function update_filter_display()
    text = formatted_post_filter(post_filter)
    filter_display:SetWidth(filter_display_size())
    set_filter_display_offset()
    filter_display:SetText(text)
end

function filter_display_size()
    -- Iterates all lines, measures text width
    for line in string.gfind(text, '<p>(.-)</p>') do
        lines = lines + 1
        filter_display.measure:SetFont(font, font_size)
        filter_display.measure:SetText(line)
        width = max(width, filter_display.measure:GetStringWidth())
    end
end
```

### 6.5 Real-Time Scan Record Merging

**Problem**: Real-time mode rebuilds entire record set on each page.

```lua
-- results.lua:172-186
on_complete = function()
    local map = T.temp-T.acquire()
    for _, record in search.records do
        map[record.sniping_signature] = record  -- O(n) iteration
    end
    for _, record in new_records do
        map[record.sniping_signature] = record
    end
    T.release(new_records)
    new_records = aux.values(map)  -- Creates new array

    if getn(new_records) > 2000 then
        StaticPopup_Show('AUX_SEARCH_TABLE_FULL')
    else
        search.records = new_records  -- Old records leaked!
        search.table:SetDatabase(search.records)
    end
}
```

**Issue**: Old `search.records` array is replaced but not released.

### 6.6 Post Tab Refresh Flag Polling

**Problem**: `refresh` flag checked every frame via `on_update()`.

```lua
-- post/core.lua:611-620
function on_update()
    if refresh then
        refresh = false
        price_update()
        update_item_configuration()
        update_inventory_listing()
        update_auction_listings()
    end
    validate_parameters()
end
```

**Issue**: Five functions called on any change, even minor UI updates.

## 7. Tab Lifecycle

### OPEN/CLOSE Event Handling

#### Search Tab
```lua
-- core.lua:22-31
function tab.OPEN()
    frame:Show()
    update_search_listings()  -- Refresh saved searches display
    update_filter_display()   -- Refresh filter builder
end

function tab.CLOSE()
    current_search().table:SetSelectedRecord()  -- Clear selection
    frame:Hide()
end
```

**Issue**: No cleanup of search records on close.

#### Post Tab
```lua
-- post/core.lua:68-77
function tab.OPEN()
    frame:Show()
    update_inventory_records()  -- Re-scan bags
    refresh = true              -- Trigger UI update
end

function tab.CLOSE()
    selected_item = nil
    frame:Hide()
end
```

**Issue**: No cleanup of `bid_records`/`buyout_records` on close.

#### Auctions Tab
```lua
-- auctions/core.lua:12-19
function tab.OPEN()
    frame:Show()
    scan_auctions()  -- Immediate scan on open
end

function tab.CLOSE()
    frame:Hide()
end
```

**Issue**: `auction_records` (module-level array) never cleared.

#### Bids Tab
```lua
-- bids/core.lua:13-19
function tab.OPEN()
    frame:Show()
    scan_bids()  -- Immediate scan on open
end

function tab.CLOSE()
    frame:Hide()
end
```

**Issue**: `auction_records` (module-level table) never cleared.

### Missing Cleanup Opportunities

1. **Auction House Close Event**: Tabs don't clear data when AH window closes
2. **Tab Switch**: Previous tab's scan not aborted (handled inconsistently)
3. **Search History Overflow**: Old search records not released when new search starts
4. **Real-Time Mode Exit**: No explicit cleanup of accumulated records

### Recommended Lifecycle Improvements

```lua
-- Ideal pattern (not currently implemented):
function tab.CLOSE()
    scan.abort(current_scan_id)  -- Stop any running scan

    -- Release all record arrays
    for _, search in searches do
        T.release(search.records)
    end
    T.wipe(searches)

    -- Reset state
    search_index = 1
    frame:Hide()
end
```

## Summary of Key Findings

### High-Priority Memory Issues
1. Search records accumulate up to 10,000 entries without cleanup
2. rowInfo table churn creates hundreds of temporary tables per update
3. Post tab price records never cleared
4. Validator closures leak memory on each search

### High-Priority Performance Issues
1. Full sort on every database update during scan
2. Linear record removal with full rebuild
3. Continuous OnUpdate processing with per-frame scan tests
4. Real-time mode leaks old record arrays

### Architectural Concerns
1. No cleanup on tab close or AH close
2. Pool size (50) insufficient for table churn
3. Tooltip data duplicated per auction record
4. Five concurrent searches retained without memory limits
