# Integration and Control System Analysis

## 1. Summary

The aux-addon uses a sophisticated initialization and lifecycle management system built around WoW's event-driven architecture. The addon employs:

- A custom module system (`package.lua`) providing namespace isolation
- A table pooling system (`T.lua`) for memory management
- A frame-based "threading" system (`control.lua`) for asynchronous operations
- Multi-stage initialization via event handlers

The addon intercepts the default Blizzard Auction UI, replacing it with a custom implementation while maintaining compatibility through careful event management and function hooking.

## 2. Event System

### 2.1 Event Registration Pattern (aux-addon.lua)

The main addon creates an event frame and registers for core lifecycle events:

```lua
local event_frame = CreateFrame'Frame'
for event in T.temp-T.set('ADDON_LOADED', 'VARIABLES_LOADED', 'PLAYER_LOGIN',
    'AUCTION_HOUSE_SHOW', 'AUCTION_HOUSE_CLOSED', 'AUCTION_BIDDER_LIST_UPDATE',
    'AUCTION_OWNED_LIST_UPDATE') do
    event_frame:RegisterEvent(event)
end
```

### 2.2 Handler Registration System

The addon uses a metatable-based handler registration pattern:

```lua
local set_handler = {}
M.handle = setmetatable({}, {
    __metatable=false,
    __newindex=function(_, k, v) set_handler[k](v) end
})
```

This allows modules to register handlers via:
```lua
function handle.LOAD()    -- Called on VARIABLES_LOADED
function handle.LOAD2()   -- Called on PLAYER_LOGIN
function handle.INIT_UI() -- Called on VARIABLES_LOADED (before LOAD)
function handle.CLOSE()   -- Called on AUCTION_HOUSE_CLOSED
```

### 2.3 Dynamic Event Listeners (control.lua)

The control module provides dynamic event registration:

```lua
function M.event_listener(event, cb)
    local listener_id = unique_id()
    listeners[listener_id] = T.map(
        'event', event,
        'cb', cb,
        'kill', T.vararg-function(arg)
            if getn(arg) == 0 or arg[1] then
                kill_listener(listener_id)
            end
        end
    )
    event_frame:RegisterEvent(event)
    return listener_id
end
```

**Memory Concern**: Listeners are stored in a table with unique IDs. The `kill` function creates a closure that captures `listener_id`. While listeners can be killed, the registration pattern in high-frequency operations (like bid placement) could accumulate listeners if the kill callback is never invoked.

### 2.4 Event Cleanup Pattern

```lua
function EVENT()
    for id, listener in listeners do
        if listener.killed then
            listeners[id] = nil  -- Cleanup killed listeners
        elseif event == listener.event then
            listener.cb(listener.kill)
        end
    end
end
```

**Issue**: Cleanup only occurs when events fire. If an event is registered but never fires again, killed listeners for that event may persist until a new event of that type triggers cleanup.

## 3. Threading Model

### 3.1 Overview

The "threading" system is not true threading but a cooperative scheduling system using WoW's `OnUpdate` frame handler. It provides:

- Asynchronous task execution via the `thread()` function
- Continuation-passing via the `wait()` function
- Conditional execution via the `when()` function

### 3.2 Thread Creation

```lua
M.thread = T.vararg-function(arg)
    T.static(arg)  -- Remove from auto-release pool
    arg.f = tremove(arg, 1)
    local thread_id = unique_id()
    threads[thread_id] = T.map('k', setmetatable(arg, mt))
    if event_frame:GetScript("OnUpdate") == nil then
        event_frame:SetScript('OnUpdate', UPDATE)
    end
    return thread_id
end
```

### 3.3 Thread Execution Loop

```lua
function UPDATE()
    -- Event listener cleanup
    for _, listener in listeners do
        local event, needed = listener.event, false
        for _, listener in listeners do
            needed = needed or listener.event == event and not listener.killed
        end
        if not needed then
            event_frame:UnregisterEvent(event)
        end
    end

    -- Thread execution
    for id, thread in threads do
        if thread.killed or not thread.k then
            threads[id] = nil
            -- Disable OnUpdate when no threads remain
            local hasLiveThread = false
            for _ in pairs(threads) do hasLiveThread = true break end
            if not hasLiveThread then
                event_frame:SetScript('OnUpdate', nil)
            end
        else
            local k = thread.k
            thread.k = nil
            thread_id = id
            k()
            thread_id = nil
        end
    end
end
```

### 3.4 Continuation Pattern (wait/when)

```lua
M.wait = T.vararg-function(arg)
    T.static(arg)
    arg.f = tremove(arg, 1)
    threads[thread_id].k = setmetatable(arg, mt)
end

M.when = T.vararg-function(arg)
    local c = tremove(arg, 1)  -- condition
    local k = tremove(arg, 1)  -- continuation
    if c() then
        return k(unpack(arg))
    else
        return wait(when, c, k, unpack(arg))
    end
end
```

