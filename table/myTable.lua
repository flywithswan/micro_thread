local mod_name = "Table"
local Table = {}
--_G[mod_name] = Table

local pb    = require "protobuf"
local log   = require "log"
local utils = require "utils"
local cjson = require "cjson"

local Seat  = require "mySeat"
local Blind = require "Blind"
local BoardLog = require "BoardLog"
local RecentBoardlog = require "RecentBoardlog"
local Statistic = require "Statistic"


local function fillSeatInfo(seat)
    local seatinfo = {}
    seatinfo.player = {}

    if seat.user then
        seatinfo.player.name = seat.user.name
        seatinfo.player.country = seat.user.country
        seatinfo.player.gender = seat.user.gender
        seatinfo.player.nick = seat.user.nick
        seatinfo.player.money = seat.user.money
    end
    seatinfo.player.uid = seat.uid or 0

    seatinfo.sid = seat.pos

    seatinfo.isPlaying = seat.isplaying and 1 or 0
	seat.chips = seat.chips or 0
    seatinfo.seatMoney = (seat.chips > seat.roundmoney) and (seat.chips - seat.roundmoney) or 0
    seatinfo.chipinMoney = seat.roundmoney
    seatinfo.chipinType = seat.chiptype --(seat.chiptype == network.cmd.CHIPIN_PRECHIPS) and network.cmd.CHIPIN_CLEAR_STATUS or seat.chiptype
    seatinfo.chipinNum = (seat.roundmoney > seat.chipinnum) and (seat.roundmoney - seat.chipinnum) or 0

    local t = seat.table
    local left_money = seat.chips;
    local maxraise_seat = t.seats[t.maxraisepos] and t.seats[t.maxraisepos] or {roundmoney = 0}  -- 开局前maxraisepos == 0
    local needcall = maxraise_seat.roundmoney
    if t.state == network.cmd.TexasTableState_PreFlop and maxraise_seat.roundmoney <= t.bigblind then
        needcall = t.bigblind
    else
        if maxraise_seat.roundmoney < t.bigblind and maxraise_seat.roundmoney ~= 0 then
            needcall = (left_money > t.bigblind) and t.bigblind or left_money
        else
            needcall = (left_money > maxraise_seat.roundmoney) and maxraise_seat.roundmoney or left_money
        end
    end
    seatinfo.needCall = needcall

    -- needRaise
    seatinfo.needRaise = t:minraise()



    seatinfo.needMaxRaise = t:getMaxRaise(seat)
    seatinfo.chipinTime =  seat:getChipinLeftTime()
    seatinfo.onePot = t:getOnePot()
    seatinfo.reserveSeat = seat.rv:getReservation()

    log.debug("send seatinfo: seatpos:%d seatinfo.needRaise:%d,seatinfo.needMaxRaise:%d,needCall:%d", seat.pos, seatinfo.needRaise, seatinfo.needMaxRaise, seatinfo.needCall)



    return seatinfo
end

local function onAnimation(arg)
    log.debug("onAnimation ... ")
    local t = arg
    T.cancel(t.table_timer, network.cmd.TimeTickEvent_Animation)
    if t.round_finish_time > 0 and G.ctms() > t.round_finish_time + 1200 then
        return t:onRoundOver()
    else
        return T.tick(t.table_timer, network.cmd.TimeTickEvent_Animation, 100, onAnimation, t)
    end

end

function Table:onFinish()
	log.debug("onFinish ...")
end

local function onStartPreflop(arg)
    log.debug("onStartPreflop ...")
    local t = arg
    T.cancel(t.table_timer, network.cmd.TimeTickEvent_StartPreflop)

    t.current_betting_pos = t.sbpos
	t:chipin(t.seats[t.current_betting_pos].uid, network.cmd.CHIPIN_SMALLBLIND, t.smallblind)
    t.current_betting_pos = t.bbpos
    t:chipin(t.seats[t.current_betting_pos].uid, network.cmd.CHIPIN_BIGBLIND, t.bigblind)

    t.state = network.cmd.TexasTableState_Start
    t:getNextState()
end

local function onPrechipsRoundOver(arg)
    log.debug("onPrechipsRoundOver ...")
    local t = arg
    T.cancel(t.table_timer, network.cmd.TimeTickEvent_PrechipsRoundOver)
    t:roundOver()

    T.tick(t.table_timer, network.cmd.TimeTickEvent_StartPreflop, 1000, onStartPreflop, t)
end

-- table start

function Table.new(sid, tid)
    local t = {}
    Table.__index = Table
    setmetatable(t, Table)
    t:init(sid, tid)
    return t
end

function Table:destroy()
end

function Table:init(sid, tid)
    log.debug("table init tid:%d", tid)
	self.matchid = 0
	self.sid = sid
    self.tid = tid
    self.table_timer = T.create()
    self.cards = S.create()
    self.pokerhands = PH.create()
    self.gameId = 0

	self.matchtype = PBMatchType_Regular

    self.observelist = {}
    self.state = network.cmd.TexasTableState_None --牌局状态(preflop, flop, turn...)
    self.current_betting_pos = -1
    self.buttonpos = -1
    self.sbpos = -1
    self.bbpos = -1
    self.straddlepos = -1

	--
	self.ante = 10
	self.smallblind = 100
	self.bigblind = 200
    self.minchip = 1
    --

	self.bettingtime = 1
    self.boardcards = {0,0,0,0,0}
    self.roundcount = 0
    self.potidx = 1 -- C++ 的potidx 从0 开始
    self.current_betting_pos = 0
    self.chipinpos = 0
    self.already_show_card = false
    self.maxraisepos = 0
    self.maxraisepos_real = 0
    self.pots = {
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                  }

    self.seats = {} -- 座位
    local index = {1,2,3,4,5,6,7,8,9}
    for _,seatid in ipairs(index) do
        local s = Seat.new(self, seatid)
        self.seats[seatid] = s
    end

	self.statistic = Statistic.new()

    self.round_finish_time = 0      -- 每一轮结束时间  (preflop - flop - ...)
    self.starttime  = 0  -- 牌局开始时间
    self.endtime    = 0  -- 牌局结束时间

    self.table_match_start_time = 0 -- 开赛时间
    self.table_match_end_time   = 0 -- 比赛结束时间

    self.playing_users    = {}  -- 当局参与的玩家列表，主要用于记录后方便上报
    self.chipinset        = {}
    self.last_playing_users = {} -- 上一局参与的玩家列表

    self.roomchat_mod = RC.create()

    self.finishstate = network.cmd.TexasTableState_None

	-- 配牌
	self.cfgcard_switch = false
	self.cfghandcards = {}
	self.cfgboardcards = {}
	-- 主动亮牌
	self.req_show_dealcard = false --客户端请求过主动亮牌
	self.lastchipintype = network.cmd.CHIPIN_NULL
	self.lastchipinpos = 0

	self.tableStartCount = 0

    self.round_bet_flags = {
        [0] = 0,
        [1] = 0,
        [2] = 0,
        [3] = 0,
        [4] = 0,
        [5] = 0,
    }
    self.round_3bet_flags = {
        [0] = 0,
        [1] = 0,
        [2] = 0,
        [3] = 0,
        [4] = 0,
        [5] = 0,
    }
end

function Table:reset()
    self.boardcards = {0,0,0,0,0}

    self.pots = {
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                    {money=0,seats={}},
                  }
    self.maxraisepos = 0;
    self.maxraisepos_real = 0
    self.chipinpos = 0;
    self.potidx = 1;
    self.roundcount = 0;
    self.current_betting_pos = 0;
    self.already_show_card = false;
    self.playing_users = {};
    self.chipinset     = {}
    self.finishstate = network.cmd.TexasTableState_None

	self.req_show_dealcard = false
	self.lastchipintype = network.cmd.CHIPIN_NULL
	self.lastchipinpos = 0

    self.round_bet_flags = {
        [0] = 0,
        [1] = 0,
        [2] = 0,
        [3] = 0,
        [4] = 0,
        [5] = 0,
    }
    self.round_3bet_flags = {
        [0] = 0,
        [1] = 0,
        [2] = 0,
        [3] = 0,
        [4] = 0,
        [5] = 0,
    }
end

function Table:join(uid, linkid)
    self.observelist[uid] = linkid
    return true
end

function Table:observersList()
    local uids = {}
    for k,v in pairs(self.observelist) do
        table.insert(uids, k)
    end

    return uids
end

function Table:leave(uid)
    self.observelist[uid] = nil
    return true
end

function Table:broadcastShowCardToAll(force, poss)
    -- 一个牌局只翻一次牌
    if self.already_show_card then
        return true
    end

    if not force then
        self:checkShowCardSeat(poss)
    else
        self.already_show_card = true
    end

    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true and seat.chiptype ~= network.cmd.CHIPIN_FOLD then
            if seat.show == true or force == true then
		if force then
			seat.show = true
		end
                local showdealcard = {
                    showType = 1,
                    sid      = i,
                    card1    = seat.handcards[1],
                    card2    = seat.handcards[2],
                }
            end
        end
    end
    return true
end

function Table:sendTableCmdToMe(uid, maincmd, subcmd, content)
	local linkid = self.observelist[uid] or 0

	local send_tb = {}
	send_tb.idx = {}
	send_tb.idx.flag = G.sid()
	send_tb.idx.mid  = self.matchid
	send_tb.idx.tid  = self.tid
	send_tb.idx.time = 0 -- self.match.starttime -- 0

	if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular") then
		send_tb.idx.time = self.createtime
	end

	send_tb.contentData = content

	local send_pb = pb.encode("network.cmd.PBTableCmd", send_tb)
	--bpt.accli.send(linkid, uid, maincmd, subcmd, send_pb)
end

