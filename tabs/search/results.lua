module 'aux.tabs.search'

local T = require 'T'
local aux = require 'aux'
local info = require 'aux.util.info'
local filter_util = require 'aux.util.filter'
local scan_util = require 'aux.util.scan'
local scan = require 'aux.core.scan'
local auction_cache = require 'aux.core.auction_cache'
local gui = require 'aux.gui'

search_scan_id = 0

function aux.handle.LOAD()
	new_search()
end

-- Check if filter is an exact item search and return item_id if so
function get_exact_item_id(filter_string)
	-- Parse the filter to check if it's an exact item search
	local filter = filter_util.parse_filter_string(filter_string)
	if not filter or not filter.blizzard then return nil end

	-- Must have exact flag and a name
	if not filter.blizzard.exact or not filter.blizzard.name then return nil end

	-- Get item_id from the name
	return info.item_id(filter.blizzard.name)
end

function update_real_time(enable)
	if enable then
		range_button:Hide()
		real_time_button:Show()
		search_box:SetPoint('LEFT', real_time_button, 'RIGHT', gui.is_blizzard() and 8 or 4, 0)
	else
		real_time_button:Hide()
		range_button:Show()
		search_box:SetPoint('LEFT', last_page_input, 'RIGHT', gui.is_blizzard() and 8 or 4, 0)
	end
end

do
	local searches = {}
	local search_index = 1

	function current_search()
		return searches[search_index]
	end

	function aux.handle.CLOSE()
		for _, search in searches do
			if search.records then
				T.release(search.records)
				search.records = nil
			end
		end
		searches = {}
		search_index = 1
	end

	function update_search(index)
		-- Hide all search UI elements first to prevent overlap
		for _, search in searches do
			search.status_bar:Hide()
			search.table:Hide()
		end
		searches[search_index].table:SetSelectedRecord()

		search_index = index

		searches[search_index].status_bar:Show()
		searches[search_index].table:Show()

		search_box:SetText(searches[search_index].filter_string or '')
		first_page_input:SetText(searches[search_index].first_page and searches[search_index].first_page + 1 or '')
		last_page_input:SetText(searches[search_index].last_page and searches[search_index].last_page + 1 or '')
		if search_index == 1 then
			previous_button:Disable()
		else
			previous_button:Enable()
		end
		if search_index == getn(searches) then
			next_button:Hide()
			range_button:SetPoint('LEFT', previous_button, 'RIGHT', 4, 0)
			real_time_button:SetPoint('LEFT', previous_button, 'RIGHT', 4, 0)
		else
			next_button:Show()
			range_button:SetPoint('LEFT', next_button, 'RIGHT', 4, 0)
			real_time_button:SetPoint('LEFT', next_button, 'RIGHT', 4, 0)
		end
		update_real_time(searches[search_index].real_time)
		update_start_stop()
		update_continuation()
	end

	function new_search(filter_string, first_page, last_page, real_time)
		while getn(searches) > search_index do
			tremove(searches)
		end
		local search = T.map('records', T.acquire(), 'filter_string', filter_string, 'first_page', first_page, 'last_page', last_page, 'real_time', real_time)
		tinsert(searches, search)
		if getn(searches) > 5 then
			tremove(searches, 1)
			tinsert(status_bars, tremove(status_bars, 1))
			tinsert(tables, tremove(tables, 1))
			search_index = 4
		end

		search.status_bar = status_bars[getn(searches)]
		search.status_bar:update_status(1, 1)
		search.status_bar:set_text('')

		search.table = tables[getn(searches)]
		search.table:SetSort(1, 2, 3, 4, 5, 6, 7, 8, 9)
		search.table:Reset()
		search.table:SetDatabase(search.records)

		update_search(getn(searches))
	end

	function clear_control_focus()
		search_box:ClearFocus()
		first_page_input:ClearFocus()
		last_page_input:ClearFocus()
	end

	function previous_search()
		clear_control_focus()
		update_search(search_index - 1)
		set_subtab(RESULTS)
	end

	function next_search()
		clear_control_focus()
		update_search(search_index + 1)
		set_subtab(RESULTS)
	end
