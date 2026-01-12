module 'aux.tabs.arbitrage'

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local money = require 'aux.util.money'
local scan_util = require 'aux.util.scan'
local scan = require 'aux.core.scan'
local history = require 'aux.core.history'

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

refresh = true

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
    scan.abort(scan_id)
    scan.abort(buy_scan_id)
    buy_state = IDLE
    found_auction_record = nil
    found_auction_index = nil
    selected_candidate = nil
end

-- Add a candidate item by name (will resolve to item_id)
function M.add_candidate(item_name, opportunity_type, target_price)
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

    tinsert(candidates, {
        item_id = item_id,
        item_name = item_info.name,
        opportunity_type = opportunity_type or 'market',
        target_price = target_price or 0,
        added_time = time(),
    })

    save_candidates()
    refresh = true
    return true
end

-- Add candidate by item_id directly
function M.add_candidate_by_id(item_id, opportunity_type, target_price)
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
        opportunity_type = opportunity_type or 'market',
        target_price = target_price or 0,
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
    local item_key = item_id .. ':0:0'  -- Standard item key format

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
            local buyable_records = T.acquire()

            for _, record in records do
                if record.buyout_price > 0 and not info.is_player(record.owner) then
                    total_count = total_count + record.aux_quantity
                    local unit_price = record.unit_buyout_price
                    if not min_buyout or unit_price < min_buyout then
                        min_buyout = unit_price
                    end
                    tinsert(buyable_records, record)
                end
            end

            -- Sort by unit price
            sort(buyable_records, function(a, b)
                return a.unit_buyout_price < b.unit_buyout_price
            end)

            -- Get vendor price and historical value
            local item_info = info.item(item_id)
            local vendor_price = item_info and item_info.sell_price or 0
            local historical_value = history.value(item_key) or 0

            scan_results[item_id] = {
                item_id = item_id,
                item_name = candidate.item_name,
                min_buyout = min_buyout,
                total_count = total_count,
                vendor_price = vendor_price,
                historical_value = historical_value,
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
        local item_key = item_id .. ':0:0'
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
                local buyable_records = T.acquire()

                for _, record in records do
                    if record.buyout_price > 0 and not info.is_player(record.owner) then
                        total_count = total_count + record.aux_quantity
                        local unit_price = record.unit_buyout_price
                        if not min_buyout or unit_price < min_buyout then
                            min_buyout = unit_price
                        end
                        tinsert(buyable_records, record)
                    end
                end

                sort(buyable_records, function(a, b)
                    return a.unit_buyout_price < b.unit_buyout_price
                end)

                local item_info = info.item(item_id)
                local vendor_price = item_info and item_info.sell_price or 0
                local historical_value = history.value(item_key) or 0

                scan_results[item_id] = {
                    item_id = item_id,
                    item_name = candidate.item_name,
                    min_buyout = min_buyout,
                    total_count = total_count,
                    vendor_price = vendor_price,
                    historical_value = historical_value,
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

-- Calculate profit for a scan result
function M.calculate_profit(result)
    if not result or not result.min_buyout then
        return nil
    end

    local profits = {}

    -- Vendor profit
    if result.vendor_price and result.vendor_price > result.min_buyout then
        profits.vendor = {
            type = 'vendor',
            profit = result.vendor_price - result.min_buyout,
            target = result.vendor_price,
        }
    end

    -- Market profit (need to account for AH cut when reselling)
    if result.historical_value and result.historical_value > 0 then
        local ah_cut = 0.05
        local net_resale = result.historical_value * (1 - ah_cut)
        if net_resale > result.min_buyout then
            profits.market = {
                type = 'market',
                profit = floor(net_resale - result.min_buyout),
                target = result.historical_value,
            }
        end
    end

    return profits
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
    end

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

-- Import candidates from a Lua table (for external tool integration)
function M.import_candidates(import_list)
    local count = 0
    for _, item in import_list do
        if add_candidate_by_id(item.id, item.type, item.profit) then
            count = count + 1
        end
    end
    aux.print(format('Imported %d candidates', count))
    return count
end
