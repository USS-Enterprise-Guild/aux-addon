# aux-addon GUI Framework Analysis

## Overview

The aux-addon GUI framework is a custom UI system built on top of WoW 1.12.1's native frame API. It provides reusable components for displaying auction data, item listings, and interactive controls. The framework supports two visual themes: a modern "aux" theme and a classic "Blizzard" theme.

---

## 1. Summary - File Responsibilities

### core.lua (758 lines)
The foundational GUI module that provides:
- **Theme management** - Global toggle between modern and Blizzard visual styles
- **Basic widget factories** - Functions to create buttons, checkboxes, editboxes, dropdowns, sliders, panels, labels, and status bars
- **Styling utilities** - Backdrop configuration, scrollbar styling, frame sizing
- **Tab group system** - Metatable-based tab navigation with dynamic tab creation
- **Unique naming** - Global frame name generator (`aux.frame1`, `aux.frame2`, etc.)
- **Context menu** - Dropdown menu wrapper using WoW's UIDropDownMenu system

### auction_listing.lua (1,079 lines)
The largest and most complex file, responsible for:
- **Auction record table display** - Sortable, scrollable table with expandable/collapsible item groups
- **Column definitions** - Three column configurations: `search_columns`, `auctions_columns`, and `bids_columns`
- **Data grouping** - Groups identical auctions by `search_signature` and items by `item_key`
- **Row management** - Virtual scrolling via FauxScrollFrame with dynamic row allocation
- **Sorting system** - Multi-column sort with ascending/descending support
- **Selection handling** - Row selection with highlight management
- **Price display** - Toggle between per-unit and per-stack pricing

### listing.lua (302 lines)
A simpler generic listing component:
- **Generic scrollable table** - Configurable columns with dynamic data binding
- **Lazy row/cell creation** - Rows and cells created on-demand as needed
- **Data-driven updates** - SetData() triggers re-render with automatic cleanup
- **Handler delegation** - OnEnter, OnLeave, OnClick, OnDoubleClick event routing

### item_listing.lua (128 lines)
Specialized for displaying item records:
- **Item display rows** - Shows item icon, name, quantity, and quality color
- **Tooltip integration** - Hover shows item tooltip via `info.set_tooltip()`
- **Selection state** - Callback-based selection tracking
- **Fixed row height** - 39px rows with scaled item buttons

### purchase_summary.lua (227 lines)
Displays purchase statistics:
- **Session tracking** - Aggregates purchases by item name with quantity and cost
- **Dynamic row creation** - Creates row frames on-demand for each unique item
- **Auto-hiding** - Hides when no purchases exist or feature disabled
- **Cleanup on close** - Wipes purchase data when auction house closes

---

## 2. UI Components

### Core Widgets (core.lua)

| Component | Factory Function | Description |
|-----------|-----------------|-------------|
| Button | `gui.button(parent, text_height)` | Standard button with enable/disable states |
| Checkbox | `gui.checkbox(parent)` | Toggle checkbox with custom or Blizzard template |
| Checkbutton | `gui.checkbutton(parent, text_height)` | Button that acts as a toggle with state tracking |
| Editbox | `gui.editbox(parent)` | Text input with overlay display, focus handling |
| Dropdown | `gui.dropdown(parent)` | Wrapper around UIDropDownMenuTemplate |
| Slider | `gui.slider(parent)` | Horizontal slider with label and editbox |
| Panel | `gui.panel(parent)` | Styled frame with panel backdrop |
| Label | `gui.label(parent, size)` | FontString wrapper |
| Status Bar | `gui.status_bar(parent)` | Dual-layer progress bar with pulsing animation |
| Item | `gui.item(parent)` | Item icon button with name label and count |
| Tab Group | `gui.tabs(parent, orientation)` | Tab strip with 'UP' or 'DOWN' orientation |

### Listing Components

| Component | Module | Purpose |
|-----------|--------|---------|
| Auction Listing | `auction_listing.new(parent, rows, columns)` | Complex table for auction records |
| Generic Listing | `listing.new(parent)` | Simple table for generic data |
| Item Listing | `item_listing.new(parent, on_click, selected)` | Item-focused list with icons |

---

## 3. Frame Management

### Frame Creation Patterns

**Unique Naming System:**
```lua
do
    local id = 1
    function M.unique_name()
        id = id + 1
        return 'aux.frame' .. id
    end
end
```
This ensures every named frame gets a unique global identifier, preventing name collisions. The counter is never reset during the session.

