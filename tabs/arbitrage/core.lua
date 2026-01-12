module 'aux.tabs.arbitrage'

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local money = require 'aux.util.money'
local scan_util = require 'aux.util.scan'
local scan = require 'aux.core.scan'

local tab = aux.tab 'Arbitrage'

local scan_id = 0
local candidates = {}
local scan_results = {}
local selected_candidate = nil

-- Buying state
local IDLE, SEARCHING, FOUND = 1, 2, 3
local buy_state = IDLE
local buy_scan_id = 0
local found_auction_record = nil
local found_auction_index = nil

-- Background scanning state
local bg_scan_enabled = false
local bg_scan_index = 0
local bg_scan_interval = 2  -- seconds between each item scan
local bg_last_scan_time = 0
local bg_scan_paused = false  -- pause during manual operations
local MAX_STORED_RECORDS = 5  -- limit records per item for memory

refresh = true

-- Forward declare internal function (defined in background scanning section)
local stop_background_scan

function aux.handle.LOAD2()
    -- Load saved candidates from account data
    if aux.account_data.arbitrage_candidates then
        candidates = aux.account_data.arbitrage_candidates
    end
end

function tab.OPEN()
    frame:Show()
    refresh = true
end

function tab.CLOSE()
    frame:Hide()
    stop_background_scan()
    scan.abort(scan_id)
    scan.abort(buy_scan_id)
    buy_state = IDLE
    found_auction_record = nil
    found_auction_index = nil
    selected_candidate = nil
    -- Release records to free memory when leaving tab
    for item_id, result in scan_results do
        if result.records then
            T.release(result.records)
            result.records = nil
        end
    end
end

-- Add a candidate item by name (will resolve to item_id)
function M.add_candidate(item_name)
    local item_id = info.item_id(item_name)
    if not item_id then
        aux.print('Item not found: ' .. item_name)
        return false
    end

    local item_info = info.item(item_id)
    if not item_info then
        aux.print('Could not get item info for: ' .. item_name)
        return false
    end

    -- Check for duplicates
    for _, candidate in candidates do
        if candidate.item_id == item_id then
            aux.print('Item already in list: ' .. item_info.name)
            return false
        end
    end

    tinsert(candidates, {
        item_id = item_id,
        item_name = item_info.name,
        added_time = time(),
    })

    save_candidates()
    refresh = true
    return true
end

-- Add candidate by item_id directly
function M.add_candidate_by_id(item_id)
    local item_info = info.item(item_id)
    if not item_info then
        aux.print('Could not get item info for id: ' .. item_id)
        return false
    end

    -- Check for duplicates
    for _, candidate in candidates do
        if candidate.item_id == item_id then
            aux.print('Item already in list: ' .. item_info.name)
            return false
        end
    end

    tinsert(candidates, {
        item_id = item_id,
        item_name = item_info.name,
        added_time = time(),
    })

    save_candidates()
    refresh = true
    return true
end

-- Remove a candidate
function M.remove_candidate(item_id)
    for i, candidate in candidates do
        if candidate.item_id == item_id then
            tremove(candidates, i)
            if selected_candidate and selected_candidate.item_id == item_id then
                selected_candidate = nil
            end
            save_candidates()
            refresh = true
            return true
        end
    end
    return false
end

-- Clear all candidates
function M.clear_candidates()
    candidates = {}
    selected_candidate = nil
    scan_results = {}
    save_candidates()
    refresh = true
end

-- Save candidates to SavedVariables
function save_candidates()
    aux.account_data.arbitrage_candidates = candidates
end

-- Get all candidates
function M.get_candidates()
    return candidates
end

-- Select a candidate
function M.select_candidate(candidate)
    if selected_candidate ~= candidate then
        scan.abort(buy_scan_id)
        buy_state = IDLE
        found_auction_record = nil
        found_auction_index = nil
    end
    selected_candidate = candidate
    refresh = true
end

function M.get_selected_candidate()
    return selected_candidate
end

-- Get scan result for a candidate
function M.get_scan_result(item_id)
    return scan_results[item_id]
end

