local mod_name = "Seat"
local Seat = {}
--_G[mod_name] = Seat

local pb    = require "protobuf"
local log   = require "log"
local utils = require "utils"
local Reservation = require "Reservation"
local User = require "User"

-- seat start


function Seat.new(t ,seatid)
    local s = {}
    Seat.__index = Seat
    setmetatable(s, Seat)

    s:init(t, seatid)

    return s
end

function Seat:destroy()
end

function Seat:init(t, seatid)
    --self.uid = 0
    self.table = t
    self.seatid = seatid
    self.handtype = 0                   -- 手牌类型查看enum CardWinType
    self.handcards = {0,0}              -- 手牌
    self.besthand = {0,0,0,0,0}         -- 结算后的5张牌
    self.pos = seatid
    self.isplaying = false              -- 是否在玩状态
    self.chips = 0                      -- 剩余筹码数
    self.roundmoney = 0                 -- 一轮下注筹码值
    self.money = 0                      -- 一局总消耗筹码数
    self.chipinnum = 0                  -- 上一轮下注筹码值
    self.state = network.cmd.TexasSeatState_None -- 位置状态
    self.chiptype = network.cmd.CHIPIN_NULL -- 下注操作类型
    self.isdelayplay = false                -- 是否延迟进入比赛
    self.reraise = false                    -- 是否起reraise
    self.bettingtime = 0                    -- 下注时刻
    self.show = false                       -- 是否需要亮牌
    self.bigblind_betting = false
    self.cgcoins = 0                        -- 筹码变化
    self.save = 0                           -- 牌局是否收藏
	self.isputin = 0                        -- 是否入局
	self.escape_bb_count = 0                -- 防逃盲次数

	self.gamecount = 0
	self.reservback_gamecnt = 0				-- 留座回来座位游戏次数
	self.reservback_time = 0				-- 留座回来时刻,用来判断全部玩家留座之后 回来两个的最后一个用户

    self.CancelRevJustNow = false           --是否刚刚取消留座离桌，使得isplaying=false

    self.rv = Reservation.new(self.table, self)    -- 留座发生器

    self.si = {
        raisecount = 0,
        callcount = 0,
        totaljudgecount = 0,
        betcount = 0,
        threebetcount = 0,
		isallin = "NO",
		isputin = "VPIP_NOT",
		israise = "PFR_NOT",
		foldtime = 0,
		WTSD = "NO"
    }

    self.autobuy = 0  -- 普通场玩法自动买入
    self.buyinToMoney = 0 -- 普通场玩法自动买入多少钱
	self.autoBuyinToMoney = 0 --普通场勾选了自动买入后手动补币数
    self.escapebb = 0 -- 1: 坐下立刻交大盲，然后玩牌    0：分配到小盲或庄位要等1轮
	self.seat_timer = Timer.create()
end

function Seat:sit(uid, init_money, autobuy, escapebb)
	log.debug("Seat.lua Seat:sit, uid:%d", uid)
    if self.uid ~= nil then
        return false
    end

	self:reset()
    self.uid = uid
    self.chips = init_money
    self.state = network.cmd.TexasSeatState_PLAYING
    self.rv:reset()
    self.autobuy = autobuy
    self.buyinToMoney =init_money
    self.escapebb = escapebb or 0

    if self.autobuy == 0 then
        self.buyinToMoney = 0
    end

    self.user = User.new(uid)

	self.escape_bb_count = 0
    self.gamecount = 0
	self.reservback_gamecnt = 0
	if init_money == 0 then
		self.chips = 0
		self.chiptype = network.cmd.CHIPIN_BUYING
		Timer.tick(self.seat_timer, network.cmd.TimeTickEvent_buying, 10000, function(arg)
			T.cancel(self.match_timer, network.cmd.TimeTickEvent_buying)
            --玩家新进入桌子坐下10s倒计时，但是如果比赛正在进行，只允许下一局买入，比赛到下一局结束超过10s
            --时，会弹出玩家，玩家请求买入时设置变量self.buyinToMoney为买入的money，so self.buyinToMoney ~= 0
            --不让玩家站起，add by HassonLiu at 2017/08/02
			if self.chiptype == network.cmd.CHIPIN_BUYING and self.chips <= 0 and self.buyinToMoney == 0 then
				--站起
				self.table.stand(self.uid, network.cmd.PBTexasStandType_Kickout)
				log.debug("Seat.lua Seat:sit, tostand, buyin timeout %d", self.uid or 0)
			end
		end, self)
	end
    return true;
end

