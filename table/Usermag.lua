--callback function definition
local pb = require "protobuf"
local log = require "log"
local Config = require "Config"
local Tmgr = require "TableManager"

BptLg = {}

function BptLg.processJoinTable(uid, linkid, msg)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)
    local p = pb.decode("network.cmd.PBReqJoinTable", rev.contentData)

    log.debug("processJoinTable uid:" .. uid)
    log.debug(string.format("idx:%d %d %d %d ", rev.idx.flag, rev.idx.mid, rev.idx.tid, rev.idx.time))

    local t = Tmgr.getTableById(rev.idx.tid)
    if t ~= nil then
        t:join(uid, linkid)
    else
        log.debug("t is nil")
    end
end

function BptLg.processLeaveTable(uid, linkid, msg)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)
    local p = pb.decode("network.cmd.PBReqLeaveTable", rev.contentData)
    log.debug("processLeaveTable UID:%d", uid)
    log.debug(string.format("idx:%d %d %d %d ", rev.idx.flag, rev.idx.mid, rev.idx.tid, rev.idx.time))

    local t = Tmgr.getTableById(rev.idx.tid)
	if t ~= nil then
        t:leave(uid)
    else
        log.debug("t is nil")
    end
end

function BptLg.processSitTable(uid, linkid, msg)
    log.debug("processSitTable %d", uid)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)

    local p = pb.decode("network.cmd.PBReqSit", rev.contentData)
	local t = Tmgr.getTableById(rev.idx.tid)

	if t ~= nil then
        local pos = p.sid
        local money = p.buyinMoney
        local autobuy = p.autoBuy
        t:sit(uid, pos, money, autobuy, escapebb)
    else
        log.debug("m is nil, mid:%d", rev.idx.mid)
    end

end

function BptLg.processStandTable(uid, linkid, msg)
    log.debug("processStandTable %d", uid)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)

    local p = pb.decode("network.cmd.PBReqStand", rev.contentData)
    local t = Tmgr.getTableById(rev.idx.tid)

    if t ~= nil then
        t:stand(uid)
    else
        log.debug("m is nil, mid:%d", rev.idx.mid)
    end
end

function BptLg.processGetInfoTable(uid, linkid, msg)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)
    local p = pb.decode("network.cmd.PBReqTableInfo", rev.contentData)
    log.debug("processGetInfoTable UID:%d",uid)
    log.debug(string.format("idx:%d %d %d %d", rev.idx.flag, rev.idx.mid, rev.idx.tid, rev.idx.time))

	local t = Tmgr.getTableById(rev.idx.tid)
	if t ~= nil then
		t:getInfo(uid)
	end

end

function BptLg.processChipinTable(uid, linkid, msg)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)
    local p = pb.decode("network.cmd.PBReqChipin", rev.contentData)
    log.debug("processChipinTable UID:%d", uid)

	local t = Tmgr.getTableById(rev.idx.tid)
    if t ~= nil then
        t:userchipin(uid, p.chipType, p.chipinMoney)
    end
end

function BptLg.processReservation(uid, linkid, msg)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)
    local p = pb.decode("network.cmd.PBReservationReq", rev.contentData)
    log.debug("processReservation UID:%d", uid)

    local t = Tmgr.getTableById(rev.idx.tid)
    if t ~= nil then
        t:reservation(uid, p.type)
    end
end

---------------------------------------------------------------------------------------


function BptLg.processReqMatchContent(uid, linkid, msg)
	--常规场屏蔽MatchContent
	if uid then
		return nil
	end
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)
    local p = pb.decode("network.cmd.PBTableMatchContentReq", rev.contentData)
    log.debug("usermsg.lua processReqMatchContent UID:%d", uid)

    local m = Match.getMatchById(rev.idx.mid)
    if m ~= nil then
        local content = m:getMatchContent(uid)

        local send_tb = {}
        send_tb.idx = {}
        send_tb.idx.flag = G.sid()
        send_tb.idx.mid  = rev.idx.mid
        send_tb.idx.tid  = rev.idx.tid
        send_tb.idx.time = 0
        send_tb.contentData = content

        if rev.context and rev.context.seq then
            send_tb.context = rev.context
        end

        local send_pb = pb.encode("network.cmd.PBTableCmd", send_tb)

        bpt.accli.send(linkid, uid, 0x0011, 0x1033, send_pb) -- PBTexasSubCmdID_RespMatchContent
    else
        log.debug("match is nil, mid:%d", rev.idx.mid)
    end
