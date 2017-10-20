local pb			= require "protobuf"
local log			= require "log"
local utils			= require "utils"
local MultiTable	= require "MultiTable"
local MServer		= require "MServer"
local Config		= require "Config"
local cjson			= require "cjson"
local Table			= require "myTable"
local TableManager = {}

local table_mgr = {}
local playTables = {}

function TableManager.new(sid)
    local m = {}
    TableManager.__index = TableManager
    setmetatable(m, TableManager)
	m:init(sid)
    return m
end

function TableManager:init(sid)
		local t = Table.new(sid,1)
		print(t:getSitSize())
		for uid=100, 103 do
			t:sit(uid,nil,10,nil,nil)
		end
		t:start()
		if t then
			table_mgr[1] = t
		end
end

--[[function TableManager:init(sid)
	for tid=1 , 1 do
		local t = Table.new(sid,tid)
		local t = Table.new(sid,1)
		if t then
			table_mgr[tid] = t
		end
	end
end]]--

function TableManager:getTableById(tid)
	return table_mgr[tid]
end

function TableManager:useTable(tid)
	local t = table_mgr[tid]
	if t then
		playTables[tid] = t
		table_mgr[tid] = nil
	end
end

function TableManager:backTable(tid)
	local t = playTables[tid]
	if t then
		table_mgr[tid] = t
		playTables[tid] = nil
	end
end
return TableManager
