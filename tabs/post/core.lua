module 'aux.tabs.post'

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local sort_util = require 'aux.util.sort'
local persistence = require 'aux.util.persistence'
local money = require 'aux.util.money'
local scan_util = require 'aux.util.scan'
local post = require 'aux.core.post'
local scan = require 'aux.core.scan'
local history = require 'aux.core.history'
local auction_cache = require 'aux.core.auction_cache'
local item_listing = require 'aux.gui.item_listing'
local al = require 'aux.gui.auction_listing'
local gui = require 'aux.gui'

local tab = aux.tab 'Post'

local settings_schema = {'tuple', '#', {duration='number'}, {start_price='number'}, {buyout_price='number'}, {hidden='boolean'}, {stack_size='number'}}

local scan_id, inventory_records, bid_records, buyout_records = 0, {}, {}, {}

-- Raw auction records for buying (keyed by item_key)
local raw_auction_records = {}

M.DURATION_2, M.DURATION_8, M.DURATION_24 = 120, 480, 1440

refresh = true

selected_item = nil

-- Buying state machine
local buy_scan_id = 0
local IDLE, SEARCHING, FOUND = 1, 2, 3
local buy_state = IDLE
local found_auction_record = nil
local found_auction_index = nil

function get_default_settings()
	return T.map('duration', aux.account_data.post_duration, 'start_price', 0, 'buyout_price', 0, 'hidden', false, 'stack_size', 1)
end

function aux.handle.LOAD2()
	data = aux.faction_data.post
end

function read_settings(item_key)
	item_key = item_key or selected_item.key
	return data[item_key] and persistence.read(settings_schema, data[item_key]) or get_default_settings()
end
function write_settings(settings, item_key)
	item_key = item_key or selected_item.key
	data[item_key] = persistence.write(settings_schema, settings)
end

do
	local bid_selections, buyout_selections = {}, {}
	function get_bid_selection()
		if not selected_item then return nil end
		return bid_selections[selected_item.key]
	end
	function set_bid_selection(record)
		if not selected_item then return end
		bid_selections[selected_item.key] = record
	end
	function get_buyout_selection()
		if not selected_item then return nil end
		return buyout_selections[selected_item.key]
	end
	function set_buyout_selection(record)
		if not selected_item then return end
		local old_selection = buyout_selections[selected_item.key]
		buyout_selections[selected_item.key] = record
		-- Reset buying state when selection changes
		if old_selection ~= record then
			scan.abort(buy_scan_id)
			buy_state = IDLE
			found_auction_record = nil
			found_auction_index = nil
		end
	end
end

function refresh_button_click()
	scan.abort(scan_id)
	-- Invalidate cache for this item so we get fresh data
	if selected_item then
		auction_cache.invalidate(selected_item.item_id)
	end
	refresh_entries()
	refresh = true
end

function tab.OPEN()
    frame:Show()
    update_inventory_records()
    refresh = true
end

function tab.CLOSE()
    selected_item = nil
    frame:Hide()
    scan.abort(buy_scan_id)
    buy_state = IDLE
    found_auction_record = nil
    found_auction_index = nil
    -- Clean up pooled tables to prevent memory leaks
    for _, records in bid_records do
        if records then
            T.release(records)
        end
    end
    for _, records in buyout_records do
        if records then
            T.release(records)
        end
    end
    for _, records in raw_auction_records do
        if records then
            T.release(records)
        end
    end
    bid_records = {}
    buyout_records = {}
    raw_auction_records = {}
end

function tab.USE_ITEM(item_info)
	select_item(item_info.item_key)
end

function get_unit_start_price()
	return selected_item and read_settings().start_price or 0
end

function set_unit_start_price(amount)
	local settings = read_settings()
	settings.start_price = amount
	write_settings(settings)
end

function get_unit_buyout_price()
	return selected_item and read_settings().buyout_price or 0
end

function set_unit_buyout_price(amount)
	local settings = read_settings()
	settings.buyout_price = amount
	write_settings(settings)
end

function update_inventory_listing()
	local records = aux.values(aux.filter(aux.copy(inventory_records), function(record)
		local settings = read_settings(record.key)
		return record.aux_quantity > 0 and (not settings.hidden or show_hidden_checkbox:GetChecked() or aux.account_data.showhidden)
	end))
	sort(records, function(a, b) return a.name < b.name end)
	item_listing.populate(inventory_listing, records)