**Template Usage:**
- `UIDropDownMenuTemplate` - For dropdown menus
- `FauxScrollFrameTemplate` - For virtual scrolling
- `ActionButtonTemplate` - For item icon buttons
- `UIPanelButtonTemplate2` - For Blizzard-themed buttons
- `UICheckButtonTemplate` - For checkboxes
- `OptionsSliderTemplate` - For sliders (Blizzard theme)
- `CharacterFrameTabButtonTemplate` - For tabs (Blizzard theme)

### Show/Hide Behavior

**Auction Listing:**
- Rows are hidden via `row:Hide()` before each update cycle
- `SetRowInfo()` shows only rows within the visible scroll range
- FauxScrollFrame manages virtual scroll offset

**Listing:**
- Rows beyond `numRows` are hidden and their data cleared
- Rows with no data are hidden: `if i > getn(self.rowData) then row:Hide()`

**Purchase Summary:**
- Frame hidden when `purchase_summaries` is empty
- Hidden on CLOSE event and data is wiped

### Frame Destruction

**Critical Finding: Frames are NEVER destroyed.**

The addon creates frames but never calls methods to destroy or recycle them:
- `auction_listing.new()` creates all rows and cells upfront
- `listing.AddRow()` and `listing.AddCell()` create frames on-demand but never remove them
- `item_listing.new()` creates all rows in a while loop
- `purchase_summary` creates row frames in `update_display()` that persist

This is a significant memory concern as frames accumulate over the session lifetime.

---

## 4. Memory Concerns

### Frame Creation (HIGH IMPACT)

**auction_listing.new() - Upfront Allocation:**
```lua
-- Creates N rows x M columns cells immediately
for i = 1, rows do
    local row = CreateFrame('Button', nil, rt.contentFrame)
    -- Each row creates:
    -- - 1 highlight texture
    -- - M cells, each with 1 FontString
    -- - For item column: 1 spacer frame, 1 iconBtn button, 1 icon texture
```

For a typical 15-row table with 9 columns:
- 15 row frames (Button)
- 135 cell frames
- 135 FontStrings
- 15 highlight textures
- 9 header cells with FontStrings and textures
- ~15 icon buttons for item columns

**listing.lua - Lazy but Leaky:**
```lua
function AddRow(self)
    local row = CreateFrame('Button', nil, self.contentFrame)
    -- Creates rows but never removes them
    -- T.acquire() used for row.cols table but row frames persist
```

**item_listing.lua - While Loop Allocation:**
```lua
while total_height + ROW_HEIGHT < max_height do
    local row = CreateFrame('Frame', nil, content_frame)
    -- Creates rows until parent is filled
    -- Never cleaned up
```

### Texture Allocation (MEDIUM IMPACT)

**Scrollbar Background (Blizzard theme):**
```lua
-- set_scrollbar_style creates 3 textures per scrollbar:
local backgroundTop = scrollFrame:CreateTexture(nil, 'BACKGROUND')
local backgroundBottom = scrollFrame:CreateTexture(nil, 'BACKGROUND')
local backgroundMiddle = scrollFrame:CreateTexture(nil, 'BACKGROUND')
```

**Row Highlights:**
```lua
-- Every row creates a highlight texture
local highlight = row:CreateTexture()
highlight:SetAllPoints()
```

**Cell Background Textures:**
```lua
-- auction_listing creates textures for alternating columns
if gui.is_blizzard() or mod(j, 2) == 1 then
    local tex = cell:CreateTexture()
```

### FontString Allocation (MEDIUM IMPACT)

Every text element creates a new FontString:
- Column headers: 9 FontStrings
- Each cell: 1 FontString
- Labels, editbox overlays, status bar text

**Example in editbox:**
```lua
local overlay = label(editbox)  -- Creates FontString
-- Plus the EditBox's internal text
```

### Table Allocations (MODERATE IMPACT)

**T module usage:**
```lua
rt.expanded = {}           -- Persists for session
rt.handlers = {}           -- Persists
rt.sorts = {}             -- Persists
rt.records = {}           -- Database reference
rt.rowInfo = {numDisplayRows=0}  -- Rebuilt on data change
```

**rowInfo rebuilding in UpdateRowInfo:**
```lua
-- Good: Uses T.release() for cleanup
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
```

### Event Handler Closures (LOW-MEDIUM IMPACT)

**Scripts with closure references:**
```lua
editbox:SetScript('OnMouseDown', function()
    -- References last_click table
    if GetTime() - last_click.t < .5 ...
end)
```