-- Scan a single candidate
function M.scan_candidate(candidate)
    if not candidate then return end

    local item_id = candidate.item_id

    scan.abort(scan_id)
    status_bar:update_status(0, 0)
    status_bar:set_text('Scanning ' .. candidate.item_name .. '...')

    local records = T.acquire()
    local query = scan_util.item_query(item_id)

    scan_id = scan.start{
        type = 'list',
        ignore_owner = true,
        queries = T.list(query),
        on_page_loaded = function(page, total_pages)
            status_bar:update_status(page / total_pages, 0)
            status_bar:set_text(format('Scanning %s: Page %d / %d', candidate.item_name, page, total_pages))
        end,
        on_auction = function(auction_record)
            if auction_record.item_id == item_id then
                tinsert(records, auction_record)
            end
        end,
        on_abort = function()
            T.release(records)
            status_bar:update_status(1, 1)
            status_bar:set_text('Scan aborted')
        end,
        on_complete = function()
            -- Process results
            local min_buyout = nil
            local total_count = 0
            local vendor_price = 0
            local buyable_records = T.acquire()

            for _, record in records do
                if record.buyout_price > 0 and not info.is_player(record.owner) then
                    total_count = total_count + record.aux_quantity
                    local unit_price = record.unit_buyout_price
                    if not min_buyout or unit_price < min_buyout then
                        min_buyout = unit_price
                    end
                    -- Get vendor price from first record's tooltip_money (per unit)
                    if vendor_price == 0 and record.tooltip_money then
                        vendor_price = record.tooltip_money / record.aux_quantity
                    end
                    tinsert(buyable_records, record)
                end
            end

            -- Sort by unit price
            sort(buyable_records, function(a, b)
                return a.unit_buyout_price < b.unit_buyout_price
            end)

            scan_results[item_id] = {
                item_id = item_id,
                item_name = candidate.item_name,
                min_buyout = min_buyout,
                total_count = total_count,
                vendor_price = vendor_price,
                records = buyable_records,
                scan_time = time(),
            }

            -- Release original records table but keep buyable_records
            T.release(records)

            status_bar:update_status(1, 1)
            if min_buyout then
                status_bar:set_text(format('%s: %d available, min %s',
                    candidate.item_name, total_count, money.to_string(min_buyout, true)))
            else
                status_bar:set_text(format('%s: None available', candidate.item_name))
            end

            refresh = true
        end,
    }
end

-- Scan all candidates
function M.scan_all_candidates()
    if getn(candidates) == 0 then
        aux.print('No candidates to scan')
        return
    end

    scan.abort(scan_id)

    local index = 0
    local total = getn(candidates)

    local function scan_next()
        index = index + 1
        if index > total then
            status_bar:update_status(1, 1)
            status_bar:set_text('Scan complete: ' .. total .. ' items')
            refresh = true
            return
        end

        local candidate = candidates[index]
        status_bar:update_status((index - 1) / total, 0)
        status_bar:set_text(format('Scanning %d/%d: %s', index, total, candidate.item_name))

        local item_id = candidate.item_id
        local records = T.acquire()
        local query = scan_util.item_query(item_id)

        scan_id = scan.start{
            type = 'list',
            ignore_owner = true,
            queries = T.list(query),
            on_auction = function(auction_record)
                if auction_record.item_id == item_id then
                    tinsert(records, auction_record)
                end
            end,
            on_abort = function()
                T.release(records)
                status_bar:update_status(1, 1)
                status_bar:set_text('Scan aborted')
            end,
            on_complete = function()
                -- Process results
                local min_buyout = nil
                local total_count = 0
                local vendor_price = 0
                local buyable_records = T.acquire()

                for _, record in records do
                    if record.buyout_price > 0 and not info.is_player(record.owner) then
                        total_count = total_count + record.aux_quantity
                        local unit_price = record.unit_buyout_price
                        if not min_buyout or unit_price < min_buyout then
                            min_buyout = unit_price
                        end
                        -- Get vendor price from first record's tooltip_money (per unit)
                        if vendor_price == 0 and record.tooltip_money then
                            vendor_price = record.tooltip_money / record.aux_quantity
                        end
                        tinsert(buyable_records, record)
                    end
                end

                sort(buyable_records, function(a, b)
                    return a.unit_buyout_price < b.unit_buyout_price
                end)

                scan_results[item_id] = {
                    item_id = item_id,
                    item_name = candidate.item_name,
                    min_buyout = min_buyout,
                    total_count = total_count,
                    vendor_price = vendor_price,
                    records = buyable_records,
                    scan_time = time(),
                }

                T.release(records)
                refresh = true

                -- Continue to next
                scan_next()
            end,
        }
    end

    scan_next()
