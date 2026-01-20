if module 'T' then return end

local next, getn, setn, tremove, setmetatable = next, getn, table.setn, tremove, setmetatable

local wipe, acquire, release
local pool, pool_size, overflow_pool, auto_release = {}, 0, setmetatable({}, {__mode='k'}), {}

function wipe(t)
	setmetatable(t, nil)
	for k in t do
		t[k] = nil
	end
	t.reset, t.reset = nil, 1
	t.reset = nil
	setn(t, 0)
	-- DEBUG: Verify wipe worked
	local leftover = next(t)
	if leftover then
		DEFAULT_CHAT_FRAME:AddMessage(format('|cffff0000[T.wipe BUG] Table still has key after wipe: %s = %s|r', tostring(leftover), tostring(t[leftover])))
	end
end
M.wipe = wipe

function acquire()
	local t
	if pool_size > 0 then
		pool_size = pool_size - 1
		t = pool[pool_size + 1]
	else
		t = next(overflow_pool)
		if t then
			overflow_pool[t] = nil
		else
			return {}
		end
	end
	-- DEBUG: Verify acquired table is clean
	local leftover = next(t)
	if leftover then
		DEFAULT_CHAT_FRAME:AddMessage(format('|cffff0000[T.acquire BUG] Pooled table has stale key: %s = %s|r', tostring(leftover), tostring(t[leftover])))
		-- Clean it before returning
		for k in t do
			t[k] = nil
		end
		setn(t, 0)
	end
	return t
end
M.acquire = acquire

local f = CreateFrame('Frame', 'AuxGCFrame')
local function AuxGCFrame_OnUpdate()
	for t in auto_release do
		release(t)
	end
	wipe(auto_release)
	this:SetScript("OnUpdate", nil) -- Remove the script, it will be set back if anything is added to auto_release
end
local function autoRelease(t)
	auto_release[t] = true
	f:SetScript("OnUpdate", AuxGCFrame_OnUpdate)
end

function release(t)
	wipe(t)
	auto_release[t] = nil
	if pool_size < 200 then
		pool_size = pool_size + 1
		pool[pool_size] = t
	else
		overflow_pool[t] = true
	end
end
M.release = release

do
	local function f(_, v)
		if v then
			autoRelease(v)
			return v
		end
	end
	M.temp = setmetatable({}, {__metatable=false, __newindex=pass, __call=f, __sub=f})
end
do
	local function f(_, v)
		if v then
			auto_release[v] = nil
			return v
		end
	end
	M.static = setmetatable({}, {__metatable=false, __newindex=pass, __call=f, __sub=f})
end

do
	local function unpack(t)
		if getn(t) > 0 then
			return tremove(t, 1), unpack(t)
		else
			release(t)
		end
	end
	M.unpack = unpack
end

M.empty = setmetatable({}, {__metatable=false, __newindex=pass})

local vararg
do
	local MAXPARAMS = 100

	local code = [[
		local f, setn, acquire, autoRelease = f, setn, acquire, autoRelease
		return function(
	]]
	for i = 1, MAXPARAMS - 1 do
		code = code .. format('a%d,', i)
	end
	code = code .. [[
		overflow)
		if overflow ~= nil then error("T-vararg overflow.", 2) end
		local n = 0
		repeat
	]]
	for i = MAXPARAMS - 1, 1, -1 do
		code = code .. format('if a%1$d ~= nil then n = %1$d; break end;', i)
	end
	code = code .. [[
		until true
		local t = acquire()
		autoRelease(t)
		setn(t, n)
		repeat
	]]
	for i = 1, MAXPARAMS - 1 do
		code = code .. format('if %1$d > n then break end; t[%1$d] = a%1$d;', i)
	end
	code = code .. [[
		until true
		return f(t)
		end
	]]

	local chunk = loadstring(code)
	local chunkEnv = {setn=setn, acquire=acquire, auto_release=auto_release, autoRelease=autoRelease}
	setfenv(chunk, chunkEnv)
	function vararg(f)
		chunkEnv.f = f
		return chunk()
	end
	M.vararg = setmetatable({}, {
		__metatable = false,
		__sub = function(_, v)
			return vararg(v)
		end,
	})
end

M.list = vararg(function(arg)
	auto_release[arg] = nil
	return arg
end)
M.set = vararg(function(arg)
	local t = acquire()
	for _, v in arg do
		t[v] = true
	end
	return t
end)
M.map = vararg(function(arg)
	local t = acquire()
	for i = 1, getn(arg), 2 do
		t[arg[i]] = arg[i + 1]
	end
	return t
end)