end

function BptLg.processRoomChat(uid, linkid, msg)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)

	local t = Tmgr.getTableById(rev.idx.tid)
    if t then
        t:roomchat(uid, msg.contentData)
    end
end

function BptLg.processGetRecentBoard(uid, linkid, msg)
    local rev = msg--pb.decode("network.cmd.PBTableCmd", msg)
end

function BptLg.processBuyin(uid, linkid, msg)
	log.debug("usermsg.lua processBuyin, %d", uid or -1)
end

function BptLg.processReqTables(uid, linkid, msg)
	log.debug("processReqTables")
	local rev = msg--pb.decode("network.cmd.PBReqTables", msg)

	local tables = {}
	tables.arr = {}
	tables.svid = G.sid()
	local match_mgr = Match:getMatchMgr()
	for matchid, match in pairs(match_mgr) do
		local arr_item = {}
		arr_item.index = {}
		local index_item = {}
		index_item.tid = {}
		index_item.time = match.starttime
		table.insert(index_item.tid, 1)
		table.insert(arr_item.index, index_item)
		arr_item.matchid = matchid
		arr_item.matchname = match.match_conf.name
		table.insert(tables.arr, arr_item)
	end
	--print_lua_table(tables)

	local resptables = {}
	resptables.param = rev.param
	resptables.size = rev.size
	resptables.cmdid = rev.cmdid
	resptables.jsonStr = cjson.encode(tables)
	--print_lua_table(resptables)
	return resptables
	--local send = pb.encode("network.cmd.PBRespTables", resptables)
    --bpt.mocli.send(linkid,
                    --pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
                    --pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_RespTables"),
                    --send)
end

function BptLg.processCfgCard(uid, linkid, msg)
end

function BptLg.processReqShowDealCard(uid, linkid, msg)
	local cmd = msg--pb.decode("network.cmd.PBTableCmd", msg)
	local rev = pb.decode("network.cmd.PBReqShowDealCard", cmd.contentData)

	local t = Tmgr.getTableById(rev.idx.tid)
	if t ~= nil then
		t:showDealCard(rev)
	end
end

function BptLg.processGetObserversList(uid, linkid, msg)
end

--PBTexasSubCmdID_ReqJoinTable
register(0x0011, 0x0001, "", processJoinTable)
--PBTexasSubCmdID_ReqTableInfo
register(0x0011, 0x0003, "", processGetInfoTable)
--PBTexasSubCmdID_ReqLeaveTable
register(0x0011, 0x0002, "", processLeaveTable)
--PBTexasSubCmdID_ReqChipin
register(0x0011, 0x0006, "", processChipinTable)
--PBTexasSubCmdID_ReqReservation
register(0x0011, 0x000B, "", processReservation)


--PBTexasSubCmdID_ReqMatchContent
register(0x0011, 0x0015, "", processReqMatchContent)



register(pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
         pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_ReqRoomChat"),
         "",
         processRoomChat)

register(pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
         pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_ReqRecentBoard"),
         "",
         processGetRecentBoard)

register(pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
         pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_ReqSit"),
         "",
         processSitTable)


register(pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
         pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_ReqStand"),
         "",
         processStandTable)

register(pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
         pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_ReqBuyin"),
         "",
         processBuyin)

register(pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
		pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_ReqTables"),
		"",
		processReqTables)

register(pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
		pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_CfgCard"),
		"",
		processCfgCard)


return BptLg