end

function update_continuation()
	if current_search().continuation then
		resume_button:Show()
		search_box:SetPoint('RIGHT', resume_button, 'LEFT', -4, 0)
	else
		resume_button:Hide()
		search_box:SetPoint('RIGHT', start_button, 'LEFT', -4, 0)
	end
end

function discard_continuation()
	scan.abort(search_scan_id)
	current_search().continuation = nil
	update_continuation()
end

function update_start_stop()
	if current_search().active then
		stop_button:Show()
		start_button:Hide()
	else
		start_button:Show()
		stop_button:Hide()
	end
end

function start_real_time_scan(query, search, continuation)

	local ignore_page
	if not search then
		search = current_search()
		query.blizzard_query.first_page = tonumber(continuation) or 0
		query.blizzard_query.last_page = tonumber(continuation) or 0
		ignore_page = not tonumber(continuation)
	end

	local next_page
	local new_records = T.acquire()
	search_scan_id = scan.start{
		type = 'list',
		queries = {query},
		auto_buy_validator = search.auto_buy_validator,
		auto_bid_validator = search.auto_bid_validator,
		on_scan_start = function()
			search.status_bar:update_status(.9999, .9999)
			search.status_bar:set_text('Scanning last page ...')
		end,
		on_page_loaded = function(_, _, last_page)
			next_page = last_page
			if last_page == 0 then
				ignore_page = false
			end
		end,
		on_auction = function(auction_record)
			if not ignore_page then
				-- DEBUG: Validate auction_record before inserting
				if type(auction_record) ~= 'table' then
					aux.print(format('|cffff0000[RT SCAN BUG] on_auction received non-table: %s (type: %s)|r', tostring(auction_record), type(auction_record)))
				else
					tinsert(new_records, auction_record)
				end
			end
		end,
		on_complete = function()
			local map = T.temp-T.acquire()
			for k, record in search.records do
				if type(record) ~= 'table' then
					aux.print(format('|cffff0000[RT BUG] search.records[%s] = %s (type: %s)|r', tostring(k), tostring(record), type(record)))
				else
					map[record.sniping_signature] = record
				end
			end
			for k, record in new_records do
				if type(record) ~= 'table' then
					aux.print(format('|cffff0000[RT BUG] new_records[%s] = %s (type: %s)|r', tostring(k), tostring(record), type(record)))
				else
					map[record.sniping_signature] = record
				end
			end
			T.release(new_records)
			new_records = aux.values(map)

			if getn(new_records) > 2000 then
				StaticPopup_Show('AUX_SEARCH_TABLE_FULL')
			else
				search.records = new_records
				search.table:SetDatabase(search.records)
			end

			query.blizzard_query.first_page = next_page
			query.blizzard_query.last_page = next_page
			start_real_time_scan(query, search)
		end,
		on_abort = function()
			search.status_bar:update_status(1, 1)
			search.status_bar:set_text('Scan paused')

			search.continuation = next_page or not ignore_page and query.blizzard_query.first_page or true

			if current_search() == search then
				update_continuation()
			end

			search.active = false
			update_start_stop()
		end,
	}
end