end

-- Calculate vendor flip profit for a scan result
function M.calculate_profit(result)
    if not result or not result.min_buyout then
        return nil
    end

    -- Vendor profit only - guaranteed profit
    if result.vendor_price and result.vendor_price > result.min_buyout then
        return {
            profit = result.vendor_price - result.min_buyout,
            vendor_price = result.vendor_price,
        }
    end

    return nil
end

-- Find cheapest auction for buying
function find_auction_for_buy(record)
    if not record or info.is_player(record.owner) then
        return
    end

    scan.abort(buy_scan_id)
    buy_state = SEARCHING
    found_auction_record = nil
    found_auction_index = nil

    buy_scan_id = scan_util.find(
        record,
        status_bar,
        function()  -- on_abort
            buy_state = IDLE
        end,
        function()  -- on_failure
            buy_state = IDLE
            -- Remove from results
            if selected_candidate then
                local result = scan_results[selected_candidate.item_id]
                if result and result.records then
                    for i, r in result.records do
                        if r == record then
                            tremove(result.records, i)
                            break
                        end
                    end
                end
            end
        end,
        function(index)  -- on_success
            buy_state = FOUND
            found_auction_record = record
            found_auction_index = index
            buyout_button:Enable()
        end
    )
end

-- Execute buyout
function M.execute_buyout()
    if buy_state ~= FOUND or not found_auction_record or not found_auction_index then
        return
    end

    if scan_util.test(found_auction_record, found_auction_index) then
        aux.place_bid('list', found_auction_index, found_auction_record.buyout_price, function()
            -- Remove from results
            if selected_candidate then
                local result = scan_results[selected_candidate.item_id]
                if result and result.records then
                    for i, r in result.records do
                        if r == found_auction_record then
                            tremove(result.records, i)
                            -- Update min_buyout if needed
                            if getn(result.records) > 0 then
                                result.min_buyout = result.records[1].unit_buyout_price
                                result.total_count = result.total_count - found_auction_record.aux_quantity
                            else
                                result.min_buyout = nil
                                result.total_count = 0
                            end
                            break
                        end
                    end
                end
            end
            buy_state = IDLE
            found_auction_record = nil
            found_auction_index = nil
            refresh = true
        end)
    end
end

function on_update()
    if refresh then
        refresh = false
        update_candidate_listing()
        update_result_display()
        update_background_button()
    end

    -- Process background scanning
    process_background_scan()

    -- Handle buying state
    if buy_state == IDLE or buy_state == SEARCHING then
        buyout_button:Disable()
    end

    if buy_state == SEARCHING then return end

    if not selected_candidate then
        buy_state = IDLE
        buyout_button:Disable()
    elseif buy_state == IDLE then
        -- Auto-find cheapest auction when candidate is selected
        local result = scan_results[selected_candidate.item_id]
        if result and result.records and getn(result.records) > 0 then
            local cheapest = result.records[1]
            if cheapest and not info.is_player(cheapest.owner) then
                find_auction_for_buy(cheapest)
            end
        end
    elseif buy_state == FOUND then
        -- Verify the found auction is still valid
        if not found_auction_record or not scan_util.test(found_auction_record, found_auction_index) then
            buyout_button:Disable()
            if not aux.bid_in_progress() then
                buy_state = IDLE
            end
        end
    end
end

-- Background scanning functions

function M.start_background_scan()
    if getn(candidates) == 0 then
        aux.print('No candidates to scan')
        return
    end
    bg_scan_enabled = true
    bg_scan_index = 0
    bg_last_scan_time = 0
    bg_scan_paused = false
    refresh = true
    aux.print('Background scanning started (' .. getn(candidates) .. ' items, ' .. bg_scan_interval .. 's interval)')
end

-- Assign to forward-declared local
stop_background_scan = function()
    bg_scan_enabled = false
    bg_scan_paused = false
    refresh = true
end

function M.stop_background_scan()
    stop_background_scan()
    aux.print('Background scanning stopped')
end

function M.is_background_scanning()
    return bg_scan_enabled
end

function M.is_background_paused()
    return bg_scan_paused
end