function Table:broadcastCanShowCardToAll(poss)
	local showpos = {}
	for i = 1, #self.seats do
		showpos[i] = false
	end
	--摊牌前最后一个弃牌的玩家可以主动亮牌
	if self.lastchipintype == network.cmd.CHIPIN_FOLD
		and self.lastchipinpos ~= 0
		and self.lastchipinpos <= #self.seats
		and not self.seats[self.lastchipinpos].show then
		showpos[self.lastchipinpos] = true
	end

	--获取底池的玩家可以主动亮牌
	for pos,_ in pairs(poss) do
		if not self.seats[pos].show then showpos[pos] = true end
	end

	for i = 1, #self.seats do
		local seat = self.seats[i]
		if seat.isplaying and seat.uid then
			--系统盖牌的玩家有权主动亮牌
			if not showpos[i]
				and not seat.show
				and seat.chiptype ~= network.cmd.CHIPIN_REBUYING
				and seat.chiptype ~= network.cmd.CHIPIN_FOLD then
				showpos[i] = true
			end

			local send = {}
			send.sid = i
			send.canReqShow = showpos[i]
			local content = pb.encode("network.cmd.PBCanShowDealCard", send)
			self:sendTableCmdToMe(  seat.uid,
									pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
									pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_RespCanShowDealCard"),
									content)
		end
	end
end

function Table:checkShowCardSeat(poss)
    local playing   = self:getNoFoldCnt()
    local allin     = self:getAllinSize()
    if playing == 1 then
        return
    end

    if playing == allin or allin == playing - 1 then
        for i = 1, #self.seats do
            local seat = self.seats[i]
            if seat.isplaying == true and seat.chiptype ~= network.cmd.CHIPIN_FOLD then
                seat.show = true
            end
        end
    else
        if self.roundcount == 4 then
            if self.maxraisepos ~= 0 then
                self.seats[self.maxraisepos].show = true
                self:setShowCard(self.maxraisepos, true, poss)
            else
                local s = self:getNextNoFlodPosition(self.buttonpos)
                log.debug("NoFlodPosition %d", s.seatid)
                if s ~= nil then
                    self.seats[s.seatid].show = true
                    self:setShowCard(s.seatid, false, poss)
                end
            end
        else
            local s = self:getNextNoFlodPosition(self.buttonpos)
            log.debug("NoFlodPosition %d", s.seatid)
            if s ~= nil then
                self.seats[s.seatid].show = true
                self:setShowCard(s.seatid, false, poss)
            end
        end
    end

end

function Table:getInfo(uid)
	log.debug("Table getInfo UID:%d", uid)
	local tableinfo = {
		gameId = self.gameId,
		seatCount = self.match:getSeatCount(),
		gameState = self.state,
		matchState = self.match.state,
		buttonSid = self.buttonpos,
		smallBlindSid = self.sbpos,
		bigBlindSid = self.bbpos,
		smallBlind  = self.smallblind,
		bigBlind    = self.bigblind,
		ante        = self.ante,
		tableName   = self.tablename,
		tableType   = self.tabletype,
		bettingtime = self.bettingtime,
		tid         = self.tid,
		roundNum    = self.roundcount,
	}

	if self.match.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
		self.match.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then
		tableinfo.minbuyinbb = self.match.minbuyinbb
		tableinfo.maxbuyinbb = self.match.maxbuyinbb
	end

	if self.match.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular") then
		tableinfo.create_uid = self.match.create_uid
		tableinfo.code = self.match.code
	end

	tableinfo.publicCards = {}
	for i = 1, #self.boardcards do
		tableinfo.publicCards[i] = self.boardcards[i]
	end

	self:sendAllSeatsInfoToMe(uid, tableinfo)
end

function Table:broadcastToAllObserver(maincmd, subcmd, content)
	for uid,linkid in pairs(self.observelist) do
		self:sendTableCmdToMe(uid, maincmd, subcmd, content)
	end
end

function Table:sendPosInfoToAll(seat)
    log.debug("Table:sendPosInfoToAll seatid:%d UID:%d", seat.pos, (seat.uid and seat.uid or 0))
    if (seat.uid ~= nil) then
        local seatinfo = fillSeatInfo(seat)
        local updateseat = {
            seatInfo = seatinfo
        }
        local content = pb.encode("network.cmd.PBUpdateSeat", updateseat)
        self:broadcastToAllObserver(0x0011, 0x1009, content) --PBTexasSubCmdID_UpdateSeat
        return true
    else
        return false
    end
end

function Table:updateSeatChipType(seat, type)
    if seat == nil then
        return false
    end
    seat.chiptype = type
	self:sendPosInfoToMe(0, seat.pos)
end

function Table:sendPosInfoToMe(uid, pos)

	local updateseat = {}
	local seat = self.seats[pos]
	if seat.uid == nil then
		return false
	end

	local updateseat = {seatInfo = {}}
	updateseat.seatInfo = fillSeatInfo(seat)
	if uid ~= 0 then
		updateseat.seatInfo.card1 = seat.handcards[1]
		updateseat.seatInfo.card2 = seat.handcards[2]
	end

	local content = pb.encode("network.cmd.PBUpdateSeat", updateseat)

	if uid ~= 0 then
		self:sendTableCmdToMe(uid, 0x0011, 0x1009, content)
	else
		self:broadcastToAllObserver(0x0011, 0x1009, content) -- PBTexasSubCmdID_UpdateSeat
	end
end

function Table:inTable(uid)
    for i=1, #self.seats do
        if self.seats[i].uid == uid then
            return true
        end
    end
    return false
end

function Table:inObserveList(uid)
    if self.observelist[uid] ~= nil then
        return true
    end
    return false
end

function Table:getSeatByUid(uid)
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.uid == uid then
            return seat
        end
    end
    return nil
end

function Table:getOnePot()
    local money = 0
    for i = 1, #self.seats do
        if self.seats[i].isplaying == true then
            money = money + self.seats[i].money +  self.seats[i].roundmoney
        end
    end
    return money
end

function Table:getPotCount()
    return self.potidx
end

function Table:distance(seat_a, seat_b)
    local dis = 0
    for i = seat_a.seatid, seat_b.seatid - 1 + #self.seats do
        dis = dis + 1
    end
    return dis % #self.seats
end

function Table:sit(uid, pos, buyinmoney, autobuy, escapebb)
	for i = 1, #self.seats do
		local seat = self.seats[i]
		if seat.uid == uid then
			pos = i
			break
		end
	end

	if pos == nil then
		for i = 1, #self.seats do
			if self.seats[i].uid == nil then
				pos = i
				break
			end
		end
	end

	if pos == nil then
		local sitfail = {code=1, description=1}
		local content = pb.encode("network.cmd.PBSitFailed", sitfail)
		self:sendTableCmdToMe(uid, 0x0011, 0x1005, content) --network::cmd::PBTexasSubCmdID_SitFailed
		return false
	end

	local init_money = buyinmoney
	local seat = self.seats[pos]

	if seat:sit(uid, init_money, autobuy, escapebb) then
		local playersit = {seatInfo={}}
		playersit.seatInfo = fillSeatInfo(seat)
		local content = assert(pb.encode("network.cmd.PBPlayerSit", playersit))
		self:broadcastToAllObserver(0x0011, 0x1004, content)
	else
		log.debug("seat sit fail UID:%d", uid)
	end
	return true
end

function Table:SitPre(uid, pos, buyinmoney, autobuy, escapebb)
	log.debug(string.format("Table.lua Table:SitPre, %d, %d, %d, %d, %d", uid or -1, pos or -1, buyinmoney or -1, autobuy or -1, escapebb or -1))
    -- 找到一个最合适的位置
    if pos == nil then
        -- 如果已经在座位上，直接返回该pos
        for i = 1, #self.seats do
            local seat = self.seats[i]
            if seat.uid == uid then
                pos = i
                break
            end
        end

        if pos == nil then
            for i = 1, #self.seats do
                if self.seats[i].uid == nil then
                    pos = i
                    break
                end
            end
        end
    end

    --实在找不到位置
    if pos == nil then
        local sitfail = {code=1, description=1}
        local content = pb.encode("network.cmd.PBSitFailed", sitfail)

        return false
    end

    local seat = self.seats[pos]
	if seat:sit(uid, init_money, autobuy, escapebb) then
		local playersit = {seatInfo={}}
		playersit.seatInfo = fillSeatInfo(seat)
		local content = assert(pb.encode("network.cmd.PBPlayerSit", playersit))
		self:broadcastToAllObserver(0x0011, 0x1004, content) --network::cmd::PBTexasSubCmdID_PlayerSit
	else
		log.debug("Table.lua Table:SitPre, seat sit fail UID:%d", uid)
	end
end

--[[ pos is nil if default --]]
function Table:sit_with_lockchip(uid, pos, buyinmoney, autobuy, lockchip, escapebb)
    -- 找到一个最合适的位置
    if pos == nil then
        -- 如果已经在座位上，直接返回该pos
        for i = 1, #self.seats do
            local seat = self.seats[i]
            if seat.uid == uid then
                pos = i
                break
            end
        end

        if pos == nil then
            for i = 1, #self.seats do
                if self.seats[i].uid == nil then
                    pos = i
                    break
                end
            end
        end
    end

    --实在找不到位置
    if pos == nil then
        local sitfail = {code=1, description=1}
        local content = pb.encode("network.cmd.PBSitFailed", sitfail)

        return false
    end

    local init_money = lockchip
    local seat = self.seats[pos]
    if seat:sit(uid, init_money, autobuy, escapebb) then

        local playersit = {seatInfo={}}
        playersit.seatInfo = fillSeatInfo(seat)
        --local content = assert(pb.encode("network.cmd.PBPlayerSit", playersit))
        local content = pb.encode("network.cmd.PBPlayerSit", playersit)
        self:broadcastToAllObserver(0x0011, 0x1004, content) --network::cmd::PBTexasSubCmdID_PlayerSit
    else
        log.debug("seat sit fail UID:%d", uid)
    end

    return true

end