function start_search(queries, continuation, cache_item_id)
	local current_query, current_page, total_queries, start_query, start_page

	local search = current_search()

	total_queries = getn(queries)

	if continuation then
		start_query, start_page = unpack(continuation)
		for i = 1, start_query - 1 do
			tremove(queries, 1)
		end
		queries[1].blizzard_query.first_page = (queries[1].blizzard_query.first_page or 0) + start_page - 1
		search.table:SetSelectedRecord()
	else
		start_query, start_page = 1, 1
	end


	search_scan_id = scan.start{
		type = 'list',
		queries = queries,
		auto_buy_validator = search.auto_buy_validator,
		auto_bid_validator = search.auto_bid_validator,
		on_scan_start = function()
			search.status_bar:update_status(0, 0)
			if continuation then
				search.status_bar:set_text('Resuming scan...')
			else
				search.status_bar:set_text('Scanning auctions...')
			end
		end,
		on_page_loaded = function(_, total_scan_pages)
			current_page = current_page + 1
			total_scan_pages = total_scan_pages + (start_page - 1)
			total_scan_pages = max(total_scan_pages, 1)
			current_page = min(current_page, total_scan_pages)
			search.status_bar:update_status((current_query - 1) / getn(queries), current_page / total_scan_pages)
			search.status_bar:set_text(format('Scanning %d / %d (Page %d / %d)', current_query, total_queries, current_page, total_scan_pages))
		end,
		on_page_scanned = function()
			search.table:SetDatabase()
		end,
		on_start_query = function(query)
			current_query = current_query and current_query + 1 or start_query
			current_page = current_page and 0 or start_page - 1
		end,
		on_auction = function(auction_record, ctrl)
			if getn(search.records) < 2000 then
				-- DEBUG: Validate auction_record before inserting
				if type(auction_record) ~= 'table' then
					aux.print(format('|cffff0000[SCAN BUG] on_auction received non-table: %s (type: %s)|r', tostring(auction_record), type(auction_record)))
				else
					tinsert(search.records, auction_record)
					if getn(search.records) == 2000 then
						StaticPopup_Show('AUX_SEARCH_TABLE_FULL')
					end
				end
			end
		end,
		on_complete = function()
			search.status_bar:update_status(1, 1)
			search.status_bar:set_text('Scan complete')

			-- Populate shared cache for exact item searches
			if cache_item_id then
				auction_cache.set(cache_item_id, search.records)
			end

			if current_search() == search and frame.results:IsVisible() and getn(search.records) == 0 then
				set_subtab(SAVED)
			end

			search.active = false
			update_start_stop()
		end,
		on_abort = function()
			search.status_bar:update_status(1, 1)
			search.status_bar:set_text('Scan paused')

			if current_query then
				search.continuation = {current_query, current_page + 1}
			else
				search.continuation = {start_query, start_page}
			end
			if current_search() == search then
				update_continuation()
			end

			search.active = false
			update_start_stop()
		end,
	}
end