end

function update_auction_listing(listing, records, reference)
	local rows = T.acquire()
	if selected_item then
		local historical_value = history.value(selected_item.key)
		local stack_size = stack_size_slider:GetValue()
		for _, record in records[selected_item.key] or T.empty do
			local price_color = undercut(record, stack_size_slider:GetValue(), listing == 'bid') < reference and aux.color.red
			local price = record.unit_price * (listing == 'bid' and record.stack_size / stack_size_slider:GetValue() or 1)
			tinsert(rows, T.map(
				'cols', T.list(
				T.map('value', record.own and aux.color.green(record.count) or record.count),
				T.map('value', al.time_left(record.duration)),
				T.map('value', record.stack_size == stack_size and aux.color.green(record.stack_size) or record.stack_size),
				T.map('value', money.to_string(price, true, nil, price_color)),
				T.map('value', historical_value and gui.percentage_historical(aux.round(price / historical_value * 100)) or '---')
			),
				'record', record
			))
		end
		if historical_value then
			tinsert(rows, T.map(
				'cols', T.list(
				T.map('value', '---'),
				T.map('value', '---'),
				T.map('value', '---'),
				T.map('value', money.to_string(historical_value, true, nil, aux.color.green)),
				T.map('value', historical_value and gui.percentage_historical(100) or '---')
			),
				'record', T.map('historical_value', true, 'stack_size', stack_size, 'unit_price', historical_value, 'own', true)
			))
		end
		sort(rows, function(a, b)
			return sort_util.multi_lt(
				a.record.unit_price * (listing == 'bid' and a.record.stack_size or 1),
				b.record.unit_price * (listing == 'bid' and b.record.stack_size or 1),

				a.record.historical_value and 1 or 0,
				b.record.historical_value and 1 or 0,

				b.record.own and 0 or 1,
				a.record.own and 0 or 1,

				a.record.stack_size,
				b.record.stack_size,

				a.record.duration,
				b.record.duration
			)
		end)
	end
	if listing == 'bid' then
		bid_listing:SetData(rows)
	elseif listing == 'buyout' then
		buyout_listing:SetData(rows)
	end
end

function update_auction_listings()
	update_auction_listing('bid', bid_records, get_unit_start_price())
	update_auction_listing('buyout', buyout_records, get_unit_buyout_price())
end

function M.select_item(item_key)
    for _, inventory_record in aux.filter(aux.copy(inventory_records), function(record) return record.aux_quantity > 0 end) do
        if inventory_record.key == item_key then
            update_item(inventory_record)
            return
        end
    end
end

function price_update()
    if selected_item then
        local historical_value = history.value(selected_item.key)
        if get_bid_selection() or get_buyout_selection() then
	        set_unit_start_price(undercut(get_bid_selection() or get_buyout_selection(), stack_size_slider:GetValue(), get_bid_selection()))
	        unit_start_price_input:SetText(money.to_string(get_unit_start_price(), true, nil, nil, true))
        end
        if get_buyout_selection() then
	        set_unit_buyout_price(undercut(get_buyout_selection(), stack_size_slider:GetValue()))
	        unit_buyout_price_input:SetText(money.to_string(get_unit_buyout_price(), true, nil, nil, true))
        end
        start_price_percentage:SetText(historical_value and gui.percentage_historical(aux.round(get_unit_start_price() / historical_value * 100)) or '---')
        buyout_price_percentage:SetText(historical_value and gui.percentage_historical(aux.round(get_unit_buyout_price() / historical_value * 100)) or '---')
    end
end

function post_auctions()
	if selected_item then
        local unit_start_price = get_unit_start_price()
        local unit_buyout_price = get_unit_buyout_price()
        local stack_size = stack_size_slider:GetValue()
        local stack_count
        stack_count = stack_count_slider:GetValue()
        local duration = UIDropDownMenu_GetSelectedValue(duration_dropdown)
		local key = selected_item.key

        local duration_code
		if duration == DURATION_2 then
            duration_code = 2
		elseif duration == DURATION_8 then
            duration_code = 3
		elseif duration == DURATION_24 then
            duration_code = 4
		end

		post.start(
			key,
			stack_size,
			duration,
            unit_start_price,
            unit_buyout_price,
			stack_count,
			function(posted)
				if not frame:IsShown() then
					return
				end
				for i = 1, posted do
                    record_auction(key, stack_size, unit_start_price * stack_size, unit_buyout_price, duration_code, UnitName'player')
                end
                update_inventory_records()
				local same
                for _, record in inventory_records do
                    if record.key == key then
	                    same = record
	                    break
                    end
                end
                if same then
	                update_item(same)
                else
                    selected_item = nil
                end
                refresh = true
			end
		)
	end