**Memory Concern**: The `when()` function recursively schedules itself until the condition is met. Each iteration creates a new argument table via `T.vararg`. While `T.static` prevents auto-release, this pattern can create many intermediate tables during long waits.

## 4. Global State

### 4.1 Persistent Data (SavedVariables)

The addon maintains hierarchical persistent state in `aux` (saved variable):

| Key | Scope | Contents |
|-----|-------|----------|
| `aux.account` | Account-wide | UI settings, item cache, merchant prices |
| `aux.realm[key]` | Realm-specific | Character list, search history |
| `aux.faction[key]` | Faction-specific | Price history, posting data |
| `aux.character[key]` | Character-specific | Tooltip preferences |

### 4.2 Runtime State

```lua
-- aux-addon.lua
local bids_loaded              -- Boolean: bid list loaded flag
local current_owner_page       -- Number: current owner auction page
local locked                   -- Boolean: bid/cancel operation lock
local index                    -- Number: current tab index

-- control.lua
local listeners = T.acquire()  -- Table: active event listeners
local threads = T.acquire()    -- Table: active threads
local thread_id                -- Number: currently executing thread ID

-- frame.lua
M.frame                        -- Frame: main auction UI frame
```

### 4.3 Module Exports

The `M.` pattern exports values to module interfaces:

```lua
M.account_data    -- Reference to aux.account
M.realm_data      -- Reference to aux.realm[key]
M.faction_data    -- Reference to aux.faction[key]
M.character_data  -- Reference to aux.character[key]
M.orig            -- Table: original hooked functions
```

## 5. Memory Concerns

### 5.1 Event Listener Accumulation

**Location**: `aux-addon.lua` lines 179-184, 202-207

```lua
event_listener('CHAT_MSG_SYSTEM', function(kill)
    if arg1 == ERR_AUCTION_BID_PLACED then
        send_signal()
        kill()
    end
end)
```

**Problem**: If the expected chat message never arrives (e.g., server disconnect, error), the listener persists indefinitely. The 5-second timeout sends a signal but does not kill the listener.

**Impact**: Each failed bid/cancel creates an orphaned listener that:
- Consumes memory for the listener table entry
- Creates a closure capturing `send_signal` and `kill`
- Remains registered for `CHAT_MSG_SYSTEM` events

### 5.2 Closure Retention in Threads

**Location**: `aux-addon.lua` lines 169-178

```lua
thread(when, signal_received, function()
    -- Captures: name, texture, count, amount, buyout_price, on_success
    if name and amount > 0 and amount >= buyout_price then
        purchase_summary.add_purchase(name, texture, count, amount)
        purchase_summary.update_display()
    end
    do (on_success or pass)() end
    locked = false
end)
```

**Problem**: The closure captures multiple variables. If the condition never becomes true (signal never received), the thread and its closure persist.

### 5.3 Table Pool Overflow

**Location**: `libs/T.lua` lines 45-54

```lua
function release(t)
    wipe(t)
    auto_release[t] = nil
    if pool_size < 50 then
        pool_size = pool_size + 1
        pool[pool_size] = t
    else
        overflow_pool[t] = true  -- Weak table
    end
end
```

**Mitigation**: The overflow pool uses weak keys (`__mode='k'`), allowing GC to collect excess tables. However, during heavy operations, temporary tables may bypass the pool entirely before GC runs.

### 5.4 Handler Array Growth

**Location**: `aux-addon.lua` lines 27-36

```lua
local handlers_INIT_UI, handlers_LOAD, handlers_LOAD2 = {}, {}, {}
function set_handler.INIT_UI(f)
    tinsert(handlers_INIT_UI, f)
end
```

**Note**: Handler arrays grow but are never cleared. This is acceptable since handlers are only added during load, but the pattern doesn't support handler removal if modules need to unload.

### 5.5 Signal Object Retention

**Location**: `util.lua` lines 180-188

```lua
function M.signal()
    local params
    return T.vararg-function(arg)
        T.static(arg)  -- Prevents auto-release
        params = arg
    end, function()
        return params
    end
end
```

**Problem**: When a signal is created, `T.static(arg)` prevents automatic release. If the signal's send function is called, the `params` table persists until explicitly released (which never happens in current code).

## 6. Performance Issues

### 6.1 O(n^2) Event Unregistration

**Location**: `control.lua` lines 27-36

```lua
for _, listener in listeners do
    local event, needed = listener.event, false
    for _, listener in listeners do  -- Nested iteration
        needed = needed or listener.event == event and not listener.killed
    end
    if not needed then
        event_frame:UnregisterEvent(event)
    end
end
```

**Impact**: For `n` listeners, this performs `n^2` comparisons on every frame update. With many active listeners, this degrades performance.

### 6.2 Per-Frame Thread Iteration

**Location**: `control.lua` lines 38-53