function M.execute(resume, real_time)

	if resume then
		real_time = current_search().real_time
	elseif real_time == nil then
		real_time = real_time_button:IsShown()
	end

	if resume then
		search_box:SetText(current_search().filter_string)
	end
	local filter_string, first_page, last_page = search_box:GetText(), blizzard_page_index(first_page_input:GetText()), blizzard_page_index(last_page_input:GetText())

	local queries, error = filter_util.queries(filter_string)
	if not queries then
		aux.print('Invalid filter:', error)
		return
	elseif real_time then
		if getn(queries) > 1 then
			aux.print('Error: The real time mode does not support multi-queries')
			return
		elseif queries[1].blizzard_query.first_page or queries[1].blizzard_query.last_page then
			aux.print('Error: The real time mode does not support page ranges')
			return
		end
	end

	if resume then
		if current_search() then
			current_search().table:SetSelectedRecord()
		end
	else
		local cur = current_search()
		if not cur or filter_string ~= cur.filter_string then
			if cur and cur.filter_string then
				new_search(filter_string, first_page, last_page, real_time)
			elseif not cur then
				-- No search exists, create one
				new_search(filter_string, first_page, last_page, real_time)
			else
				cur.filter_string = filter_string
			end
			new_recent_search(filter_string, aux.join(aux.map(aux.copy(queries), function(filter) return filter.prettified end), ';'))
		else
			-- Re-searching same filter - invalidate cache to get fresh data
			local item_id = get_exact_item_id(filter_string)
			if item_id then
				auction_cache.invalidate(item_id)
			end
			local search = current_search()
			search.records = T.acquire()
			search.table:Reset()
			search.table:SetDatabase(search.records)
		end
		local search = current_search()
		if search then
			search.first_page = first_page
			search.last_page = last_page
			search.real_time = real_time
			search.auto_buy_validator = get_auto_buy_validator()
			search.auto_bid_validator = get_auto_bid_validator()
		end
	end

	local search = current_search()
	if not search then return end

	local continuation = resume and search.continuation
	discard_continuation()
	search.active = true
	update_start_stop()
	clear_control_focus()
	set_subtab(RESULTS)

	-- Check shared cache for exact item searches (not resuming, not real-time, single query, no page range)
	if not resume and not real_time and getn(queries) == 1 and not first_page and not last_page then
		local item_id = get_exact_item_id(filter_string)
		if item_id then
			local cached_records = auction_cache.get(item_id)
			if cached_records then
				-- Copy cached records and apply validator
				local validator = queries[1].validator
				for k, record in cached_records do
					-- DEBUG: Validate record from cache
					if type(record) ~= 'table' then
						aux.print(format('|cffff0000[CACHE LOAD BUG] cached_records[%s] = %s (type: %s)|r', tostring(k), tostring(record), type(record)))
					elseif not validator or validator(record) then
						if getn(search.records) < 2000 then
							-- Deep copy the record
							local copy = T.acquire()
							for ck, cv in record do
								copy[ck] = cv
							end
							tinsert(search.records, copy)
						end
					end
				end
				search.table:SetDatabase(search.records)
				search.status_bar:update_status(1, 1)
				search.status_bar:set_text('Loaded from cache')
				search.active = false
				update_start_stop()
				return
			end
		end
	end

	-- Track exact item searches to populate cache on completion
	local cache_item_id = nil
	if not resume and not real_time and getn(queries) == 1 and not first_page and not last_page then
		cache_item_id = get_exact_item_id(filter_string)
	end

	if real_time then
		start_real_time_scan(queries[1], nil, continuation)
	else
		for _, query in queries do
			query.blizzard_query.first_page = search.first_page
			query.blizzard_query.last_page = search.last_page
		end
		start_search(queries, continuation, cache_item_id)
	end
end

do
	local scan_id = 0
	local IDLE, SEARCHING, FOUND = aux.enum(3)
	local state = IDLE
	local found_index

	function find_auction(record)
		local search = current_search()
		if not search then return end

		if not search.table:ContainsRecord(record) or info.is_player(record.owner) then
			return
		end

		scan.abort(scan_id)
		state = SEARCHING
		scan_id = scan_util.find(
			record,
			current_search().status_bar,
			function()
				state = IDLE
			end,
			function()
				state = IDLE
				search.table:RemoveAuctionRecord(record)
			end,
			function(index)
				if search.table:GetSelection() and search.table:GetSelection().record ~= record then
					return
				end

				state = FOUND
				found_index = index

				if not record.high_bidder then
					bid_button:SetScript('OnClick', function()
						if scan_util.test(record, index) and search.table:ContainsRecord(record) then
							aux.place_bid('list', index, record.bid_price, record.bid_price < record.buyout_price and function()
								info.bid_update(record)
								search.table:SetDatabase()
							end or function() search.table:RemoveAuctionRecord(record) end)
						end
					end)
					bid_button:Enable()
				else
					bid_button:Disable()
				end

				if record.buyout_price > 0 then
					buyout_button:SetScript('OnClick', function()
						if scan_util.test(record, index) and search.table:ContainsRecord(record) then
							aux.place_bid('list', index, record.buyout_price, function() search.table:RemoveAuctionRecord(record) end)
						end
					end)
					buyout_button:Enable()
				else
					buyout_button:Disable()
				end
			end
		)
	end

	function on_update()
		if state == IDLE or state == SEARCHING then
			buyout_button:Disable()
			bid_button:Disable()
		end

		if state == SEARCHING then return end

		local search = current_search()
		if not search then return end
		local selection = search.table:GetSelection()
		if not selection then
			state = IDLE
		elseif selection and state == IDLE then
			find_auction(selection.record)
		elseif state == FOUND and not scan_util.test(selection.record, found_index) then
			buyout_button:Disable()
			bid_button:Disable()
			if not aux.bid_in_progress() then
				state = IDLE
			end
		end
	end
end