end

function M.post_auctions_bind()
	if selected_item then
        local unit_start_price = get_unit_start_price()
        local unit_buyout_price = get_unit_buyout_price()
        local stack_size = stack_size_slider:GetValue()
        local stack_count
        stack_count = stack_count_slider:GetValue()
        local duration = UIDropDownMenu_GetSelectedValue(duration_dropdown)
		local key = selected_item.key

        local duration_code
		if duration == DURATION_2 then
            duration_code = 2
		elseif duration == DURATION_8 then
            duration_code = 3
		elseif duration == DURATION_24 then
            duration_code = 4
		end

		post.start(
			key,
			stack_size,
			duration,
            unit_start_price,
            unit_buyout_price,
			stack_count,
			function(posted)
				if not frame:IsShown() then
					return
				end
				for i = 1, posted do
                    record_auction(key, stack_size, unit_start_price * stack_size, unit_buyout_price, duration_code, UnitName'player')
                end
                update_inventory_records()
				local same
                for _, record in inventory_records do
                    if record.key == key then
	                    same = record
	                    break
                    end
                end
                if same then
	                update_item(same)
                else
                    selected_item = nil
                end
                refresh = true
			end
		)
	end
end

function validate_parameters()
    if not selected_item then
        post_button:Disable()
        return
    end
    if get_unit_buyout_price() > 0 and get_unit_start_price() > get_unit_buyout_price() then
        post_button:Disable()
        return
    end
    if get_unit_start_price() == 0 then
        post_button:Enable()
        return
    end
    if stack_count_slider:GetValue() == 0 then
        post_button:Disable()
        return
    end
    post_button:Enable()
end

function update_item_configuration()
	if not selected_item then
        refresh_button:Disable()

        item.texture:SetTexture(nil)
        item.count:SetText()
        item.name:SetTextColor(aux.color.label.enabled())
        item.name:SetText('No item selected')

        unit_start_price_input:Hide()
        unit_buyout_price_input:Hide()
        stack_size_slider:Hide()
        stack_count_slider:Hide()
        deposit:Hide()
        duration_dropdown:Hide()
        hide_checkbox:Hide()
        vendor_price_label:Hide()
    else
		unit_start_price_input:Show()
        unit_buyout_price_input:Show()
        stack_size_slider:Show()
        stack_count_slider:Show()
        deposit:Show()
        duration_dropdown:Show()
        hide_checkbox:Show()
        vendor_price_label:Show()

        item.texture:SetTexture(selected_item.texture)
        item.name:SetText('[' .. selected_item.name .. ']')
		do
	        local color = ITEM_QUALITY_COLORS[selected_item.quality]
	        item.name:SetTextColor(color.r, color.g, color.b)
        end
		if selected_item.aux_quantity > 1 then
            item.count:SetText(selected_item.aux_quantity)
		else
            item.count:SetText()
        end

        stack_size_slider.editbox:SetNumber(stack_size_slider:GetValue())
        stack_count_slider.editbox:SetNumber(stack_count_slider:GetValue())

        do
            local deposit_factor = 0.025
            local duration_factor = UIDropDownMenu_GetSelectedValue(duration_dropdown) / 120
            local stack_size, stack_count = selected_item.max_charges and 1 or stack_size_slider:GetValue(), stack_count_slider:GetValue()
            local max_stack = selected_item.max_stack
            local amount = floor(selected_item.unit_vendor_price * stack_size * duration_factor * (1 + (max_stack - stack_size) * 0.05) * deposit_factor) * stack_count
            deposit:SetText('Deposit: ' .. money.to_string(amount, nil, nil, aux.color.text.enabled))
        end

        --vendor price
        do
            local unit_vendor_price = selected_item.unit_vendor_price
            if not unit_vendor_price then
                vendor_price_label:SetText("Unit Vendor Price: N/A")
            elseif unit_vendor_price == 0 then
                vendor_price_label:SetText("Unit Vendor Price: None")
            else
                vendor_price_label:SetText("Unit Vendor Price: " .. money.to_string(unit_vendor_price, nil, nil, aux.color.text.enabled))
            end
        end

        refresh_button:Enable()
	end
