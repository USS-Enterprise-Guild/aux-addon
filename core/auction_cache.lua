module 'aux.core.auction_cache'

local T = require 'T'
local aux = require 'aux'

-- Cache structure: item_id -> { records = {...}, timestamp = time }
local cache = {}

-- Cache expiry time in seconds (5 minutes)
local CACHE_EXPIRY = 300

function aux.handle.CLOSE()
	clear()
end

function M.get(item_id)
	local entry = cache[item_id]
	if entry and GetTime() - entry.timestamp < CACHE_EXPIRY then
		return entry.records
	end
	return nil
end

function M.set(item_id, records)
	-- Deep copy the records so the cache has its own copy
	local cached_records = T.acquire()
	for _, record in records do
		-- Copy the record so modifications don't affect the cache
		local copy = T.acquire()
		for k, v in record do
			copy[k] = v
		end
		tinsert(cached_records, copy)
	end

	-- Release old cache entry if exists
	if cache[item_id] then
		for _, record in cache[item_id].records do
			T.release(record)
		end
		T.release(cache[item_id].records)
	end

	cache[item_id] = {
		records = cached_records,
		timestamp = GetTime(),
	}
end

function M.clear()
	for item_id, entry in cache do
		for _, record in entry.records do
			T.release(record)
		end
		T.release(entry.records)
	end
	cache = {}
end

function M.invalidate(item_id)
	local entry = cache[item_id]
	if entry then
		for _, record in entry.records do
			T.release(record)
		end
		T.release(entry.records)
		cache[item_id] = nil
	end
end