function Seat:stand(uid)
    if self.uid == nil then
        return false
    end

    self.uid = nil
    self.state = network.cmd.TexasSeatState_None

    -- 普通场可以随时站起，但isplaying要维持原来的，否则不参与结算
    if self.table.matchtype ~= pb.enum_id("network.cmd.PBMatchType", "PBMatchType_Regular") and
       self.table.matchtype ~= pb.enum_id("network.cmd.PBMatchType", "PBMatchType_SelfRegular")  then
        self.isplaying = false
    end

    self.user = nil
    self.autobuy = 0
    self.buyinToMoney = 0
	self.autoBuyinToMoney = 0
    self.escapebb = 0

    self.escape_bb_count = 0
    self.gamecount = 0
	self.reservback_gamecnt = 0

	self.rv.is_set_rvtimer = false
    return true
end

function Seat:reset()
    self.handtype = 0
    self.handcards = {0,0}
    self.besthand = {0,0,0,0,0}
    self.money = 0
    self.roundmoney = 0
    self.chipinnum = 0
    self.chiptype = network.cmd.CHIPIN_NULL
    self.isplaying = false
    self.reraise = false
    self.bettingtime = 0
    self.show = false
    self.bigblind_betting = false
    self.cgcoins = 0
    self.save = 0
	self.isputin = 0

    self.si = {
        raisecount = 0,
        callcount = 0,
        totaljudgecount = 0,
        betcount = 0,
        threebetcount = 0,
		isallin = "NO",
		isputin = "VPIP_NOT",
		israise = "PFR_NOT",
		foldtime = 0,
		WTSD = "NO"
    }
end

function Seat:chipin(type, money)
    log.debug("Seat:chipin UID:%d pos:%d type:%d money:%d chips:%d", self.uid, self.pos, type, money, self.chips)
    self.chiptype = type
    self.chipinnum = self.roundmoney
    self.roundmoney = money

	if (type == network.cmd.CHIPIN_CALL or type == network.cmd.CHIPIN_RAISE or type == network.cmd.CHIPIN_ALL_IN) then
		self.isputin = 1
	end
	if type == network.cmd.CHIPIN_FOLD then
		self.si.foldtime = self.table.state - 1
	end
    if money >= self.chips and type ~= network.cmd.CHIPIN_FOLD then
        self.chiptype = network.cmd.CHIPIN_ALL_IN
        self.roundmoney = self.chips
        money = self.chips
    end

    if type ~= network.cmd.CHIPIN_FOLD and type ~= network.cmd.CHIPIN_BIGBLIND and type ~= network.cmd.CHIPIN_SMALLBLIND then
        self.rv:resetBySys()
    end

    -- 统计
    if network.cmd.CHIPIN_CALL == self.chiptype or
       network.cmd.CHIPIN_RAISE == self.chiptype or
       network.cmd.CHIPIN_ALL_IN == self.chiptype then
		   self.si.isputin = "VPIP_YES"

       if network.cmd.CHIPIN_RAISE == self.chiptype then
            self.si.raisecount = self.si.raisecount + 1
       end
       if network.cmd.CHIPIN_CALL == self.chiptype then
            self.si.callcount = self.si.callcount + 1
       end
       if network.cmd.CHIPIN_ALL_IN == self.chiptype then
            self.si.isallin = "YES"
       end

    end

	self.table.lastchipintype = self.chiptype
	self.table.lastchipinpos = self.pos
    return true
end

function Seat:isChipinTimeout()
    local elapse = G.ctsec() - self.bettingtime
    if elapse > self.table.bettingtime then
        return true
    else
        return false
    end
end

function Seat:getChipinLeftTime()
    local now = G.ctsec()
    local elapse = now -  self.bettingtime
    if elapse > self.table.bettingtime then
        return 0
    else
        return now + self.table.bettingtime - self.bettingtime
    end
end

function Seat:chipin_escapebb(type, money)
	local money = self.roundmoney + money
	self.chiptype = type
	self.chipinnum = self.roundmoney
	self.roundmoney = money
	if money >= self.chips and type ~= network.cmd.CHIPIN_FOLD then
		self.chiptype = network.cmd.CHIPIN_ALL_IN
		self.roundmoney = self.chips
		money = self.chips
		log.debug("TexasSeat::chipin_escapebb allin")
	end

	--if self.chips >= money then
		--self.chiptype = type
		--self.chips = self.chips - money
	--end
    return true
end


-- seat end

--return Seat
return {
    new = Seat.new,
    init = Seat.init,
    sit = Seat.sit,
    stand = Seat.stand,
    reset = Seat.reset,
    chipin = Seat.chipin,
    isChipinTimeout = Seat.isChipinTimeout,
    --getChipinLeftTime = Seat.getChipinLeftTime,
}