**Scroll frame closure:**
```lua
scrollFrame:SetScript('OnVerticalScroll', function()
    FauxScrollFrame_OnVerticalScroll(rt.ROW_HEIGHT, function() rt:UpdateRows() end)
end)
-- Creates new closure on each scroll event
```

---

## 5. Performance Issues

### Rendering Bottlenecks

**1. Full Re-sort on Every Update (auction_listing.lua):**
```lua
function UpdateRows(self)
    if not self.isSorted then
        -- sort_helper called for EVERY comparison
        for _, v in ipairs(self.rowInfo) do
            sort(v.children, sort_helper)  -- O(n log n) per group
        end
        sort(self.rowInfo, sort_helper)    -- O(n log n) for groups
    end
```
- `isSorted` flag prevents redundant sorts
- But `SetSort()` and `UpdateRowInfo()` clear it, forcing re-sort

**2. Linear Search in UpdateRowInfo:**
```lua
for i = 1, getn(records) do
    -- Accesses previous element for comparison
    if prevRecord and record.search_signature == prevRecord.search_signature then
        -- Deeply nested table access
        self.rowInfo[getn(self.rowInfo)].children[getn(self.rowInfo[getn(self.rowInfo)].children)].count = ...
```
- Repeated `getn()` calls instead of caching length
- Repeated table indexing

**3. Status Bar OnUpdate (core.lua):**
```lua
local function update_bar()
    if this:GetValue() < 1 then
        this:SetAlpha(1 - (sin(GetTime() * 180) + 1) / 4)
    end
end
-- Called every frame for BOTH status bars
```
- Continuous sine calculation and alpha changes even when not visible

**4. Scrollbar OnSizeChanged (core.lua, Blizzard theme):**
```lua
scrollBar:SetScript('OnSizeChanged', function()
    -- Complex height calculation
    local missingSpace = (scrollBar:GetHeight() / scrollBar:GetEffectiveScale()) + ...
    -- Texture resize and texcoord update
end)
```

**5. Column Resize on Every UpdateRows:**
```lua
function UpdateRows(self)
    self:ResizeColumns()  -- Called every update
```
ResizeColumns iterates all header cells and all row cells:
```lua
for i, cell in self.headCells do
    local width = cell.info.width * weight
    cell:SetWidth(width)
    for _, row in self.rows do
        row.cells[i]:SetWidth(width)  -- Nested loop
    end
end
```

### Data Processing Inefficiencies

**1. String Operations in Fill Functions:**
```lua
fill = function(cell, record)
    cell.text:SetText(gsub(record.link, '[%[%]]', ''))  -- gsub every render
end
```

**2. Repeated aux.key() Searches:**
```lua
function RemoveAuctionRecord(self, record)
    local index = aux.key(self.records, record)  -- Linear search
    if index then
        tremove(self.records, index)             -- O(n) shift
    end
    self:SetDatabase()                           -- Full rebuild
end
```

**3. record_percentage() Called Per-Cell:**
```lua
fill = function(cell, record)
    local pct, bidPct = record_percentage(record)  -- history lookup
    -- Called for every visible row on every update
```

---

## 6. Optimization Opportunities

### Frame Pooling (HIGH PRIORITY)

**Problem:** Frames are created but never recycled.

**Solution:** Implement a frame pool system:
```lua
local frame_pool = {
    rows = {},
    cells = {},
    textures = {}
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

### Lazy Loading (HIGH PRIORITY)

**Problem:** All rows/cells created upfront even if never displayed.

**Solution:** Create rows only when scrolled into view:
```lua
function EnsureRowExists(self, index)
    if not self.rows[index] then
        self.rows[index] = self:CreateRow(index)
    end
    return self.rows[index]
end
```

### Cached Computations (MEDIUM PRIORITY)

**Problem:** Same calculations repeated every render.

**Solutions:**

1. **Cache record_percentage:**
```lua
function record_percentage(record)
    if record._cached_pct then
        return record._cached_pct, record._cached_bid_pct
    end
    -- Calculate...
    record._cached_pct = pct
    record._cached_bid_pct = bidPct
    return pct, bidPct
end
```

2. **Cache string operations:**
```lua
-- In item record creation
record.display_name = gsub(record.link, '[%[%]]', '')
-- Then in fill:
cell.text:SetText(record.display_name)
```

3. **Cache getn() results:**
```lua
local rowInfo = self.rowInfo
local numRowInfo = getn(rowInfo)
for i = 1, numRowInfo do
    local v = rowInfo[i]
    local numChildren = getn(v.children)
    -- Use cached values