function M.set_scan_interval(seconds)
    bg_scan_interval = max(1, min(30, seconds))
    aux.print('Scan interval set to ' .. bg_scan_interval .. 's')
end

function M.get_scan_interval()
    return bg_scan_interval
end

-- Memory-efficient background scan for a single item
-- Only keeps summary + limited records for buying
local function background_scan_item(candidate, on_complete)
    if not candidate then
        if on_complete then on_complete() end
        return
    end

    local item_id = candidate.item_id

    -- Lightweight record collection
    local min_buyout = nil
    local total_count = 0
    local vendor_price = 0
    local top_records = {}  -- Only keep cheapest N records
    local query = scan_util.item_query(item_id)

    scan_id = scan.start{
        type = 'list',
        ignore_owner = true,
        queries = T.list(query),
        on_auction = function(auction_record)
            if auction_record.item_id == item_id and
               auction_record.buyout_price > 0 and
               not info.is_player(auction_record.owner) then

                total_count = total_count + auction_record.aux_quantity
                local unit_price = auction_record.unit_buyout_price

                if not min_buyout or unit_price < min_buyout then
                    min_buyout = unit_price
                end

                -- Get vendor price from first record's tooltip_money (per unit)
                if vendor_price == 0 and auction_record.tooltip_money then
                    vendor_price = auction_record.tooltip_money / auction_record.aux_quantity
                end

                -- Only keep top N cheapest records for memory efficiency
                if getn(top_records) < MAX_STORED_RECORDS then
                    tinsert(top_records, auction_record)
                    -- Keep sorted
                    sort(top_records, function(a, b)
                        return a.unit_buyout_price < b.unit_buyout_price
                    end)
                elseif unit_price < top_records[MAX_STORED_RECORDS].unit_buyout_price then
                    -- Replace the most expensive one
                    top_records[MAX_STORED_RECORDS] = auction_record
                    sort(top_records, function(a, b)
                        return a.unit_buyout_price < b.unit_buyout_price
                    end)
                end
            end
        end,
        on_abort = function()
            bg_scan_paused = false
            if on_complete then on_complete() end
        end,
        on_complete = function()
            -- Release old records for this item
            local old_result = scan_results[item_id]
            if old_result and old_result.records then
                T.release(old_result.records)
            end

            -- Convert to pooled table for records
            local records = T.acquire()
            for _, r in top_records do
                tinsert(records, r)
            end

            scan_results[item_id] = {
                item_id = item_id,
                item_name = candidate.item_name,
                min_buyout = min_buyout,
                total_count = total_count,
                vendor_price = vendor_price,
                records = records,
                scan_time = time(),
            }

            refresh = true
            bg_scan_paused = false
            if on_complete then on_complete() end
        end,
    }
end

-- Called from on_update to drive background scanning
function process_background_scan()
    if not bg_scan_enabled then return end
    if bg_scan_paused then return end
    if buy_state == SEARCHING then return end  -- Don't interfere with buying
    if getn(candidates) == 0 then
        stop_background_scan()
        return
    end

    local now = GetTime()
    if now - bg_last_scan_time < bg_scan_interval then
        return
    end

    bg_last_scan_time = now
    bg_scan_index = bg_scan_index + 1
    if bg_scan_index > getn(candidates) then
        bg_scan_index = 1  -- Loop back to start
    end

    local candidate = candidates[bg_scan_index]
    if candidate then
        bg_scan_paused = true  -- Pause until this scan completes
        status_bar:set_text(format('[BG %d/%d] %s', bg_scan_index, getn(candidates), candidate.item_name))
        background_scan_item(candidate)
    end
end

-- Get background scan progress info
function M.get_background_progress()
    if not bg_scan_enabled then
        return nil
    end
    return {
        current = bg_scan_index,
        total = getn(candidates),
        paused = bg_scan_paused,
        interval = bg_scan_interval,
    }
end

-- Clear old scan results to free memory
function M.clear_scan_results()
    for item_id, result in scan_results do
        if result.records then
            T.release(result.records)
        end
    end
    scan_results = {}
    refresh = true
end

-- Import candidates from a Lua table (for external tool integration)
function M.import_candidates(import_list)
    local count = 0
    for _, item in import_list do
        if add_candidate_by_id(item.id) then
            count = count + 1
        end
    end
    aux.print(format('Imported %d candidates', count))
    return count
end