function Table:stand(uid, type)
	local seat = self:getSeatByUid(uid)
	if self.state ~= network.cmd.TexasMatchState_WAIT and
		self.state ~= network.cmd.TexasTableState_None and
		seat ~= nil and
		seat.state ~= network.cmd.TexasSeatState_OUT  then
		return false
	end
	-- GameLog

	-- 普通场玩法玩家站起要先弃牌
	if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
		self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then
		self:updateSeatChipType(seat, network.cmd.CHIPIN_FOLD)

		if self.current_betting_pos == seat.pos then
			T.cancel(self.table_timer, network.cmd.TimeTickEvent_Betting)
			self:userchipin(uid, network.cmd.CHIPIN_FOLD, 0)
		end
	end

	if seat ~= nil and seat:stand(uid) then

		local send = {}
		send.sid = seat.pos
		send.type = 1
		if type ~= nil then
			send.type = type
		end
		local content = pb.encode("network.cmd.PBPlayerStand", send)
		self:broadcastToAllObserver(0x0011, 0x1006, content)

		if network.cmd.TexasTableState_None ~= self.state and self:getCurrentBoardSitSize() < 2 then
			self:roundOver()
			self.finishstate = network.cmd.TexasTableState_Finish
			self:finish()
		end

	else
		if uid then
			log.debug("seat stand fail UID:%d", uid)
		end
	end
end

function Table:getSitSize()
    local count = 0
    for i = 1, #self.seats do
        if self.seats[i].uid ~= nil then
            count = count + 1
        end
    end
    return count
end

-- 非留座
function Table:getNonRsrvSitSize()
    local count = 0
    for i = 1, #self.seats do
        if self.seats[i].uid ~= nil and
			not self.seats[i].rv:isReservation() then
            count = count + 1
        end
    end
    return count
end

function Table:hasNewPlayer()
    local timems = 0
    local pos = -1
    for i = 1, #self.seats do
        if self.seats[i].uid ~= nil and not self.seats[i].rv:isReservation() then
			-- 刚坐下 ,刚坐下的多个用户，哪个应该是大盲位？
			if self.seats[i].gamecount == 0 then return true, i end
            -- 刚取消留座
            if self.seats[i].reservback_gamecnt == 0 then
                -- 找到最晚取消留座离桌的用户位置,即是大盲位
                if self.seats[i].reservback_time > timems then
                    timems = self.seats[i].reservback_time
                    pos = i
                    log.debug("hasNewPlayer-- timems:%d, pos:%d", timems, pos)
                end
            end
        end
    end

    if pos >= 0 then
        return true, pos
    end

	return false
end

function Table:getCurrentBoardSitSize()
    local count = 0
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.uid ~= nil and not seat.rv:isReservation() and seat.isplaying == true then
            count = count + 1
        end
    end

    return count
end

function Table:getPlayingSize()
    local count = 0
    for i = 1, #self.seats do
        if self.seats[i].isplaying == true then
            log.debug("getPlayingSize playing pos:%d", i)
            count = count + 1
        end
    end
    return count
end

function Table:getValidDealPos()

    for i = self.buttonpos + 1,self.buttonpos + #self.seats - 1 do
        local j = i % #self.seats > 0 and i % #self.seats or #self.seats
        local seat = self.seats[j]
        if seat ~= nil and seat.isplaying == true then
            return j
        end
    end
    return -1

end

function Table:getNextNoFlodPosition(pos)
    for i = pos + 1, pos - 1 + #self.seats do
        local j = i % #self.seats > 0 and i % #self.seats or #self.seats
        local seat = self.seats[j]
        if seat.isplaying ==  true and seat.chiptype ~= network.cmd.CHIPIN_FOLD then
            return seat
        end
    end
    return nil
end

function Table:getNextActionPosition(seat)
    local pos = seat.pos
    for i = pos + 1, pos + #self.seats - 1 do
        local j = i % #self.seats > 0 and  i % #self.seats or #self.seats
        local seat = self.seats[j]
        if seat ~= nil and seat.chiptype ~= network.cmd.CHIPIN_ALL_IN and seat.chiptype ~= network.cmd.CHIPIN_FOLD and seat.isplaying == true then
            return seat
        end

    end
    return self.seats[self.maxraisepos]
end

function Table:getNoFoldCnt()
    local nfold = 0
    for i = 1,#self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true and seat.chiptype ~= network.cmd.CHIPIN_FOLD then
            nfold = nfold + 1
        end
    end
    return nfold
end

function Table:getAllinSize()
    local allin = 0
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true and seat.chiptype == network.cmd.CHIPIN_ALL_IN then
            allin = allin + 1
        end
    end
    return allin
end

function Table:setShowCard(pos, riverraise, poss)
    if riverraise == true then
        local bigseat = self.seats[pos]
        for i = pos + 1, pos - 1 + #self.seats do
            local j = i % #self.seats > 0 and i % #self.seats or #self.seats
            local seat = self.seats[j]
            if seat.isplaying and seat.chiptype ~= network.cmd.CHIPIN_FOLD then
                if seat.chiptype == network.cmd.CHIPIN_ALL_IN then
                    seat.show = true
                end

                local result = PH.comphandstype(self.pokerhands,
                                                seat.handtype,
                                                seat.besthand,
                                                bigseat.handtype,
                                                bigseat.besthand)
                if result == 1 or result == 0 then
                    seat.show = true
                    bigseat = seat
                    log.debug("riverraise show %d", j)
                end
            end

            if seat.isplaying and seat.chiptype == network.cmd.CHIPIN_ALL_IN then
                seat.show = true
            end
        end
    else
        for i = pos + 1, pos - 1 + #self.seats do
            local j = i % #self.seats > 0 and i % #self.seats or #self.seats
            local seat = self.seats[j]
            if seat.isplaying and seat.chiptype ~= network.cmd.CHIPIN_FOLD then
                if poss[seat.seatid] ~= nil then
                    seat.show = true
                end
            end
            if seat.isplaying and seat.chiptype == network.cmd.CHIPIN_ALL_IN then
                seat.show = true
            end
        end
    end
end

function Table:isRegularMatch()
	if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
	   self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then
	   return true
    else
	   return false
    end
end

--刚刚取消留座离桌的玩家个数
function Table:CancelRevJustNowCount()
    local count = 0
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.uid ~= nil then
            log.debug("Table:CancelRevJustNowCount()  seat pos :%d, CancelRevJustNow:%d",seat.pos, seat.CancelRevJustNow and 1 or 0)
        end
        if seat.uid ~= nil and seat.CancelRevJustNow == true then
            count = count + 1
        end
    end

    log.debug("CancelRevJustNowCount count:%d", count)
    return count
end

--清零刚刚取消留座离桌的玩家个数
function Table:ClearCancelRevJustNowCount()
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.uid ~= nil then
            log.debug("Table:ClearCancelRevJustNowCount()  seat pos :%d, CancelRevJustNow:%d",seat.pos, seat.CancelRevJustNow and 1 or 0)
        end
        if seat.uid ~= nil and seat.CancelRevJustNow == true then
            seat.CancelRevJustNow = false
        end
    end
end