end
```

### Reduce Closure Creation (MEDIUM PRIORITY)

**Problem:** New closures created in hot paths.

**Solution:** Use upvalues or method binding:
```lua
-- Instead of:
scrollFrame:SetScript('OnVerticalScroll', function()
    FauxScrollFrame_OnVerticalScroll(rt.ROW_HEIGHT, function() rt:UpdateRows() end)
end)

-- Use:
local function scroll_callback()
    rt:UpdateRows()
end
scrollFrame:SetScript('OnVerticalScroll', function()
    FauxScrollFrame_OnVerticalScroll(rt.ROW_HEIGHT, scroll_callback)
end)
```

### Throttle Status Bar Animation (LOW PRIORITY)

**Problem:** OnUpdate runs every frame for pulsing effect.

**Solution:** Only update when visible and value < 1:
```lua
local function update_bar()
    if not this:IsVisible() then return end
    if this:GetValue() >= 1 then
        this:SetAlpha(1)
        this:SetScript('OnUpdate', nil)  -- Stop updating
        return
    end
    this:SetAlpha(1 - (sin(GetTime() * 180) + 1) / 4)
end

-- Re-enable on value change:
function self:update_status(primary_status, ...)
    if primary_status and primary_status < 1 then
        self.primary_status_bar:SetScript('OnUpdate', update_bar)
    end
    -- ...
end
```

### Batch Column Resizing (LOW PRIORITY)

**Problem:** ResizeColumns called on every UpdateRows.

**Solution:** Only resize when parent size actually changes:
```lua
local last_width = 0
function ResizeColumns(self)
    local current_width = self.contentFrame:GetRight() - self.contentFrame:GetLeft()
    if current_width == last_width then return end
    last_width = current_width
    -- ... actual resize logic
end
```

### Incremental Data Updates (LOW PRIORITY)

**Problem:** `RemoveAuctionRecord()` rebuilds entire dataset.

**Solution:** Implement incremental updates:
```lua
function RemoveAuctionRecord(self, record)
    -- Remove from rowInfo without full rebuild
    for i, v in ipairs(self.rowInfo) do
        for j, child in ipairs(v.children) do
            if child.record == record then
                child.count = child.count - 1
                if child.count == 0 then
                    tremove(v.children, j)
                end
                if getn(v.children) == 0 then
                    tremove(self.rowInfo, i)
                end
                self:UpdateRows()  -- Just re-render
                return
            end
        end
    end
end
```

---

## 7. Architecture Diagram

```
+------------------+
|    core.lua      |
|  (Base Widgets)  |
+--------+---------+
         |
         | provides gui.* functions
         |
    +----+----+----+----+
    |         |         |
    v         v         v
+-------+ +-------+ +----------+
|listing| |auction| |  item    |
|  .lua | |listing| | listing  |
+---+---+ +---+---+ +----+-----+
    |         |          |
    | uses    | uses     | uses
    v         v          v
+------------------------------------------+
|           WoW Frame API                  |
| CreateFrame, FontString, Texture, etc.  |
+------------------------------------------+
```

---

## 8. Summary of Memory-Critical Issues

| Issue | Severity | Location | Impact |
|-------|----------|----------|--------|
| No frame recycling | HIGH | All listing modules | Frames accumulate, never freed |
| Upfront row allocation | HIGH | auction_listing.new() | ~150+ objects per table |
| Texture per cell | MEDIUM | auction_listing cells | 135+ textures per table |
| FontString per cell | MEDIUM | All listings | 135+ FontStrings per table |
| Closure in OnVerticalScroll | LOW | All scroll frames | New closure per scroll |
| Status bar OnUpdate | LOW | core.lua | Continuous computation |
| getn() in loops | LOW | UpdateRowInfo | Repeated calculations |

---

## 9. Recommended Priority Actions

1. **Implement Frame Pooling** - Create a shared pool for row and cell frames that can be reused across different listing instances.

2. **Add Lazy Row Creation** - Only create rows that will be visible, create more on scroll.

3. **Cache Computed Values** - Store `record_percentage`, display strings, and other repeated calculations on the record objects.

4. **Optimize UpdateRowInfo** - Cache loop lengths, reduce nested table access, consider maintaining an index structure.

5. **Conditional ResizeColumns** - Only recalculate when parent dimensions actually change.

6. **Throttle Animations** - Disable OnUpdate handlers when not needed.
