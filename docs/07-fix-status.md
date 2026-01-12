# Performance Fix Status

This document tracks the status of performance issues identified during the aux-addon analysis.

**PR**: https://github.com/USS-Enterprise-Guild/aux-addon/pull/1
**Date**: 2026-01-11

---

## Fixed

| Priority | Issue | File | Fix Applied |
|----------|-------|------|-------------|
| HIGH | Nested table leak in tooltip() - color tables not marked temp | `util/info.lua` | Added `T.temp-` to inner `T.map()` and `T.list()` calls |
| HIGH | Table pool size too small (50) causes GC pressure | `libs/T.lua` | Increased pool size from 50 to 200 |
| HIGH | Search records (up to 10,000) never cleaned on AH close | `tabs/search/results.lua` | Added `handle.CLOSE()` to release records |
| HIGH | Post tab bid_records/buyout_records never cleaned | `tabs/post/core.lua` | Added cleanup in `tab.CLOSE()` |
| MEDIUM | Redundant disenchant.distribution() calls | `core/disenchant.lua`, `core/tooltip.lua` | Added optional `dist` parameter to `value()`, caller passes pre-computed distribution |
| MEDIUM | O(n^2) event unregistration in UPDATE() | `control.lua` | Replaced nested iteration with event reference counting |
| MEDIUM | Status bar OnUpdate runs every frame even when not needed | `gui/core.lua` | Added visibility check, auto-disable when value >= 1 |

---

## Not Fixed (Future Work)

### Medium Priority

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Real-time scan leaks old records array | `tabs/search/results.lua` | 172-186 | When `search.records` is replaced with `new_records`, the old array is not released back to the pool |
| Validator closures never released | `tabs/search/saved.lua` | 94-109 | `get_auto_buy_validator()` creates a `validators` table with `T.acquire()` that is never released |
| No frame recycling | `gui/auction_listing.lua`, `gui/listing.lua` | Various | Frames are created but never destroyed or pooled for reuse |

### Low Priority

| Issue | File | Lines | Description |
|-------|------|-------|-------------|
| Upfront row allocation | `gui/auction_listing.lua` | ~150 | All rows created at initialization even if never displayed; should use lazy creation |
| record_percentage() not cached | `gui/auction_listing.lua` | fill functions | Called per-cell on every render; result should be cached on record object |
| Item class lookup is O(n) | `util/filter.lua` | `item_class_index()` | Linear search through `GetAuctionItemClasses()` on every filter parse; should use prebuilt lookup table |
| Filter suggestions rebuilt every keystroke | `util/filter.lua` | 424-468 | `suggestions()` rebuilds entire array on each autocomplete; should memoize based on filter state |
| Full sort on every database update | `gui/auction_listing.lua` | 656 | Records sorted on every `SetDatabase()` call during scan; could defer or batch |
| Linear record removal | `gui/auction_listing.lua` | 863-869 | `RemoveAuctionRecord()` uses `aux.key()` linear search + `tremove()` shift + full rebuild |
| String concatenation in hot paths | Multiple | Various | Item keys built via `..` operator in tooltip and history code; could pre-compute |
| Tooltip data duplicated per auction | `util/info.lua` | `auction()` | Each auction record stores full tooltip array; could reference shared data |

---

## Cannot Fix (Server-Side Limitations)

| Issue | Description |
|-------|-------------|
| Auction query rate limit | `CanSendAuctionQuery()` enforces ~2-3 queries/second server-side |
| 50 auctions per page | Fixed by WoW API, cannot request more |
| Owner data delay | Server sends owner information asynchronously after main auction data |
| No batch queries | Each `QueryAuctionItems()` call is independent |

---

## Implementation Notes

### Frame Pooling (Recommended Next Step)

The highest-impact remaining fix would be implementing frame pooling for the GUI components. Pattern:

```lua
local frame_pool = {
    rows = {},
    cells = {},
}

function acquire_row(parent)
    local row = tremove(frame_pool.rows)
    if not row then
        row = CreateFrame('Button', nil, parent)
        -- Initialize once
    end
    row:SetParent(parent)
    row:Show()
    return row
end

function release_row(row)
    row:Hide()
    row:ClearAllPoints()
    tinsert(frame_pool.rows, row)
end
```

### Real-Time Scan Fix

In `tabs/search/results.lua` around line 172-186, add:
```lua
local old_records = search.records
search.records = new_records
T.release(old_records)  -- Release the old array
```

### Validator Cleanup Fix

In `tabs/search/saved.lua`, the `validators` table created in `get_auto_buy_validator()` should either:
1. Be released when the search completes, or
2. Use `T.temp-T.acquire()` if it's only needed for the current frame
