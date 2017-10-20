local log		= require "log"
local utils		= require "utils"
local pb		= require("protobuf")
local Table		= require("Table")
local TableManager = require("TableManager")

function init()
	local sid = G.sid()
	TableManager.new(sid)
end

init()