end

function undercut(record, stack_size, stack)
    local price = ceil(record.unit_price * (stack and record.stack_size or stack_size))
    if not record.own then
        if aux.account_data.undercut then
            price = price - 1
        end
    end
    return price / stack_size
end

function quantity_update(maximize_count)
    if selected_item then
        local max_stack_count = selected_item.max_charges and selected_item.availability[stack_size_slider:GetValue()] or floor(selected_item.availability[0] / stack_size_slider:GetValue())
        stack_count_slider:SetMinMaxValues(1, max_stack_count)
        if maximize_count then
            stack_count_slider:SetValue(max_stack_count)
        end
    end
    refresh = true
end

function unit_vendor_price(item_key)
    for slot in info.inventory() do
	    T.temp(slot)
        local item_info = T.temp-info.container_item(unpack(slot))
        if item_info and item_info.item_key == item_key then
            if info.auctionable(item_info.tooltip, nil, true) and not item_info.lootable then
                ClearCursor()
                PickupContainerItem(unpack(slot))
                ClickAuctionSellItemButton()
                local auction_sell_item = T.temp-info.auction_sell_item()
                ClearCursor()
                ClickAuctionSellItemButton()
                ClearCursor()
                if auction_sell_item then
                    return auction_sell_item.vendor_price / auction_sell_item.count
                end
            end
        end
    end
end

function update_item(item)
    local settings = read_settings(item.key)

    item.unit_vendor_price = unit_vendor_price(item.key)
    if not item.unit_vendor_price then
        settings.hidden = true
        write_settings(settings, item.key)
        refresh = true
        return
    end

    scan.abort(scan_id)

    selected_item = item

    UIDropDownMenu_Initialize(duration_dropdown, initialize_duration_dropdown)
    UIDropDownMenu_SetSelectedValue(duration_dropdown, settings.duration)

    hide_checkbox:SetChecked(settings.hidden)
	
	local ii = 1
	if selected_item.max_charges then
		for i = selected_item.max_charges, 1, -1 do
			if selected_item.availability[i] > 0 then
				stack_size_slider:SetMinMaxValues(1, i)
				ii=i
				break
			end
		end
	else
		ii = min(selected_item.max_stack, selected_item.aux_quantity)
		stack_size_slider:SetMinMaxValues(1, min(selected_item.max_stack, selected_item.aux_quantity))
	end
		
	if not aux.account_data.post_stack then
		-- post_stack OFF: Always use full/max stack size
		stack_size_slider:SetValue(aux.huge)
	else
		-- post_stack ON: Use saved stack size if available, otherwise full stack
		local settings = read_settings(selected_item.key)
		if settings.stack_size and settings.stack_size > 0 and settings.stack_size <= ii then
			stack_size_slider:SetValue(settings.stack_size)
		else
			stack_size_slider:SetValue(aux.huge)
		end
	end

    quantity_update(true)

    unit_start_price_input:SetText(money.to_string(settings.start_price, true, nil, nil, true))
    unit_buyout_price_input:SetText(money.to_string(settings.buyout_price, true, nil, nil, true))

    if not bid_records[selected_item.key] then
        refresh_entries()
    end

    write_settings(settings, item.key)

    refresh = true
end