```lua
for id, thread in threads do
    if thread.killed or not thread.k then
        threads[id] = nil
        local hasLiveThread = false
        for _ in pairs(threads) do hasLiveThread = true break end  -- Check every removal
        if not hasLiveThread then
            event_frame:SetScript('OnUpdate', nil)
        end
    else
        -- Execute thread
    end
end
```

**Impact**: The "has live thread" check iterates threads on every thread removal, even when multiple threads remain. This could be optimized with a counter.

### 6.3 Vararg Function Generation

**Location**: `libs/T.lua` lines 89-138

The `T.vararg` system uses `loadstring` to generate functions dynamically. While this happens once per vararg function definition (not per call), each generated function has its own code chunk, potentially impacting instruction cache efficiency.

### 6.4 Tab Event Handler Pattern

**Location**: `aux-addon.lua` lines 119-141

```lua
function M.tab(name)
    local tab = T.map('name', name)
    local tab_event = {
        OPEN = function(f) tab.OPEN = f end,
        CLOSE = function(f) tab.CLOSE = f end,
        -- ...
    }
    tinsert(tab_info, tab)
    return setmetatable({}, {__metatable=false, __newindex=function(_, k, v) tab_event[k](v) end})
end
```

**Note**: Creates a new metatable and closure for each tab. With 4 tabs, this is negligible, but the pattern doesn't scale.

## 7. Initialization Sequence

### 7.1 Load Order (from .toc file)

```
1. libs/package.lua      -- Module system
2. libs/T.lua            -- Table pooling
3. libs/ChatThrottleLib.lua -- Chat throttling
4. aux-addon.lua         -- Core addon, event frame, hooks
5. util.lua              -- Utility functions
6. control.lua           -- Threading system
7. color.lua             -- Color definitions
8. gui/core.lua          -- GUI framework
9. frame.lua             -- Main frame creation
10. util/persistence.lua -- Data persistence
... (remaining modules)
57. localization.lua     -- Localization strings
```

### 7.2 Event-Driven Initialization

```
Game Load
    |
    v
ADDON_LOADED (per addon)
    |-- If Blizzard_AuctionUI: auction_ui_loaded()
    |       |-- Unregister AUCTION_HOUSE_SHOW from AuctionFrame
    |       |-- Hook ShowUIPanel, GetOwnerAuctionItems, etc.
    |
    v
VARIABLES_LOADED
    |-- Set global theme
    |-- Execute all handlers_INIT_UI (frame creation)
    |-- Execute all handlers_LOAD (data initialization)
    |       |-- Initialize aux saved variable structure
    |       |-- Set up account_data, realm_data
    |       |-- Create tabs
    |       |-- Set up control.lua OnEvent handler
    |
    v
PLAYER_LOGIN
    |-- Execute all handlers_LOAD2
    |       |-- Initialize faction_data (requires UnitFactionGroup)
    |       |-- Set frame scale
    |-- Print welcome message
```

### 7.3 Runtime Event Flow

```
AUCTION_HOUSE_SHOW
    |-- Hide Blizzard AuctionFrame
    |-- Show aux frame
    |-- Select first tab

AUCTION_HOUSE_CLOSED
    |-- Reset bids_loaded, current_owner_page
    |-- Execute all CLOSE handlers
    |-- Deselect tab (calls tab.CLOSE)
    |-- Hide aux frame

AUCTION_BIDDER_LIST_UPDATE
    |-- Set bids_loaded = true

AUCTION_OWNED_LIST_UPDATE
    |-- Update current_owner_page
```

### 7.4 Module Registration Pattern

Each module follows this pattern:

```lua
module 'aux.some.module'

local aux = require 'aux'

-- Register for LOAD event
function handle.LOAD()
    -- Initialize module state
end

-- Register for CLOSE event (auction house)
function handle.CLOSE()
    -- Cleanup on AH close
end
```

### 7.5 Hook Chain

```lua
orig = setmetatable({[_G]=T.acquire()}, {
    __index=function(self, key) return self[_G][key] end
})

hook = T.vararg-function(arg)
    -- Stores original function in orig[object][name]
    -- Replaces with handler
end
```

Hooked functions:
- `ShowUIPanel` - Intercepts AuctionFrame display
- `GetOwnerAuctionItems` - Tracks owner page requests
- `SetItemRef` - Item link click handling
- `UseContainerItem` - Bag item usage
- `AuctionFrameAuctions_OnEvent` - Blizzard auction events

## 8. Recommendations Summary

### Critical Issues

1. **Orphaned Event Listeners**: Add timeout-based cleanup for bid/cancel listeners
2. **O(n^2) Unregistration**: Use event reference counting instead of iteration
3. **Signal Table Leaks**: Implement explicit signal cleanup or use weak references

### Moderate Issues

4. **Thread Check Optimization**: Replace iteration with counter for live thread tracking
5. **Listener Cleanup Timing**: Trigger cleanup on all events, not just matching ones

### Minor Issues

6. **Handler Array Management**: Consider weak tables if dynamic module unloading is needed
7. **Closure Capture Minimization**: Pass only necessary data to thread closures