function Table:moveButton()
    log.debug("move button")
    local sitsize = self:getSitSize()
    if sitsize <= 1 then
        return false
    end

	local playersize = 0
	if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
	   self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then
	   playersize = self:getNonRsrvSitSize()
	else
	   playersize = self:getSitSize()
	end

    if self.bbpos == -1 then
        -- 如果是刚进来，2人情况下，随机大小盲, 小盲和庄同一人
        if playersize == 2 then
            local pos = {}
            for i = 1, #self.seats do
                local seat = self.seats[i]
                if seat.uid ~= nil then
					if (self:isRegularMatch() and not seat.rv:isReservation()) or
						not self:isRegularMatch() then
						pos[#pos + 1] = i
					end
                end
            end
            local rand = D.rand_between(0 , 1)
            if rand == 1 then
                self.bbpos     = pos[2]
                self.sbpos     = pos[1]
                self.buttonpos = pos[1]
                self.chipinpos = pos[2]
            else
                self.bbpos     = pos[1]
                self.sbpos     = pos[2]
                self.buttonpos = pos[2]
                self.chipinpos = pos[1]
            end
        else
            -- 3人或以上情况下，大盲，小盲，庄，分别为不同人
            local c = 0
            for i = 1, #self.seats do
                local seat = self.seats[i]
                if seat.uid ~= nil then
					if (self:isRegularMatch() and not seat.rv:isReservation()) or
						not self:isRegularMatch() then
						c = c + 1
						if c == 1 then
							self.buttonpos = i
						elseif c == 2 then
							self.sbpos     = i
						else
							self.bbpos     = i
							self.chipinpos = i
							break
						end
					end
                end
            end
        end
    else
        -- 之前已经有牌局了，大小盲，庄，轮着来(大盲先走，小盲和庄跟着大盲走)
        for i = self.bbpos + 1, self.bbpos - 1 + #self.seats do
            local j = i % #self.seats > 0 and i % #self.seats or #self.seats
            if self.seats[j].uid ~= nil then
                local iscontinue = false
                -- 普通场玩法留座不参与牌局
                if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
                   self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then

				   -- 大盲略过留座
                    if self.seats[j].rv:isReservation() then
                        self.seats[j].rv:chipinTimeoutRound()
                        if self.seats[j].rv:isStandup() then
                            local stand_type = pb.enum_id("network.cmd.PBTexasStandType", "PBTexasStandType_ReservationTimesLimit")
                        end
						iscontinue = true
                    end
					-- 大盲略过正在买入
					if self.seats[j].chiptype == network.cmd.CHIPIN_BUYING then iscontinue = true end
					-- 桌上除留座外只有一个玩家，新进入玩家一定是大盲
					if playersize == 2 then
						local hasNew, pos = self:hasNewPlayer()
						if hasNew and pos then
                            j = pos
                        end
					end
					-- 大盲略过的玩家，记录逃盲次数
					if iscontinue then
						self.seats[j].escape_bb_count = self.seats[j].escape_bb_count + 1
					end
                end

                if iscontinue ~= true then
                    local last_bbpos = self.bbpos
                    self.bbpos = j
                    self.chipinpos = j
                    self.sbpos  = self:getSB(last_bbpos)
                    self.buttonpos = self:getButton()
                    break
                end
            end
        end
    end

    local last_playersize = 0
    for k, v in pairs(self.last_playing_users) do
        last_playersize = last_playersize + 1
    end

    log.debug("moveButton sbpos:%d,button:%d",self.sbpos,self.buttonpos)
    for i = 1, #self.seats do
        local seat = self.seats[i]
        --local sit_size = self:getSitSize()
        if seat.uid ~= nil and self.tableStartCount > 1 then
            -- 刚坐下 ，且坐在小盲或庄位，要等下一局才能玩
            if seat.isplaying == false and (i == self.sbpos or i == self.buttonpos) and last_playersize >= 3 then
                seat.isdelayplay = true
                log.debug("#t.playing_users:%d", self:getPlayingSize())

                --Added by HassonLiu at 2017.08.07
                --解决bug，如果玩家全部留座离桌，回来两个玩家不开赛，因为回来的玩家有sb或者button，
                --而且回来时的isplaying=false，导致不能入局，，现临时添加变量进行判断
                if seat.CancelRevJustNow == true and self:getPlayingSize() == 0 and self:CancelRevJustNowCount() >= 2 then
                    seat.isdelayplay = false

                    self:ClearCancelRevJustNowCount()
                end
            else
                seat.isdelayplay = false
            end
        end
    end

    log.debug("movebutton:%d,%d,%d,%d,%d",self.tid ,self.bbpos, self.sbpos, self.buttonpos, self.chipinpos);
    return true
end

function Table:getSB(last_bbpos)
    -- >2情况， 小盲等于上局大盲
	if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
		self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular") then
		if self:getNonRsrvSitSize() > 2 then
			return last_bbpos
		end
	else
		if self:getSitSize() > 2 then
			return last_bbpos
		end
	end
    -- 这时候bbpos已经是新一局的bbpos，小盲就是新一局大盲后面第一个有人的位置
    local pos
    local i = (self.bbpos - 1 + #self.seats) % #self.seats
    repeat
        local j = i % #self.seats > 0 and i % #self.seats or #self.seats
        local seat = self.seats[j]

		--普通场/自建普通场留座离桌不交大小盲
		local flag = true
		if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
			self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular") then
			if seat.rv:getReservation() == network.cmd.PBLeaveToSitResultSucc then
				flag = false
			end
		end

        if seat.uid ~= nil and flag then
            pos = seat.seatid
            break
        end
        i = i - 1
    until (i == (self.bbpos % #self.seats))

    return pos == nil and 0 or pos
end

function Table:getButton()
    -- 只有2人，庄和小盲同一人
	if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
		self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular") then
		if self:getNonRsrvSitSize() == 2 then
			return self.sbpos
		end
	else
		if self:getSitSize() == 2 then
			return self.sbpos
		end
	end
    if self.sbpos == 0 then
        return 0
    end
    local pos
    local i = (self.sbpos - 1 + #self.seats) % #self.seats
    repeat
        local j = i % #self.seats > 0 and i % #self.seats or #self.seats
        local seat = self.seats[j]

		--普通场/自建普通场留座离桌做庄
		local flag = true
		if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
			self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular") then
			if seat.rv:getReservation() == network.cmd.PBLeaveToSitResultSucc then
				flag = false
			end
		end

        --      有人                    或者                      这个人上一局刚站起，这一局空庄
        if (seat.uid ~= nil or (seat.uid == nil and seat.isplaying == true)) and flag then
            pos = seat.seatid
            break
        end
        i = i - 1
    until (i == self.sbpos % #self.seats)
    return pos == nil and 0 or pos
end

function Table:getGameId()
    return self.gameId + 1
end

function Table:start()
    log.debug("Table start...")

    self:reset()
    S.shuffle(self.cards)  -- 洗牌

    self.gameId = self:getGameId()
    self.tableStartCount = self.tableStartCount + 1
    self.starttime = G.ctsec()

    self:moveButton()

    for i = 1, #self.seats do
        local seat = self.seats[i]

        seat.rv:checkSitResultSuccInTime()

        local allow = true
        if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
            self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then
            if seat.rv:isReservation() then
                allow = false
            end
        end

        seat:reset()
        log.debug("allow:%d", allow and 1 or 0);
        if seat.uid ~= nil and allow then
            if  seat.isdelayplay == false then
                seat.isplaying = true
                if seat.state == network.cmd.TexasSeatState_REBUYING or seat.state == network.cmd.TexasSeatState_OUT then
                    seat.isplaying = false
                end

                if seat.isplaying == true then
					self.playing_users[seat.uid] = seat
                end

            else
                seat.chiptype = network.cmd.CHIPIN_WAIT
                log.debug("UID:%d isdelayplay is true", seat.uid)
            end
        end

    end
    for i = 1, #self.seats do
        local seat = self.seats[i]

        if seat.uid ~= nil then
            log.debug("pos:%d,isReservation:%d",seat.pos, seat.rv:isReservation() and 1 or 0)
        end
    end

    self.maxraisepos = self.bbpos;
    self.maxraisepos_real = self.maxraisepos
	--配牌处理
	if self.cfgcard_switch then
		self:setcard()
	end

	local gamestart =  {
		gameId          = self.gameId,
		gameState       = self.state,
		buttonSid       = self.buttonpos,
		smallBlindSid   = self.sbpos,
		bigBlindSid     = self.bbpos,
		smallBlind      = self.smallBlind,
		bigBlind        = self.bigBlind,
		ante            = self.ante,
		minChip         = self.minchip,
		table_starttime = self.starttime,
	}
	local content = assert(pb.encode("network.cmd.PBGameStart", gamestart), pb.lasterror())
	self:broadcastToAllObserver(0x0011, 0x1008, content) --PBTexasSubCmdID_GameStart

	for i = 1, #self.seats do
		local seat = self.seats[i]
		self:sendPosInfoToAll(seat)
	end

	if self:getPlayingSize() == 1 then
		print("only one user")
		return
	end

    -- 前注，大小盲处理
    self:dealPreChips()

	-- 防逃盲
	local isDelayStart = self:dealAntiEscapeBB()

	if self.ante <= 0 and not isDelayStart then
	   onStartPreflop(self)
	end
end

function Table:checkCanChipin(seat)
    if seat ~= nil and seat.uid ~= nil and seat.pos == self.current_betting_pos and seat.isplaying == true then
        return true
    else
        return false
    end
end

function Table:chipin(uid, type, money)
	local seat = self:getSeatByUid(uid)
	if self:checkCanChipin(seat) == false then
        return false
    end
    if seat.chips < money then
        money = seat.chips
    end

    log.debug("Table:chipin pos:%d uid:%d type:%d money:%d", seat.pos, seat.uid and seat.uid or 0, type, money)

    local old_roundmoney = seat.roundmoney

    local function fold_func(seat, type, money)
        log.debug("exec fold_func")
        seat:chipin(type, seat.roundmoney)

        seat.rv:checkSitResultSuccInTime()
    end

    local function call_check_raise_allin_func(seat, type, money)
        log.debug("exec call_check_raise_allin_func")
        local maxraise_seat = self.seats[self.maxraisepos] and self.seats[self.maxraisepos] or {roundmoney = 0}
        if type == network.cmd.CHIPIN_CHECK and money == 0 then
            if seat.roundmoney >= maxraise_seat.roundmoney then
                type = network.cmd.CHIPIN_CHECK
                money = seat.roundmoney
            else
                type = network.cmd.CHIPIN_FOLD
            end
        elseif type == network.cmd.CHIPIN_ALL_IN and money < seat.chips then
            money = seat.chips
        elseif type == network.cmd.CHIPIN_RAISE and money == seat.chips then
            type = network.cmd.CHIPIN_ALL_IN
        elseif money < seat.chips and money <  maxraise_seat.roundmoney then
            type = network.cmd.CHIPIN_FOLD;
            money = 0
        else
            if money < seat.roundmoney then
                if type == network.cmd.CHIPIN_CHECK and money == 0 then
                    type = network.cmd.CHIPIN_CHECK
                else
                    type = network.cmd.CHIPIN_FOLD
                    money = 0
                end

            elseif money > seat.roundmoney then
                if money == maxraise_seat.roundmoney then
                    type = network.cmd.CHIPIN_CALL
                else
                    type = network.cmd.CHIPIN_RAISE
                end

            else
                type = network.cmd.CHIPIN_CHECK
            end
        end
        seat:chipin(type, money)
    end

    local function smallblind_func(seat, type, money)
        log.debug("exec smallblind_func")
        seat:chipin(type, money)
    end

    local function bigblind_func(seat, type, money)
        log.debug("exec bigblind_func")
        seat:chipin(type, money)
    end

    local function straddle_func(seat, type, money)
        log.debug("exec straddle_func")
        seat:chipin(type, money)
    end

    local switch = {
        [network.cmd.CHIPIN_FOLD]       = fold_func,
        [network.cmd.CHIPIN_CALL]       = call_check_raise_allin_func,
        [network.cmd.CHIPIN_CHECK]      = call_check_raise_allin_func,
        [network.cmd.CHIPIN_RAISE]      = call_check_raise_allin_func,
        [network.cmd.CHIPIN_ALL_IN]     = call_check_raise_allin_func,
        [network.cmd.CHIPIN_SMALLBLIND] = smallblind_func,
        [network.cmd.CHIPIN_BIGBLIND]   = bigblind_func,
        [network.cmd.CHIPIN_STRUGGLE]   = straddle_func,
    }

    local chipin_func = switch[type]
    if chipin_func == nil then
        long.debug("无效加注类型 type:%d", type)
        return true
    end

    -- 真正操作chipin
    chipin_func(seat, type, money)

    local maxraise_seat = self.seats[self.maxraisepos] and self.seats[self.maxraisepos] or {roundmoney = 0}
    if seat.roundmoney > maxraise_seat.roundmoney then
        self.maxraisepos = seat.seatid
        if (self.seats[seat.seatid].roundmoney >= self:minraise()) then
            self.maxraisepos_real = seat.seatid
        end
    end

    -- 统计
    if self.maxraisepos == seat.seatid and (seat.chiptype == network.cmd.CHIPIN_RAISE or seat.chiptype == network.cmd.CHIPIN_ALL_IN) then
        self.seats[self.maxraisepos].reraise = true;

        if self.state == network.cmd.TexasTableState_PreFlop then
            self.seats[self.maxraisepos].si.israise = pb.enum_id("network.cmd.PFR", "PFR_YES")
        end

        if self.roundcount > 0 and self.round_bet_flags[self.roundcount] ~= 0 then
            self.seats[self.maxraisepos].si.betcount = self.seats[self.maxraisepos].si.betcount + 1
            self.round_bet_flags[self.roundcount] = 1
        end
        if self.round_3bet_flags[self.roundcount] ~= 0 then
            self.round_3bet_flags[self.roundcount] = 1
        else
            self.seats[self.maxraisepos].si.threebetcount =  self.seats[self.maxraisepos].si.threebetcount + 1
        end

    end

    self.chipinpos = seat.pos

    if type ~= network.cmd.CHIPIN_FOLD and type ~= network.cmd.CHIPIN_SMALLBLIND and money > 0 then
        self.chipinset[#self.chipinset + 1] = money
    end

    return true
end

function Table:userchipin(uid, type, money)
	if self.state == network.cmd.TexasTableState_None or self.state == network.cmd.TexasTableState_Finish then
        log.debug("chipin error uid:%d state:%d", uid, self.state)
        return false
    end
    if self.minchip == 0 then
        log.debug("chipin error uid:%d minchip:%d", uid, self.minchip)
        return false
    end

    log.debug("userchipin 111 uid:%d type:%d money:%d", uid, type, money)
    if money % self.minchip ~= 0 then
        if money < self.minchip then
            money = self.minchip
        else
            money = math.floor(money / self.minchip) * self.minchip
        end
    end
    log.debug("userchipin 222 uid:%d type:%d money:%d", uid, type, money)

    local chipin_result = self:chipin(uid, type, money)
    if chipin_result == false then
        return false
    end
    local chipin_seat = self:getSeatByUid(uid)
    if chipin_seat.pos == self.current_betting_pos then
        T.cancel(self.table_timer, network.cmd.TimeTickEvent_Betting)
    end


    local next_seat = self:getNextActionPosition(self.seats[self.chipinpos])
    log.debug("next_seat uid:%d chipin_uid:%d chiptype:%d chips:%d",
        next_seat and next_seat.uid or 0, self.seats[self.chipinpos].uid, self.seats[self.chipinpos].chiptype, chipin_seat.chips)


    local isallfold = self:isAllFold()
    if isallfold == true then
        log.debug("chipin isallfold")
        self:roundOver()
        self.finishstate = network.cmd.TexasTableState_Finish
        self:finish()
        return true
    end

    if next_seat.chiptype == network.cmd.CHIPIN_BIGBLIND then
        log.debug("chipin next_seat is bigblind next_uid:%d", next_seat.uid)

        if next_seat.pos == self.maxraisepos and self:isAllAllin() then
            self.round_finish_time = G.ctms()
            T.tick(self.table_timer, network.cmd.TimeTickEvent_Animation, 100, onAnimation, self)
            return true
        end

        self.seats[self.bbpos].bigblind_betting = true
        self:betting(next_seat)
        self.seats[self.bbpos].bigblind_betting = false
        return true
    end

    local maxraise_seat = self.seats[self.maxraisepos] and self.seats[self.maxraisepos] or {reraise=false, roundmoney = 0}
    if maxraise_seat.reraise == true then
        log.debug("next_seat.pos:%d self.maxraisepos:%d", next_seat.pos, self.maxraisepos)
        log.debug("isAllCall:%d isAllAllin:%d", self:isAllCall() and 1 or 0, self:isAllAllin() and 1 or 0)

        if next_seat.pos == self.maxraisepos or self:isAllCall() or self:isAllAllin() then
            log.debug("maxraise_seat.reraise ... ")

            self.round_finish_time = G.ctms()
            T.tick(self.table_timer, network.cmd.TimeTickEvent_Animation, 100, onAnimation, self)

        else
            log.debug("maxraise_seat.reraise betting...")
            self:betting(next_seat)
        end
    else
        log.debug("!!! isReraise %d,%d,%d", self.maxraisepos, self.chipinpos, self.seats[self.chipinpos].chiptype)

        local chipin_seat = self.seats[self.chipinpos]
        local chipin_seat_chiptype = chipin_seat.chiptype
        if self:isAllCheck() or self:isAllAllin() or
                (self.maxraisepos == self.chipinpos and (network.cmd.CHIPIN_CHECK == chipin_seat_chiptype or network.cmd.CHIPIN_FOLD == chipin_seat_chiptype)) then
            log.debug("onAnimation")
            self.round_finish_time = G.ctms()
            T.tick(self.table_timer, network.cmd.TimeTickEvent_Animation, 100, onAnimation, self)
        else
            log.debug("onAnimation betting")
            self:betting(next_seat)
        end
    end
    return true
end

function Table:getNextState()
    local oldstate = self.state

    if oldstate == network.cmd.TexasTableState_Start then
        self.state = network.cmd.TexasTableState_PreFlop
        self:dealPreFlop()
    elseif oldstate == network.cmd.TexasTableState_PreFlop then
        self.state = network.cmd.TexasTableState_Flop
        self:dealFlop()
    elseif oldstate == network.cmd.TexasTableState_Flop then
        self.state = network.cmd.TexasTableState_Turn
		self:dealTurn()
    elseif oldstate == network.cmd.TexasTableState_Turn then
        self.state = network.cmd.TexasTableState_River
        self:dealRiver()
    elseif oldstate == network.cmd.TexasTableState_River then
        self.state = network.cmd.TexasTableState_Finish
    elseif oldstate == network.cmd.TexasTableState_Finish then
        self.state = network.cmd.TexasTableState_None
    end

    log.debug("State Change: %d => %d", oldstate, self.state)
end

function Table:dealPreChips()
    log.debug("Table dealPreChips ante:%d", self.ante)
    if self.ante > 0 then
        for i = 1, #self.seats do
            local seat = self.seats[i]
            if seat.isplaying then
                -- seat的chipin, 不是self的chipin
                seat:chipin(network.cmd.CHIPIN_PRECHIPS, self.ante)
                self:sendPosInfoToAll(seat)
            end
        end

        T.tick(self.table_timer, network.cmd.TimeTickEvent_PrechipsRoundOver, 1000, onPrechipsRoundOver, self)
    end
end

function Table:dealStraddle()
    log.debug("dealStraddle ...")
    if self.seats[self.current_betting_pos].uid ~= nil then
        local chipnum = 2 * self.bigblind
        self:chipin(self.seats[self.current_betting_pos].uid, network.cmd.CHIPIN_STRUGGLE, chipnum)
    else
        log.debug("dealStraddle uid is nil, current_betting_pos:%d", self.current_betting_pos)
    end
end

function Table:dealAntiEscapeBB()
    log.debug("dealAntiEscapeBB ...")

    if self.matchtype ~= pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") and
    self.matchtype ~= pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then
        return false
    end

    local arr = {}
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.uid and seat.isplaying  and self.bbpos ~= i and self.tableStartCount > 1 then
            log.debug("escapebb gamecount:%d,escape_bb_count:%d",seat.gamecount,seat.escape_bb_count)
			if  seat.gamecount == 0 or
				seat.escape_bb_count > 0 then
				table.insert(arr, seat)
				if seat.escape_bb_count > 0 then seat.escape_bb_count = 0 end
			end
        end
    end

    -- 不需要缴纳防逃盲
    if #arr == 0 then
        return false
    end

    for i = 1, #arr do
        local seat = arr[i]
        local chips = seat.chips < self.bigblind and seat.chips or self.bigblind
		--seat:chipin_escapebb(network.cmd.CHIPIN_LATE_BB, chips)
		seat:chipin_escapebb(network.cmd.CHIPIN_BIGBLIND, chips)
		self:sendPosInfoToAll(seat)
        --seat.escapebb = 0
    end

	if self.ante <= 0 then
        T.tick(self.table_timer, network.cmd.TimeTickEvent_PrechipsRoundOver, 1000, onPrechipsRoundOver, self)
	end


    return true
end

function Table:dealPreFlop()
    log.debug("dealPreFlop")
    local dealcard = {dealFromSid = self:getValidDealPos()}

    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.uid ~= nil then
            if seat.isplaying == true and seat.isdelayplay == false then
				if self.cfgcard_switch then
					seat.handcards[1] = S.pop(self.cards)
					seat.handcards[2] = S.pop(self.cards)
				else
					seat.handcards[1] = S.deal(self.cards)
					seat.handcards[2] = S.deal(self.cards)
				end

                local d = {
                    dealFromSid = self:getValidDealPos(),
                    sid         = i,
                    card1       = seat.handcards[1],
                    card2       = seat.handcards[2],
                }
                local c = pb.encode("network.cmd.PBDealCard", d)
                log.debug("手牌: 0x%x,0x%x", seat.handcards[1], seat.handcards[2])
            elseif seat.isdelayplay == true then
            end
        end
    end

    if self:isAllAllin() == true then
        self.round_finish_time = G.ctms()
        T.tick(self.table_timer, network.cmd.TimeTickEvent_Animation, 100, onAnimation, self)
    else
        local bbseat = self.seats[self.current_betting_pos]

        local nextseat = self:getNextActionPosition(bbseat)
        self:betting(nextseat)
    end
end

function Table:dealFlop()
    log.debug("dealFlop")

	if self.cfgcard_switch then
		self.boardcards[1] = S.pop(self.cards)
		self.boardcards[2] = S.pop(self.cards)
		self.boardcards[3] = S.pop(self.cards)
	else
		self.boardcards[1] = S.deal(self.cards)
		self.boardcards[2] = S.deal(self.cards)
		self.boardcards[3] = S.deal(self.cards)
	end

    log.debug("公共牌:0x%x,0x%x,0x%x", self.boardcards[1], self.boardcards[2], self.boardcards[3])

    local dealflopcards = {
        card1 = self.boardcards[1],
        card2 = self.boardcards[2],
        card3 = self.boardcards[3],
    }
    local content = pb.encode("network.cmd.PBDealFlopCards", dealflopcards)
    self:broadcastToAllObserver(0x0011, 0x100B, content) --PBTexasSubCmdID_DealFlopCards

	-- m_seats.dealFlop start
    self.maxraisepos = 0
    self.maxraisepos_real = 0
    self.chipinset[#self.chipinset + 1] = 0

    -- m_seats.dealFlop end

    if self:isAllAllin() == true then
        self:getNextState()
    else
        local buttonseat = self.seats[self.buttonpos]
        local nextseat = self:getNextActionPosition(buttonseat);
        self:betting(nextseat)
    end
end

function Table:dealTurn()
    log.debug("dealTurn")
	if self.cfgcard_switch then
		self.boardcards[4] = S.pop(self.cards)
	else
		self.boardcards[4] = S.deal(self.cards)
	end
    log.debug("转牌:0x%x", self.boardcards[4])

    local dealturncard = {
        card1 = self.boardcards[4]
    }
    local content = pb.encode("network.cmd.PBDealTurnCard", dealturncard)
    self:broadcastToAllObserver(0x0011, 0x100C, content) --PBTexasSubCmdID_DealTurnCard

    -- m_seats.dealTurn start
    self.maxraisepos = 0;
    self.maxraisepos_real = 0
    self.chipinset[#self.chipinset + 1] = 0
    -- m_seats.dealTurn end


    if self:isAllAllin() == true then
        self:getNextState()
    else
        local buttonseat = self.seats[self.buttonpos]
        local nextseat = self:getNextActionPosition(buttonseat);
        self:betting(nextseat)
    end

end

function Table:dealRiver()
    log.debug("dealRiver")
	if self.cfgcard_switch then
		self.boardcards[5] = S.pop(self.cards)
	else
		self.boardcards[5] = S.deal(self.cards)
	end
    log.debug("河牌:0x%x", self.boardcards[5])

    local dealrivercard = {
        card1 = self.boardcards[5]
    }
    local content = pb.encode("network.cmd.PBDealRiverCard", dealrivercard)
    self:broadcastToAllObserver(0x0011, 0x100D, content) --PBTexasSubCmdID_DealRiverCard

    -- m_seats.dealRiver start
    self.maxraisepos = 0;
    self.maxraisepos_real = 0
    self.chipinset[#self.chipinset + 1] = 0
    -- m_seats.dealRiver end

    if self:isAllAllin() == true then
        self:getNextState()
        self:finish()
    else
        local buttonseat = self.seats[self.buttonpos]
        local nextseat = self:getNextActionPosition(buttonseat);
        self:betting(nextseat)
    end

end

function Table:isAllAllin()
	local allin     = 0
    local playing   = 0
    local pos       = 0
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true then
            if seat.chiptype ~= network.cmd.CHIPIN_FOLD then
                playing = playing + 1
                if seat.chiptype == network.cmd.CHIPIN_ALL_IN then
                    allin = allin + 1
                else
                    pos = i
                end
            end
        end
    end

    log.debug("Table:isAllAllin playing:%d allin:%d self.maxraisepos:%d pos:%d", playing, allin, self.maxraisepos, pos)

    if playing == allin + 1 then
        if self.maxraisepos == pos or self.maxraisepos == 0 then
            return true
        end
    end

    if playing == allin then
        return true
    end
    return false
end

function Table:isAllCall()
    log.debug("Table:isAllCall...")
    local maxraise_seat = self.seats[self.maxraisepos]
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true then
            log.debug("Table:isAllCall chiptype:%d roundmoney:%d max_roundmoney:%d", seat.chiptype, seat.roundmoney, maxraise_seat.roundmoney)

            if seat.chiptype == network.cmd.CHIPIN_CALL and seat.roundmoney < maxraise_seat.roundmoney then
                return false
            end

            if seat.chiptype ~= network.cmd.CHIPIN_CALL and seat.chiptype ~= network.cmd.CHIPIN_FOLD and seat.chiptype ~= network.cmd.CHIPIN_ALL_IN then
                return false
            end
        end
    end
    return true
end

function Table:isAllFold()
    local fold_count = 0
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true then
            if seat.chiptype == network.cmd.CHIPIN_FOLD then
                fold_count = fold_count + 1
            end
        end
    end
    if fold_count == self:getPlayingSize() or fold_count + 1 == self:getPlayingSize() then
        return true
    else
        return false
    end
end

function Table:isAllCheck()
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true then
            if seat.chiptype ~= network.cmd.CHIPIN_CHECK and seat.chiptype ~= network.cmd.CHIPIN_FOLD and seat.chiptype ~= network.cmd.CHIPIN_ALL_IN then
                return false
            end
        end
    end
    return true
end

function Table:minraise()
    local current_betting_seat = self.seats[self.current_betting_pos]
    if self.state == network.cmd.TexasTableState_PreFlop then
        if #self.chipinset == 1 then
            if current_betting_seat ~= nil and current_betting_seat.chips < 2 * self.bigBlind then
                return current_betting_seat.chips
            end
            return 2 * self.bigBlind
        else

            local maxdiff, maxchipin, flag = self:getMaxDiff()
            if flag == false and maxdiff < self.bigBlind then
                maxdiff = self.bigBlind
            end
            if maxdiff + maxchipin < 2 * self.bigBlind then
                if current_betting_seat.chips < 2 * self.bigBlind then
                    return current_betting_seat.chips
                end
                return 2 * self.bigBlind
            end
            return maxdiff + maxchipin

        end
    elseif self.state > network.cmd.TexasTableState_PreFlop and self.state < network.cmd.TexasTableState_Finish then
        if #self.chipinset == 1 then
            if current_betting_seat.chips < self.bigBlind then
                return current_betting_seat.chips
            end
            return self.bigBlind
        else
            local maxdiff, maxchipin, flag = self:getMaxDiff()
            log.debug("minraise-- maxdiff:%d, maxchipin:%d, bb:%d",maxdiff, maxchipin,  self.bigBlind)
            if flag == false and maxdiff < self.bigBlind then
                maxdiff = self.bigBlind
            end
            if maxdiff + maxchipin < self.bigBlind then
                if current_betting_seat.chips < self.bigBlind then
                    return current_betting_seat.chips
                end
                return self.bigBlind
            end
            return maxdiff + maxchipin
        end
    end
    return 0
end

function Table:getMaxDiff()
    local maxdiff = 0
    local maxchipin = 0
    local flag = true

    if #self.chipinset == 0 then
        return maxdiff, maxchipin, flag
    end

	local i = 2
	while i <= #self.chipinset do
        local chipintable_temp = {}
        local j = 1
        while j <= i do
            chipintable_temp[j] = self.chipinset[j]
            j = j +1
        end
        table.sort(chipintable_temp)

        --参照文档：最小加注需求文档v1.0
        local chinin_temp_max = chipintable_temp[#chipintable_temp]--临时表最大元素
        local chinin_temp_sec_max = chipintable_temp[#chipintable_temp - 1]--临时表第二大元素
        local value1 = chinin_temp_max - chinin_temp_sec_max
        local value2 = self.chipinset[i] - self.chipinset[i-1] -- 元素Ni - N(i-1)
        local maxdiff_temp = value1 < value2 and value1 or value2

		maxdiff = math.max(maxdiff, maxdiff_temp)
		maxchipin = math.max(maxchipin, self.chipinset[i-1])
		if self.chipinset[i - 1] >= self.bigBlind then flag = false end
		i = i + 1
	end

	maxchipin = math.max(maxchipin, self.chipinset[#self.chipinset])
	if self.chipinset[#self.chipinset] >= self.bigBlind then flag = false end

    log.debug("max diff %d, chipin %d, flag %d", maxdiff, maxchipin, flag and 1 or 0);
    return maxdiff, maxchipin, flag
end

function Table:getMaxRaise(seat)
    if seat == nil or seat.uid == nil then
        return 0
    end

    local playing = 0
    local allin   = 0
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true then
            if seat.chiptype ~= network.cmd.CHIPIN_FOLD then
                playing = playing + 1
                if seat.chiptype == network.cmd.CHIPIN_ALL_IN then
                    allin = allin + 1
                end
            end
        end
    end

    log.debug("getMaxRaise playing:%d, allin:%d", playing, allin)

    local minraise_ = self:minraise()
    if playing == allin + 1 then
        local maxraise_seat = self.seats[self.maxraise_seat]
                          and self.seats[self.maxraise_seat]
                          or  {chips = 0}
        if maxraise_seat.chips < seat.chips then
            --return self:minraise()
            return minraise_
        end
    end
    --return seat.chips

    log.debug("getMaxRaise seatpos:%d maxraisepos:%d, maxraisepos_real:%d", seat.pos, self.maxraisepos , self.maxraisepos_real)
    if (self.maxraisepos == self.maxraisepos_real) then
        return seat.chips
    end
    -- 出现无效加注情况
    log.debug("getMaxRaise seat.roundmoney:%d, self.seats[self.maxraisepos_real].roundmoney:%d", seat.roundmoney, self.seats[self.maxraisepos_real].roundmoney)
    if (seat.roundmoney < self.seats[self.maxraisepos_real].roundmoney) then
    --if (seat.roundmoney < self.seats[self.maxraisepos_real].roundmoney) then
        --出现无效加注后没行动过的玩家，可以加注
        return seat.chips;
    end
    --出现无效加注前行动过的玩家，只能call or fold
    --如果出现无效加注后 再有玩家加注， m_maxraisepos_real == m_maxraisepos
    return minraise_;
end

function Table:betting(seat)
    if seat == nil then
        return false
    end
    log.debug("Table:betting pos:%d uid:%d", seat.pos, seat.uid)
    seat.bettingtime = G.ctsec()
    self.current_betting_pos = seat.pos

    -- 统计
    seat.si.totaljudgecount = seat.si.totaljudgecount + 1

    local function onBettingTimer(arg)
        log.debug("onBettingTimer ... ")
        local table = arg
        local current_betting_seat = table.seats[table.current_betting_pos]
        T.cancel(table.table_timer, network.cmd.TimeTickEvent_Betting)

        -- 留座的就立刻帮他fold牌
        if current_betting_seat.rv:getReservation() == network.cmd.PBLeaveToSitResultSucc then
            return table:userchipin(current_betting_seat.uid, network.cmd.CHIPIN_FOLD, 0)
        end

        if current_betting_seat:isChipinTimeout() == true then
			-- 操作超时
            --current_betting_seat.rv:chipinTimeoutCount() -- 记录超时次数，然后要马上判断是否已经留座了，要发包
            if current_betting_seat.rv:getReservation() == network.cmd.PBLeaveToSitResultSucc then
                self:notifyReservation(current_betting_seat, network.cmd.PBLeaveToSitResultSucc)
            end
            return table:userchipin(current_betting_seat.uid, network.cmd.CHIPIN_FOLD, 0)
        else
            return T.tick(table.table_timer, network.cmd.TimeTickEvent_Betting, 1000, onBettingTimer, table)  -- 不是尾调用
        end

    end

    self:updateSeatChipType(seat, network.cmd.CHIPIN_BETING);
    T.tick(self.table_timer, network.cmd.TimeTickEvent_Betting, 1000, onBettingTimer, self)
end

function Table:onRoundOver()
    log.debug("Table:onRoundOver ...")
    self:roundOver()
    if 4 == self.roundcount then
        log.debug("onRoundOver finish")
        self.finishstate = self.state
        self:finish()
    else
        if self:isAllAllin() then
            self.finishstate = self.state
        end

        self:getNextState()
    end
end

function Table:finish()
    log.debug("Table:finish ...\n 结束")

    local t_msec = self:nextRoundInterval() * 1000

    self.state = network.cmd.TexasTableState_Finish

    T.cancel(self.table_timer, network.cmd.TimeTickEvent_Betting)

    --[[ 计算在玩玩家最佳牌形和最佳手牌，用于后续比较 --]]
    for i = 1, #self.seats do
        local seat = self.seats[i]

        seat.rv:checkSitResultSuccInTime()

        if seat.chiptype ~= network.cmd.CHIPIN_FOLD and seat.isplaying == true then

            PH.initialize(self.pokerhands)
            PH.sethands(self.pokerhands, seat.handcards[1], seat.handcards[2], self.boardcards)
            seat.besthand = PH.checkhandstype(self.pokerhands)
            seat.handtype = PH.gethandstype(self.pokerhands)

			seat.si.WTSD = "YES"
        end
    end

	local minchip = self.minchip
    local total_winner_info = {} -- 总的奖池分池信息，哪些人在哪些奖池上赢取多少钱都在里面
    local FinalGame = {potInfos={}}
    -- 计算对于每个奖池，每个参与的玩家赢多少钱
    for i = self.potidx, 1, -1 do
        local winnerlist = {} -- i号奖池的赢牌玩家列表，能同时多人赢，所以用table

        for j = 1, #self.seats do
            local seat = self.seats[j]
            if seat.chiptype ~= network.cmd.CHIPIN_FOLD and seat.isplaying == true then
                -- i号奖池，j号玩家是有份参与的
                if self.pots[i].seats[j] ~= nil then
                    if #winnerlist == 0 then
                        table.insert(winnerlist, {pos = j, winmoney = 0})
                    end
                    -- 不和自己比较
                    if winnerlist[#winnerlist] ~= nil and winnerlist[#winnerlist].pos ~= j then
                        local tmp_wi = winnerlist[#winnerlist]
                        local winner_seat = self.seats[tmp_wi.pos]
                        local result = PH.comphandstype(self.pokerhands,
                                                    seat.handtype,
                                                    seat.besthand,
                                                    winner_seat.handtype,
                                                    winner_seat.besthand)

                        -- comphandstype(A.handtype, A.besthand, B.handtype, B.besthand)
                        -- 1：A赢牌   0：和牌   -1：A输牌
                        if result == 0 then
                            table.insert(winnerlist, {pos = j, winmoney = 0})
                        elseif result == 1 then
                            -- 发现目前为止牌形最大的人
                            winnerlist = {}
                            table.insert(winnerlist, {pos = j, winmoney = 0})

                        end
                    end
                end
            end
        end

        -- i号奖池赢钱人计算完成，下面计算赢多少钱
        if #winnerlist ~= 0 then
            local avg = math.floor(self.pots[i].money / #winnerlist)
            local avg_floor = math.floor(avg / minchip) * minchip
            local remain = self.pots[i].money - avg_floor * #winnerlist
            local remain_floor = math.floor(remain / minchip)

            if true then
                log.debug("big bug AAA avg:%d avg_floor:%d remain:%d remain_floor:%d", avg, avg_floor, remain, remain_floor)
            end

            if true then
                local avg = self.pots[i].money / #winnerlist
                local avg_floor = avg / minchip * minchip
                local remain = self.pots[i].money - avg_floor * #winnerlist
                local remain_floor = remain / minchip
                log.debug("big bug BBB avg:%d avg_floor:%d remain:%d remain_floor:%d", self.pots[i].money / #winnerlist,
                                                                                   avg / minchip * minchip,
                                                                                   self.pots[i].money - avg_floor * #winnerlist,
                                                                                   remain / minchip)
            end

            for j = self.sbpos,self.sbpos + #self.seats - 1 do
                local pos = j % #self.seats > 0 and j % #self.seats or #self.seats
                for k = 1, #winnerlist do
                    local wi = winnerlist[k]
                    if pos == wi.pos then
                        if remain_floor ~= 0 then
                            wi.winmoney = avg_floor + minchip
                            remain_floor = remain_floor - 1
                        else
                            wi.winmoney = avg_floor
                        end
                        break;
                    end
                end
            end
        end

        -- 加钱
        for j = 1, #winnerlist do
            local wi = winnerlist[j]
            self.seats[wi.pos].chips = self.seats[wi.pos].chips + wi.winmoney
        end

        for j = 1, #winnerlist do
            local wi = winnerlist[j]
            local potinfo = {}
            potinfo.potID = i - 1 -- i号奖池 (客户端那边potID从0开始)
            potinfo.sid = wi.pos
            potinfo.potMoney = self.pots[i].money
            potinfo.winMoney = wi.winmoney
            potinfo.seatMoney = self.seats[wi.pos].chips
            potinfo.mark = {}
            for k = 1, #self.seats[wi.pos].besthand do
                --potinfo.mark = self.seats[wi.pos].besthand[k]
                table.insert(potinfo.mark, self.seats[wi.pos].besthand[k])
            end
            if self:isAllFold() then
                potinfo.winType = network.cmd.WINNING
            else
                potinfo.winType = self.seats[wi.pos].handtype
            end
            table.insert(FinalGame.potInfos, potinfo)
        end

        -- 总的奖池分池信息获取， 用于上报等
        for j = 1, #winnerlist do
            local wi = winnerlist[j]
            local potid = i
            total_winner_info[potid] = total_winner_info[potid] or {}
            total_winner_info[potid][wi.pos] = wi.winmoney  -- 第 potid 个奖池，seatid 为 wi.pos 的人赢了 wi.winmoney
        end

    end

    -- show牌
    local poss = {} -- 记录赢钱的人的seatid  (Set)
    for i=1,#total_winner_info do
        for pos,winmoney in pairs(total_winner_info[i]) do
            poss[pos] = 1
        end
    end

	self:broadcastShowCardToAll(false, poss);
	self:broadcastCanShowCardToAll(poss)

    -- 广播结算
    local content = pb.encode("network.cmd.PBFinalGame", FinalGame)
	self:broadcastToAllObserver(0x0011, 0x1011, content) --PBTexasSubCmdID_FinalGame

	for uid, v in pairs(self.playing_users) do
        local seat = v
        local winmoney = 0
        for potid, info in pairs(total_winner_info) do
            for pos, w_m in pairs(info) do
                if pos == seat.seatid then
                    winmoney = winmoney + w_m
                end
            end
        end
        -- 金币在这1局中的变化
        seat.cgcoins = winmoney - seat.money
		print(uid,seat.cgcoins)
		-- 普通场/自建普通场更新
		self:updateChips(uid, seat.cgcoins)
    end

    self:getNextState()
    self.endtime = G.ctsec()
    self.round_finish_time = 0

    T.tick(self.table_timer, network.cmd.TimeTickEvent_Onfinish, t_msec, onFinish, self)

    for uid, v in pairs(self.playing_users) do
        local seat = v
        if seat then
			seat.gamecount = seat.gamecount + 1
			seat.reservback_gamecnt = seat.reservback_gamecnt + 1
        end
    end

    -- 牌局结束, 如果桌子上没人了，那下一局就随机大小盲。如果还剩下1人，那这个人下一局就不会让他当大盲(普通场规则)
    if self:getSitSize() == 0 then
        self.bbpos = -1
    elseif self:getSitSize() == 1 then
        for i = 1, #self.seats do
            local seat = self.seats[i]
            if seat.uid ~= nil and not seat.rv:isReservation() then
                self.bbpos = i
                break
            end
        end
    end

	return true
end

function Table:roundOver()
    log.debug("Table:roundOver ...")
    local allin = {}
    local allinset = {}
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true and seat.roundmoney > 0 then
            seat.money = seat.money + seat.roundmoney
            seat.chips = seat.chips > seat.roundmoney and seat.chips - seat.roundmoney or 0

            --本轮有下注的玩家
            if seat.chiptype ~= network.cmd.CHIPIN_FOLD then
                allinset[seat.roundmoney] = 1
            end
        end
    end

	for k,v in pairs(allinset) do
        table.insert(allin, k)
    end
    table.sort(allin)

	for i = 1, #self.seats do
		local seat = self.seats[i]
		if seat.isplaying == true then
			-- 当有人allin，potidx 要 +1， 以区分哪些奖池属于哪些人的
			-- ALLIN 位置在这一圈下注 0 ，说明是上一圈 ALLIN 的，这一圈有人下注要造一个新池
			if seat.chiptype == network.cmd.CHIPIN_ALL_IN and seat.roundmoney == 0 then
				if self.pots[self.potidx].seats[i] ~= nil then
					self.potidx = self.potidx + 1
					break
				end
			end
		end
	end

    if self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
       self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then
        -- 普通场能随便站起，（修复2个人，preflop，大盲站起，导致m_pots少了的bug）

        for i = 1, #allin do
            for j = 1, #self.seats do
                local seat = self.seats[j]
                if seat.isplaying == true then
                    if seat.roundmoney > 0 then
                        if i == 1 then
                            if seat.pos == self.bbpos then
                                local money = allin[i] > seat.roundmoney and seat.roundmoney or allin[i]
                                self.pots[self.potidx].money = self.pots[self.potidx].money + money
                            else

                                -- 你的下注大于别人allin， 或者别人allin 大于你的下注
                                local money = allin[i] > seat.roundmoney and seat.roundmoney or allin[i]
                                self.pots[self.potidx].money = self.pots[self.potidx].money + money
                            end
                            self.pots[self.potidx].seats[j] = j
                        else
                            local pot = allin[i] > seat.roundmoney and
                                        (seat.roundmoney > allin[i-1] and seat.roundmoney - allin[i-1] or 0) or
                                        allin[i] - allin[i-1]
                            if pot > 0 then
                                self.pots[self.potidx].money = self.pots[self.potidx].money + pot
                                self.pots[self.potidx].seats[j] = j
                            end
                        end
                    end
                end
            end

            self.potidx = self.potidx + 1
        end
    else
        for i = 1, #allin do
            for j = 1, #self.seats do
                local seat = self.seats[j]
                if seat.isplaying == true then
                    if seat.roundmoney > 0 then
                        if i == 1 then
                            -- 你的下注大于别人allin， 或者别人allin 大于你的下注
                            local money = allin[i] > seat.roundmoney and seat.roundmoney or allin[i]
                            self.pots[self.potidx].money = self.pots[self.potidx].money + money
                            self.pots[self.potidx].seats[j] = j
                        else
                            local pot = allin[i] > seat.roundmoney and
                                        (seat.roundmoney > allin[i-1] and seat.roundmoney - allin[i-1] or 0) or
                                        allin[i] - allin[i-1]
                            if pot > 0 then
                                self.pots[self.potidx].money = self.pots[self.potidx].money + pot
                                self.pots[self.potidx].seats[j] = j
                            end
                        end
                    end
                end
            end
            self.potidx = self.potidx + 1
        end
    end
	for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying == true then
            seat.roundmoney = 0
            seat.chipinnum = 0
            seat.reraise = false
            if seat.chiptype ~= network.cmd.CHIPIN_FOLD and seat.chiptype ~= network.cmd.CHIPIN_ALL_IN then
                seat.chiptype = network.cmd.CHIPIN_NULL
            end
        end
    end

    if #allin > 0 and self.potidx > 1 then
        self.potidx = self.potidx - 1
    end

    if self.state > network.cmd.TexasTableState_Start then
        self.roundcount = self.roundcount + 1
    end

    self:sendUpdatePotsToAll()
    self.chipinset = {}
end

function Table:sendUpdatePotsToAll()
	local updatepots = {}
	updatepots.roundNum = self.roundcount
	updatepots.publicPools = {}
	for i = 1,self.potidx do
		updatepots.publicPools[#updatepots.publicPools + 1] = self.pots[i].money
	end

	local content = pb.encode("network.cmd.PBUpdatePots", updatepots)
	self:broadcastToAllObserver(0x0011, 0x100F, content) -- PBTexasSubCmdID_UpdatePots
	return true
end


-- //0取消离座1请求离座
-- PBLeaveToSitResultSucc:留座成功(立刻生效)
-- PBLeaveToSitResultCancelSucc:取消成功
-- PBLeaveToSitResultReserveSucc:预留成功(下局生效)
function Table:reservation(uid, type)
    local seat = self:getSeatByUid(uid)
    log.debug("table reservation UID:%d type:%d sid:%d", uid, type, seat and seat.seatid or 0)
    if seat ~= nil then
        if type == 1 then
            if self.state == network.cmd.TexasTableState_Finish or
                self.state == network.cmd.TexasTableState_None or
                seat.chiptype == network.cmd.CHIPIN_FOLD or
                seat.isplaying == false then

                seat.isplaying = false

                -- 立刻留座
                local result = network.cmd.PBLeaveToSitResultSucc
                seat.rv:setReservation(result)
                self:notifyReservation(seat, result)
            else
                -- 预留成功
                local result = network.cmd.PBLeaveToSitResultReserveSucc
                seat.rv:setReservation(result)
                self:notifyReservation(seat, result)
            end
        else
            -- 取消离座
			if (seat.rv:getReservation() == network.cmd.PBLeaveToSitResultSucc )
                and (self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") or
				self.matchtype == pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular"))  then
				seat.reservback_gamecnt = 0
				seat.reservback_time = G.ctms()
				seat.isplaying = false
                seat.CancelRevJustNow = true

                log.debug("seat pos :%d, CancelRevJustNow:%d",seat.pos, seat.CancelRevJustNow and 1 or 0)
			end
            local result = network.cmd.PBLeaveToSitResultCancelSucc
            seat.rv:setReservation(result)
            self:notifyReservation(seat, result)
        end
    end
    return true
end

function Table:notifyReservation(seat, rs)
    local reservationResp = {
        sid = seat.seatid,
        result = rs,
    }
    local content = pb.encode("network.cmd.PBReservationResp", reservationResp)
    self:broadcastToAllObserver(0x0011, 0x101A, content) -- PBTexasSubCmdID_ReservationResp
end

function Table:roomchat(uid, msg)
    local content
    local touid
	local res
	local chattype
    content, touid, res, chattype = RC.roomchat(self.roomchat_mod, uid, msg)
	log.debug('Table:roomchat, uid:%d, content:%s, touid:%d, res:%d, chattype:%d', uid, content, touid, res, chattype)

	--弹幕扣除次数判断
	if res ~= nil and chattype == pb.enum_id("PBRoomChatType", "PBRoomChatType_Danmaku") then
		if res == pb.enum_id("PBChatSendResult", "ChatSendResult_Succ") then
			local send = {}
			send.type = pb.enum_id("PBRoomChatType", "PBRoomChatType_Danmaku")
			send.result = pb.enum_id("PBChatSendResult", "ChatSendResult_Succ")
			local sendarray = pb.encode("network.cmd.PBRespChatSendResult", send)
		elseif res == pb.enum_id("PBChatSendResult", "ChatSendResult_NoEnoughCnt") then
			local send = {}
			send.type = pb.enum_id("PBRoomChatType", "PBRoomChatType_Danmaku")
			send.result = pb.enum_id("PBChatSendResult", "ChatSendResult_NoEnoughCnt")
			local sendarray = pb.encode("network.cmd.PBRespChatSendResult", send)
			return
		end
	end

    if touid == 0 then
    else
    end

end

function Table:cfgCard(hand, boards)
	self.cfgcard_switch = true
	self.cfghandcards = hand
	self.cfgboardcards = boards
end

function Table:setcard()
	log.debug("setcard()")
	local pos = S.size(self.cards) - 1
    for i = 1, #self.seats do
        local seat = self.seats[i]
        if seat.isplaying then
			ret = S.getidxbycard(self.cards, self.cfghandcards[( i - 1) * 2 + 1])
			if ret ~= -1 then
				S.swapcards(self.cards, pos, ret)
			end
			pos = pos - 1
			ret = S.getidxbycard(self.cards, self.cfghandcards[( i - 1) * 2 + 2])
			if ret ~= -1 then
				S.swapcards(self.cards, pos, ret)
			end
			pos = pos - 1
        end
    end
	for i = 1, 5 do
		ret = S.getidxbycard(self.cards, self.cfgboardcards[i])
		if ret ~= -1 then
			S.swapcards(self.cards, pos, ret)
		end
		pos = pos - 1
	end
end

function Table:nextRoundInterval()
    local preflop_time = 1.2
    local flop_time = 1.2
    local turn_time = 0.9
    local river_time = 0.9
    local chips2pots_time = 2.5
    local show_card_time = 1.5

    local tm = 0.0
    local finishstate = self.finishstate
    if finishstate == network.cmd.TexasTableState_None or finishstate == network.cmd.TexasTableState_Start or finishstate == network.cmd.TexasTableState_PreFlop then
        tm = tm + flop_time + turn_time + river_time
    elseif finishstate == network.cmd.TexasTableState_Flop then
        tm = tm + turn_time + river_time
    elseif finishstate == network.cmd.TexasTableState_Turn then
        tm = tm + river_time
    --elseif finishstate == network.cmd.TexasTableState_River then
        --tm = tm + river_time
    end

    tm = tm + self:getPotCount() * chips2pots_time
    tm = tm + show_card_time
	if self.req_show_dealcard then
		tm = tm + show_card_time
	end

    if self:getPotCount() > 1 then
        tm = tm + 1.5
    end
    log.debug("Table:nextRoundInterval tm:%d %f, finishstate:%d potCount:%d",
                math.floor(tm + 0.5), tm+0.5, finishstate, self:getPotCount())
    return math.floor(tm + 0.5) -- 四舍五入
end

function Table:showDealCard(rev)
	-- 下一局开始了，屏蔽主动亮牌
    if self.state >= network.cmd.TexasTableState_Start
		and self.state <= network.cmd.TexasTableState_PreFlop then
		return
	end
	log.debug("req show deal card sid:%d", rev.sid)
	self.req_show_dealcard = true

	local send = {}
	send.showType = 2
	send.sid = rev.sid
	if rev.card1 ~= nil then
		send.card1 = rev.card1
	end
	if rev.card2 ~= nil then
		send.card2 = rev.card2
	end
	local content = pb.encode("network.cmd.PBShowDealCard", send)
	self:broadcastToAllObserver(pb.enum_id("network.cmd.PBMainCmdID", "PBMainCmdID_Texas"),
								pb.enum_id("network.cmd.PBTexasSubCmdID", "PBTexasSubCmdID_ShowDealCard"),
								content)
end


function Table:updateChips(uid, cnt, mod)
	if self.matchtype ~= pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") and
		self.matchtype ~= pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular") then
		return
	end
	local REQ  = {}
	REQ.orders = {}
	local item = {}
	item.uid = uid
	item.cnt = cnt
	item.cas = 0
	if mod then
		item.mod = mod
	else
		item.mod = cnt >=0 and network.inter.WL_W_PLAY or network.inter.WL_L_PLAY
	end
	item.bid = self.gameId
	item.tidx={}
	item.tidx.flag = G.sid()
	item.tidx.mid  = self.matchid
	item.tidx.tid  = self.tid
	item.tidx.time = 0
	table.insert(REQ.orders, item)
	local content = pb.encode("network.inter.MultiChipsUpdateReq", REQ)
	bpt.mscli.request_multi_chips_update(content, function(e)
	end)
end
-- table end


return Table