function update_inventory_records()
    local auctionable_map = T.temp-T.acquire()
    for slot in info.inventory() do
	    T.temp(slot)
	    local item_info = T.temp-info.container_item(unpack(slot))
        if item_info then
            local charge_class = item_info.charges or 0
            if info.auctionable(item_info.tooltip, nil, true) and not item_info.lootable then
                if not auctionable_map[item_info.item_key] then
                    local availability = T.acquire()
                    for i = 0, 10 do
                        availability[i] = 0
                    end
                    availability[charge_class] = item_info.count
                    auctionable_map[item_info.item_key] = T.map(
	                    'item_id', item_info.item_id,
	                    'suffix_id', item_info.suffix_id,
	                    'key', item_info.item_key,
	                    'itemstring', item_info.itemstring,
	                    'name', item_info.name,
	                    'texture', item_info.texture,
	                    'quality', item_info.quality,
	                    'aux_quantity', item_info.charges or item_info.count,
	                    'max_stack', item_info.max_stack,
	                    'max_charges', item_info.max_charges,
	                    'availability', availability
                    )
                else
                    local auctionable = auctionable_map[item_info.item_key]
                    auctionable.availability[charge_class] = (auctionable.availability[charge_class] or 0) + item_info.count
                    auctionable.aux_quantity = auctionable.aux_quantity + (item_info.charges or item_info.count)
                end
            end
        end
    end
    T.release(inventory_records)
    inventory_records = aux.values(auctionable_map)
    refresh = true
end

function refresh_entries()
	if selected_item then
        local item_key = selected_item.key
        local item_id = selected_item.item_id
		set_bid_selection()
        set_buyout_selection()
        bid_records[item_key], buyout_records[item_key] = nil, nil

        -- Reset buying state
        scan.abort(buy_scan_id)
        buy_state = IDLE
        found_auction_record = nil
        found_auction_index = nil

        -- Clear old raw records for this item
        if raw_auction_records[item_key] then
            T.release(raw_auction_records[item_key])
            raw_auction_records[item_key] = nil
        end

        -- Check shared cache first
        local cached_records = auction_cache.get(item_id)
        if cached_records then
            -- Use cached records to populate bid/buyout records
            local local_raw_records = T.acquire()
            for _, record in cached_records do
                if record.item_key == item_key then
                    -- Copy record for local storage
                    local copy = T.acquire()
                    for k, v in record do
                        copy[k] = v
                    end
                    tinsert(local_raw_records, copy)
                    record_auction(
                        record.item_key,
                        record.aux_quantity,
                        record.unit_blizzard_bid,
                        record.unit_buyout_price,
                        record.duration,
                        record.owner
                    )
                end
            end
            bid_records[item_key] = bid_records[item_key] or T.acquire()
            buyout_records[item_key] = buyout_records[item_key] or T.acquire()
            raw_auction_records[item_key] = local_raw_records
            refresh = true
            status_bar:update_status(1, 1)
            status_bar:set_text('Loaded from cache')
            return
        end

        local query = scan_util.item_query(item_id)
        status_bar:update_status(0, 0)
        status_bar:set_text('Scanning auctions...')

        -- Collect raw auction records for shared cache and buying
        local raw_records = T.acquire()

		scan_id = scan.start{
            type = 'list',
            ignore_owner = true,
			queries = T.list(query),
			on_page_loaded = function(page, total_pages)
                status_bar:update_status(page / total_pages, 0) -- TODO
                status_bar:set_text(format('Scanning Page %d / %d', page, total_pages))
			end,
			on_auction = function(auction_record)
				if auction_record.item_key == item_key then
                    -- Store raw record for shared cache and buying
                    tinsert(raw_records, auction_record)
                    record_auction(
                        auction_record.item_key,
                        auction_record.aux_quantity,
                        auction_record.unit_blizzard_bid,
                        auction_record.unit_buyout_price,
                        auction_record.duration,
                        auction_record.owner
                    )
				end
			end,
			on_abort = function()
				bid_records[item_key], buyout_records[item_key] = nil, nil
                T.release(raw_records)
                status_bar:update_status(1, 1)
                status_bar:set_text('Scan aborted')
			end,
			on_complete = function()
				bid_records[item_key] = bid_records[item_key] or T.acquire()
				buyout_records[item_key] = buyout_records[item_key] or T.acquire()
                -- Store raw records in shared cache for search tab
                auction_cache.set(item_id, raw_records)
                -- Also keep local copy for buying (don't release, just copy reference)
                raw_auction_records[item_key] = raw_records
                refresh = true
                status_bar:update_status(1, 1)
                status_bar:set_text('Scan complete')
            end,
		}
	end
end

function record_auction(key, aux_quantity, unit_blizzard_bid, unit_buyout_price, duration, owner)
    bid_records[key] = bid_records[key] or T.acquire()
    do
	    local entry
	    for _, record in bid_records[key] do
	        if unit_blizzard_bid == record.unit_price and aux_quantity == record.stack_size and duration == record.duration and info.is_player(owner) == record.own then
	            entry = record
	        end
	    end
	    if not entry then
	        entry = T.map('stack_size', aux_quantity, 'unit_price', unit_blizzard_bid, 'duration', duration, 'own', info.is_player(owner), 'count', 0)
	        tinsert(bid_records[key], entry)
	    end
	    entry.count = entry.count + 1
    end
    buyout_records[key] = buyout_records[key] or T.acquire()
    if unit_buyout_price == 0 then return end
    do
	    local entry
	    for _, record in buyout_records[key] do
		    if unit_buyout_price == record.unit_price and aux_quantity == record.stack_size and duration == record.duration and info.is_player(owner) == record.own then
			    entry = record
		    end
	    end
	    if not entry then
		    entry = T.map('stack_size', aux_quantity, 'unit_price', unit_buyout_price, 'duration', duration, 'own', info.is_player(owner), 'count', 0)
		    tinsert(buyout_records[key], entry)
	    end
	    entry.count = entry.count + 1
    end
end

-- Find a raw auction record matching the aggregated buyout selection
function find_matching_raw_record()
    if not selected_item or not get_buyout_selection() then return nil end

    local selection = get_buyout_selection()
    if selection.historical_value then return nil end  -- Can't buy historical value row

    local records = raw_auction_records[selected_item.key]
    if not records then return nil end

    -- Find a raw record matching the selection criteria
    for _, record in records do
        if record.unit_buyout_price == selection.unit_price
           and record.aux_quantity == selection.stack_size
           and record.duration == selection.duration
           and not info.is_player(record.owner) then  -- Can't buy from yourself
            return record
        end
    end
    return nil
end

-- Find the auction in the AH for buying
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
            -- Remove the record from raw_auction_records since it's gone
            if selected_item and raw_auction_records[selected_item.key] then
                for i, r in raw_auction_records[selected_item.key] do
                    if r == record then
                        tremove(raw_auction_records[selected_item.key], i)
                        break
                    end
                end
            end
        end,
        function(index)  -- on_success
            buy_state = FOUND
            found_auction_record = record
            found_auction_index = index

            -- Configure buyout button
            buyout_button:SetScript('OnClick', function()
                if scan_util.test(record, index) then
                    aux.place_bid('list', index, record.buyout_price, function()
                        -- Remove from raw records
                        if selected_item and raw_auction_records[selected_item.key] then
                            for i, r in raw_auction_records[selected_item.key] do
                                if r == record then
                                    tremove(raw_auction_records[selected_item.key], i)
                                    break
                                end
                            end
                        end
                        -- Decrement count in aggregated record
                        local selection = get_buyout_selection()
                        if selection then
                            selection.count = selection.count - 1
                            if selection.count <= 0 then
                                set_buyout_selection()
                            end
                        end
                        buy_state = IDLE
                        found_auction_record = nil
                        found_auction_index = nil
                        refresh = true
                    end)
                end
            end)
            buyout_button:Enable()
        end
    )
end

function on_update()
    if refresh then
        refresh = false
        price_update()
        update_item_configuration()
        update_inventory_listing()
        update_auction_listings()
    end
    validate_parameters()

    -- Handle buying state
    if buy_state == IDLE or buy_state == SEARCHING then
        buyout_button:Disable()
    end

    if buy_state == SEARCHING then return end

    local selection = get_buyout_selection()
    if not selection or selection.historical_value or selection.own then
        buy_state = IDLE
        buyout_button:Disable()
    elseif buy_state == IDLE then
        local raw_record = find_matching_raw_record()
        if raw_record then
            find_auction_for_buy(raw_record)
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

function initialize_duration_dropdown()
    local function on_click()
        UIDropDownMenu_SetSelectedValue(duration_dropdown, this.value)
        local settings = read_settings()
        settings.duration = this.value
        write_settings(settings)
        refresh = true
    end
    UIDropDownMenu_AddButton{
        text = '6 Hours',
        value = DURATION_2,
        func = on_click,
    }
    UIDropDownMenu_AddButton{
        text = '24 Hours',
        value = DURATION_8,
        func = on_click,
    }
    UIDropDownMenu_AddButton{
        text = '72 Hours',
        value = DURATION_24,
        func = on_click,
    }
end
