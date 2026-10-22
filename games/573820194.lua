local __modules, __cache, __loading = {}, {}, {}
local function use(name)
    local cached = __cache[name]
    if cached ~= nil then
        return cached
    end
    local loader = __modules[name]
    if not loader then
        error("NOX: no module named " .. tostring(name), 2)
    end
    if __loading[name] then
        error("NOX: circular use of " .. tostring(name), 2)
    end
    __loading[name] = true
    -- A module that errors is unmarked, so the next use() reports its error, not a cycle.
    local trace = debug and type(debug.traceback) == 'function' and debug.traceback or tostring
    local ok, result = xpcall(loader, trace, use)
    __loading[name] = nil
    if not ok then
        error(result, 0)
    end
    if result == nil then
        result = true
    end
    __cache[name] = result
    return result
end
__modules["core/env"] = function(use)
-- Ball VS Ball: the game's own ModuleScripts and remotes. Everything else (services, the executor,
-- elevate) comes from shared/env.
--
-- Remotes use sleitnick Net names. Resolve their instances under Packages without invoking
-- the module loader while resolving a replicated event or function.

local Env = use("shared/env")

Env.checkMissing({
    { "queue_on_teleport", Env.queueOnTeleport },
    { "setclipboard", Env.setClipboard },
})
for name, _ in pairs({ readfile = true, writefile = true, isfile = true, isfolder = true,
    makefolder = true, listfiles = true, delfile = true }) do
    Env.checkMissing({ { name, Env.files[name] } })
end
table.sort(Env.missing)

local RS = Env.ReplicatedStorage
local SERVICE = { "Engine", "Service" }
local function service(name)
    return { SERVICE[1], SERVICE[2], name }
end

-- Env.loadModule("Config"), Env.loadModule("PlayerData"), ...: required on first use and cached.
Env.Game, Env.loadModule = Env.modules(RS, {
    Net = { "Packages", "Net" },
    Config = service("Config"), -- the game's CloudConfig: balls, codes, quests, crates, limits
    PlayerData = service("PlayerData"),
    ExperienceService = service("ExperienceService"),
    TimeService = service("TimeService"),
    GameModeRegistry = service("GameModeRegistry"),
    CheckInService = service("CheckInService"),
    OnlineRewardConfig = service("OnlineRewardConfig"),
    HalloweenCandyRules = service("HalloweenCandyRules"), -- which event is on, its end, the daily candy cap
    StatsCore = { "Engine", "Service", "BallBattleStatsService", "Core" },
    BattleConfig = { "BattleDemo", "BattleConfig" },
    BattleSimulation = { "BattleDemo", "BattleSimulation" },
    ArenaOverride = { "BattleDemo", "ArenaOverride" },
})

local remotes = {}
local CONSTRUCTORS = { event = "RemoteEvent", unreliable = "UnreliableRemoteEvent", fn = "RemoteFunction" }
local PREFIX = { event = "RE/", unreliable = "URE/", fn = "RF/" }
local function remote(kind, name)
    Env.elevate()
    local key = kind .. name
    if not remotes[key] or not remotes[key].Parent then
        -- Locate the replicated instance without requiring Net in a lazy-table lookup;
        -- matching the class avoids an event/function mixup.
        local packages = Env.need(RS, "Packages", 10)
        local found = packages:FindFirstChild(PREFIX[kind] .. name, true)
        local deadline = os.clock() + 5
        while not found and os.clock() < deadline do
            task.wait(0.1)
            found = packages:FindFirstChild(PREFIX[kind] .. name, true)
        end
        Env.elevate()
        if not found then
            error("NOX: remote " .. name .. " is not available yet", 2)
        end
        assert(found:IsA(CONSTRUCTORS[kind]), "NOX: remote " .. name .. " has an unexpected class")
        remotes[key] = found
    end
    return remotes[key]
end

-- The RemoteEvent the game calls `name` ("DuelTableState").
function Env.event(name)
    return remote("event", name)
end

-- The UnreliableRemoteEvent the game calls `name` ("DuelTableAimPreview").
function Env.unreliable(name)
    return remote("unreliable", name)
end

local pending, retryAt = {}, {}
Env.requestIssues = {}

-- A timeout cannot undo a server action. Keep that remote occupied until its original call
-- finishes, then allow replication time before another request. Never retry inside this helper.
function Env.invoke(name, ...)
    if Env.stopped then return false, "hub unloaded" end
    if pending[name] or os.clock() < (retryAt[name] or 0) then
        return false, "waiting for the previous " .. name .. " request"
    end
    local work, args = {}, table.pack(...)
    pending[name] = work
    task.spawn(function()
        work.result = table.pack(Env.call(function()
            local fn = remote("fn", name)
            return fn:InvokeServer(table.unpack(args, 1, args.n))
        end))
        work.done = true
        if work.timedOut then
            retryAt[name] = os.clock() + 30
            Env.requestIssues[name] = "Late reply received; waiting for inventory/balance updates."
            local untilAt = retryAt[name]
            task.delay(30, function()
                if retryAt[name] == untilAt then Env.requestIssues[name] = nil end
            end)
        end
        if pending[name] == work then pending[name] = nil end
    end)
    local deadline = os.clock() + 15
    while not work.done and not Env.stopped and os.clock() < deadline do task.wait(0.05) end
    Env.elevate()
    if Env.stopped then return false, "hub unloaded" end
    if not work.done then
        work.timedOut = true
        Env.requestIssues[name] = "No reply yet; duplicate requests are paused."
        return false, "request timed out; its result is not yet known"
    end
    Env.requestIssues[name] = nil
    return table.unpack(work.result, 1, work.result.n)
end

-- What kind of server this is: "standard" (3 HP tables), "twoVTwoServer" (2v2 tables) or
-- "tradeServer", or nil until the game has said. Since the October 16 update each mode has its own
-- servers and Quick Play seats you at whatever this one has. The game's ServerTeleport package
-- keeps it as an attribute on its module; getServerType() waits for it, this does not.
function Env.serverType()
    local ok, kind = pcall(function()
        for _, child in ipairs(Env.need(RS, "Packages", 10)._Index:GetChildren()) do
            if child.Name:find("serverteleport", 1, true) then
                local module = child:FindFirstChild("serverteleport")
                return module and module:GetAttribute("serverType")
            end
        end
        return nil
    end)
    Env.elevate()
    return ok and type(kind) == "string" and kind or nil
end

-- The local player's saved data as the game's client sees it: Env.data("coins") -> 490.
-- Nil when the value is not there (yet).
function Env.data(key)
    local ok, value = Env.call(function()
        return Env.loadModule("PlayerData").client[key]()
    end)
    if ok then return value end
    return nil
end

-- A ball's English name (roleIds are the game's Chinese ids, e.g. "刀片球" -> "Blade Ball").
function Env.ballName(roleId)
    local ok, ball = pcall(function()
        return Env.loadModule("Config").ball.byCnId[roleId]
    end)
    return ok and ball and ball.displayName or tostring(roleId)
end

return Env
end
__modules["core/fusion"] = function(use)
-- October 2026: rarity fusion takes ten Classic balls; form fusion takes six matching copies.
-- Keep tradeability groups separate so automatic fusion cannot bind a tradable copy's result.
local Env = use("core/env")
local Fusion = {}

function Fusion.requiredCount(mode)
    if mode == nil or mode == "Higher rarity" then
        return 10
    elseif mode == "Shiny" or mode == "Rainbow" then
        return 6
    end
end

function Fusion.kind(item)
    if item.serial ~= nil then
        return "Rainbow"
    end
    local kills
    if type(item.metadata) == "table" then
        kills = item.metadata.killCount
    end
    if kills == nil then
        kills = item.killCount
    end
    if kills == nil then
        return "Classic"
    end
    if type(kills) == "number" and kills >= 0 and kills < math.huge and kills % 1 == 0 then
        return "Shiny"
    end
    return nil -- malformed kill metadata must not turn a special copy into a Classic material
end

function Fusion.nextBatch(items, equipment, maxRating, reserved, allowedBall, mode)
    mode = mode or "Higher rarity"
    local required = Fusion.requiredCount(mode)
    if not required then
        return nil
    end
    reserved = reserved or {}
    local materialKind = mode == "Rainbow" and "Shiny" or "Classic"
    local equipped = {}
    for _, value in pairs(type(equipment) == "table" and equipment or {}) do
        local id = type(value) == "table" and (value.id or value.instanceId) or value
        if type(id) == "string" then
            equipped[id] = true
        end
    end
    local groups = {}
    for id, item in pairs(type(items) == "table" and items or {}) do
        if type(id) == "string" and type(item) == "table" and item.itemType == "Ball"
            and type(item.itemId) == "string" and item.ownerUserId == Env.LocalPlayer.UserId
            and Fusion.kind(item) == materialKind and (mode ~= "Higher rarity" or item.canFusion == true)
            and not equipped[id] and not reserved[id]
            and (item.locks == nil or (type(item.locks) == "table" and next(item.locks) == nil)) then
            local ball = Env.loadModule("Config").ball.byCnId[item.itemId]
            if ball and type(ball.rating) == "number" and ball.rating <= maxRating
                and (not allowedBall or allowedBall(item.itemId)) then
                local key = item.itemId .. (item.tradable == true and ":tradable" or ":bound")
                local group = groups[key]
                if not group then
                    group = { ballId = item.itemId, rating = ball.rating, key = key, ids = {} }
                    groups[key] = group
                end
                group.ids[#group.ids + 1] = id
            end
        end
    end
    local candidates = {}
    for _, group in pairs(groups) do
        if #group.ids > required then -- retain one copy of each ball/tradability group
            candidates[#candidates + 1] = group
        end
    end
    table.sort(candidates, function(a, b)
        return a.rating < b.rating or (a.rating == b.rating and a.key < b.key)
    end)
    local group = candidates[1]
    if not group then
        return nil
    end
    table.sort(group.ids)
    return table.move(group.ids, 2, required + 1, 1, {}), group.ballId
end

return Fusion
end
__modules["core/limits"] = function(use)
-- How many duel coins are left today and this week. Duels pay nothing once either cap is reached
-- (the game's config: misc.coinsLimit, 6,000 a day and 30,000 a week at the time of writing).
-- The saved counters only count for the day/week key they were written under, the same way the
-- game's DuelCoinLimitService reads them.

local Env = use("core/env")

local Limits = {}

local function limitsConfig()
    local ok, limits = pcall(function()
        return Env.loadModule("Config").misc.coinsLimit
    end)
    return ok and type(limits) == "table" and limits or {}
end

-- { day, dayMax, week, weekMax, capped } (a max is nil when the game has no such cap).
-- The whole lookup is optional: a place without TimeService reports no progress rather than
-- throwing out of the panels and the duel loop that call this every half second.
function Limits.coins()
    local config = limitsConfig()
    local saved = Env.data("duelCoinLimit") or {}
    local dayMax, weekMax = config["每日金币上限"], config["每周金币上限"]
    local okDay, dayKey = Env.call(function()
        return Env.loadModule("TimeService").getDayKey(0, config["每日重置时间"])
    end)
    local okWeek, weekKey = Env.call(function()
        return Env.loadModule("TimeService").getWeekKey(0, config["每周重置时间"], config["每周重置日期"])
    end)
    local day = okDay and saved.dailyKey == dayKey and saved.dailyEarned or 0
    local week = okWeek and saved.weeklyKey == weekKey and saved.weeklyEarned or 0
    local capped = (type(dayMax) == "number" and day >= dayMax) or (type(weekMax) == "number" and week >= weekMax)
    return { day = day, dayMax = dayMax, week = week, weekMax = weekMax, capped = capped == true }
end

-- Halloween candy: every 3 HP or 2v2 match pays 1, won or lost, up to the event's daily cap (30),
-- and keeps paying after the coin cap. Saved per event as halloweenCandy[eventId] =
-- { balance, dayKey, dailyEarned }, where dailyEarned only counts for its own dayKey.
-- { active, eventId, balance, today, dayMax, capped, endsIn }; active is false outside the event.
function Limits.candy()
    local ok, event, now = Env.call(function()
        local now = Env.loadModule("TimeService").now()
        return Env.loadModule("HalloweenCandyRules").active(Env.loadModule("Config").event.list, now), now
    end)
    if not ok or type(event) ~= "table" or type(event.cnId) ~= "string" then
        return { active = false, balance = 0, today = 0, capped = true }
    end
    local dayMax = type(event.feature) == "table" and tonumber(event.feature["每日糖果上限"]) or nil
    local saved = Env.data("halloweenCandy")
    local mine = type(saved) == "table" and type(saved[event.cnId]) == "table" and saved[event.cnId] or {}
    local okDay, dayKey = Env.call(function()
        return Env.loadModule("TimeService").getDayKeyAt(now, 0)
    end)
    local today = okDay and mine.dayKey == dayKey and tonumber(mine.dailyEarned) or 0
    local okLeft, left = Env.call(Env.loadModule("HalloweenCandyRules").remainingSeconds, event, now)
    return {
        active = true,
        eventId = event.cnId,
        balance = tonumber(mine.balance) or 0,
        today = today,
        dayMax = dayMax,
        capped = dayMax ~= nil and today >= dayMax,
        endsIn = okLeft and tonumber(left) or nil,
    }
end

return Limits
end
__modules["core/match"] = function(use)
-- What the server tells us about our table: its state, the ball and upgrade offers, and the
-- replays of this match.
--
-- A match is rounds of Picking (30s to choose one of 3 offered balls), Aiming (30s to set the
-- launch direction) and Playing (the server simulates the battle and streams a replay). Each
-- player has 3 hp and a lost round costs 1. Battles are deterministic: the replay's seed, balls and
-- directions reproduce the result exactly (see core/sim), and round r's seed is round 1's seed
-- plus (r - 1) * 1009. So once round 1 has been replayed, every later round's seed is known while
-- we still choose.

local Env = use("core/env")
local Life = use("shared/life")

local SEED_STEP = 1009

local Match = {
    tableModel = nil,
    tableId = nil,
    state = nil, -- the latest DuelTableState of our table
    slot = nil, -- our key in state.players ("Blue", "Yellow", "Blue1"...)
    left = false, -- a state showed our table, or every table, without us
    offer = nil, -- the latest ball offer: { offer = {roleIds}, selectPrice, rerollPrice, at }
    selectList = nil, -- the free pick's list: { roleIds, at }
    weeklyFreeRoleIds = {}, -- server-provided weekly choices for this match; never infer owned items
    upgradeOffer = nil, -- { offer = { { kind, id } }, at }
    ballLocked = nil, -- { roleId, at }
    aimToken = nil, -- a new table each time Aiming starts
    aimStartedAt = 0, -- os.clock() when it did
    aimLocked = nil, -- { direction, at }
    teammateAim = nil, -- 2v2: { userId, direction, at } as the teammate drags their aim
    liveAims = {}, -- per-userId { direction, at } from any aim-preview relay seen this round
    replays = {}, -- this match's replays by round
    lastReplay = nil,
    capped = false, -- the server said today's duel coins are used up
    queueRefusal = nil, -- { reason, at } when Quick Play last said no
    status = nil, -- what auto duel is doing (set by features/duel, shown on Home)
    prediction = nil, -- the solver's reasoning for the round in play (set by features/duel)
    history = nil, -- recent rounds and whether their predictions held (set by features/duel)
    session = nil, -- this session's match, round and coin tally (set by features/duel)
}

local listeners = {}

function Match.phase()
    return Match.state and Match.state.state or nil
end

-- Bind independently so one missing optional event cannot prevent all match tracking. The
-- connector retries after replication and disconnects a replaced remote before rebinding.
--
-- Exported because binding a remote at module load means a renamed or absent one errors out of
-- the whole feature on the way up: a hub that loses the coin tally should not also lose auto duel.
function Match.listen(name, fn, unreliable)
    local current, connection
    Life.loop("remote:" .. name, 5, function()
        if connection and connection.Connected and current and current.Parent then return end
        if connection then connection:Disconnect() end
        current = unreliable and Env.unreliable(name) or Env.event(name)
        connection = Life.connect(current.OnClientEvent, fn, "match:" .. name)
    end)
end
local listen = Match.listen

-- fn(replay, won) after each replay of our table. `won` is true, false, or nil for a draw.
function Match.onRound(fn)
    listeners[#listeners + 1] = fn
end

local function hasMe(state)
    local players = type(state) == "table" and state.players
    if type(players) ~= "table" then
        return nil
    end
    for slot, player in pairs(players) do
        if type(player) == "table" and player.userId == Env.LocalPlayer.UserId then
            return slot
        end
    end
    return nil
end

local function newMatch()
    table.clear(Match.replays)
    table.clear(Match.weeklyFreeRoleIds)
    Match.lastReplay = nil
    Match.offer, Match.selectList, Match.upgradeOffer = nil, nil, nil
    Match.ballLocked, Match.aimLocked = nil, nil
    Match.aimToken, Match.teammateAim = nil, nil
    table.clear(Match.liveAims)
end

local function applyState(state)
    local slot = hasMe(state)
    if not slot then
        return false
    end
    if state.tableId ~= Match.tableId or (state.state == "Countdown" and Match.phase() ~= "Countdown") then
        newMatch()
    end
    -- A fresh token each time the table enters Aiming, so each round is aimed once.
    if state.state == "Aiming" and (Match.phase() ~= "Aiming" or Match.aimToken == nil) then
        Match.aimToken, Match.aimLocked, Match.teammateAim = {}, nil, nil
        Match.aimStartedAt = os.clock()
        table.clear(Match.liveAims)
    end
    Match.tableId = state.tableId
    if typeof(state.table) == "Instance" then
        Match.tableModel = state.table
    end
    Match.state, Match.slot, Match.left = state, slot, false
    return true
end

-- The server only sends states when a table changes, so there can be long quiet stretches (a
-- whole battle): being seated is decided by what the states say, never by how long ago one came.
listen("DuelTableState", function(payload)
    if type(payload) ~= "table" then
        return
    end
    if payload.table then
        if not applyState(payload) and payload.tableId == Match.tableId then
            Match.left = true
        end
        return
    end
    if type(payload.tables) ~= "table" then
        return
    end
    local found = false
    for _, state in pairs(payload.tables) do
        found = applyState(state) or found
    end
    -- A full snapshot (every table) without us: we are not at any table.
    if not found and Match.state then
        Match.left = true
    end
end)

-- Offers and locks are only sent to the players at the table, so they are ours.
local function stamp(payload)
    local copy = table.clone(type(payload) == "table" and payload or {})
    copy.at = os.clock()
    copy.revision = 0
    return copy
end

local function updateWeeklyFree(payload)
    if type(payload) ~= "table" or type(payload.weeklyFreeRoleIds) ~= "table" then
        return
    end
    table.clear(Match.weeklyFreeRoleIds)
    for _, id in ipairs(payload.weeklyFreeRoleIds) do
        if type(id) == "string" then
            Match.weeklyFreeRoleIds[id] = true
        end
    end
end

function Match.isWeeklyFree(roleId)
    return Match.weeklyFreeRoleIds[roleId] == true
end

listen("DuelTableBallOffer", function(model, payload)
    if typeof(model) ~= "Instance" or type(payload) ~= "table" then return end
    -- The first offer of a match is not a reselect: whatever we saw before belongs to another match
    -- (even at the same table), and its seed must not be used.
    if type(payload) == "table" and not payload.isReselect then
        newMatch()
    end
    Match.tableModel = model
    Match.offer, Match.selectList, Match.ballLocked = stamp(payload), nil, nil
    updateWeeklyFree(payload)
end)
-- Keep the offer's identity and original deadline. A reroll is a revision of that offer,
-- not another picking window. Failed replies also release the response wait.
local function rerolled(model, payload, offer)
    if not Life.alive or model ~= Match.tableModel or type(payload) ~= "table" or not offer then
        return
    end
    offer.rerollReplyAt = os.clock()
    offer.rerollPending = false
    offer.rerollError = payload.reason
    if payload.ok ~= false and type(payload.offer) == "table" then
        offer.offer = payload.offer
        offer.revision += 1
        updateWeeklyFree(payload)
    end
    for _, key in ipairs({ "rerollPrice", "rerollCurrency", "canReroll", "rerollsRemaining", "freeRerolls" }) do
        if payload[key] ~= nil then
            offer[key] = payload[key]
        end
    end
end
listen("DuelTableBallRerollResult", function(model, payload)
    if Match.phase() == "Picking" and not Match.ballLocked then
        rerolled(model, payload, Match.offer)
    end
end)
listen("DuelTableUpgradeRerollResult", function(model, payload)
    if Match.phase() == "Upgrading" then
        rerolled(model, payload, Match.upgradeOffer)
    end
end)
listen("DuelTableRerollDenied", function(model, reason)
    local offer = Match.phase() == "Picking" and Match.offer or Match.upgradeOffer
    rerolled(model, { ok = false, reason = reason }, offer)
end)
listen("DuelTableBallSelectPurchaseResult", function(model, payload)
    if model == Match.tableModel and type(payload) == "table" and payload.ok ~= false
        and type(payload.roleIds) == "table" and Match.phase() == "Picking" and not Match.ballLocked then
        Match.selectList = stamp(payload)
        if Match.offer then
            Match.offer.selectPending = false
            Match.offer.selectError = nil
        end
        updateWeeklyFree(payload)
    end
end)
listen("DuelTableBallSelectDenied", function(model, reason)
    if model == Match.tableModel and Match.offer then
        Match.offer.selectPending = false
        Match.offer.selectError = reason or "unavailable"
    end
end)
listen("DuelTableBallSelectConfirmDenied", function(model, reason, price)
    if model == Match.tableModel and Match.offer then
        Match.offer.selectConfirmError = reason or "refused"
        if type(price) == "number" then
            Match.offer.selectPrice = price
        end
    end
end)
listen("DuelTableBallLocked", function(model, payload)
    if model == Match.tableModel then
        Match.ballLocked = stamp(payload)
    end
end)
listen("DuelTableBallSelectConfirmed", function(model, payload)
    if model == Match.tableModel then
        Match.ballLocked = stamp(payload)
    end
end)
listen("DuelTableUpgradeOffer", function(model, payload)
    Match.tableModel = model
    Match.upgradeOffer = stamp(payload)
end)
listen("DuelTableUpgradeLocked", function(model)
    if model == Match.tableModel then
        Match.upgradeOffer = nil
    end
end)
listen("DuelTableLaunchLocked", function(model, payload)
    if model == Match.tableModel then Match.aimLocked = stamp(payload) end
end)
-- In 2v2 the server relays the teammate's aim while they drag it: (table, their userId, direction).
listen("DuelTableAimPreview", function(model, userId, direction)
    if model == Match.tableModel and typeof(direction) == "Vector2" then
        Match.teammateAim = { userId = userId, direction = direction, at = os.clock() }
        if type(userId) == "number" then
            Match.liveAims[userId] = { direction = direction, at = os.clock() }
        end
    end
end, true)
listen("DuelCoinLimitReached", function()
    Match.capped = true
end)
-- Quick Play's answer: (false, "noAvailableTable") when this server has no free seat. The game
-- then offers to move you to another server; auto duel only reports it.
listen("DuelQuickPlayResult", function(ok, reason)
    Match.queueRefusal = ok == false and { reason = tostring(reason or "refused"), at = os.clock() } or nil
end)

listen("DuelTableReplayStream", function(replay)
    if type(replay) ~= "table" or replay.tableId ~= Match.tableId or type(replay.round) ~= "number" then
        return
    end
    Match.replays[replay.round] = replay
    Match.lastReplay = replay
    local me = Env.LocalPlayer.UserId
    local won = nil
    if replay.isDraw ~= true then
        won = table.find(type(replay.winnerUserIds) == "table" and replay.winnerUserIds or {}, me) ~= nil
            or replay.winnerUserId == me
    end
    for index, fn in ipairs(listeners) do
        Life.spawn("match:round:" .. index, fn, replay, won)
    end
end)

local function canReroll(offer, allowDiamonds)
    if not offer or offer.rerollTried or offer.rerollPending or offer.canReroll == false
        or (type(offer.rerollsRemaining) == "number" and offer.rerollsRemaining <= 0) then
        return false
    end
    if type(offer.freeRerolls) == "number" and offer.freeRerolls > 0 then
        return true
    end
    -- The shipped client hides a zero-price reroll; only explicit metadata enables a free one.
    local price = offer.rerollPrice
    if price == 0 then
        return offer.canReroll == true
    end
    -- DuelChoice handles an insufficient reroll by opening DiamondTopUpService. Rerolls
    -- without currency metadata are priced in diamonds, so coins cannot fund them.
    local currency = offer.rerollCurrency or "diamonds"
    if currency == "diamonds" and not allowDiamonds then
        return false
    end
    return (currency == "coins" or currency == "diamonds") and type(price) == "number" and price > 0
        and (tonumber(Env.data(currency)) or 0) >= price
end

function Match.canRerollBall(allowDiamonds)
    return Match.seated() and Match.phase() == "Picking" and not Match.ballLocked and canReroll(Match.offer, allowDiamonds)
end

function Match.canRerollUpgrade(allowDiamonds)
    return Match.seated() and Match.phase() == "Upgrading" and canReroll(Match.upgradeOffer, allowDiamonds)
end

-- True while we sit at a table whose match is not over.
function Match.seated()
    return Match.state ~= nil and not Match.left and Match.phase() ~= "Finished"
end

function Match.teamSize()
    return Match.state and Match.state.teamSize or 1
end

-- Everyone at our table: { { userId, team, index, roleId, me, teammate } }, from the latest state.
-- roleId is only there once balls are locked (Aiming on). `index` is the seat within the team
-- (always 1 in a 1v1).
function Match.players()
    local out = {}
    local players = Match.state and Match.state.players
    local mine = players and players[Match.slot]
    for slot, player in pairs(type(players) == "table" and players or {}) do
        if type(player) == "table" then
            local team = player.team or slot
            out[#out + 1] = {
                userId = player.userId,
                team = team,
                index = player.teamIndex or 1,
                roleId = player.roleId,
                me = slot == Match.slot,
                teammate = slot ~= Match.slot and mine ~= nil and team == (mine.team or Match.slot),
            }
        end
    end
    return out
end

-- Our team's name ("Blue" or "Yellow"): what the simulation reports as the winner.
function Match.team()
    local players = Match.state and Match.state.players
    local mine = players and players[Match.slot]
    return mine and mine.team or Match.slot
end

function Match.hp(player)
    local state = Match.state
    if not (state and type(state.hp) == "table" and player) then
        return nil
    end
    return state.hp[player.userId] or state.hp[tostring(player.userId)]
end

-- The round being chosen or aimed right now (1 before this match's first replay).
function Match.round()
    local replay = Match.lastReplay
    if not replay or type(replay.round) ~= "number" then
        return 1
    end
    local phase = Match.phase()
    local playing = phase == "Playing" or phase == "Finished"
    return replay.round + (playing and 0 or 1)
end

-- Our hp and the lowest hp on the other team, which is what decides whether a round is worth a
-- risk: a loss at 1 hp ends the match, and so does a win against someone on their last one.
function Match.stakes()
    local ours, theirs
    for _, player in ipairs(Match.players()) do
        local hp = tonumber(Match.hp(player))
        if hp then
            if player.me then
                ours = hp
            elseif not player.teammate then
                theirs = math.min(theirs or math.huge, hp)
            end
        end
    end
    return ours, theirs
end

-- The seed of the round being chosen now, or nil before this match's first replay.
function Match.nextSeed()
    local replay = Match.lastReplay
    if not replay or type(replay.seed) ~= "number" then
        return nil
    end
    return replay.seed + SEED_STEP
end

-- A replay keeps balls and directions by team: one value in a 1v1, a list by seat in team modes.
function Match.forPlayer(byTeam, team, index)
    local value = type(byTeam) == "table" and byTeam[team]
    if type(value) == "table" then
        return value[index]
    end
    return value
end

-- The ball and direction `player` (from Match.players) used last round, or nil.
function Match.lastPlay(player)
    local options = Match.lastReplay and Match.lastReplay.replayOptions
    if not options then
        return nil, nil
    end
    return Match.forPlayer(options.selectedRoles, player.team, player.index),
        Match.forPlayer(options.initialDirections, player.team, player.index)
end

-- Whether `player` launched in the same direction in this match's last two rounds: true or false,
-- or nil with fewer than two rounds played. Someone who re-aims is not worth predicting.
function Match.keepsAim(player)
    local last = Match.lastReplay
    local before = last and Match.replays[last.round - 1]
    if not before then
        return nil
    end
    local a = Match.forPlayer((last.replayOptions or {}).initialDirections, player.team, player.index)
    local b = Match.forPlayer((before.replayOptions or {}).initialDirections, player.team, player.index)
    return typeof(a) == "Vector2" and typeof(b) == "Vector2" and (a - b).Magnitude < 1e-3
end

-- A direction relayed for `userId` this round, if fresher than `maxAge` seconds. The server relays
-- a teammate's drag; this reads the same store for anyone, so an opponent direction is used the
-- moment the server ever leaks one, and costs nothing while it never does.
function Match.liveAim(userId, maxAge)
    local found = Match.liveAims[userId]
    if found and typeof(found.direction) == "Vector2" and (not maxAge or os.clock() - found.at <= maxAge) then
        return found.direction
    end
    return nil
end

-- The arena the round is fought in: nil for the 1v1 board, the 2v2 board's layout otherwise.
function Match.arena()
    local options = Match.lastReplay and Match.lastReplay.replayOptions
    if options then
        return options.arena
    end
    if Match.teamSize() > 1 and Match.tableModel then
        local ok, arena = Env.call(function()
            return Env.loadModule("ArenaOverride").buildArenaData(Env.loadModule("GameModeRegistry").getForTable(Match.tableModel))
        end)
        return ok and arena or nil
    end
    return nil
end

function Match.excitementSelection()
    local ok, result = Env.call(function()
        local config = Env.loadModule("BattleConfig")
        local replay = config and config.replay
        if not replay then return nil end
        return {
            enabled = replay.enableExcitementSelection == true,
            candidates = type(replay.candidateCount) == "number" and replay.candidateCount or 1,
        }
    end)
    return ok and result or nil
end

Life.onCleanup(function()
    newMatch()
    table.clear(listeners)
    Match.tableModel, Match.tableId, Match.state, Match.slot = nil, nil, nil, nil
    Match.left, Match.status = true, "Off"
    Match.prediction, Match.history, Match.session = nil, nil, nil
end)

return Match
end
__modules["core/profile"] = function(use)
-- What we have learned about the people we duel, kept between sessions.
--
-- The aim solver needs one number from the opponent: how likely they are to launch where they
-- launched last round. The hub used to assume 0.6, or 0.8 after two matching rounds, for everyone.
-- That is a reasonable guess and it is wrong for most individual players: an afk account is re-sent
-- its old aim by the server every round and never deviates, while someone actually playing re-aims
-- constantly. Measuring it per player and remembering it turns a constant into evidence.
--
-- Ball choices are recorded for the same reason. The pick phase simulates our offered balls against
-- what the opponent played last round, which is only a good assumption for someone who keeps
-- playing the same ball -- and now we know who does.
--
-- Nothing here is required. Without file access it is a memory-only model that starts fresh each
-- session, which is still better than a constant.

local Env = use("core/env")
local Life = use("shared/life")

local Profile = {}

local FOLDER = "NOX/BallVsBall"
local FILE = FOLDER .. "/opponents.json"
local SAVE_INTERVAL = 45
local MAX_ENTRIES = 400

-- The prior, as a count of imaginary rounds: a player seen once does not get a 0% or 100% model.
-- 3 of 5 kept starts everyone at the 0.6 the hub used to assume for all players.
local PRIOR_KEPT, PRIOR_SEEN = 3, 5

local players = {}
local dirty, savedAt = false, os.clock()

local function entry(userId)
    local key = tostring(userId)
    local found = players[key]
    if not found then
        found = { kept = 0, seen = 0, rounds = 0, won = 0, lost = 0, balls = {}, at = os.time() }
        players[key] = found
    end
    return found
end

-- Load ---------------------------------------------------------------------------------------

local function decode(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return Env.HttpService:JSONDecode(body)
    end)
    Env.elevate()
    return ok and type(decoded) == "table" and decoded or nil
end

-- A saved file is data we wrote, but it is still a file on disk that anything could have edited,
-- so every field is checked before it reaches the solver's weights.
local function sanitise(raw)
    local out = {}
    for key, value in pairs(type(raw) == "table" and raw or {}) do
        if type(key) == "string" and type(value) == "table" then
            local seen = tonumber(value.seen) or 0
            local kept = tonumber(value.kept) or 0
            if seen >= 0 and seen < math.huge and kept >= 0 and kept <= seen then
                local balls = {}
                for ball, count in pairs(type(value.balls) == "table" and value.balls or {}) do
                    local number = tonumber(count)
                    if type(ball) == "string" and number and number > 0 and number < math.huge then
                        balls[ball] = math.floor(number)
                    end
                end
                out[key] = {
                    kept = math.floor(kept),
                    seen = math.floor(seen),
                    rounds = math.max(0, math.floor(tonumber(value.rounds) or 0)),
                    won = math.max(0, math.floor(tonumber(value.won) or 0)),
                    lost = math.max(0, math.floor(tonumber(value.lost) or 0)),
                    balls = balls,
                    at = math.max(0, math.floor(tonumber(value.at) or 0)),
                }
            end
        end
    end
    return out
end

local files = Env.files
local canSave = files.writefile ~= nil and files.isfolder ~= nil and files.makefolder ~= nil

do
    local ok, body = pcall(function()
        return Env.canCache and files.isfile(FILE) and files.readfile(FILE)
    end)
    Env.elevate()
    players = ok and sanitise(decode(body)) or {}
end

-- Save ---------------------------------------------------------------------------------------

-- Oldest first, so a long-lived file keeps the people still being played against.
local function trim()
    local keys = {}
    for key in pairs(players) do
        keys[#keys + 1] = key
    end
    if #keys <= MAX_ENTRIES then
        return
    end
    table.sort(keys, function(a, b)
        return (players[a].at or 0) > (players[b].at or 0)
    end)
    for index = MAX_ENTRIES + 1, #keys do
        players[keys[index]] = nil
    end
end

local function write()
    if not canSave or not dirty then
        return
    end
    dirty, savedAt = false, os.clock()
    trim()
    local ok = pcall(function()
        local path = ""
        for part in FOLDER:gmatch("[^/]+") do
            path = path == "" and part or path .. "/" .. part
            if not files.isfolder(path) then
                files.makefolder(path)
            end
        end
        files.writefile(FILE, Env.HttpService:JSONEncode(players))
    end)
    Env.elevate()
    if not ok then
        canSave = false -- a filesystem that refuses once is not asked again every 45 seconds
    end
end

Life.loop("duel:profile-save", SAVE_INTERVAL, function()
    if dirty and os.clock() - savedAt >= SAVE_INTERVAL then
        write()
    end
end)

-- Record -------------------------------------------------------------------------------------

-- One round of one opponent. `kept` is whether they launched where we assumed (nil when there was
-- no previous round to compare against, which teaches us nothing either way).
function Profile.observe(userId, kept, roleId, won)
    if type(userId) ~= "number" then
        return
    end
    local found = entry(userId)
    found.rounds += 1
    found.at = os.time()
    if kept ~= nil then
        found.seen += 1
        found.kept += kept and 1 or 0
    end
    if type(roleId) == "string" then
        found.balls[roleId] = (found.balls[roleId] or 0) + 1
    end
    if won == true then
        found.lost += 1 -- we won, so they lost
    elseif won == false then
        found.won += 1
    end
    dirty = true
end

-- Read ---------------------------------------------------------------------------------------

-- How likely `userId` is to launch where they launched last round, as a probability the solver can
-- weight its first column by. Everyone starts at the old 0.6 assumption and moves from there.
function Profile.keepRate(userId)
    local found = players[tostring(userId)]
    local kept = (found and found.kept or 0) + PRIOR_KEPT
    local seen = (found and found.seen or 0) + PRIOR_SEEN
    return kept / seen
end

-- The whole table's keep rate, which is what a scenario weight actually needs: one opponent who
-- re-aims is enough to make the "everyone kept their aim" column unlikely.
function Profile.tableKeepRate(opponents)
    local rate = 1
    local counted = 0
    for _, player in ipairs(opponents) do
        if not player.me and not player.teammate then
            rate *= Profile.keepRate(player.userId)
            counted += 1
        end
    end
    return counted > 0 and rate or PRIOR_KEPT / PRIOR_SEEN
end

-- The ball `userId` plays most often, and how often, or nil when we have not seen them pick.
function Profile.likelyBall(userId)
    local found = players[tostring(userId)]
    if not found then
        return nil
    end
    local best, bestCount, total = nil, 0, 0
    for ball, count in pairs(found.balls) do
        total += count
        if count > bestCount then
            best, bestCount = ball, count
        end
    end
    if not best or total == 0 then
        return nil
    end
    return best, bestCount / total
end

-- The opponent's balls as weights that sum to 1, most-played first, up to `max` entries, or nil
-- when we have not seen them pick. Unlike likelyBall this keeps the spread, so a ball-switcher is
-- met with a hedge across their likely balls rather than a bet on one.
function Profile.ballDistribution(userId, max)
    local found = players[tostring(userId)]
    if not found then
        return nil
    end
    local list, total = {}, 0
    for ball, count in pairs(found.balls) do
        list[#list + 1] = { roleId = ball, count = count }
        total += count
    end
    if total == 0 then
        return nil
    end
    table.sort(list, function(a, b)
        return a.count > b.count
    end)
    local out = {}
    for index = 1, math.min(max or #list, #list) do
        out[index] = { roleId = list[index].roleId, weight = list[index].count / total }
    end
    return out
end

-- A line per opponent for the Intel tab. `name` is what to call them (their user id otherwise).
function Profile.describe(player, name)
    local found = players[tostring(player.userId)]
    local keep = math.floor(Profile.keepRate(player.userId) * 100 + 0.5)
    name = name or tostring(player.userId)
    if not found or found.rounds == 0 then
        return string.format("%s: new opponent, assuming %d%% aim repeat", name, keep)
    end
    local ball, share = Profile.likelyBall(player.userId)
    local favourite = ball and string.format(", favours %s (%d%%)", Env.ballName(ball),
        math.floor(share * 100 + 0.5)) or ""
    return string.format("%s: %d rounds, repeats aim %d%% (%d/%d), %d-%d against you%s",
        name, found.rounds, keep, found.kept, found.seen, found.won, found.lost, favourite)
end

function Profile.count()
    local total = 0
    for _ in pairs(players) do
        total += 1
    end
    return total
end

function Profile.forget()
    table.clear(players)
    dirty = true
    write()
end

Life.onCleanup(write)

return Profile
end
__modules["core/sim"] = function(use)
-- Runs the game's own battle simulation (BattleDemo.BattleSimulation) to see how a round would
-- end. It uses the game's deterministic inputs and yields between groups of simulation steps
-- so a slower client can still draw frames, handle events, and stop an obsolete search.
--
-- Balls and directions are keyed by team, as in the server's replays: { Blue = "刀片球" } in a 1v1,
-- { Blue = { "刀片球", "蛇球" } } (by seat) in a 2v2, which also needs the 2v2 arena.

local Env = use("core/env")
local Life = use("shared/life")

local Sim = {}

-- Only these two decide a battle. ArenaOverride and GameModeRegistry shape the 2v2 board, and
-- both callers already fall back to the 1v1 config when they are missing, so a place that does
-- not ship them must not hold Smart aim off for the whole session.
local REQUIRED = { "BattleConfig", "BattleSimulation" }
local OPTIONAL = { "ArenaOverride", "GameModeRegistry" }

-- Reads the module cache rather than a flag this file sets, so readiness follows what is actually
-- loaded instead of whether the loader loop below has had its turn yet.
function Sim.ready()
    for _, name in ipairs(REQUIRED) do
        if rawget(Env.Game, name) == nil then
            return false
        end
    end
    return true
end

local optionalTries = {}
Life.loop("duel:simulation-modules", 5, function()
    if not Sim.ready() then
        for _, name in ipairs(REQUIRED) do
            Env.loadModule(name)
        end
        return
    end
    -- The arena modules only matter in 2v2. A few attempts, then they are left alone: each miss
    -- costs this thread a 30-second wait, and the 1v1 board works without them.
    for _, name in ipairs(OPTIONAL) do
        if rawget(Env.Game, name) == nil and (optionalTries[name] or 0) < 3 then
            optionalTries[name] = (optionalTries[name] or 0) + 1
            pcall(Env.loadModule, name)
        end
    end
end)

local SCORE = { win = 1, draw = 0.5, loss = 0 }
local FAST_WIN_BONUS = 0.01 -- tie-break: a quicker win is a safer one

-- Giving a frame back costs ~16ms of a think budget measured in seconds, so yielding once per
-- simulation spent more time waiting for the next frame than simulating. Every search yields off
-- one shared slice clock instead.
local SLICE = 0.008
local sliceStart = os.clock()

function Sim.breathe()
    if os.clock() - sliceStart >= SLICE then
        task.wait()
        Env.elevate()
        sliceStart = os.clock()
    end
    return Life.alive
end

-- Battles run on the game's own step(). A copy of it used to reuse one event table per battle, but
-- the Halloween update added clean-up calls (CandySpill, GraveHaunt) to the real step that the copy
-- missed, so rounds with the new balls were predicted on different rules. The copy saved about 1.5%.

-- The battle config for an arena (nil: the 1v1 board), resolved once per board.
local configs = {}
local function battleConfig(arena)
    local key = arena and arena.boardAssetName or "default"
    if not configs[key] then
        local ok, resolved = Env.call(Env.loadModule("ArenaOverride").resolveConfig, Env.loadModule("BattleConfig"), arena)
        configs[key] = ok and resolved or Env.loadModule("BattleConfig")
    end
    return configs[key]
end

-- The longest a battle can run on this board, for scoring a fast win.
function Sim.maxDuration(arena)
    local ok, duration = pcall(function()
        return battleConfig(arena).replay.maxDuration
    end)
    return ok and type(duration) == "number" and duration > 0 and duration or 1
end

-- A battle is a pure function of (seed, balls, directions, stats, traits, board), and the same
-- combination comes up again and again: the coarse and refine passes share scenarios, the ball
-- search re-tests the same opponents, and the matrix solver re-reads rows it has already filled.
local CACHE_LIMIT = 4096
local cache, cacheCount = {}, 0

local function keyOf(value, out)
    local kind = typeof(value)
    if kind == "Vector2" then
        -- Rounded to the tolerance directions are compared by everywhere else (1e-3).
        out[#out + 1] = string.format("v%.4f,%.4f", value.X, value.Y)
    elseif kind == "table" then
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        out[#out + 1] = "{"
        for _, key in ipairs(keys) do
            out[#out + 1] = tostring(key)
            out[#out + 1] = "="
            keyOf(value[key], out)
            out[#out + 1] = ";"
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = tostring(value)
    end
    return out
end

-- The board goes in by name: resolveConfig already keys its own cache that way, and serialising a
-- whole arena layout per simulation would cost more than the lookup saves.
local function cacheKey(seed, roles, directions, statLevels, traits, arena)
    local out = { tostring(seed), "|", arena and tostring(arena.boardAssetName) or "default", "|" }
    keyOf(roles, out)
    out[#out + 1] = "|"
    keyOf(directions, out)
    out[#out + 1] = "|"
    keyOf(statLevels, out)
    out[#out + 1] = "|"
    keyOf(traits, out)
    return table.concat(out)
end

function Sim.clearCache()
    table.clear(cache)
    cacheCount = 0
end

-- Plays one battle out. Returns the winning team ("Blue", "Yellow" or "Draw") and its length in
-- seconds, or nil and the error.
function Sim.run(seed, roles, directions, statLevels, traits, arena, deadline, valid)
    if not Sim.ready() then return nil, "simulation modules are still loading" end
    local key = cacheKey(seed, roles, directions, statLevels, traits, arena)
    local hit = cache[key]
    if hit then
        return hit[1], hit[2]
    end
    local cfg = battleConfig(arena)
    local ok, winner, elapsed = Env.call(function()
        local sim = Env.loadModule("BattleSimulation").new(cfg, seed, roles, traits, statLevels, directions)
        local dt = cfg.replay.fixedDt
        assert(type(dt) == "number" and dt > 0 and dt < math.huge, "invalid simulation time step")
        local duration = cfg.replay.maxDuration
        assert(type(duration) == "number" and duration > 0 and duration < math.huge, "invalid simulation duration")
        for step = 1, math.ceil(duration / dt) do
            if sim:step(dt).finished then
                break
            end
            if step % 32 == 0 and os.clock() - sliceStart >= SLICE then
                task.wait()
                Env.elevate()
                sliceStart = os.clock()
                if not Life.alive or (deadline and os.clock() >= deadline) or (valid and not valid()) then
                    return nil, "simulation cancelled"
                end
            end
        end
        local state = sim:getState()
        return state.finished and state.winner or "Draw", state.elapsed
    end)
    if not ok then
        return nil, winner
    end
    -- A cancelled run reports no winner; only a finished battle is a fact worth keeping.
    if winner == nil then
        return nil, elapsed
    end
    if cacheCount >= CACHE_LIMIT then
        Sim.clearCache()
    end
    cache[key] = { winner, elapsed }
    cacheCount += 1
    return winner, elapsed
end

-- `count` launch directions spread evenly around the circle.
function Sim.directions(count)
    local out = {}
    for index = 0, count - 1 do
        local angle = index / count * math.pi * 2
        out[#out + 1] = Vector2.new(math.cos(angle), math.sin(angle))
    end
    return out
end

local random = Random.new()

function Sim.randomDirection()
    local angle = random:NextNumber(0, math.pi * 2)
    return Vector2.new(math.cos(angle), math.sin(angle))
end

function Sim.randomSeed()
    return math.floor(workspace:GetServerTimeNow() * 1000) + random:NextInteger(-600000, 600000)
end

-- The plain result for `team`: 1 win, 0.5 draw, 0 loss. A draw costs no hp, so it really is worth
-- half a win and must never be lumped in with a loss.
function Sim.outcome(winner, team)
    if winner == team then
        return SCORE.win
    end
    return winner == "Draw" and SCORE.draw or SCORE.loss
end

-- How good one outcome is for `team`, plus a little for winning fast.
function Sim.score(winner, elapsed, team, maxDuration)
    local base = Sim.outcome(winner, team)
    if base ~= SCORE.win then
        return base
    end
    return base + FAST_WIN_BONUS * (1 - math.clamp((elapsed or 0) / maxDuration, 0, 1))
end

local score = Sim.score

-- The coarse pass gets this share of the think time; the rest refines around its best directions,
-- since a winning window can be narrower than the gap between two coarse directions.
local COARSE_SHARE = 0.65
local REFINE_TOP = 3
local REFINE_STEPS = { -1 / 3, -1 / 6, 1 / 6, 1 / 3 } -- of the gap between coarse directions

local function rotate(direction, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return Vector2.new(direction.X * c - direction.Y * s, direction.X * s + direction.Y * c)
end

-- Tries every direction against each scenario in turn until the deadline (scenario 1 may run on to
-- `firstDeadline`). A scenario only counts once every direction has been tried against it, so the
-- directions stay comparable. Returns the weighted total per direction, how many scenarios
-- completed, and who wins scenario 1 with each.
local function evaluate(spec, directions, scenarios, deadline, firstDeadline)
    local maxDuration = Sim.maxDuration(spec.arena)
    local totals, rates, completed, firstWinners = {}, {}, 0, {}
    for scenarioIndex, scenario in ipairs(scenarios) do
        local results, outcomes = {}, {}
        local stopAt = scenarioIndex == 1 and (firstDeadline or deadline) or deadline
        for index, direction in ipairs(directions) do
            if not Life.alive or (spec.valid and not spec.valid()) or os.clock() > stopAt then
                break
            end
            local winner, elapsed = Sim.run(scenario.seed, spec.roles, spec.place(direction, scenario),
                spec.statLevels, spec.traits, spec.arena, stopAt, spec.valid)
            results[index] = winner and score(winner, elapsed, spec.team, maxDuration) or 0
            if not winner then
                return totals, completed, firstWinners, rates -- errors are not predicted losses
            end
            outcomes[index] = Sim.outcome(winner, spec.team)
            if scenarioIndex == 1 then
                firstWinners[index] = winner
            end
            Sim.breathe()
        end
        if #results < #directions then
            break -- out of time: this scenario is incomplete, so it is left out
        end
        for index, value in ipairs(results) do
            totals[index] = (totals[index] or 0) + value * scenario.weight
            rates[index] = (rates[index] or 0) + outcomes[index] * scenario.weight
        end
        completed = scenarioIndex
    end
    return totals, completed, firstWinners, rates
end

-- Finds our best launch direction.
-- spec = {
--   team            -- our team ("Blue" or "Yellow"): the winner we want
--   roles           -- every ball, keyed by team as in a replay
--   place           -- function(ourDirection, scenario) -> every direction, keyed by team
--   directions      -- our coarse candidate directions, evenly spaced (Sim.directions)
--   scenarios       -- { { seed, weight, ... } }, most likely first; `place` reads the rest
--   statLevels, traits, arena -- from the match's last replay (nil in round 1, arena nil in a 1v1)
--   deadline        -- os.clock() by which to answer
-- }
-- A coarse pass over `directions`, then a finer one around its best few, against the scenarios the
-- coarse pass completed. Returns the best direction, its expected score (0..1), how many coarse
-- directions win the first scenario, and who wins the first scenario with the best direction.
function Sim.bestDirection(spec)
    if not Sim.ready() or not Life.alive then return nil, 0, 0, nil end
    local started = os.clock()
    local coarseDeadline = started + (spec.deadline - started) * COARSE_SHARE
    -- Scenario 1 (the likely one) may use the whole think time; more only fit in the coarse share.
    local totals, completed, winners, rates = evaluate(spec, spec.directions, spec.scenarios, coarseDeadline, spec.deadline)
    if completed == 0 then
        return nil, 0, 0, nil
    end
    local weights = 0
    for index = 1, completed do
        weights += spec.scenarios[index].weight
    end
    local firstWins = 0
    for _, winner in pairs(winners) do
        firstWins += winner == spec.team and 1 or 0
    end

    local best, bestTotal, bestWinner, bestRate = nil, -1, nil, 0
    local order = {}
    for index, total in ipairs(totals) do
        order[#order + 1] = index
        if total > bestTotal then
            best, bestTotal, bestWinner = spec.directions[index], total, winners[index]
            bestRate = rates[index]
        end
    end

    -- Refine: directions between the best coarse ones and their neighbours, scored on the same
    -- scenarios. Kept only if every one of them finishes, so the comparison stays fair.
    table.sort(order, function(a, b)
        return totals[a] > totals[b]
    end)
    local gap = math.pi * 2 / #spec.directions
    local finer = {}
    for rank = 1, math.min(REFINE_TOP, #order) do
        for _, step in ipairs(REFINE_STEPS) do
            finer[#finer + 1] = rotate(spec.directions[order[rank]], step * gap)
        end
    end
    local scenarios = table.move(spec.scenarios, 1, completed, 1, {})
    local fineTotals, fineCompleted, fineWinners, fineRates = evaluate(spec, finer, scenarios, spec.deadline)
    if fineCompleted == completed then
        for index, total in ipairs(fineTotals) do
            if total > bestTotal then
                best, bestTotal, bestWinner = finer[index], total, fineWinners[index]
                bestRate = fineRates[index]
            end
        end
    end
    return best, math.clamp(bestRate / weights, 0, 1), firstWins, bestWinner
end

Life.onCleanup(function()
    table.clear(configs)
    table.clear(optionalTries)
    Sim.clearCache()
end)

return Sim
end
__modules["core/solver"] = function(use)
-- Solves the aim phase as the game it actually is.
--
-- From round 2 the seed is known exactly (core/match), every ball is locked before aiming starts,
-- and the battle is deterministic. The only thing left unknown is where the others launch. That
-- makes one round a finite two-player zero-sum simultaneous game whose payoff function we can
-- evaluate directly, so instead of guessing one opponent aim and answering it, this builds the
-- payoff matrix: our candidate directions down the rows, the opponent's down the columns.
--
-- Three numbers come out of a row, and they answer different questions:
--   expected  how the row does against the opponent we actually expect (core/profile weights it)
--   worst     the worst any opponent direction can do to it: a floor that holds whatever they pick
--   wins      how many opponent directions it beats outright, i.e. how forgiving the aim is
--
-- Ranking by `expected` alone exploits a predictable opponent but can be punished badly by a
-- surprise. Ranking by `worst` alone is the maximin play: it gives up some wins to never be
-- blown out. `lambda` slides between them, and hp moves it on its own, because the value of a
-- round is not symmetric when someone is one loss from going out.

local Life = use("shared/life")
local Sim = use("core/sim")

local Solver = {}

-- A row has to cover every column in the current comparison set before it can be ranked against
-- another row: a partly filled row has a flattering minimum and a meaningless average.
local function rank(a, b)
    if a.score ~= b.score then
        return a.score > b.score
    end
    if a.worst ~= b.worst then
        return a.worst > b.worst
    end
    return a.wins > b.wins
end

-- Fills columns `from`..`to` of one row. False when the search was cancelled or ran out of time,
-- in which case the row keeps whatever it had and must not be ranked at the new column count.
local function fill(spec, row, from, to)
    for column = from, to do
        if not Life.alive or (spec.valid and not spec.valid()) or os.clock() >= spec.deadline then
            return false
        end
        local scenario = spec.opponents[column]
        local winner, elapsed = Sim.run(spec.seed, spec.roles, spec.place(row.direction, scenario),
            spec.statLevels, spec.traits, spec.arena, spec.deadline, spec.valid)
        if not winner then
            return false -- an error or a cancellation is not a predicted loss
        end
        row.scores[column] = Sim.score(winner, elapsed, spec.team, spec.maxDuration)
        row.outcomes[column] = Sim.outcome(winner, spec.team)
        if column == 1 then
            row.winner = winner
        end
        Sim.breathe()
    end
    return true
end

-- Collapses a row's filled columns into the three numbers, under `lambda`.
local function summarise(row, spec, columns)
    local weighted, weights, worst, wins = 0, 0, math.huge, 0
    for column = 1, columns do
        local weight = spec.opponents[column].weight or 1
        weighted += row.scores[column] * weight
        weights += weight
        worst = math.min(worst, row.outcomes[column])
        wins += row.outcomes[column] >= 1 and 1 or 0
    end
    row.expected = weights > 0 and weighted / weights or 0
    row.worst = worst == math.huge and 0 or worst
    row.wins = wins
    row.columns = columns
    row.score = (1 - spec.lambda) * row.expected + spec.lambda * row.worst
end

local function newRow(direction)
    return { direction = direction, scores = {}, outcomes = {}, expected = 0, worst = 0, wins = 0, score = -1 }
end

-- Evaluates every candidate against columns 1..`columns` and returns the ones that covered them
-- all, best first. `done` is false when the stage was cut short, so the caller keeps the previous
-- stage's answer rather than comparing rows judged on different opponents.
local function stage(spec, candidates, columns)
    local complete, done = {}, true
    for _, row in ipairs(candidates) do
        local from = (row.columns or 0) + 1
        if from > columns then
            summarise(row, spec, columns)
            complete[#complete + 1] = row
        elseif fill(spec, row, from, columns) then
            summarise(row, spec, columns)
            complete[#complete + 1] = row
        else
            done = false
            break
        end
    end
    table.sort(complete, rank)
    return complete, done
end

local function rotate(direction, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return Vector2.new(direction.X * c - direction.Y * s, direction.X * s + direction.Y * c)
end

-- How much weight the floor gets. A round is not worth the same to both sides once someone is one
-- loss from out: at 1 hp a loss ends the match, so the floor matters more than the average; when
-- the opponent is at 1 hp a win ends it, so it is worth reaching for.
local STYLE = { Exploit = 0, Balanced = 0.5, Safe = 1 }

function Solver.lambda(style, ourHp, theirHp)
    local lambda = STYLE[style] or STYLE.Balanced
    if ourHp == 1 then
        lambda += 0.25
    end
    if theirHp == 1 then
        lambda -= 0.2
    end
    return math.clamp(lambda, 0, 1)
end

-- The opponent's candidate directions, as scenarios the caller's `place` can read.
--
-- Column 1 is who we think they are: the aim core/profile expects them to keep. The rest cover
-- what else they could do. With one unknown opponent that space is just the circle, so it is
-- covered evenly and the row minimum becomes a real maximin over that discretisation. With two
-- (a 2v2) the joint space is square and sampling it is the only thing that fits the budget.
function Solver.columns(players, likely, modelled, count)
    local unknown = {}
    for _, player in ipairs(players) do
        if not player.me and not player.teammate then
            unknown[#unknown + 1] = player
        end
    end
    -- An opponent who changed their aim last round has no direction to expect. Their slot in
    -- column 1 is then as random as any other column, and giving it the model's weight would let
    -- a coin flip dominate the expected value -- so without a full prediction every column counts
    -- the same and the row's average is a plain average over the sweep.
    local predicted = true
    for _, player in ipairs(unknown) do
        predicted = predicted and likely[player.userId] ~= nil
    end
    local weight = predicted and math.clamp(modelled or 0.6, 0.05, 0.95) or 1 / math.max(1, count)
    local first = { others = {}, weight = weight, modelled = predicted }
    for _, player in ipairs(players) do
        if not player.me then
            first.others[player.userId] = likely[player.userId] or Sim.randomDirection()
        end
    end
    local columns = { first }
    local spread = (1 - first.weight) / math.max(1, count - 1)
    if #unknown == 1 then
        local opponent = unknown[1]
        local sweep = Sim.directions(count - 1)
        for _, direction in ipairs(sweep) do
            local others = {}
            for userId, value in pairs(first.others) do
                others[userId] = value -- the teammate's aim is known and stays put
            end
            others[opponent.userId] = direction
            columns[#columns + 1] = { others = others, weight = spread }
        end
        return columns
    end
    for _ = 2, count do
        local others = {}
        for userId, value in pairs(first.others) do
            others[userId] = value
        end
        for _, player in ipairs(unknown) do
            others[player.userId] = Sim.randomDirection()
        end
        columns[#columns + 1] = { others = others, weight = spread }
    end
    return columns
end

-- spec = {
--   team, seed, roles, statLevels, traits, arena -- the round, exactly as the server will run it
--   ours        -- our candidate directions, evenly spaced (Sim.directions)
--   opponents   -- Solver.columns(...): index 1 is the opponent we expect
--   place       -- function(ourDirection, scenario) -> directions keyed by team, as in a replay
--   lambda      -- Solver.lambda(...): 0 answers the expected opponent, 1 plays the floor
--   deadline, valid
-- }
--
-- Widens in stages so there is always an answer to give back: the whole grid against a few
-- opponent directions first, then the leaders against all of them, then finer directions around
-- the leaders. Every stage compares rows that saw the same opponents.
--
-- Returns the winning row { direction, score, expected, worst, wins, winner, columns } and how
-- many opponent directions it was judged against, or nil when nothing finished in time.
local NARROW = 4 -- opponent columns every one of our directions is tried against
local SURVIVORS = 4
local REFINE_STEPS = { -1 / 3, -1 / 6, 1 / 6, 1 / 3 } -- of the gap between our coarse directions
local PHI = (math.sqrt(5) - 1) / 2

-- Our directions in golden-ratio order rather than round the circle. If the clock runs out
-- partway through the first pass, the rows that did finish are still spread over every side of
-- the board, instead of all sitting in the one arc that happened to come first.
local function spread(directions)
    local order = {}
    for index = 1, #directions do
        order[index] = index
    end
    table.sort(order, function(a, b)
        return ((a - 1) * PHI) % 1 < ((b - 1) * PHI) % 1
    end)
    local out = {}
    for _, index in ipairs(order) do
        out[#out + 1] = directions[index]
    end
    return out
end

function Solver.solve(spec)
    if not Sim.ready() or not Life.alive or not spec.seed or #spec.ours == 0 or #spec.opponents == 0 then
        return nil
    end
    spec.lambda = math.clamp(spec.lambda or 0.5, 0, 1)
    spec.maxDuration = Sim.maxDuration(spec.arena)
    local narrow = math.min(NARROW, #spec.opponents)
    local full = #spec.opponents

    -- Every list `stage` returns holds only rows that covered all of its columns, so a stage cut
    -- short still ranks fairly; it just ranks fewer rows.
    local rows = {}
    for _, direction in ipairs(spread(spec.ours)) do
        rows[#rows + 1] = newRow(direction)
    end
    local best = stage(spec, rows, narrow)
    if #best == 0 then
        return nil
    end

    -- The leaders face every opponent column. The narrow pass is already cached, so this only
    -- pays for the columns it adds. Leaders run best first, so a cut-off loses the weakest.
    local leaders = table.move(best, 1, math.min(SURVIVORS, #best), 1, {})
    local widened, done = stage(spec, leaders, full)
    if #widened == 0 then
        return best[1], narrow
    end
    if not done then
        return widened[1], full
    end

    if widened[1].worst >= 1 then
        return widened[1], full
    end

    -- A winning window can be narrower than the gap between two coarse directions.
    local gap = math.pi * 2 / #spec.ours
    local finer = table.move(widened, 1, #widened, 1, {})
    for place = 1, math.min(2, #widened) do
        for _, step in ipairs(REFINE_STEPS) do
            finer[#finer + 1] = newRow(rotate(widened[place].direction, step * gap))
        end
    end
    -- The widened rows lead the list and are already complete, so this is never empty.
    local refined = stage(spec, finer, full)
    return refined[1], full
end

return Solver
end
__modules["core/stats"] = function(use)
-- Every ball's win rate across all players, from the game's own BallBattleStats (the numbers its
-- Ball Index shows): overall, and head to head against each other ball.

local Env = use("core/env")
local Life = use("shared/life")

local Stats = {}

local REFRESH = 600 -- seconds; the server rate-limits the call
local MIN_MATCHUP_GAMES = 500 -- fewer head-to-head games than this and the overall rate is used

local raw, fetchedAt = nil, -math.huge
local fetching = false

local function all()
    if not fetching and os.clock() - fetchedAt > REFRESH then
        fetching, fetchedAt = true, os.clock()
        Life.spawn("duel:statistics", function()
            local moduleOk = Env.call(Env.loadModule, "StatsCore")
            local ok, result = Env.invoke("BallBattleStats/GetAll")
            if Life.alive and moduleOk and ok and type(result) == "table" then
                raw = type(result.data) == "table" and result.data or result
            else
                fetchedAt = os.clock() - REFRESH + 30
            end
            fetching = false
        end)
    end
    return raw
end

-- Refresh off the picking path: a slow statistics service must not use the pick timer.
all()

-- A ball's overall win rate (0..1), or nil when the game has no numbers for it.
function Stats.winRate(ball)
    local entry = (all() or {})[ball]
    if type(entry) ~= "table" then
        return nil
    end
    local core = rawget(Env.Game, "StatsCore")
    if not core then return nil end
    local ok, summary = Env.call(core.summarize, entry)
    return ok and summary and summary.winRate or nil
end

-- How often `ball` beats `versus`, falling back to its overall rate on too few games.
function Stats.against(ball, versus)
    local entry = (all() or {})[ball]
    local record = versus and type(entry) == "table" and type(entry.opponents) == "table" and entry.opponents[versus]
    if type(record) == "table" then
        local games = (record.wins or 0) + (record.losses or 0) + (record.draws or 0)
        if games >= MIN_MATCHUP_GAMES then
            return (record.wins + 0.5 * (record.draws or 0)) / games
        end
    end
    return Stats.winRate(ball)
end

return Stats
end
__modules["core/trajectory"] = function(use)
-- Aim uses the same arena anchor and XY plane as DuelLaunchAimClient (local -Z is up).
local Env = use("core/env")
local Life = use("shared/life")
local Match = use("core/match")
local Trajectory = {}
local root, shownModel, shownToken

function Trajectory.clear()
    Env.elevate()
    if root then
        root:Destroy()
    end
    root, shownModel, shownToken = nil, nil, nil
end

-- `detail` is an optional second line: what the solver guarantees, next to what it expects.
function Trajectory.show(player, direction, expected, detail)
    Trajectory.clear()
    local model = Match.tableModel
    if not Life.alive or not Match.seated() or Match.phase() ~= "Aiming" or not model then
        return false
    end
    local anchor = model:FindFirstChild("棋盘锚点") or model:FindFirstChild("ArenaAnchor")
    if not anchor or not anchor:IsA("BasePart") or direction.Magnitude < 1e-6 then
        return false
    end
    local ok, cfg = Env.call(Env.loadModule("ArenaOverride").resolveConfig, Env.loadModule("BattleConfig"), Match.arena())
    if not ok or not Life.alive or model ~= Match.tableModel or Match.phase() ~= "Aiming" then
        return false
    end
    local slot = cfg.slots[player.team]
    local spawn = slot and ((slot.spawnPositionCorners or {})[player.index] or slot.spawnPosition)
    if typeof(spawn) ~= "Vector2" then
        return false
    end
    Env.elevate()
    root = Instance.new("Folder")
    root.Name = "NOXAimTrajectory"
    root.Parent = model
    shownModel, shownToken = model, Match.aimToken
    local color = expected > 0.60 and Color3.fromRGB(70, 235, 115)
        or expected >= 0.45 and Color3.fromRGB(255, 215, 65) or Color3.fromRGB(255, 85, 85)
    direction = direction.Unit
    local length = math.min(cfg.arena.size.X, cfg.arena.size.Y) * 0.3
    -- Clip the launch segment to the board's edge, including corner spawns in team modes.
    for _, axis in ipairs({ "X", "Y" }) do
        local component = direction[axis]
        if math.abs(component) > 1e-6 then
            local edge = math.sign(component) * (cfg.arena.size[axis] / 2 - 0.2)
            length = math.min(length, math.max(0.2, (edge - spawn[axis]) / component))
        end
    end
    local tip = spawn + direction * length
    local wing = Vector2.new(-direction.Y, direction.X)
    local head = math.min(1.1, length * 0.3)
    local function point(position)
        local attachment = Instance.new("Attachment")
        attachment.Position = Vector3.new(position.X, position.Y, -0.3)
        attachment.Parent = anchor
        return attachment
    end
    -- Attachments are on a transparent anchor part owned by the visual, so one Destroy clears all.
    local holder = Instance.new("Part")
    holder.Name = "ArenaPlane"
    holder.Size = Vector3.new(0.1, 0.1, 0.1)
    holder.Transparency, holder.Anchored = 1, true
    holder.CanCollide, holder.CanTouch, holder.CanQuery = false, false, false
    holder.CFrame = anchor.CFrame
    holder.Parent = root
    anchor = holder
    local start, finish = point(spawn), point(tip)
    local function beam(a, b, width)
        local line = Instance.new("Beam")
        line.Attachment0, line.Attachment1 = a, b
        line.Width0, line.Width1 = width, width
        line.Color, line.Transparency = ColorSequence.new(color), NumberSequence.new(0)
        line.FaceCamera, line.LightEmission, line.Segments = true, 1, 1
        line.Parent = root
    end
    beam(start, finish, 0.16)
    beam(finish, point(tip - direction * head + wing * head * 0.5), 0.16)
    beam(finish, point(tip - direction * head - wing * head * 0.5), 0.16)
    local label = Instance.new("BillboardGui")
    label.Name, label.Adornee = "Prediction", holder
    label.Size = UDim2.fromOffset(260, detail and 58 or 44)
    label.StudsOffsetWorldSpace = holder.CFrame.LookVector * 3
    label.AlwaysOnTop, label.MaxDistance = true, 150
    label.Parent = root
    local text = Instance.new("TextLabel")
    text.Size, text.BackgroundTransparency = UDim2.fromScale(1, 1), 1
    text.TextColor3, text.TextStrokeTransparency = color, 0.25
    text.Font, text.TextSize = Enum.Font.GothamBold, 18
    local outcome = expected > 0.60 and "Win" or expected >= 0.45 and "Even" or "Loss"
    text.Text = string.format("Predicted: %s (%d%%)", outcome, math.clamp(math.floor(expected * 100 + 0.5), 0, 100))
        .. (detail and "\n" .. detail or "")
    text.Parent = label
    return true
end

local function refresh()
    if root and (not Life.alive or not Match.seated() or Match.phase() ~= "Aiming"
        or Match.tableModel ~= shownModel or Match.aimToken ~= shownToken or not root.Parent) then
        Trajectory.clear()
    end
end
-- Through Match, so an absent or renamed state remote costs the overlay its prompt refresh
-- rather than erroring out of this module while the hub is still loading.
Match.listen("DuelTableState", refresh)
Life.loop("duel:trajectory", 0.1, refresh)
Life.onCleanup(Trajectory.clear)

return Trajectory
end
__modules["core/ui"] = function(use)
-- Ball VS Ball's window and tabs.

local Ui = use("shared/ui")

return Ui.create({
    icons = use("vendor/icons"),
    footer = "Ball VS Ball",
    tabs = {
        { "Home", "house", "Welcome to NOX" },
        { "Duel", "swords", "Auto duel, ball picks and aim" },
        { "Intel", "radar", "Opponents, the aim solver and prediction accuracy" },
        { "Rewards", "gift", "Daily quests, Halloween candy, check-in, mail, fusion and crates" },
        { "Settings", "settings", "Menu, themes and configs" },
    },
})
end
__modules["core/upgrades"] = function(use)
-- Card ids are engine keys; upgradeChoice is indexed by the corresponding Chinese config id.
--
-- Two ways to judge a card. Upgrades.score reads its star rating out of the cloud config and adds
-- a bonus where its text lines up with the ball's traits: cheap, always available, and a guess.
-- Upgrades.bestBySimulation is the real answer, because a card is not a description -- it is an
-- entry in the statLevels and secondary-trait tables the server hands to the battle simulation.
-- Project the card into those tables, replay the next round with the game's own code, and the
-- question "which of these three wins" stops being a keyword match. The heuristic stays as the
-- tie-break and as the fallback for round 1, where there is no seed to replay against.
local Env = use("core/env")
local Sim = use("core/sim")
local Upgrades = {}

local function textOf(value)
    if type(value) ~= "table" then
        return tostring(value or "")
    end
    return table.concat({ tostring(value.behaviorKey or ""), tostring(value.displayName or ""),
        tostring(value.cnId or ""), tostring(value.trigger or "") }, " ")
end

local function contains(text, words)
    for _, word in ipairs(words) do
        if string.find(text, word, 1, true) then
            return true
        end
    end
    return false
end

function Upgrades.definition(candidate)
    if type(candidate) ~= "table" or type(candidate.id) ~= "string" then
        return nil
    end
    local battle = rawget(Env.Game, "BattleConfig")
    if not battle then return nil end
    local stats = type(battle.tournament_upgrade) == "table" and battle.tournament_upgrade.basicStats or nil
    local defs = candidate.kind == "effect" and battle.traits
        or candidate.kind == "basicStat" and stats
    local effect = type(defs) == "table" and defs[candidate.id] or nil
    local choice = Env.loadModule("Config").upgradeChoice
    local choices = type(choice) == "table" and choice.byTargetCnId or nil
    if type(choices) ~= "table" then
        return nil, effect
    end
    return choices[effect and effect.cnId or candidate.id], effect
end

function Upgrades.score(candidate, roleId, secondary)
    local choice, effect = Upgrades.definition(candidate)
    local star = choice and tonumber(choice.star) or 0
    if not choice then
        return -math.huge, nil -- unknown metadata must not be mistaken for a one-star card
    end
    local config, battle = Env.loadModule("Config"), Env.loadModule("BattleConfig")
    local ball = config.ball.byCnId[roleId]
    local role = battle.roles and battle.roles[roleId]
    local traitsByKey = type(battle.traits) == "table" and battle.traits or {}
    local active = { textOf(ball), textOf(role and role.skill) }
    -- Cloud ball.skills contains Chinese skill ids; resolve them to engine behavior keys.
    for _, id in ipairs(ball and ball.skills or {}) do
        active[#active + 1] = textOf(id)
        for key, trait in pairs(traitsByKey) do
            if type(trait) == "table" and trait.cnId == id then
                active[#active + 1] = key .. " " .. textOf(trait)
            end
        end
    end
    for _, id in ipairs(type(secondary) == "table" and secondary or {}) do
        active[#active + 1] = textOf(id) .. " " .. textOf(traitsByKey[id])
    end
    local traits = string.lower(table.concat(active, " "))
    local target = string.lower(candidate.id .. " " .. textOf(effect) .. " " .. textOf(choice))
    local bonus = 0
    if contains(traits, { "blade", "axe", "burst" })
        and contains(target, { "attackspeed", "attack speed", "bounceaccel", "bounce accel", "ballhitaccel" }) then
        bonus = 15
    elseif contains(traits, { "poison", "acid", "snake", "venom", "virus" })
        and contains(target, { "poisonduration", "poison duration", "poisonampl", "poison ampl", "lastingpoison", "damageamplification", "venom" }) then
        bonus = 15
    elseif contains(traits, { "electric", "electro", "voltaic" })
        and contains(target, { "stun", "paraly", "paralysis", "shockduration", "shock duration" }) then
        bonus = 15
    elseif candidate.id == "hp" or candidate.id == "LowHpArmor"
        or contains(target, { "defense", "shield", "health", "maxhp", "thick skin" }) then
        bonus = 3
    end
    return star * 10 + bonus, star
end

local function usable(candidate)
    return type(candidate) == "table" and type(candidate.id) == "string"
        and (candidate.kind == "effect" or candidate.kind == "basicStat")
end

function Upgrades.best(candidates, roleId, secondary)
    local best, bestScore, maxStar, known = nil, -math.huge, 0, true
    for _, candidate in ipairs(candidates) do
        local score, star = Upgrades.score(candidate, roleId, secondary)
        known = known and star ~= nil
        maxStar = math.max(maxStar, star or 0)
        if usable(candidate) and (not best or score > bestScore) then
            best, bestScore = candidate, score
        end
    end
    return best, maxStar, known
end

-- Projection -----------------------------------------------------------------------------------

-- Replaces one level of a container so the original (the live replay options) is never touched.
local function branch(container, key)
    local copy = table.clone(container)
    copy[key] = type(container[key]) == "table" and table.clone(container[key]) or nil
    return copy
end

-- Where our entry lives in a replay's per-team tables: one value per team in a 1v1, a list by seat
-- in a 2v2. `teamMode` says which, and the stored shape has to agree before anything is projected:
-- a mismatch means the game changed how it keys these, and simulating a guessed layout would be
-- worse than the heuristic it is meant to replace.
local function seat(container, team, index, teamMode)
    local value = type(container) == "table" and container[team]
    if type(value) ~= "table" then
        return nil
    end
    local perSeat = type(value[1]) == "table"
    if perSeat ~= (teamMode == true) then
        return nil
    end
    if not perSeat then
        return value
    end
    return type(value[index]) == "table" and value[index] or nil
end

-- The round's simulation inputs with `candidate` applied, or nil when the layout is unfamiliar.
-- A basic stat raises its level by one; an effect is appended to our secondary traits, which is
-- how the server records a chosen trait card.
function Upgrades.project(candidate, statLevels, traits, team, index, teamMode)
    if not usable(candidate) then
        return nil
    end
    if candidate.kind == "basicStat" then
        local current = seat(statLevels, team, index, teamMode)
        if not current or type(current[candidate.id]) ~= "number" then
            return nil
        end
        local projected = branch(statLevels, team)
        local target = projected[team]
        if teamMode then
            target[index] = table.clone(target[index])
            target = target[index]
        end
        target[candidate.id] += 1
        return projected, traits
    end
    local current = seat(traits, team, index, teamMode)
    if not current then
        return nil
    end
    for _, held in ipairs(current) do
        if held == candidate.id then
            return nil -- already carried; the card would change nothing to simulate
        end
    end
    local projected = branch(traits, team)
    local target = projected[team]
    if teamMode then
        target[index] = table.clone(target[index])
        target = target[index]
    end
    target[#target + 1] = candidate.id
    return statLevels, projected
end

-- Simulated selection -------------------------------------------------------------------------

-- Picks the card that actually wins the next round.
--
-- context = {
--   seed                      -- next round's seed (Match.nextSeed); nil means no simulation
--   team, index, teamMode     -- which entry in the per-team tables is ours
--   roles, directions         -- every ball and launch direction, keyed by team as in a replay
--   statLevels, traits, arena -- the round's inputs, from the last replay
--   roleId, secondary         -- for the heuristic tie-break
--   deadline, valid
-- }
--
-- Returns the card, a line explaining it, and the simulated outcome (1 win, 0.5 draw, 0 loss), or
-- nil when nothing could be simulated in time and the caller should fall back to Upgrades.best.
function Upgrades.bestBySimulation(candidates, context)
    if not context.seed or not Sim.ready() or type(context.roles) ~= "table"
        or type(context.directions) ~= "table" then
        return nil
    end
    local maxDuration = Sim.maxDuration(context.arena)
    local function play(statLevels, traits)
        local winner, elapsed = Sim.run(context.seed, context.roles, context.directions, statLevels, traits,
            context.arena, context.deadline, context.valid)
        if not winner then
            return nil
        end
        return Sim.outcome(winner, context.team), Sim.score(winner, elapsed, context.team, maxDuration)
    end

    -- The same round without any card, so the report can say what the choice is worth.
    local baseline = play(context.statLevels, context.traits)
    local best, bestOutcome, bestScore, bestHeuristic, tried = nil, -1, -1, -math.huge, 0
    for _, candidate in ipairs(candidates) do
        if os.clock() >= context.deadline or (context.valid and not context.valid()) then
            break
        end
        local statLevels, traits = Upgrades.project(candidate, context.statLevels, context.traits,
            context.team, context.index, context.teamMode)
        if statLevels then
            local outcome, score = play(statLevels, traits)
            if outcome then
                tried += 1
                local heuristic = Upgrades.score(candidate, context.roleId, context.secondary)
                -- Outcome first, then how fast, then the star/synergy guess for a genuine tie.
                if outcome > bestOutcome
                    or (outcome == bestOutcome and score > bestScore)
                    or (outcome == bestOutcome and score == bestScore and heuristic > bestHeuristic) then
                    best, bestOutcome, bestScore, bestHeuristic = candidate, outcome, score, heuristic
                end
            end
        end
        Sim.breathe()
    end
    if not best or tried < 2 then
        return nil -- one simulated card is not a comparison
    end
    local result = bestOutcome >= 1 and "wins" or bestOutcome >= 0.5 and "draws" or "loses"
    local change = baseline and bestOutcome > baseline and " (turns the round around)"
        or baseline and bestOutcome < baseline and " (best of a losing round)" or ""
    return best, string.format("%s: simulated, %s next round%s", best.id, result, change), bestOutcome
end

return Upgrades
end
__modules["features/duel"] = function(use)
-- Duel tab: queue with Quick Play, pick the ball, aim, and queue again.
--
-- Picks: inventory choices use the free pick, then a pick voucher or diamonds when enabled.
-- DuelTableBallSelectPurchase lists eligible choices; DuelTableBallSelfSelect confirms one. "Smart"
-- simulates each offered ball against what everyone else played last round once the round's seed is
-- known (round 2 on, see core/match); otherwise, and in round 1, balls go by their win rate across
-- all players.
--
-- Aim: the launch direction decides the battle. Smart aim runs the game's own simulation for each
-- direction and locks the one that wins most. From round 2 the seed is exact and most players keep
-- the same direction every round, so the prediction is usually right; in round 1 it can only pick
-- the direction that wins most often over random seeds. 2v2 works the same way with four balls: the
-- replays key balls and directions by team and seat, the 2v2 board has its own arena, and the
-- server relays the teammate's aim while they drag it.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Match = use("core/match")
local Sim = use("core/sim")
local Solver = use("core/solver")
local Profile = use("core/profile")
local Stats = use("core/stats")
local Limits = use("core/limits")
local Upgrades = use("core/upgrades")
local Trajectory = use("core/trajectory")

local Options = Ui.Options

local QUEUE_INTERVAL = 6 -- seconds between Quick Play requests while unseated
local PICK_WINDOW = 30 -- seconds the game gives to pick (and to aim)
local PICK_MARGIN = 4 -- answer this long before the game picks for us
local FREE_LIST_WAIT = 4
local LOCK_WAIT = 3
local PICK_DIRECTIONS = 12 -- directions tried per ball when picking by simulation
local AIM_DIRECTIONS = 36
local OPPONENT_SWEEP = 10 -- opponent launch directions the guaranteed floor is measured over
local REROLL_WAIT, REROLL_COOLDOWN = 3, 5
-- Round 1 has no seed, so there is no grid to solve: every scenario is a guessed seed and the
-- opponent's aim can only be averaged over. More think time buys more guesses.
local ROUND_ONE_SAMPLES, ROUND_ONE_MAX = 6, 14
-- 2v2: think once the teammate's aim has stopped moving this long (or when time runs short).
local TEAMMATE_SETTLE = 2
-- 2v2 Smart picks wait up to this long into the pick timer for the teammate to lock their ball,
-- leaving at least PICK_THINK_RESERVE seconds to simulate.
local TEAMMATE_PICK_WAIT, PICK_THINK_RESERVE = 12, 8

local MODES = { "1v1 (3 HP)", "2v2" }
-- Since the October 16 update each mode has its own servers (Env.serverType) and Quick Play seats
-- you at whatever tables this server has, so the mode decides the server, not the request.
local SERVER_FOR_MODE = { ["1v1 (3 HP)"] = "standard", ["2v2"] = "twoVTwoServer" }
local SERVER_NAME = { standard = "1v1", twoVTwoServer = "2v2", tradeServer = "trading" }
local STRATEGIES = { "Smart", "Best win rate", "First offered", "Selected inventory ball" }

-- Ball names for the "Never pick" list.
local ballNames = {}
for _, ball in ipairs(Env.loadModule("Config").ball.list) do
    if ball.canPlayerUse then
        ballNames[#ballNames + 1] = ball.displayName
    end
end
table.sort(ballNames)

local tab = Ui.Tabs.Duel
local auto = tab:AddGroupbox({ Side = "Left", Name = "Auto duel", IconName = "swords" })
auto:AddToggle("AutoDuel", {
    Text = "Auto duel",
    Default = false,
    Tooltip = "Queues with Quick Play, picks your ball, aims, and queues again after each match.",
})
Ui.automation("AutoDuel")
auto:AddDropdown("DuelMode", {
    Text = "Mode", Values = MODES, Default = MODES[1],
    Tooltip = "Each mode has its own servers now. On the wrong kind, auto duel waits: use Switch server below or the game's mode button.",
})
auto:AddToggle("StopAtCoinCap", {
    Text = "Stop at the coin cap",
    Default = true,
    Tooltip = "Duels pay nothing past the daily (and weekly) coin cap. Stops after the match in progress.",
})
auto:AddToggle("DuelForCandy", {
    Text = "Keep going for Halloween candy",
    Default = true,
    Tooltip = "During the Halloween event every match still pays 1 candy past the coin cap, up to 30 a day. Stops at whichever cap comes last.",
})
auto:AddButton({
    Text = "Switch server for this mode",
    Func = function()
        local wanted = SERVER_FOR_MODE[Options.DuelMode.Value]
        if not wanted then return end
        if Env.serverType() == wanted then
            Ui.notify("Auto duel", "You are already on a " .. SERVER_NAME[wanted] .. " server.", 5)
            return
        end
        -- The same request as the game's mode button; the server teleports you.
        Env.event("ModeTeleportRequest"):FireServer(wanted)
        Ui.notify("Auto duel", "Moving to a " .. SERVER_NAME[wanted] .. " server. Run the script again there if it does not load by itself.", 8)
    end,
    Tooltip = "Teleports you to a server for the selected mode, as the game's own mode button does.",
})
auto:AddButton({
    Text = "Leave the table",
    Func = function()
        Env.event("DuelTableLeaveRequest"):FireServer()
    end,
    Tooltip = "Mid-match this forfeits.",
})

local picks = tab:AddGroupbox({ Side = "Left", Name = "Ball picks", IconName = "circle-dot" })
picks:AddDropdown("PickStrategy", {
    Text = "Pick by",
    Values = STRATEGIES,
    Default = STRATEGIES[1],
    Tooltip = "Smart simulates each offered ball against the opponent's last ball once the seed is known, and uses win rates before that.",
})
picks:AddToggle("FreePick", {
    Text = "Use the free pick",
    Default = true,
    Tooltip = "Takes the best server-approved free choice, including owned balls and weekly free balls you have unlocked.",
})
local NO_INVENTORY_BALL = "Choose an inventory ball"
local inventoryByLabel, inventorySignature = {}, nil
local function inventoryChoices()
    local items = Env.data("items")
    if type(items) ~= "table" then
        return nil
    end
    local labels, ids, seen = { NO_INVENTORY_BALL }, {}, {}
    for _, item in pairs(items) do
        if type(item) == "table" and item.itemType == "Ball" and type(item.itemId) == "string"
            and (item.ownerUserId == nil or item.ownerUserId == Env.LocalPlayer.UserId) and not seen[item.itemId] then
            local definition = Env.loadModule("Config").ball.byCnId[item.itemId]
            if definition and definition.canPlayerUse ~= false then
                seen[item.itemId] = true
                local label = Env.ballName(item.itemId) .. " [" .. item.itemId .. "]"
                ids[label] = item.itemId
                labels[#labels + 1] = label
            end
        end
    end
    table.sort(labels, function(a, b)
        if a == NO_INVENTORY_BALL then return b ~= NO_INVENTORY_BALL end
        if b == NO_INVENTORY_BALL then return false end
        return a < b
    end)
    return labels, ids
end
local initialInventory, initialIds = inventoryChoices()
inventoryByLabel = initialIds or {}
picks:AddDropdown("InventoryBall", {
    Text = "Inventory ball", Values = initialInventory or { NO_INVENTORY_BALL },
    Default = NO_INVENTORY_BALL, Searchable = true,
    Tooltip = "Set Pick by to Selected inventory ball to use this ball whenever the game allows it. The list follows your inventory.",
})
picks:AddToggle("PaidInventoryPick", {
    Text = "Allow paid inventory picks", Default = false,
    Tooltip = "After the free pick, allows the game's normal cost: a pick voucher first, otherwise your existing diamonds. Applies to every picking round while Auto duel is on.",
})
local inventoryCostLabel = picks:AddLabel("Inventory picks: waiting for a ball offer.", true)
local function selectedInventoryBall()
    if Options.PickStrategy.Value == "Selected inventory ball" then
        return inventoryByLabel[Options.InventoryBall.Value]
    end
end
local function inventoryPickAvailable(offer)
    local price = offer and offer.selectPrice
    if type(price) ~= "number" or price < 0 or price ~= price or price == math.huge then
        return false, "Inventory selection is unavailable."
    end
    if price == 0 then
        return true, "Inventory pick: free."
    end
    local vouchers = Env.data("vouchers")
    local count = type(vouchers) == "table" and tonumber(vouchers["指定卡"]) or 0
    if (count or 0) >= 1 then
        return Ui.on("PaidInventoryPick"), "Inventory pick: 1 pick voucher" .. (Ui.on("PaidInventoryPick") and "." or " (paid picks off).")
    end
    local enough = (tonumber(Env.data("diamonds")) or 0) >= price
    local suffix = not Ui.on("PaidInventoryPick") and " (paid picks off)." or not enough and " (not enough diamonds)." or "."
    return Ui.on("PaidInventoryPick") and enough, string.format("Inventory pick: %s diamonds%s", tostring(price), suffix)
end
Life.loop("duel:inventory", 3, function()
    local labels, ids = inventoryChoices()
    if labels then
        local signature = table.concat(labels, "\0")
        inventoryByLabel = ids
        if signature ~= inventorySignature then
            inventorySignature = signature
            Env.elevate()
            Options.InventoryBall:SetValues(labels)
        end
    end
    if not Life.alive then return end
    Env.elevate()
    if Match.seated() and Match.phase() == "Picking" and not Match.ballLocked then
        local _, text = inventoryPickAvailable(Match.offer)
        Env.elevate()
        inventoryCostLabel:SetText(text)
    else
        inventoryCostLabel:SetText("Inventory picks: available while choosing a ball.")
    end
end)
picks:AddDropdown("NeverPick", {
    Text = "Never pick",
    Values = ballNames,
    Multi = true,
    Searchable = true,
    Default = {},
})
picks:AddToggle("RerollBadOffers", {
    Text = "Reroll bad offers", Default = true,
    Tooltip = "Rerolls once when every offered ball is excluded or below the threshold. Diamond rerolls require the separate option below.",
})
picks:AddToggle("UseOwnedDiamondsForRerolls", {
    Text = "Use owned diamonds for rerolls", Default = false,
    Tooltip = "Allows ball and upgrade rerolls only when your existing diamonds cover the price. Off by default to avoid the game's Robux top-up prompt.",
})
picks:AddSlider("RerollThreshold", {
    Text = "Reroll below", Default = 50, Min = 30, Max = 70, Rounding = 0, Suffix = "%",
    Tooltip = "Rerolls when every offered ball's win rate across all players is below this. Higher holds out for strong balls but spends more rerolls.",
})
picks:AddSlider("PickDelay", {
    Text = "Pick after",
    Default = 2,
    Min = 0,
    Max = 20,
    Rounding = 0,
    Suffix = "s",
    Tooltip = "Waits this long before picking. The pick always goes in before the game's timer ends.",
})

local aimBox = tab:AddGroupbox({ Side = "Right", Name = "Aim", IconName = "crosshair" })
aimBox:AddToggle("SmartAim", {
    Text = "Smart aim",
    Default = true,
    Tooltip = "Simulates the round for each launch direction with the game's own battle code and locks the best. Also aims for you when you play yourself.",
})
aimBox:AddToggle("AimTrajectory", {
    Text = "Show aim prediction", Default = true,
    Callback = function(value)
        if not value then
            Trajectory.clear()
        end
    end,
})
aimBox:AddDropdown("AimStyle", {
    Text = "Play style",
    Values = { "Balanced", "Exploit", "Safe" },
    Default = "Balanced",
    Tooltip = "Exploit answers the aim this opponent is expected to use. Safe takes the direction with the best worst case, so a surprise aim cannot blow the round out. Balanced weighs both, and all three lean safer at 1 hp and bolder when the opponent is on their last.",
})
aimBox:AddSlider("AimThinkTime", {
    Text = "Think time",
    Default = 10,
    Min = 3,
    Max = 22,
    Rounding = 0,
    Suffix = "s",
    Tooltip = "Longer tries more of the opponent's possible aims. Each simulation stalls the game for a moment.",
})
aimBox:AddLabel("From round 2 the seed is exact and every ball is locked, so the round is solved as a grid: your directions against theirs. You get the aim that beats the opponent you expect and the one that cannot be punished, and the Intel tab shows which is which.", true)
aimBox:AddToggle("SeedResilience", {
    Text = "Seed resilience",
    Default = false,
    Tooltip = "When the game uses excitement selection (BestOfN seeds) or recent seed predictions have failed, falls back to multi-seed sampling instead of trusting one exact seed. Enable when Intel shows seed accuracy dropping.",
})

local matchBox = tab:AddGroupbox({ Side = "Right", Name = "Match", IconName = "activity" })
local panel = Ui.panel(matchBox, 6)
local upgrades = tab:AddGroupbox({ Side = "Left", Name = "Upgrades", IconName = "sparkles" })
upgrades:AddToggle("RerollLowUpgrades", {
    Text = "Reroll one-star offers", Default = true,
    Tooltip = "Rerolls once if every card is one star. Diamond rerolls also require Use owned diamonds for rerolls under Ball picks.",
})
upgrades:AddToggle("SimulateUpgrades", {
    Text = "Simulate upgrade cards", Default = true,
    Tooltip = "A card is an entry in the stat and trait tables the battle simulation reads, so each one can be played out instead of guessed at. Needs a known seed; before that, and whenever the card tables are not in a shape it recognises, the star rating decides.",
})
local upgradeLabel = upgrades:AddLabel("Cards score 10 per star, +15 for a matching ball trait, or +3 for defense, shield and health.", true)

-- Session tally --------------------------------------------------------------------------------

local session = { rounds = { won = 0, lost = 0, draw = 0 }, matches = { won = 0, lost = 0 }, coins = 0 }
Match.status = "Off"
local prediction = nil -- { text, ... } for the round being played
-- The last rounds, newest last, for checking predictions: what was assumed and what happened.
local history = {}
local HISTORY_SIZE = 30
-- Published on Match, the way `status` already is, so features/intel can report on the solver
-- without a feature having to use() another feature (and rebuild its tab if that one failed).
Match.history, Match.session = history, session

local function directionsMatch(a, b)
    return typeof(a) == "Vector2" and typeof(b) == "Vector2" and (a - b).Magnitude < 1e-3
end

local function otherTeam(team)
    return team == "Blue" and "Yellow" or "Blue"
end

-- Balls or directions for everyone at the table, keyed by team the way the simulation and the
-- replays have them: one value per team in a 1v1, a list by seat in a 2v2.
local function byTeam(players, valueOf)
    local out = {}
    local teamMode = Match.teamSize() > 1
    for _, player in ipairs(players) do
        if teamMode then
            out[player.team] = out[player.team] or {}
            out[player.team][player.index] = valueOf(player)
        else
            out[player.team] = valueOf(player)
        end
    end
    return out
end

-- "Ray Ball + Spider Ball" for a team's entry in a replay's selectedRoles.
local function teamBalls(roles, team)
    local value = type(roles) == "table" and roles[team]
    if type(value) ~= "table" then
        return Env.ballName(value)
    end
    local names = {}
    for _, role in ipairs(value) do
        names[#names + 1] = Env.ballName(role)
    end
    return table.concat(names, " + ")
end

Match.onRound(function(replay, won)
    local rounds = session.rounds
    if won == nil then
        rounds.draw += 1
    elseif won then
        rounds.won += 1
    else
        rounds.lost += 1
    end
    if prediction then
        prediction.result = won
    end
    local options = replay.replayOptions or {}
    local team = Match.team()
    local entry = {
        round = replay.round,
        won = won,
        balls = string.format("%s vs %s", teamBalls(options.selectedRoles, team), teamBalls(options.selectedRoles, otherTeam(team))),
    }
    if prediction and prediction.seed then
        -- Was the seed right, and did everyone else aim where we assumed?
        entry.seedRight = prediction.seed == replay.seed
        local kept, opponents, opponentsKept = true, 0, 0
        for _, player in ipairs(Match.players()) do
            local assumed = prediction.assumed[player.userId]
            local same = assumed ~= nil
                and directionsMatch(assumed, Match.forPlayer(options.initialDirections, player.team, player.index))
            if assumed and not same then
                kept = false
            end
            if player.teammate then
                entry.teammateKeptAim = same
            elseif not player.me then
                opponents += 1
                opponentsKept += same and 1 or 0
            end
        end
        entry.othersKeptAim = kept
        entry.opponentsKeptAim = string.format("%d/%d", opponentsKept, opponents)
        entry.opponentsKept, entry.opponents = opponentsKept, opponents
        entry.predicted = prediction.predicted
        entry.expected, entry.worst = prediction.expected, prediction.worst
    end
    -- Learn from the round regardless of whether we predicted it. keepsAim compares the replay
    -- that just landed against the one before it, which is exactly "did they launch there again",
    -- and is nil in round 1 where there is nothing to compare and nothing to learn.
    for _, player in ipairs(Match.players()) do
        if not player.me then
            Profile.observe(player.userId, Match.keepsAim(player),
                Match.forPlayer(options.selectedRoles, player.team, player.index),
                not player.teammate and won or nil)
        end
    end
    history[#history + 1] = entry
    if #history > HISTORY_SIZE then
        table.remove(history, 1)
    end
    if replay.matchFinished then
        local matches = session.matches
        if won then
            matches.won += 1
        else
            matches.lost += 1
        end
    end
end)

-- Through Match, so a renamed currency event costs the session tally and nothing else. Bound
-- directly, it errored on the way up and took auto duel, picks and aim with it.
Match.listen("CurrencyChanged", function(currency, delta, _, source)
    if currency == "coins" and type(delta) == "number" and type(source) == "table" and source.type == "duelReward" then
        session.coins += delta
    end
end)

-- Choosing a ball --------------------------------------------------------------------------------

local function never(ball)
    local chosen = Options.NeverPick and Options.NeverPick.Value or {}
    return chosen[Env.ballName(ball)] == true
end

local function allowed(candidates)
    local out = {}
    for _, ball in ipairs(candidates) do
        if not never(ball) then
            out[#out + 1] = ball
        end
    end
    -- The server requires a pick even when every candidate is excluded; reroll is attempted first.
    return #out > 0 and out or candidates
end

-- The one opponent of a 1v1 (from Match.players), or nil in a 2v2.
local function soleOpponent(players)
    if Match.teamSize() ~= 1 then
        return nil
    end
    for _, player in ipairs(players) do
        if not player.me then
            return player
        end
    end
    return nil
end

-- Best by win rate, head to head against `versus` when the game has enough games of it.
local function byWinRate(candidates, versus)
    if #candidates == 0 then return nil, "no eligible balls" end
    local best, bestRate = candidates[1], -1
    local hasStatistics = false
    for _, ball in ipairs(candidates) do
        local rate = Stats.against(ball, versus)
        hasStatistics = hasStatistics or rate ~= nil
        rate = rate or 0
        if rate > bestRate then
            best, bestRate = ball, rate
        end
    end
    if not hasStatistics then return best, Env.ballName(best) .. ": statistics unavailable" end
    return best, string.format("%s: %d%% win rate%s", Env.ballName(best), math.floor(bestRate * 100 + 0.5),
        versus and " vs " .. Env.ballName(versus) or "")
end

-- Simulates each candidate with the known seed against everyone else's ball and aim from last
-- round (teammate included in a 2v2). Nil when the seed or last round is not known yet.
local function bySimulation(candidates, deadline, valid)
    local seed = Match.nextSeed()
    if not seed or not Sim.ready() then
        return nil
    end
    local players = Match.players()
    local lastRole, lastDirection = {}, {}
    for _, player in ipairs(players) do
        if not player.me then
            local role, direction = Match.lastPlay(player)
            -- A teammate who has already locked this round shows their ball (the pick screen does
            -- too). Failing both, the ball this player is known to favour beats giving up on the
            -- simulation entirely.
            role = player.teammate and player.roleId or role or Profile.likelyBall(player.userId)
            if not (role and direction) then
                return nil
            end
            lastRole[player.userId], lastDirection[player.userId] = role, direction
        end
    end
    local options = Match.lastReplay.replayOptions or {}
    local arena = Match.arena()

    -- The opponent's ball next round is their last one if they keep it; for a switcher (a spread
    -- ball history) hedge our pick across their likeliest balls instead of a single guess. A
    -- concentrated history, no history, or a 2v2 leaves one hypothesis: the old behaviour exactly.
    local opponent = soleOpponent(players)
    local hypotheses = { { roles = lastRole, weight = 1 } }
    if opponent then
        local dist = Profile.ballDistribution(opponent.userId, 2)
        if dist and #dist == 2 and dist[1].weight < 0.75 then
            hypotheses = {}
            for _, item in ipairs(dist) do
                local roles = table.clone(lastRole)
                roles[opponent.userId] = item.roleId
                hypotheses[#hypotheses + 1] = { roles = roles, weight = item.weight }
            end
        end
    end

    local best, bestScore, bestWins = nil, -1, 0
    local perCall = math.max(1, (deadline - os.clock()) / (#candidates * #hypotheses))
    for _, ball in ipairs(candidates) do
        local weighted, weights, minWins = 0, 0, math.huge
        for _, hypothesis in ipairs(hypotheses) do
            local direction, expected, wins = Sim.bestDirection({
                team = Match.team(),
                roles = byTeam(players, function(player)
                    return player.me and ball or hypothesis.roles[player.userId]
                end),
                place = function(direction)
                    return byTeam(players, function(player)
                        return player.me and direction or lastDirection[player.userId]
                    end)
                end,
                directions = Sim.directions(PICK_DIRECTIONS),
                scenarios = { { seed = seed, weight = 1 } },
                statLevels = options.statLevels,
                traits = options.selectedSecondaryTraits,
                arena = arena,
                deadline = math.min(deadline, os.clock() + perCall),
                valid = valid,
            })
            if not direction then return nil end
            weighted += expected * hypothesis.weight
            weights += hypothesis.weight
            minWins = math.min(minWins, wins)
        end
        -- Weighted win chance across the opponent's likely balls, then the most forgiving aim in the
        -- worst of them, then the ball itself. A guaranteed win needs every hypothesis to win.
        local expected = weights > 0 and weighted / weights or 0
        local score = (expected >= 1 and 0.6 or 0) + 0.25 * minWins / PICK_DIRECTIONS + 0.15 * (Stats.winRate(ball) or 0.5)
        if score > bestScore then
            best, bestScore, bestWins = ball, score, minWins
        end
    end
    if not best then
        return nil
    end
    if #hypotheses > 1 then
        return best, string.format("%s: robust across %d likely opponent balls, %d/%d aims win (simulated)",
            Env.ballName(best), #hypotheses, bestWins, PICK_DIRECTIONS)
    end
    return best, string.format("%s: wins with %d/%d aims against last round's balls (simulated)", Env.ballName(best),
        bestWins, PICK_DIRECTIONS)
end

local function choose(candidates, deadline, valid)
    local strategy = Options.PickStrategy.Value
    local selected = selectedInventoryBall()
    if selected and table.find(candidates, selected) then
        return selected, Env.ballName(selected) .. ": selected inventory ball"
    end
    if strategy == "First offered" then
        return candidates[1], Env.ballName(candidates[1]) .. ": first offered"
    end
    if strategy == "Smart" then
        local ball, why = bySimulation(candidates, deadline, valid)
        if ball then
            return ball, why
        end
    end
    local opponent = soleOpponent(Match.players())
    return byWinRate(candidates, opponent and (Match.lastPlay(opponent)))
end

local function waitFor(predicate, seconds)
    local deadline = os.clock() + seconds
    while Life.alive and not predicate() and os.clock() < deadline do
        Life.wait(0.1)
    end
    Env.elevate()
    return Life.alive and predicate()
end

local triedAt = {}
local function mayTry(key, cooldown)
    local now = os.clock()
    if not Life.alive or now - (triedAt[key] or -math.huge) < cooldown then
        return false
    end
    triedAt[key] = now -- acquire before sending, including failed/timed-out calls
    return true
end

local function reroll(kind, offer, deadline, valid)
    local function affordable()
        local allowDiamonds = Ui.on("UseOwnedDiamondsForRerolls")
        if kind == "ball" then
            return Match.canRerollBall(allowDiamonds)
        end
        return Match.canRerollUpgrade(allowDiamonds)
    end
    if offer.rerollTried or deadline - os.clock() < REROLL_WAIT + 1
        or not affordable()
        or not mayTry("reroll:" .. kind, REROLL_COOLDOWN) then
        return
    end
    local remote = Env.event(kind == "ball" and "DuelTableBallReroll" or "DuelTableUpgradeReroll")
    if not valid() or not affordable() then
        return
    end
    offer.rerollTried, offer.rerollPending = true, true
    Match.status = kind == "ball" and "Rerolling bad balls" or "Rerolling one-star upgrades"
    Env.elevate()
    remote:FireServer(Match.tableModel)
    waitFor(function()
        return not valid() or not offer.rerollPending
    end, math.min(REROLL_WAIT, deadline - os.clock()))
    -- If no reply arrives, leave the request pending until near the deadline. A later loop
    -- reads the latest offer rather than choosing from the pre-reroll candidates.
end

local function badBalls(candidates)
    if #candidates == 0 then
        return false
    end
    for _, ball in ipairs(candidates) do
        local rate = Stats.winRate(ball)
        if not never(ball) and (rate == nil or rate * 100 >= Options.RerollThreshold.Value) then
            return false -- unknown stats do not justify spending a reroll
        end
    end
    return true
end

local function pick(offer)
    local model = Match.tableModel
    local deadline = offer.at + (offer.duration or PICK_WINDOW) - PICK_MARGIN
    local function valid()
        return Life.alive and Ui.on("AutoDuel") and Match.seated() and Match.phase() == "Picking"
            and Match.tableModel == model and Match.offer == offer and not Match.ballLocked
    end
    if not valid() then
        return true
    end
    local candidates, inventoryPick = offer.offer or {}, false
    local selected = selectedInventoryBall()
    local alreadyOffered = selected and table.find(candidates, selected) ~= nil
    local wantsInventory = not alreadyOffered and (selected ~= nil
        or (Options.PickStrategy.Value ~= "Selected inventory ball" and (Ui.on("FreePick") or Ui.on("PaidInventoryPick"))))
    local available = wantsInventory and inventoryPickAvailable(offer)
    local useInventory = available and (offer.selectPrice > 0 or Ui.on("FreePick") or selected ~= nil)
    if useInventory and not offer.selectAsked and mayTry("inventoryPick", 5) then
        offer.selectAsked, offer.selectPending, offer.selectError = true, true, nil
        offer.selectAskedAt = os.clock()
        Match.selectList = nil
        Env.elevate()
        Env.event("DuelTableBallSelectPurchase"):FireServer(model)
        waitFor(function()
            return not valid() or not offer.selectPending
        end, math.max(0, math.min(FREE_LIST_WAIT, deadline - os.clock())))
    end
    if not valid() then
        return true
    end
    if useInventory and offer.selectPending and os.clock() < deadline - 1 then
        Match.status = "Waiting for inventory choices"
        return false
    end
    if useInventory and Match.selectList and not offer.selectError and type(Match.selectList.roleIds) == "table"
        and #Match.selectList.roleIds > 0 and (not selected or table.find(Match.selectList.roleIds, selected)) then
        candidates, inventoryPick = Match.selectList.roleIds, true
    end
    if not inventoryPick and not alreadyOffered and Ui.on("RerollBadOffers") and badBalls(candidates)
        and Match.canRerollBall(Ui.on("UseOwnedDiamondsForRerolls")) then
        reroll("ball", offer, deadline, valid)
    end
    if not valid() then
        return true
    end
    if offer.rerollPending and os.clock() < deadline - 1 then
        Match.status = "Waiting for ball reroll"
        return false
    end
    candidates = inventoryPick and candidates or offer.offer or {}
    if #candidates == 0 then
        return false
    end
    -- 2v2: simulating is worth more with the teammate's real ball, so give them time to lock it,
    -- keeping enough of the timer to simulate afterwards.
    local waitUntil = math.min(offer.at + TEAMMATE_PICK_WAIT, deadline - PICK_THINK_RESERVE)
    if Match.teamSize() > 1 and Options.PickStrategy.Value == "Smart" and Match.nextSeed() then
        Match.status = "Picking a ball (waiting for your teammate's pick)"
        waitFor(function()
            if os.clock() >= waitUntil or not valid() then
                return true
            end
            for _, player in ipairs(Match.players()) do
                if player.teammate and player.roleId then
                    return true
                end
            end
            return false
        end, TEAMMATE_PICK_WAIT)
    end
    if not valid() then
        return true
    end
    Match.status = "Picking a ball"
    -- A reply can arrive during the teammate wait too.
    candidates = inventoryPick and candidates or offer.offer or {}
    local revision = offer.revision
    local preferred = selectedInventoryBall()
    local choices = preferred and table.find(candidates, preferred) and { preferred } or allowed(candidates)
    local ball, why = choose(choices, deadline - 1, valid)
    local pickAt = math.min(offer.at + Options.PickDelay.Value, deadline)
    waitFor(function()
        return not valid() or os.clock() >= pickAt
    end, math.max(0, pickAt - os.clock()))
    if not valid() then
        return true
    end
    if not ball or offer.revision ~= revision then
        return false
    end
    if inventoryPick then
        local selectedNow = selectedInventoryBall()
        if selectedNow and selectedNow ~= ball then return false end
        local affordable, text = inventoryPickAvailable(offer)
        if not affordable then
            Env.elevate()
            inventoryCostLabel:SetText(text)
            return false -- re-read the current balance/settings before confirming a paid choice
        end
    end
    if not valid() then return true end
    offer.selectConfirmError = nil
    -- A callback error or a delayed confirmation must never submit another paid pick.
    if inventoryPick and offer.inventorySubmitted then return true end
    local pickRemote = Env.event(inventoryPick and "DuelTableBallSelfSelect" or "DuelTableBallSelect")
    if inventoryPick then
        local selectedNow = selectedInventoryBall()
        if (selectedNow and selectedNow ~= ball) or not inventoryPickAvailable(offer) then return false end
    end
    if not valid() then return true end
    if inventoryPick then offer.inventorySubmitted = true end
    Env.elevate()
    pickRemote:FireServer(model, ball)
    local weekly = Match.isWeeklyFree(ball) and " (weekly free)" or ""
    prediction = { text = "Picked " .. why .. weekly }
    Match.status = "Ball selected: " .. Env.ballName(ball) .. weekly
    if inventoryPick then
        waitFor(function()
            return not valid() or offer.selectConfirmError ~= nil
        end, LOCK_WAIT)
    end
    if inventoryPick and valid() then
        -- An unavailable/denied inventory choice falls back to the ordinary offer.
        local fallback, fallbackWhy = byWinRate(allowed(offer.offer or {}))
        if fallback then
            Env.elevate()
            Env.event("DuelTableBallSelect"):FireServer(model, fallback)
            prediction = { text = "Picked " .. fallbackWhy }
            Match.status = "Inventory choice unavailable; selected " .. Env.ballName(fallback)
        end
    end
    return true
end

-- Aiming -----------------------------------------------------------------------------------------

-- A score as a percentage. Scores carry a small bonus for quick wins (core/sim's tie-break), which
-- pushes a certain win just past 1, and "101% expected" reads as a bug.
local function percent(score)
    return math.clamp(math.floor(score * 100 + 0.5), 0, 100)
end

local function aim()
    if not Sim.ready() then
        Match.status = "Waiting for simulation modules"
        return
    end
    local token, model = Match.aimToken, Match.tableModel
    local function valid()
        return Life.alive and Ui.on("SmartAim") and Match.seated() and Match.phase() == "Aiming"
            and Match.aimToken == token and Match.tableModel == model and not Match.aimLocked
    end
    local players = Match.players()
    local me
    for _, player in ipairs(players) do
        if player.me then
            me = player
        end
        if not player.roleId then
            return -- balls are not all locked yet
        end
    end
    if not (Ui.on("SmartAim") and me) then
        return -- the game locks the current aim when its timer runs out
    end
    Match.status = "Aiming"
    -- 2v2: the teammate's aim is known as they drag it, so wait for it to settle first.
    local thinkTime = math.min(Options.AimThinkTime.Value, PICK_WINDOW - PICK_MARGIN)
    local latest = Match.aimStartedAt + PICK_WINDOW - PICK_MARGIN - thinkTime
    local hasTeammate = false
    for _, player in ipairs(players) do
        hasTeammate = hasTeammate or player.teammate
    end
    while hasTeammate and valid() and os.clock() < latest do
        local live = Match.teammateAim
        if live and os.clock() - live.at >= TEAMMATE_SETTLE then
            break
        end
        Match.status = "Aiming (waiting for your teammate's aim)"
        Life.wait(0.2)
    end
    if not valid() then
        return
    end
    Match.status = "Aiming (solving launch directions)"
    local seed = Match.nextSeed()
    -- Where everyone else will likely aim: a teammate's live aim while they drag it, otherwise
    -- last round's aim (nil in round 1, and nil for anyone the model says re-aims: they are
    -- swept or sampled instead).
    local likely = {}
    for _, player in ipairs(players) do
        if not player.me then
            local _, lastDirection = Match.lastPlay(player)
            -- A direction relayed this round beats last round's guess: a teammate's always, an
            -- opponent's only if the server ever leaks one (then it is their actual aim, not a guess).
            local live = Match.liveAim(player.userId, 10)
            likely[player.userId] = live or (Match.keepsAim(player) ~= false and lastDirection) or nil
        end
    end
    local options = Match.lastReplay and Match.lastReplay.replayOptions or {}
    local team = Match.team()
    local roles = byTeam(players, function(player)
        return player.roleId
    end)
    local function place(ours, scenario)
        return byTeam(players, function(player)
            return player.me and ours or scenario.others[player.userId]
        end)
    end
    local directionCount = math.clamp(math.floor(thinkTime / 10 * AIM_DIRECTIONS / 6) * 6, 12, AIM_DIRECTIONS)
    local deadline = math.min(os.clock() + thinkTime, Match.aimStartedAt + PICK_WINDOW - PICK_MARGIN)
    local arena = Match.arena()
    -- `call` becomes the round's prediction only once the aim is actually sent, so the accuracy
    -- figures never judge a call the hub abandoned at the last moment.
    local direction, expected, detail, call

    local seedReliable = true
    if Ui.on("SeedResilience") and seed then
        local excitement = Match.excitementSelection()
        if excitement and excitement.enabled then
            seedReliable = false
        end
        if seedReliable then
            local misses, checks = 0, 0
            for i = math.max(1, #history - 4), #history do
                local entry = history[i]
                if entry and entry.seedRight ~= nil then
                    checks += 1
                    if not entry.seedRight then misses += 1 end
                end
            end
            if checks >= 2 and misses / checks > 0.4 then
                seedReliable = false
            end
        end
    end

    if seed and seedReliable then
        -- The round is fully determined except for where the others launch, so solve it as a grid
        -- instead of answering one guess. The first opponent column is who the model expects, and
        -- its weight is how often these specific players have actually repeated an aim.
        local modelled = Profile.tableKeepRate(players)
        local sweep = math.clamp(math.floor(thinkTime / 2), 4, OPPONENT_SWEEP)
        local ourHp, theirHp = Match.stakes()
        local lambda = Solver.lambda(Options.AimStyle.Value, ourHp, theirHp)
        local row, columns = Solver.solve({
            team = team,
            seed = seed,
            roles = roles,
            ours = Sim.directions(directionCount),
            opponents = Solver.columns(players, likely, modelled, sweep),
            place = place,
            statLevels = options.statLevels,
            traits = options.selectedSecondaryTraits,
            arena = arena,
            lambda = lambda,
            deadline = deadline,
            valid = valid,
        })
        if not row or not valid() then
            return
        end
        direction, expected = row.direction, row.expected
        local floor = row.worst >= 1 and "a win" or row.worst >= 0.5 and "a draw" or "a loss"
        detail = string.format("floor %s | beats %d/%d aims", floor, row.wins, columns)
        local versus = string.format("%s vs %s", teamBalls(roles, team), teamBalls(roles, otherTeam(team)))
        call = {
            text = string.format("%s: %s (%s, %d%% expected, %s style at lambda %.2f)", versus,
                row.winner == team and "expect a win" or row.winner == "Draw" and "expect a draw" or "likely a loss",
                detail, percent(row.expected), Options.AimStyle.Value, lambda),
            seed = seed,
            assumed = likely,
            predicted = row.winner == team,
            expected = row.expected,
            worst = row.worst,
            wins = row.wins,
            columns = columns,
            lambda = lambda,
            modelled = modelled,
        }
    elseif seed then
        local samples = math.clamp(math.floor(thinkTime / 3), 3, 8)
        local others = {}
        for _, player in ipairs(players) do
            if not player.me then
                others[player.userId] = likely[player.userId] or Sim.randomDirection()
            end
        end
        local scenarios = { { seed = seed, others = others, weight = 0.4 } }
        local altWeight = 0.6 / math.max(1, samples - 1)
        for _ = 2, samples do
            scenarios[#scenarios + 1] = { seed = Sim.randomSeed(), others = others, weight = altWeight }
        end
        local firstWins
        direction, expected, firstWins = Sim.bestDirection({
            team = team,
            roles = roles,
            place = place,
            directions = Sim.directions(directionCount),
            scenarios = scenarios,
            arena = arena,
            deadline = deadline,
            valid = valid,
        })
        if not direction or not valid() then
            return
        end
        detail = string.format("seed unreliable | %d candidates", samples)
        local versus = string.format("%s vs %s", teamBalls(roles, team), teamBalls(roles, otherTeam(team)))
        call = {
            text = string.format("%s: %d%% expected over %d seed candidates (%d/%d directions win the primary)",
                versus, percent(expected), samples, firstWins or 0, directionCount),
            seed = seed,
            assumed = likely,
            expected = expected,
            seedReliable = false,
        }
    else
        -- Round 1: the seed is unknown, so there is no grid. Every scenario is a guessed seed and
        -- the best that can be said is which direction wins over the most of them.
        -- Nobody has a last aim yet, so opponents are random in every scenario; only a teammate
        -- dragging their arrow is known.
        local scenarios = {}
        local samples = math.clamp(math.floor(thinkTime / 10 * ROUND_ONE_SAMPLES), ROUND_ONE_SAMPLES, ROUND_ONE_MAX)
        for _ = 1, samples do
            local others = {}
            for _, player in ipairs(players) do
                if not player.me then
                    others[player.userId] = likely[player.userId] or Sim.randomDirection()
                end
            end
            scenarios[#scenarios + 1] = { seed = Sim.randomSeed(), others = others, weight = 1 }
        end
        local firstWins
        direction, expected, firstWins = Sim.bestDirection({
            team = team,
            roles = roles,
            place = place,
            directions = Sim.directions(directionCount),
            scenarios = scenarios,
            arena = arena,
            deadline = deadline,
            valid = valid,
        })
        if not direction or not valid() then
            return
        end
        detail = string.format("round 1 | %d seeds sampled", samples)
        local versus = string.format("%s vs %s", teamBalls(roles, team), teamBalls(roles, otherTeam(team)))
        call = {
            text = string.format("%s: round 1, best aim wins %d%% of %d sampled seeds (%d/%d directions win the first)",
                versus, percent(expected), samples, firstWins or 0, directionCount),
            expected = expected,
        }
    end

    Env.elevate()
    if Ui.on("AimTrajectory") then
        local ok, err = pcall(Trajectory.show, me, direction, expected, detail)
        Life.errors["duel:trajectory"] = not ok and tostring(err) or nil
        if not ok then
            Trajectory.clear()
        end
    end
    if not valid() then
        Trajectory.clear()
        return
    end
    Env.elevate()
    if Match.teamSize() > 1 then
        -- Shows our arrow on the teammate's screen, as the game does while we drag.
        Env.unreliable("DuelTableAimPreview"):FireServer(Match.tableModel, direction)
    end
    Env.event("DuelTableLaunchDirection"):FireServer(Match.tableModel, direction)
    prediction = call
    Match.status = string.format("Aim selected (%d%% expected, %s)", percent(expected), detail)
    return true
end

-- Resolve cloud star ratings and add bonuses for the current ball's traits.
local function upgrade(offer)
    local model, phase = Match.tableModel, Match.phase()
    local function valid()
        return Life.alive and Ui.on("AutoDuel") and Match.seated() and Match.tableModel == model
            and Match.phase() == phase and Match.upgradeOffer == offer
    end
    local players = Match.players()
    local me, roleId, secondary
    for _, player in ipairs(players) do
        if player.me then
            me = player
            roleId = player.roleId or (Match.ballLocked and Match.ballLocked.roleId) or Match.lastPlay(player)
            local options = Match.lastReplay and Match.lastReplay.replayOptions
            local traits = options and options.selectedSecondaryTraits
            secondary = traits and traits[player.team]
            if Match.teamSize() > 1 and type(secondary) == "table" then
                secondary = secondary[player.index]
            end
            break
        end
    end
    local deadline = offer.at + (offer.duration or 20) - 2
    local best, maxStar, known = Upgrades.best(offer.offer or {}, roleId, secondary)
    if valid() and Ui.on("RerollLowUpgrades") and known and maxStar == 1
        and Match.canRerollUpgrade(Ui.on("UseOwnedDiamondsForRerolls")) then
        reroll("upgrade", offer, deadline, valid)
    end
    if not valid() then
        return true
    end
    if offer.rerollPending and os.clock() < deadline - 1 then
        Match.status = "Waiting for upgrade reroll"
        return false
    end
    local candidates = offer.offer or {}
    local why
    best = nil
    -- The next round's balls are not chosen yet, so the card is judged on the round we just
    -- played: same balls, same aims, next round's seed. That is a proxy, not the certainty the
    -- aim solver gets -- but a card that wins a replay of the last round beats one that merely
    -- reads as if it should.
    if Ui.on("SimulateUpgrades") and me then
        local options = Match.lastReplay and Match.lastReplay.replayOptions or {}
        local lastRoles, lastDirections, complete = {}, {}, true
        for _, player in ipairs(players) do
            local role, direction = Match.lastPlay(player)
            if not (role and direction) then
                complete = false
                break
            end
            lastRoles[player.userId], lastDirections[player.userId] = role, direction
        end
        if complete then
            best, why = Upgrades.bestBySimulation(candidates, {
                seed = Match.nextSeed(),
                team = me.team,
                index = me.index,
                teamMode = Match.teamSize() > 1,
                roles = byTeam(players, function(player)
                    return lastRoles[player.userId]
                end),
                directions = byTeam(players, function(player)
                    return lastDirections[player.userId]
                end),
                statLevels = options.statLevels,
                traits = options.selectedSecondaryTraits,
                arena = Match.arena(),
                roleId = roleId,
                secondary = secondary,
                deadline = deadline,
                valid = valid,
            })
        end
    end
    if not best then
        best = Upgrades.best(candidates, roleId, secondary)
        why = best and (best.id .. ": best star rating and trait match") or nil
    end
    if not best then
        return false
    end
    if not valid() then
        return true
    end
    Match.status = "Selecting upgrade: " .. best.id
    Env.elevate()
    upgradeLabel:SetText("Last card: " .. tostring(why))
    Env.event("DuelTableUpgradeSelect"):FireServer(model, { kind = best.kind, id = best.id })
    return true
end

-- The loop ------------------------------------------------------------------------------------------

local lastQueue = -math.huge
local handledOffer, handledAim, handledUpgrade, seenOffer

-- Aims once per Aiming token. Past the point where a search could still finish before the game
-- locks the current aim, the token is given up on: otherwise a solve that cannot complete was
-- restarted every quarter second until the phase changed, stalling frames for nothing.
local function tryAim()
    if not (Ui.on("SmartAim") and Match.seated() and Match.phase() == "Aiming" and Match.aimToken
        and handledAim ~= Match.aimToken and not Match.aimLocked) then
        return
    end
    local token = Match.aimToken
    if os.clock() >= Match.aimStartedAt + PICK_WINDOW - PICK_MARGIN then
        handledAim = token
        Match.status = "Aim window closed; the game keeps the current aim"
        return
    end
    if aim() then
        handledAim = token
    end
end

local function step()
    if not Ui.on("AutoDuel") then
        Match.status = Ui.on("SmartAim") and "Auto duel off (smart aim still aims your rounds)" or "Off"
        -- Smart aim also helps in matches you play yourself.
        tryAim()
        return
    end
    if not Match.seated() then
        local forCandy = nil
        if Ui.on("StopAtCoinCap") and (Match.capped or Limits.coins().capped) then
            local candy = Limits.candy()
            if not (Ui.on("DuelForCandy") and candy.active and not candy.capped) then
                local both = Ui.on("DuelForCandy") and candy.active
                Match.status = both and "Stopped at the coin and candy caps" or "Stopped at the coin cap"
                Ui.set("AutoDuel", false)
                Ui.notify("Auto duel", (both and "Coin and candy caps" or "Coin cap")
                    .. " reached: duels pay nothing more until the reset.", 8)
                return
            end
            forCandy = string.format(" for candy, %d/%s today", candy.today, tostring(candy.dayMax or "?"))
        end
        local wanted, server = SERVER_FOR_MODE[Options.DuelMode.Value], Env.serverType()
        if wanted and server and server ~= wanted then
            Match.status = string.format("%s is played on %s servers and this is a %s server: press Switch server",
                Options.DuelMode.Value, SERVER_NAME[wanted], SERVER_NAME[server] or server)
            return
        end
        local refusal = Match.queueRefusal
        Match.status = "Queueing (" .. Options.DuelMode.Value .. ")" .. (forCandy or "")
            .. (refusal and refusal.reason == "noAvailableTable" and os.clock() - refusal.at < 30
                and " - no free table on this server yet" or "")
        if os.clock() - lastQueue > QUEUE_INTERVAL then
            lastQueue = os.clock()
            Env.event("DuelQuickPlayRequest"):FireServer()
        end
        return
    end
    local phase = Match.phase()
    Match.status = phase == "Aiming" and (Match.aimLocked or handledAim == Match.aimToken)
        and "Aim selected (waiting for other players)" or "In a match: " .. tostring(phase)
    if phase == "Upgrading" and Match.upgradeOffer and handledUpgrade ~= Match.upgradeOffer then
        local offer = Match.upgradeOffer
        if upgrade(offer) then
            handledUpgrade = offer
        end
        return
    end
    if phase == "Picking" and Match.offer and handledOffer ~= Match.offer and not Match.ballLocked then
        local offer = Match.offer
        -- Cleared once per offer, not on every pass that is still waiting on a reroll or the
        -- teammate: last round's result line used to blink out of the panel four times a second.
        if seenOffer ~= offer then
            seenOffer, prediction = offer, nil
        end
        if pick(offer) then
            handledOffer = offer
        end
    elseif phase == "Aiming" then
        tryAim()
    end
end

Life.loop("duel:auto", 0.25, step)

Life.loop("duel:panel", 0.5, function()
    Match.prediction = prediction
    local lines = { "Status: " .. Match.status }
    if Match.seated() then
        local mine, theirs
        for _, player in ipairs(Match.players()) do
            if player.me then
                mine = Match.hp(player)
            elseif not player.teammate and not theirs then
                theirs = Match.hp(player)
            end
        end
        lines[#lines + 1] = string.format("%s, round %d: you %s hp, them %s hp", tostring(Match.tableId), Match.round(),
            tostring(mine or "?"), tostring(theirs or "?"))
        lines[#lines + 1] = Match.nextSeed() and "Seed: known (exact simulation)" or "Seed: unknown until round 1 is played"
    end
    if prediction then
        local result = prediction.result == true and " - won" or prediction.result == false and " - lost" or ""
        lines[#lines + 1] = prediction.text .. result
    end
    local rounds, matches = session.rounds, session.matches
    lines[#lines + 1] = string.format("Session: matches %d-%d, rounds %d-%d%s, +%d coins", matches.won, matches.lost,
        rounds.won, rounds.lost, rounds.draw > 0 and string.format(" (%d drawn)", rounds.draw) or "", session.coins)
    local coins = Limits.coins()
    local footer = coins.dayMax and string.format("Duel coins today: %d / %d, this week: %d / %d", coins.day, coins.dayMax,
        coins.week, coins.weekMax or 0) or ""
    panel.set(lines, footer)
end)

Life.onCleanup(function()
    table.clear(triedAt)
    table.clear(history)
    prediction, handledOffer, handledAim, handledUpgrade, seenOffer = nil, nil, nil, nil, nil
    Match.prediction = nil
    Trajectory.clear()
end)

return { history = history, session = session }
end
__modules["features/home"] = function(use)
-- Home tab: the shared welcome box (shared/home), your stats, and codes.
--
-- Codes come from the game's own config (Config.codes.list, which its redeem screen checks
-- against), so new ones are picked up without a hub update. "grantOnly" codes are handed out by
-- the developers and cannot be typed in. The server allows one redeem every 2 seconds and answers
-- SUCCESS, CLAIMED, EXPIRED or INVALID.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Home = use("shared/home")
local Match = use("core/match")
local Limits = use("core/limits")

local REDEEM_INTERVAL = 2.5
local RESULTS = {
    SUCCESS = "redeemed now",
    CLAIMED = "already redeemed",
    EXPIRED = "expired",
    INVALID = "not valid",
    INVALID_CODE = "not valid",
}

local tab = Ui.Tabs.Home
local _, statusLabel = Home.build()
local statsBox = tab:AddGroupbox({ Side = "Right", Name = "You", IconName = "user" })
local codesBox = tab:AddGroupbox({ Side = "Right", Name = "Codes", IconName = "ticket" })

local stats = statsBox:AddLabel("Loading...", true)
Life.loop("home:stats", 1, function()
    statusLabel:SetText("Doing: " .. tostring(Match.status or "Idle"))
    local exp = Env.data("exp") or {}
    local ok, level = Env.call(Env.loadModule("ExperienceService").getLevelInfo, exp.total or 0)
    local matches, wins = 0, 0
    for _, mode in pairs(Env.data("matchStats") or {}) do
        matches += mode.matches or 0
        wins += mode.wins or 0
    end
    local coins = Limits.coins()
    stats:SetText(string.format(
        "Level %s\nCoins: %s  |  Diamonds: %s\nMatches: %d, won %d (%d%%)\nWin streak: %s (best %s)\nDuel coins today: %d / %s",
        ok and level and tostring(level.level) or "?",
        tostring(Env.data("coins") or "?"),
        tostring(Env.data("diamonds") or "?"),
        matches, wins, matches > 0 and math.floor(wins / matches * 100 + 0.5) or 0,
        tostring(Env.data("winStreak") or 0), tostring(Env.data("maxWinStreak") or 0),
        coins.day, tostring(coins.dayMax or "no cap")))
end)

local codeList = codesBox:AddLabel("Loading codes...", true)
local redeeming = false

local function redeemCodes()
    local lines = {}
    for _, entry in ipairs(Env.loadModule("Config").codes.list) do
        if not entry.grantOnly then
            if not Life.alive then return end
            local ok, result = Env.invoke("RedeemCodeRedeem", entry.code)
            if not Life.alive then return end
            local text = ok and (RESULTS[result] or tostring(result)) or "the game did not answer"
            lines[#lines + 1] = string.format("%s: %s", entry.code, text)
            Env.elevate()
            codeList:SetText(table.concat(lines, "\n"))
            if result == "SUCCESS" then
                Ui.notify("Codes", "Redeemed " .. entry.code, 5)
            end
            if not Life.wait(REDEEM_INTERVAL) then
                return
            end
        end
    end
    Env.elevate()
    codeList:SetText(#lines > 0 and table.concat(lines, "\n") or "No codes right now.")
end

local function startRedeeming()
    if redeeming or not Life.alive then return end
    redeeming = true
    Life.spawn("home:codes", function()
        Life.call("home:redeem", redeemCodes)
        redeeming = false
    end)
end

codesBox:AddToggle("RedeemOnLoad", {
    Text = "Redeem codes on load",
    Default = true,
    Tooltip = "Tries every code in the game's list once each time the hub loads.",
})
codesBox:AddButton({ Text = "Redeem codes", Func = function()
    startRedeeming()
end })

-- After the autoload, so a saved "off" is respected (main calls Home.afterLoad).
return {
    afterLoad = function()
        if Ui.on("RedeemOnLoad") then
            startRedeeming()
        else
            codeList:SetText("Press Redeem codes to try the game's codes.")
        end
    end,
}
end
__modules["features/intel"] = function(use)
-- Intel tab: who you are playing, what the solver decided, and whether its predictions hold up.
--
-- Everything here is read-only. It reports on what features/duel publishes on Match (prediction,
-- history, session) and on core/profile's opponent model, so a broken panel can never change how
-- a round is played -- and checking the predictions against what actually happened is the only
-- honest way to know whether the solver is worth its think time.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Match = use("core/match")
local Profile = use("core/profile")

local tab = Ui.Tabs.Intel

-- Opponents ----------------------------------------------------------------------------------

local opponentsBox = tab:AddGroupbox({ Side = "Left", Name = "Opponents", IconName = "users" })
local opponentsPanel = Ui.panel(opponentsBox, 6)
opponentsBox:AddButton({
    Text = "Forget opponents",
    Func = function()
        Profile.forget()
        Ui.notify("Intel", "Opponent history cleared. Everyone starts at the default aim-repeat guess again.", 5)
    end,
    Tooltip = "Clears every opponent's aim and ball history, here and in the saved file.",
})

local names = {}
local function nameOf(userId)
    if names[userId] == nil then
        local player = Env.Players:GetPlayerByUserId(userId)
        names[userId] = player and player.DisplayName ~= "" and player.DisplayName or false
    end
    return names[userId] or nil
end

Life.loop("intel:opponents", 1, function()
    local lines = {}
    if Match.seated() then
        local players = Match.players()
        for _, player in ipairs(players) do
            if not player.me then
                local tag = player.teammate and " (teammate)" or ""
                if not player.teammate and Match.liveAim(player.userId, 10) then
                    tag = tag .. " [LIVE AIM READ]"
                end
                lines[#lines + 1] = Profile.describe(player, nameOf(player.userId)) .. tag
            end
        end
        lines[#lines + 1] = string.format("Chance the table repeats every aim: %d%%",
            math.floor(Profile.tableKeepRate(players) * 100 + 0.5))
    else
        lines[#lines + 1] = "Not at a table. Opponents show here once you sit down."
    end
    opponentsPanel.set(lines, string.format("%d opponents remembered", Profile.count()))
end)

-- Solver -------------------------------------------------------------------------------------

local solverBox = tab:AddGroupbox({ Side = "Right", Name = "Solver", IconName = "brain" })
local solverPanel = Ui.panel(solverBox, 6)

local function percent(value)
    return value and string.format("%d%%", math.floor(value * 100 + 0.5)) or "?"
end

local function outcomeName(value)
    if value == nil then
        return "?"
    end
    return value >= 1 and "win" or value >= 0.5 and "draw" or "loss"
end

Life.loop("intel:solver", 0.5, function()
    local prediction = Match.prediction
    local lines = {}
    local ours, theirs = Match.stakes()
    if Match.seated() then
        lines[#lines + 1] = string.format("Round %d | seed %s | hp %s vs %s", Match.round(),
            Match.nextSeed() and "known" or "unknown", tostring(ours or "?"), tostring(theirs or "?"))
        local excitement = Match.excitementSelection()
        if excitement and excitement.enabled then
            lines[#lines + 1] = string.format("BestOfN active (%d candidates) — seed prediction unreliable", excitement.candidates)
        end
    end
    if prediction and prediction.columns then
        lines[#lines + 1] = string.format("Expected result: %s", percent(prediction.expected))
        lines[#lines + 1] = string.format("Guaranteed floor: %s, whatever they aim", outcomeName(prediction.worst))
        lines[#lines + 1] = string.format("Beats %d of %d opponent aims", prediction.wins or 0, prediction.columns)
        lines[#lines + 1] = string.format("Risk weight %.2f (0 exploits, 1 plays safe), aim repeat %s",
            prediction.lambda or 0, percent(prediction.modelled))
    elseif prediction then
        lines[#lines + 1] = prediction.text
    else
        lines[#lines + 1] = "No round solved yet."
    end
    solverPanel.set(lines, "From round 2 every round is solved as a grid of your aims against theirs.")
end)

-- Accuracy -----------------------------------------------------------------------------------

local accuracyBox = tab:AddGroupbox({ Side = "Right", Name = "Prediction accuracy", IconName = "target" })
local accuracyPanel = Ui.panel(accuracyBox, 9)

Life.loop("intel:accuracy", 1, function()
    local history = Match.history or {}
    local judged, correct, seeds, seedsRight, kept, opponents = 0, 0, 0, 0, 0, 0
    for _, entry in ipairs(history) do
        if entry.predicted ~= nil and entry.won ~= nil then
            judged += 1
            correct += entry.predicted == entry.won and 1 or 0
        end
        if entry.seedRight ~= nil then
            seeds += 1
            seedsRight += entry.seedRight and 1 or 0
        end
        if entry.opponents then
            kept += entry.opponentsKept or 0
            opponents += entry.opponents
        end
    end
    local lines = {}
    lines[#lines + 1] = judged > 0 and string.format("Win/loss calls right: %d of %d (%d%%)", correct, judged,
        math.floor(correct / judged * 100 + 0.5)) or "Win/loss calls right: none judged yet"
    lines[#lines + 1] = seeds > 0 and string.format("Seed predicted exactly: %d of %d", seedsRight, seeds)
        or "Seed predicted exactly: from round 2"
    lines[#lines + 1] = opponents > 0 and string.format("Opponents repeated their aim: %d of %d", kept, opponents)
        or "Opponents repeated their aim: from round 2"
    -- The newest rounds, newest first.
    for index = #history, math.max(1, #history - 5), -1 do
        local entry = history[index]
        local result = entry.won == true and "won" or entry.won == false and "lost" or "drew"
        local call = entry.predicted == nil and "" or entry.predicted and ", called a win" or ", called a loss"
        lines[#lines + 1] = string.format("R%s %s: %s%s", tostring(entry.round), entry.balls or "?", result, call)
    end
    local session = Match.session
    local footer = session and string.format("Session: matches %d-%d, rounds %d-%d", session.matches.won,
        session.matches.lost, session.rounds.won, session.rounds.lost) or ""
    accuracyPanel.set(lines, footer)
end)

Life.onCleanup(function()
    table.clear(names)
end)

return {}
end
__modules["features/rewards"] = function(use)
-- Rewards tab: claims what the game hands out for free, and buys crates with coins.
--
-- Claims use the same remotes as the game's own UI, and the server
-- checks each one (progress, time online, day, already claimed), so a claim it refuses costs
-- nothing. What is claimable is read from the player's data as the client sees it:
--   daily quests   dailyQuest.progress/claimed vs Config.dailyQuest.list -> DailyQuestClaim(id)
--   online time    granted automatically by the updated server; display replicated progress only
--   check-in       CheckInService.client.getState() "claimable" days -> CheckInService.client.claim(day)
--   mail           mailbox.mails[id].claimedAt == 0 -> MailService/Claim(id)
-- Crates: GachaRoll(crateId, "coins"), rolled and granted by the server.
-- Halloween: the candy balance and the event's candy shop (below).

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Fusion = use("core/fusion")
local Limits = use("core/limits")

local Options = Ui.Options
local Config = Env.loadModule("Config")

local CLAIM_INTERVAL = 15
local RETRY_AFTER = 120 -- seconds before a refused claim is tried again
local BUY_INTERVAL = 3

local tab = Ui.Tabs.Rewards
local claims = tab:AddGroupbox({ Side = "Left", Name = "Auto claim", IconName = "gift" })
claims:AddToggle("AutoClaim", {
    Text = "Auto claim rewards",
    Default = true,
    Tooltip = "Claims the ticked rewards as soon as the game says they are ready.",
})
Ui.automation("AutoClaim", true)
claims:AddToggle("ClaimQuests", { Text = "Daily quests", Default = true })
claims:AddToggle("ClaimOnline", {
    Text = "Show online reward progress", Default = true,
    Tooltip = "The game now claims online rewards automatically. This only controls their progress display.",
})
claims:AddToggle("ClaimCheckIn", { Text = "Daily check-in", Default = true })
claims:AddToggle("ClaimMail", { Text = "Mail", Default = true })
claims:AddToggle("ClaimLevelRewards", { Text = "Level milestone rewards", Default = true })
claims:AddToggle("ClaimFreeChests", { Text = "Free starter / first-race chests", Default = true })
claims:AddButton({
    Text = "Claim group reward",
    Func = function()
        Life.spawn("rewards:group", function()
            local ok, result = Env.invoke("GroupJoinRewardRequest")
            local text = ok and type(result) == "table" and (result.ok and "Claimed." or tostring(result.reason))
                or "The game did not answer."
            Ui.notify("Group reward", text, 5)
        end)
    end,
    Tooltip = "Only pays if you are in the game's group.",
})
local claimPanel = Ui.panel(claims, #Config.dailyQuest.list + 9)

-- Lock every attempt before sending, including successful claims awaiting data replication.
local attemptedAt = {}
local function mayTry(key)
    local now = os.clock()
    if not Life.alive or now - (attemptedAt[key] or -math.huge) < RETRY_AFTER then
        return false
    end
    attemptedAt[key] = now
    return true
end

local function claimed(ok, result, key)
    if not Life.alive then
        return false
    end
    local success = Life.alive and ok and type(result) == "table" and result.ok == true
    if not success then
        attemptedAt[key] = os.clock()
    end
    return success
end

-- These rewards are granted by the server. Ready releases queued results; it does not accept
-- a level or chest id. In particular FirstRaceFreeChestResult is receive-only.
local rewardLog, seenRewards, seenChests = {}, {}, {}
local levelMilestones, lastExp, levelReadySent = 0, nil, false
local function logReward(key, text, toggle)
    if not Life.alive or seenRewards[key] then
        return
    end
    seenRewards[key] = true
    rewardLog[#rewardLog + 1] = text
    if #rewardLog > 3 then
        table.remove(rewardLog, 1)
    end
    if Ui.on("AutoClaim") and Ui.on(toggle) then
        Env.elevate()
        Ui.notify("Free reward", text, 5)
    end
end

Life.connect(Env.event("LevelRewardResult").OnClientEvent, function(payload)
    if not Life.alive or type(payload) ~= "table" or payload.ok == false then
        return
    end
    for _, entry in ipairs(payload) do
        if type(entry) == "table" and type(entry.level) == "number" then
            local key = "level:" .. entry.level .. ":" .. tostring(entry.rewardId or entry.cnId)
            if not seenRewards[key] then
                levelMilestones += 1
            end
            logReward(key, string.format("Level %d reward claimed", entry.level), "ClaimLevelRewards")
        end
    end
end)

local function chestResult(kind, payload)
    if not Life.alive or type(payload) ~= "table" or payload.ok == false then
        return
    end
    local results = type(payload.results) == "table" and payload.results or payload
    if #results == 0 then
        return
    end
    seenChests[kind] = true
    logReward("chest:" .. kind, string.format("%s chest claimed (%d items)", kind, #results), "ClaimFreeChests")
end
Life.connect(Env.event("NewbieFreeChestResult").OnClientEvent, function(payload)
    chestResult("Starter", payload)
end)
Life.connect(Env.event("FirstRaceFreeChestResult").OnClientEvent, function(payload)
    chestResult("First race", payload)
end)

local function claimLevels(lines, allowed)
    local exp = Env.data("exp")
    local total = type(exp) == "table" and tonumber(exp.total)
    if allowed("ClaimLevelRewards") and (not levelReadySent or (total and total > (lastExp or -1)))
        and mayTry("level:ready") then
        Env.elevate()
        Env.event("LevelRewardReady"):FireServer()
        levelReadySent, lastExp = true, total
    end
    local state = Env.data("levelRewards") or {}
    local granted = {}
    for _, field in ipairs({ "grantedRewards", "grantedRandom" }) do
        for level in pairs(type(state[field]) == "table" and state[field] or {}) do
            granted[tostring(level)] = true
        end
    end
    local count = 0
    for _ in pairs(granted) do
        count += 1
    end
    lines[#lines + 1] = string.format("Level rewards: %d saved milestones, %d received this session", count, levelMilestones)
end

local newbieReadySent = false
local function claimFreeChests(lines, allowed)
    local starter = Env.data("hasClaimedNewbieFreeChestV2")
    local firstRace = Env.data("hasClaimedFirstRaceFreeChest")
    -- One initial handshake also flushes rewards granted before the hub loaded. Retry only
    -- while PlayerData says a starter reward is pending, at the normal refusal cooldown.
    if allowed("ClaimFreeChests") and not seenChests.Starter and starter ~= nil
        and (not newbieReadySent or starter == false) and mayTry("chest:ready") then
        Env.elevate()
        Env.event("NewbieFreeChestReady"):FireServer()
        newbieReadySent = true
    end
    lines[#lines + 1] = "Starter chest: " .. ((starter == true or seenChests.Starter) and "claimed" or "pending")
    lines[#lines + 1] = "First race chest: " .. ((firstRace == true or seenChests["First race"]) and "claimed" or "awaiting first race")
end

local function claimQuests(lines, allowed)
    local data = Env.data("dailyQuest") or {}
    local progress, done = data.progress or {}, data.claimed or {}
    for _, quest in ipairs(Config.dailyQuest.list) do
        local count = progress[quest.cnId] or 0
        local state = done[quest.cnId] and "claimed" or string.format("%d/%d", math.min(count, quest.requireCount), quest.requireCount)
        if not done[quest.cnId] and count >= quest.requireCount and allowed("ClaimQuests") and mayTry("quest:" .. quest.cnId) then
            local ok, result = Env.invoke("DailyQuestClaim", quest.cnId)
            if claimed(ok, result, "quest:" .. quest.cnId) then
                state = "claimed now"
                Ui.notify("Daily quest", string.format("%s: +%s coins", quest.desc, tostring(result.rewardCoins or quest.rewardCoins)), 5)
            end
        end
        lines[#lines + 1] = string.format("%s: %s (%d coins)", quest.desc, state, quest.rewardCoins)
    end
end

local function claimOnline(lines)
    if not Ui.on("ClaimOnline") then
        return
    end
    local data = Env.data("onlineReward") or {}
    local seconds, done = data.onlineSeconds or 0, data.claimed or {}
    local ok, tiers = Env.call(Env.loadModule("OnlineRewardConfig").getTiers)
    if not ok or type(tiers) ~= "table" or #tiers == 0 then
        lines[#lines + 1] = "Online rewards: waiting for reward tiers."
        return
    end
    local nextTier, pending = nil, 0
    for _, tier in ipairs(tiers) do
        local isDone = done[tostring(tier.index)] or done[tier.index]
        if not isDone and seconds >= tier.seconds then
            pending += 1
        end
        if not isDone and seconds < tier.seconds and (not nextTier or tier.seconds < nextTier.seconds) then
            nextTier = tier
        end
    end
    -- Do not poll OnlineRewardNotifications: that drains the game's own notification queue.
    local status = pending > 0 and string.format("%d rewards awaiting the game's auto claim", pending)
        or nextTier and string.format("next reward at %d min", nextTier.minutes) or "every reward claimed"
    lines[#lines + 1] = string.format("Online %d min today: %s", seconds // 60, status)
end

local function claimCheckIn(lines, allowed)
    local service = Env.loadModule("CheckInService").client
    local ok, days = Env.call(service.getState)
    if not ok or type(days) ~= "table" then
        return
    end
    local claimedDays = 0
    for _, day in ipairs(days) do
        if day.status == "claimable" and allowed("ClaimCheckIn") and mayTry("checkin:" .. day.dayIndex) then
            local sent, result = Env.call(service.claim, day.dayIndex)
            if claimed(sent, result, "checkin:" .. day.dayIndex) then
                day.status = "claimed"
                Ui.notify("Check-in", string.format("Claimed day %d", day.dayIndex), 5)
            end
        end
        if day.status == "claimed" then
            claimedDays += 1
        end
    end
    lines[#lines + 1] = string.format("Check-in: %d/%d days claimed", claimedDays, #days)
end

local function claimMail(lines, allowed)
    local mailbox = Env.data("mailbox") or {}
    local waiting = 0
    for id, mail in pairs(type(mailbox.mails) == "table" and mailbox.mails or {}) do
        if type(mail) == "table" and (mail.claimedAt or 0) <= 0 then
            if allowed("ClaimMail") and mayTry("mail:" .. id) then
                local ok, result = Env.invoke("MailService/Claim", id)
                if claimed(ok, result, "mail:" .. id) then
                    Ui.notify("Mail", "Claimed a mail reward", 5)
                else
                    waiting += 1
                end
            else
                waiting += 1
            end
        end
    end
    lines[#lines + 1] = waiting > 0 and string.format("Mail: %d unclaimed", waiting) or "Mail: nothing to claim"
end

Life.loop("rewards:claim", CLAIM_INTERVAL, function()
    local lines = {}
    -- With Auto claim off the panel still shows progress; nothing is claimed.
    local function allowed(toggle)
        return Life.alive and Ui.on("AutoClaim") and Ui.on(toggle)
    end
    for _, step in ipairs({ claimQuests, claimOnline, claimCheckIn, claimMail, claimLevels, claimFreeChests }) do
        step(lines, allowed)
        if not Life.alive then
            return
        end
    end
    for _, entry in ipairs(rewardLog) do
        lines[#lines + 1] = entry
    end
    claimPanel.set(lines, Ui.on("AutoClaim") and "Claiming automatically." or "Auto claim is off.")
end)

-- Halloween -----------------------------------------------------------------------------------------
-- Candy comes from matches (see core/limits). The event shop (Config.eventShop, rows for the
-- running event) sells balls for candy or diamonds: HalloweenShop/Buy(eventId, row index, "candy").
-- Only candy is ever spent here. A candy-bought copy cannot be traded but can be fused.

local CANDY_INTERVAL = 3
local SHOP_REST = 30 -- after a refusal

local halloween = tab:AddGroupbox({ Side = "Left", Name = "Halloween", IconName = "candy" })
local candyLabel = halloween:AddLabel("Loading...", true)

-- The shop for whichever event is configured, read once: rows carry the event id they belong to.
local shopRows, shopLabels, shopByLabel = {}, {}, {}
for index, row in ipairs(type(Config.eventShop) == "table" and Config.eventShop.list or {}) do
    local ball = type(row) == "table" and Config.ball.byCnId[row.ballId]
    local price = type(row) == "table" and tonumber(row.candyPrice)
    if ball and price and price > 0 then
        local name = ball.displayName or row.ballId
        local label = string.format("%s (%d candy)", name, price)
        local entry = { index = index, eventId = row.eventId, ballId = row.ballId, price = price, label = label, name = name }
        shopRows[#shopRows + 1] = entry
        shopLabels[#shopLabels + 1] = label
        shopByLabel[label] = entry
    end
end
halloween:AddDropdown("CandyShopPicks", {
    Text = "Buy with candy",
    Values = #shopLabels > 0 and shopLabels or { "No event shop" },
    Multi = true,
    Default = {},
    Tooltip = "Balls to buy from the Halloween shop. Diamonds are never spent.",
})
halloween:AddSlider("CandyShopCopies", {
    Text = "Copies of each",
    Default = 1,
    Min = 1,
    Max = 6,
    Rounding = 0,
    Tooltip = "Buys until you own this many of each ticked ball, the ball you have fewest of first. Six copies make a Shiny.",
})
halloween:AddToggle("AutoCandyShop", {
    Text = "Auto buy",
    Default = false,
    Tooltip = "Spends candy on the ticked balls as soon as you can afford the next one.",
})
Ui.automation("AutoCandyShop", true)

local function ownedCopies(ballId)
    local count = 0
    for _, item in pairs(Env.data("items") or {}) do
        if type(item) == "table" and item.itemType == "Ball" and item.itemId == ballId
            and (item.ownerUserId == nil or item.ownerUserId == Env.LocalPlayer.UserId) then
            count += 1
        end
    end
    return count
end

-- A bought copy reaches the inventory a moment after the reply. Until it shows up (or 30s pass)
-- it is counted anyway, so a slow replication cannot buy one copy too many.
local credited = {}
local function heldCopies(ballId)
    local actual = ownedCopies(ballId)
    local credit = credited[ballId]
    if credit and (actual >= credit.count or os.clock() >= credit.untilAt) then
        credited[ballId], credit = nil, nil
    end
    return credit and math.max(actual, credit.count) or actual
end

local shopNote, shopRestUntil = "", 0
local function candyShop(candy)
    if not Ui.on("AutoCandyShop") or os.clock() < shopRestUntil then
        return
    end
    local picks, keep = Options.CandyShopPicks.Value or {}, tonumber(Options.CandyShopCopies.Value) or 1
    local chosen, chosenHeld
    for _, entry in ipairs(shopRows) do
        if picks[entry.label] and entry.eventId == candy.eventId then
            local held = heldCopies(entry.ballId)
            -- Strictly fewer, so ties go to the shop's order (cheapest first).
            if held < keep and (not chosen or held < chosenHeld) then
                chosen, chosenHeld = entry, held
            end
        end
    end
    if not chosen then
        local any = false
        for _ in pairs(picks) do any = true break end
        shopNote = any and string.format("Shop: you own %d of every ticked ball.", keep) or "Shop: tick the balls to buy."
        return
    end
    if candy.balance < chosen.price then
        shopNote = string.format("Shop: saving for %s, %d of %d candy.", chosen.name, candy.balance, chosen.price)
        return
    end
    if not mayTry("candyshop:" .. chosen.ballId) then
        return
    end
    local ok, result = Env.invoke("HalloweenShop/Buy", candy.eventId, chosen.index, "candy")
    if not Life.alive then
        return
    end
    local name = chosen.name
    if ok and type(result) == "table" and result.ok == true then
        attemptedAt["candyshop:" .. chosen.ballId] = nil
        credited[chosen.ballId] = { count = chosenHeld + 1, untilAt = os.clock() + 30 }
        shopRestUntil = os.clock() + CANDY_INTERVAL
        shopNote = "Shop: bought " .. name .. "."
        Ui.notify("Halloween shop", "Bought " .. name .. " for " .. chosen.price .. " candy", 5)
    else
        local reason = ok and type(result) == "table" and tostring(result.reason) or tostring(result or "no reply")
        shopRestUntil = os.clock() + SHOP_REST
        shopNote = "Shop: " .. name .. " refused (" .. reason .. ")."
    end
end

local function duration(seconds)
    local days, hours = seconds // 86400, seconds % 86400 // 3600
    return days > 0 and string.format("%dd %dh", days, hours) or string.format("%dh %dm", hours, seconds % 3600 // 60)
end

Life.loop("rewards:halloween", CANDY_INTERVAL, function()
    local candy = Limits.candy()
    if candy.active then
        candyShop(candy)
        candy = Limits.candy()
    end
    if not Life.alive then
        return
    end
    Env.elevate()
    if not candy.active then
        candyLabel:SetText("No Halloween event right now.")
        return
    end
    local lines = {
        string.format("Candy: %d  |  today %d / %s%s", candy.balance, candy.today, tostring(candy.dayMax or "?"),
            candy.capped and " (cap reached)" or ""),
    }
    if candy.endsIn then
        lines[#lines + 1] = "Event ends in " .. duration(math.floor(candy.endsIn))
    end
    for _, entry in ipairs(shopRows) do
        if entry.eventId == candy.eventId then
            lines[#lines + 1] = string.format("%s: own %d", entry.label, ownedCopies(entry.ballId))
        end
    end
    if Ui.on("AutoCandyShop") and shopNote ~= "" then
        lines[#lines + 1] = shopNote
    end
    candyLabel:SetText(table.concat(lines, "\n"))
end)

-- Fusion --------------------------------------------------------------------------------------------
local fusionBox = tab:AddGroupbox({ Side = "Right", Name = "Ball Fusion", IconName = "combine" })
fusionBox:AddToggle("AutoFuseDuplicates", {
    Text = "Auto fuse duplicates", Default = false,
    Tooltip = "Fuses duplicates toward the selected goal. Keeps one eligible copy per ball, form and trade status; equipped or locked copies are skipped.",
})
Ui.automation("AutoFuseDuplicates", true)
fusionBox:AddDropdown("FuseMode", {
    Text = "Fusion goal", Values = { "Higher rarity", "Shiny", "Rainbow" }, Default = "Higher rarity",
    Tooltip = "Higher rarity consumes ten Classic copies. Shiny consumes six Classic copies; Rainbow consumes six Shiny copies. One additional copy is kept.",
})
local rarityLabels, rarityByLabel, ratings = {}, {}, {}
for _, rating in ipairs(Config.rating.list) do
    if type(rating.lvl) == "number" then
        ratings[#ratings + 1] = rating
    end
end
table.sort(ratings, function(a, b) return a.lvl < b.lvl end)
for index = 1, #ratings do
    local rating = ratings[index]
    local label = rating.displayName or rating.name or (index == 1 and "Common" or "Uncommon")
    label = tostring(label) .. " (" .. rating.lvl .. ")"
    rarityLabels[#rarityLabels + 1], rarityByLabel[label] = label, rating.lvl
end
if #rarityLabels == 0 then
    rarityLabels, rarityByLabel = { "Common", "Uncommon" }, { Common = 1, Uncommon = 2 }
end
fusionBox:AddDropdown("FuseMaxRarity", {
    Text = "Maximum material rarity", Values = rarityLabels, Default = rarityLabels[math.min(2, #rarityLabels)],
})
local fusionLabel = fusionBox:AddLabel("Fusion is off.", true)
local reserved, fusedBatches = {}, 0
Life.loop("rewards:fusion", 1.5, function()
    if not Ui.on("AutoFuseDuplicates") then
        fusionLabel:SetText("Fusion is off.")
        return
    end
    local items = Env.data("items")
    if type(items) ~= "table" then
        fusionLabel:SetText("Waiting for inventory.")
        return
    end
    local mode = Options.FuseMode.Value
    local required = Fusion.requiredCount(mode)
    if not required then
        fusionLabel:SetText("Choose a fusion goal.")
        return
    end
    local function attemptKey(id)
        return "fusion:" .. mode .. ":" .. id
    end
    for id, untilAt in pairs(reserved) do
        if items[id] == nil or os.clock() >= untilAt then
            reserved[id] = nil
        end
    end
    local batch, ballId = Fusion.nextBatch(items, Env.data("equipment"),
        rarityByLabel[Options.FuseMaxRarity.Value] or -math.huge, reserved, function(id)
            return os.clock() - (attemptedAt[attemptKey(id)] or -math.huge) >= RETRY_AFTER
        end, mode)
    if not batch then
        fusionLabel:SetText(string.format("%d batches fused. %s needs %d matching copies plus one kept.", fusedBatches, mode, required))
        return
    end
    if not Ui.on("AutoFuseDuplicates") or not mayTry(attemptKey(ballId)) then
        return
    end
    -- Reserve before the yielding invoke so delayed PlayerData cannot resubmit consumed ids.
    for _, id in ipairs(batch) do
        reserved[id] = os.clock() + RETRY_AFTER
    end
    Env.elevate()
    fusionLabel:SetText("Fusing " .. Env.ballName(ballId) .. "...")
    local ok, result
    if mode == "Higher rarity" then
        ok, result = Env.invoke("FusionRequest", batch)
    else
        -- The form-upgrade remote takes one main id and five additional ids, not six materials.
        ok, result = Env.invoke("BallUpgradeRequest", batch[1], table.move(batch, 2, #batch, 1, {}))
    end
    if not Life.alive then
        return
    end
    if ok and type(result) == "table" and result.ok == true then
        for _, id in ipairs(batch) do
            reserved[id] = math.huge -- release only after replication removes the consumed item
        end
        attemptedAt[attemptKey(ballId)] = nil -- another disjoint batch may run in 1.5s
        fusedBatches += 1
        Env.elevate()
        local target = mode == "Higher rarity" and Env.ballName(result.cnId) or (mode .. " " .. Env.ballName(ballId))
        fusionLabel:SetText("Fused " .. Env.ballName(ballId) .. " into " .. target)
    else
        Env.elevate()
        if not ok then
            -- Transport failure does not prove the server rejected the materials.
            for _, id in ipairs(batch) do reserved[id] = math.huge end
        end
        fusionLabel:SetText("Fusion not confirmed: " .. tostring(type(result) == "table" and result.reason or result or "no response"))
    end
end)

-- Crates ---------------------------------------------------------------------------------------------

local crates = tab:AddGroupbox({ Side = "Right", Name = "Crates", IconName = "package" })
local crateByLabel, crateLabels = {}, {}
for _, crate in ipairs(Config.crate.list) do
    if crate.isForSale and type(crate.coinsPrice) == "number" and crate.coinsPrice > 0 then
        local label = string.format("%s x%d (%d coins)", crate.name, crate.drawCount or 1, crate.coinsPrice)
        crateByLabel[label] = crate
        crateLabels[#crateLabels + 1] = label
    end
end
crates:AddDropdown("CrateChoice", {
    Text = "Crate",
    Values = crateLabels,
    Default = crateLabels[1],
})
crates:AddSlider("CrateReserve", {
    Text = "Keep at least",
    Default = 0,
    Min = 0,
    Max = 20000,
    Rounding = 0,
    Suffix = " coins",
    Tooltip = "Auto buy never spends below this.",
})
crates:AddToggle("AutoBuyCrate", {
    Text = "Auto buy",
    Default = false,
    Tooltip = "Buys the crate with coins whenever you have its price plus the amount to keep.",
})
Ui.automation("AutoBuyCrate", true)
local crateLabel = crates:AddLabel("", true)

local function itemName(result)
    if type(result) ~= "table" then
        return "?"
    end
    local id = result.itemId or result.targetId or result.cnId
    local ball = id and Config.ball.byCnId[id]
    return ball and ball.displayName or tostring(id or result.itemType or "?")
end

local function buyCrate()
    local crate = crateByLabel[Options.CrateChoice.Value]
    if not crate then
        return false, "no crate chosen"
    end
    local ok, result = Env.invoke("GachaRoll", crate.cnId, "coins")
    if not ok or type(result) ~= "table" then
        return false, not ok and tostring(result) or "the game did not answer"
    end
    if not result.ok then
        return false, tostring(result.reason or "refused")
    end
    local names = {}
    for _, item in ipairs(type(result.results) == "table" and result.results or { result }) do
        names[#names + 1] = itemName(item)
    end
    return true, table.concat(names, ", ")
end

local function reportBuy(ok, text)
    if not Life.alive then return end
    Env.elevate()
    crateLabel:SetText(ok and "Last crate: " .. text or "Could not buy: " .. text)
end

crates:AddButton({
    Text = "Buy once",
    Func = function()
        Life.spawn("rewards:buy-once", function()
            reportBuy(buyCrate())
        end)
    end,
})

Life.loop("rewards:crates", BUY_INTERVAL, function()
    if not Ui.on("AutoBuyCrate") then
        return
    end
    local crate = crateByLabel[Options.CrateChoice.Value]
    local coins = Env.data("coins") or 0
    if crate and coins >= crate.coinsPrice + Options.CrateReserve.Value and mayTry("crate:" .. crate.cnId) then
        local ok, text = buyCrate()
        if not Life.alive then
            return
        end
        if ok then
            attemptedAt["crate:" .. crate.cnId] = nil
        end
        reportBuy(ok, text)
    end
end)

Life.onCleanup(function()
    table.clear(attemptedAt)
    table.clear(reserved)
    table.clear(rewardLog)
    table.clear(seenRewards)
    table.clear(seenChests)
end)

return {}
end
__modules["features/settings"] = function(use)
-- Settings tab (see shared/settings): Ball VS Ball configs, and what each missing function changes.

use("core/ui")
local Settings = use("shared/settings")

return Settings.build({
    folder = "BallVsBall",
    effects = {
        queue_on_teleport = "the hub does not come back after a teleport: run the loader again",
        writefile = "configs, themes and the offline cache cannot be saved",
        readfile = "saved configs and cached downloads cannot be read",
        isfile = "saved configs and cached downloads cannot be located",
        isfolder = "config folders cannot be managed",
        makefolder = "config folders cannot be created",
        listfiles = "saved configs and themes cannot be listed",
        delfile = "saved configs cannot be deleted",
        setclipboard = "copy buttons display their text instead",
    },
})
end
__modules["main"] = function(use)
-- Entry point. Core systems first, then features in tab order, then settings (autoload last).

-- The loader waits for this too, but the bundle can also be run on its own (a local build, an
-- auto-execute folder) before the game has finished loading.
if not game:IsLoaded() then
    local deadline = os.clock() + 90
    repeat task.wait(0.1) until game:IsLoaded() or os.clock() >= deadline
    assert(game:IsLoaded(), "NOX: the game has not finished loading; run the script again once it loads")
end

local Env = use("core/env")
local Life = use("shared/life")
local activeBoot = Env.genv.__NOXBallBoot
if type(activeBoot) == "table" and type(activeBoot.at) == "number" and os.clock() - activeBoot.at < 120 then
    return "NOX is already loading"
end
local bootToken = { at = os.clock() }
Env.genv.__NOXBallBoot = bootToken
local Ui
local function boot()

-- Everything reads the game's own ModuleScripts. An executor that cannot require them cannot run
-- the hub, so that is said once here instead of by every feature failing on its own.
local canRequire, requireError = pcall(function()
    return Env.loadModule("Config")
end)
Env.elevate()
if not canRequire then
    error("your executor could not load the game's modules (require): " .. tostring(requireError), 0)
end

-- A copy already running (the bundle executed twice, or a local build after the loader's) is
-- closed first: two hubs fight over the game, and only the loader used to close the old one.
local previous = Env.genv.__NOX
if type(previous) == "table" and type(previous.Ui) == "table" and previous.Ui.Library then
    if type(previous.Life) == "table" and type(previous.Life.shutdown) == "function" then
        pcall(previous.Life.shutdown)
    end
    pcall(previous.Ui.Library.Unload, previous.Ui.Library)
    Env.genv.__NOX = nil
    Env.elevate()
end

Ui = use("core/ui")
local handle = { Ui = Ui, Life = Life, Features = {} }
Env.genv.__NOX = handle
Life.onCleanup(function()
    Env.stopped = true
    if Env.genv.__NOX == handle then Env.genv.__NOX = nil end
end)

local FEATURES = {
    "features/home",
    "features/duel",
    "features/intel",
    "features/rewards",
}
-- One feature failing (a missing remote, a game update) is reported and the rest carry on.
local function load(name)
    if not Life.alive then return nil end
    local ok, result = xpcall(use, Env.traceback, name)
    Env.elevate()
    if not ok then
        Life.errors["load:" .. name] = tostring(result)
        Ui.notify("NOX", string.format("%s failed to load; the rest still works.", name), 8)
        warn("[NOX] " .. name .. ": " .. tostring(result))
    end
    return ok and result or nil
end

local loaded = {}
for _, name in ipairs(FEATURES) do
    loaded[name] = load(name)
end

local Settings = load("features/settings")
if Settings then
    Life.call("settings:autoload", Settings.finish)
end
-- After the autoload, so a saved "Redeem codes on load: off" is respected.
local Home = loaded["features/home"]
if Home then
    Life.call("home:after-load", Home.afterLoad)
end

-- Handle for debugging from Real (and for the next version to unload this one).
handle.Features = loaded
-- Match may be unavailable after a game update; that must not undo the working Settings tab.
local matchOk, match = pcall(use, "core/match")
handle.Match = matchOk and match or nil

if Life.alive and type(Env.RuntimeState) == "table" and type(Env.RuntimeState.onCleanup) == "function" then
    Env.RuntimeState.onCleanup(function()
        Env.elevate()
        pcall(function()
            Ui.Library:Unload()
        end)
    end)
end

return "NOX loaded"
end

local ok, result = xpcall(boot, Env.traceback)
if Env.genv.__NOXBallBoot == bootToken then Env.genv.__NOXBallBoot = nil end
if not ok then
    Life.shutdown()
    -- shared/ui stores the library before CreateWindow, allowing partial startup to be cleaned.
    local sharedUi = use("shared/ui")
    if sharedUi.Library then pcall(sharedUi.Library.Unload, sharedUi.Library) end
    error("[NOX] " .. Env.executor .. ": " .. tostring(result), 0)
end
return result
end
__modules["shared/env"] = function(use)
-- Services, the local player, and the executor, the same for every game. Each game's core/env
-- extends this table with what only that game has (its ModuleScripts, its places).
--
-- Two Real quirks shape everything here:
--  * Calling into one of the game's modules, or yielding, can leave the thread without the
--    capability the UI needs ("lacking capability Plugin") while getthreadidentity() still says
--    8. Env.elevate() puts it back; Env.call() wraps a game call and elevates afterwards.
--  * Game modules are required lazily (Env.modules), so a feature only pays for what it uses.

local Env = {}

Env.Players = game:GetService("Players")
Env.ReplicatedStorage = game:GetService("ReplicatedStorage")
Env.RunService = game:GetService("RunService")
Env.CollectionService = game:GetService("CollectionService")
Env.VirtualUser = game:GetService("VirtualUser")
Env.TeleportService = game:GetService("TeleportService")
Env.HttpService = game:GetService("HttpService")
Env.LocalPlayer = Env.Players.LocalPlayer
if not Env.LocalPlayer then
    local deadline = os.clock() + 30
    repeat
        task.wait(0.05)
        Env.LocalPlayer = Env.Players.LocalPlayer
    until Env.LocalPlayer or os.clock() >= deadline
    assert(Env.LocalPlayer, "NOX: local player is not ready; run the script again once the game loads")
end

local function first(...)
    for index = 1, select("#", ...) do
        local fn = select(index, ...)
        if type(fn) == "function" then return fn end
    end
end

local setIdentity = first(setthreadidentity, set_thread_identity, setidentity, setthreadcontext)

function Env.elevate()
    if setIdentity then
        pcall(setIdentity, 8)
    end
end

-- Calls fn (usually a game-module function) and restores the thread afterwards.
-- Returns ok, ... like pcall.
function Env.call(fn, ...)
    local results = table.pack(pcall(fn, ...))
    Env.elevate()
    return table.unpack(results, 1, results.n)
end

-- Executor functions -------------------------------------------------------------------------
-- Functions are optional unless the feature actually needs them. An executor's name or sUNC
-- score does not establish that any particular operation will succeed on this client.
-- The hub must not break where a function is
-- missing or goes by another name: everything executor-specific is looked up here once, and a
-- feature that cannot work without one says so instead of silently doing nothing.

local executorEnv = getfenv()
local function member(container, key)
    return type(container) == "table" and container[key] or nil
end
local syn, fluxus = executorEnv.syn, executorEnv.fluxus
local envOk, globalEnv = pcall(function() return getgenv() end)
Env.genv = envOk and type(globalEnv) == "table" and globalEnv or _G
Env.request = first(request, http_request, member(http, "request"), member(syn, "request"), member(fluxus, "request"))
Env.queueOnTeleport = first(queue_on_teleport, queueonteleport, member(syn, "queue_on_teleport"), member(fluxus, "queue_on_teleport"))
Env.setClipboard = first(setclipboard, toclipboard, set_clipboard, member(Clipboard, "set"))
Env.loadstring = first(loadstring)
Env.files = {}
for _, name in ipairs({ "readfile", "writefile", "isfile", "isfolder", "makefolder", "listfiles", "delfile" }) do
    Env.files[name] = first(executorEnv[name], Env.genv[name])
end
Env.canCache = Env.files.readfile ~= nil and Env.files.isfile ~= nil
Env.canSave = true
for _, name in ipairs({ "readfile", "writefile", "isfile", "isfolder", "makefolder", "listfiles", "delfile" }) do
    if not Env.files[name] then Env.canSave = false end
end
Env.traceback = debug and first(debug.traceback) or tostring
local executorOk, executorName = pcall(function()
    return identifyexecutor()
end)
Env.executor = executorOk and type(executorName) == "string" and executorName or "Unknown"

-- Missing functions that switch a feature off or change how it works, for the Settings tab.
-- A list, not a map: a map literal drops the missing (nil) ones before they can be counted.
-- Each game names the functions it cares about (Env.checkMissing), since what one needs another
-- never calls.
Env.missing = {}
local missingSet = {}
function Env.checkMissing(entries)
    for _, entry in ipairs(entries) do
        if type(entry[2]) ~= "function" and not missingSet[entry[1]] then
            missingSet[entry[1]] = true
            Env.missing[#Env.missing + 1] = entry[1]
        end
    end
end

-- Triggers a ProximityPrompt. Without fireproximityprompt it is pressed the way a player would,
-- with its hold lifted for the moment: that only takes while the prompt is on screen, i.e. in
-- range, which every caller already stands within (the server checks range either way).
function Env.firePrompt(prompt)
    if fireproximityprompt and pcall(fireproximityprompt, prompt) then
        Env.elevate()
        return true
    end
    local hold, sight = prompt.HoldDuration, prompt.RequiresLineOfSight
    local ok = pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
        task.wait(0.1)
        prompt:InputHoldBegin()
        task.wait()
        prompt:InputHoldEnd()
    end)
    pcall(function()
        prompt.HoldDuration, prompt.RequiresLineOfSight = hold, sight
    end)
    Env.elevate()
    return ok
end

-- Simulates a touch (start then end) of `part` by `by`. False where the executor cannot.
function Env.touch(by, part)
    if not firetouchinterest then
        return false
    end
    local began = pcall(firetouchinterest, by, part, 0)
    task.wait() -- some executors only register the touch on the next physics step
    pcall(firetouchinterest, by, part, 1)
    return began
end

-- True when this client simulates `part`'s physics (so moving it replicates). Nil when the
-- executor cannot tell.
function Env.ownsPart(part)
    if not isnetworkowner then
        return nil
    end
    local ok, owns = pcall(isnetworkowner, part)
    return ok and owns == true
end

-- parent:WaitForChild(name) that gives up after `seconds` (30 by default) with an error naming
-- what is missing, so one absent folder fails its own feature instead of freezing the hub.
function Env.need(parent, name, seconds)
    local child = parent:WaitForChild(name, seconds or 30)
    Env.elevate()
    if not child then
        error(string.format("%s.%s is missing", parent:GetFullName(), name), 2)
    end
    return child
end

-- A lazy table of the game's ModuleScripts: modules.Name is required on first use and cached.
-- `paths` maps each name to its path under `root` (a list of child names).
--
-- Also returns load(name), the same loader as a plain function. Indexing runs it inside __index,
-- and Luau cannot yield there ("attempt to yield across metamethod/C-call boundary"), which a
-- module does while it waits on the game: right after a teleport from the main menu the client
-- controllers wait for the character and inventory. Load those with load() (Env.preload) first.
function Env.modules(root, paths)
    local cache, pending = {}, {}
    local function load(name)
        local loaded = rawget(cache, name)
        if loaded ~= nil then
            return loaded
        end
        local path = paths[name]
        assert(path, "NOX: unknown game module " .. tostring(name))
        if Env.stopped then error("NOX: hub unloaded", 2) end
        local work = pending[name]
        if not work then
            work = {}
            pending[name] = work
            task.spawn(function()
                work.result = table.pack(Env.call(function()
                    local node = root
                    local deadline = os.clock() + 30
                    for _, part in ipairs(path) do
                        node = Env.need(node, part, math.max(0.1, deadline - os.clock()))
                    end
                    return require(node)
                end))
                work.done = true
            end)
        end
        local deadline = os.clock() + 30
        repeat
            if work.done then break end
            task.wait(0.05)
        until Env.stopped or os.clock() >= deadline
        Env.elevate()
        if Env.stopped then error("NOX: hub unloaded", 2) end
        if not work.done then
            error("NOX: game module " .. name .. " is still loading; try again after the game finishes loading", 2)
        end
        pending[name] = nil
        if not work.result[1] then error(work.result[2], 2) end
        local module = work.result[2]
        rawset(cache, name, module)
        return module
    end
    return setmetatable(cache, {
        __index = function(_, name)
            return load(name)
        end,
    }), load
end

-- The live-reload handle when Real's live-reload started us (nil from the GitHub loader).
Env.RuntimeState = getfenv().STATE

return Env
end
__modules["shared/home"] = function(use)
-- The part of the Home tab every game has: welcome, Discord invite, stop-all and anti-AFK.
-- Home.build returns the groupbox and a "Doing: ..." label the game's own Home keeps up to date.

local Env = use("shared/env")
local Life = use("shared/life")
local Ui = use("shared/ui")

local DISCORD_INVITE = "https://discord.gg/Qb8edHdfU6"

local Home = {}

-- notes: extra lines shown under the welcome (where you are, what works there).
function Home.build(notes)
    local hub = Ui.Tabs.Home:AddGroupbox({ Side = "Left", Name = "NOX", IconName = "sparkles" })
    hub:AddLabel(string.format("Welcome, %s.", Env.LocalPlayer.DisplayName), true)
    for _, note in ipairs(notes or {}) do
        hub:AddLabel(note, true)
    end
    local statusLabel = hub:AddLabel("Doing: Idle", true)
    hub:AddButton({
        Text = "Copy Discord invite",
        Func = function()
            if Env.setClipboard and pcall(Env.setClipboard, DISCORD_INVITE) then
                Ui.notify("NOX", "Discord invite copied to your clipboard.", 4)
            else
                Ui.notify("NOX", DISCORD_INVITE, 10)
            end
        end,
    })
    hub:AddButton({
        Text = "Stop all automation",
        Func = function()
            Ui.stopAll()
            Ui.notify("NOX", "Everything is switched off.", 3)
        end,
    })
    hub:AddToggle("AntiAfk", {
        Text = "Anti AFK",
        Default = true,
        Tooltip = "Stops Roblox from kicking you after 20 idle minutes.",
    })

    local function nudge()
        if Ui.on("AntiAfk") then
            pcall(function()
                Env.VirtualUser:CaptureController()
                Env.VirtualUser:ClickButton2(Vector2.zero)
            end)
        end
    end
    local _, idleCallback = Life.connect(Env.LocalPlayer.Idled, nudge, "home:idle")

    -- Belt and braces: the idle kick itself listens on Idled too. Where the executor has
    -- getconnections (Real, Volt), those listeners are switched off while Anti AFK is on and
    -- switched back on when it goes off or the hub unloads.
    local silenced = {}
    local function silenceIdle(off)
        if off and type(getconnections) == "function" then
            local ok, connections = pcall(getconnections, Env.LocalPlayer.Idled)
            for _, connection in ipairs(ok and type(connections) == "table" and connections or {}) do
                local inspected, eligible = pcall(function()
                    return type(connection.Function) == "function" and connection.Function ~= idleCallback
                        and connection.Enabled == true and type(connection.Disable) == "function"
                end)
                if inspected and eligible and pcall(connection.Disable, connection) then
                    silenced[#silenced + 1] = connection
                end
            end
        elseif not off then
            for _, connection in ipairs(silenced) do
                pcall(function() connection:Enable() end)
            end
            table.clear(silenced)
        end
    end
    Ui.Toggles.AntiAfk:OnChanged(function(on)
        silenceIdle(false)
        silenceIdle(on)
    end)
    silenceIdle(Ui.on("AntiAfk"))
    Life.onCleanup(function()
        silenceIdle(false)
    end)

    return hub, statusLabel
end

return Home
end
__modules["shared/http"] = function(use)
-- Downloads the hub's own dependencies (the UI library and its addons), with a file cache.
--
-- Real's game:HttpGet does not throw when a request fails: it returns the status as the body
-- ("429: Too Many Requests", "404: Not Found"), loadstring of that is nil, and calling it killed
-- the whole hub with "attempt to call a nil value". GitHub answers like that now and then, most
-- often on the reload right after a teleport. So every download is checked and retried, the last
-- good copy is kept, and that copy is used when GitHub will not answer.

local Env = use("shared/env")

local Http = {}

local CACHE = "NOX/cache"
local TRIES = 3

local files = Env.files
local canWrite = files.writefile and files.isfolder and files.makefolder
local pending = {}
local memory = {}

-- The body at url, or nil and the reason. Tries the executor's request first (it reports the
-- status code), then game:HttpGet.
local function download(url)
    local reason
    if Env.request then
        local ok, res = Env.call(Env.request, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and res.StatusCode ~= nil then
            if tonumber(res.StatusCode) == 200 and res.Success ~= false and type(res.Body) == "string" and res.Body ~= "" then
                return res.Body
            end
            reason = "HTTP " .. tostring(res.StatusCode)
        else
            reason = ok and "invalid HTTP response" or tostring(res)
        end
    end
    local ok, body = Env.call(function() return game:HttpGet(url) end)
    if not ok then
        return nil, reason or tostring(body)
    end
    if type(body) ~= "string" or body == "" then
        return nil, "empty response"
    end
    local status = body:match("^%d%d%d: [^\n]*")
    if status then
        return nil, status
    end
    return body
end

local function get(url)
    local work = pending[url]
    if not work then
        work = {}
        pending[url] = work
        task.spawn(function()
            local ok, body, err = pcall(download, url)
            work.body, work.error = ok and body or nil, ok and err or tostring(body)
            work.done = true
        end)
    end
    local deadline = os.clock() + 15
    while not work.done and os.clock() < deadline do task.wait(0.05) end
    Env.elevate()
    if not work.done then
        -- Leave this one in flight. Reloading an addon must not spawn duplicate hung requests.
        return nil, "download timed out", true
    end
    pending[url] = nil
    return work.body, work.error
end

local function save(path, body)
    local dir = ""
    for part in CACHE:gmatch("[^/]+") do
        dir = dir == "" and part or dir .. "/" .. part
        if not files.isfolder(dir) then
            files.makefolder(dir)
        end
    end
    files.writefile(path, body)
end

local function compile(body, name)
    if not Env.loadstring then return nil, "loadstring is unavailable" end
    if type(body) ~= "string" or body == "" then return nil, "empty source" end
    local ok, chunk, reason = Env.call(Env.loadstring, body, "@" .. name)
    if not ok then return nil, tostring(chunk) end
    if type(chunk) ~= "function" then return nil, reason or "compilation failed" end
    return chunk
end

-- Downloads url and compiles it (chunk name `name`). Falls back to the cached copy saved under
-- `name` by an earlier load. Returns the compiled chunk; errors with the reason when neither works.
function Http.load(url, name)
    if not Env.loadstring then error("NOX: loadstring is unavailable; optional downloads cannot be loaded", 0) end
    local path = CACHE .. "/" .. name
    local reason
    if memory[url] then
        local chunk = compile(memory[url], name)
        if chunk then return chunk end
    end
    for attempt = 1, TRIES do
        local body, err, timedOut = get(url)
        Env.elevate()
        if body then
            local chunk, compileError = compile(body, name)
            if chunk then
                memory[url] = body
                if canWrite then
                    pcall(save, path, body)
                end
                return chunk
            end
            err = compileError -- a cut-off download
        end
        reason = err
        if timedOut then break end
        if attempt < TRIES then
            task.wait(attempt)
        end
    end
    local ok, cached = pcall(function()
        return Env.canCache and files.isfile(path) and files.readfile(path)
    end)
    local chunk = ok and compile(cached, name)
    if chunk then
        warn(string.format("[NOX] %s: %s, using the cached copy", name, tostring(reason)))
        return chunk
    end
    error(string.format("could not download %s (%s)", name, tostring(reason)), 0)
end

return Http
end
__modules["shared/life"] = function(use)
-- Lifecycle: one "alive" flag for the whole hub, a teardown list, and guarded loops.
--
-- Every background loop goes through Life.loop so it elevates the thread on each pass, stops on
-- unload, and records its last error in Life.errors[name] instead of dying silently inside a
-- task.spawn (which is how panels used to break without anyone noticing).

local Env = use("shared/env")

local Life = {
    alive = true,
    errors = {},
}

local cleanups = {}
local workers = {}
local connectionId = 0

function Life.onCleanup(fn)
    if not Life.alive then
        pcall(fn)
        return
    end
    cleanups[#cleanups + 1] = fn
end

function Life.call(name, fn, ...)
    if not Life.alive then return false, "hub unloaded" end
    Env.elevate()
    local result = table.pack(xpcall(fn, Env.traceback, ...))
    Env.elevate()
    Life.errors[name] = not result[1] and tostring(result[2]) or nil
    return table.unpack(result, 1, result.n)
end

function Life.spawn(name, fn, ...)
    local args = table.pack(...)
    -- defer lets us track the thread before its first instruction (including a shutdown).
    local thread
    thread = task.defer(function()
        Life.call(name, fn, table.unpack(args, 1, args.n))
        workers[thread] = nil
    end)
    workers[thread] = true
    return thread
end

function Life.connect(signal, fn, name)
    connectionId += 1
    name = name or ("event:" .. connectionId)
    local function guarded(...)
        Life.call(name, fn, ...)
    end
    local connection = signal:Connect(guarded)
    Life.onCleanup(function()
        connection:Disconnect()
    end)
    return connection, guarded
end

-- Runs fn every `interval` seconds (a number, or a function returning one) until unload.
function Life.loop(name, interval, fn)
    Life.spawn("loop:" .. name, function()
        local failures = 0
        while Life.alive do
            local ok = Life.call(name, fn)
            failures = ok and 0 or math.min(failures + 1, 5)
            if not Life.alive then
                break
            end
            local intervalOk, delay = pcall(function()
                return type(interval) == "function" and interval() or interval
            end)
            delay = intervalOk and tonumber(delay) or 1
            if not delay or delay ~= delay or delay == math.huge then delay = 1 end
            -- A broken API should not be hammered several times per frame.
            task.wait(math.max(0.05, delay, failures > 0 and 2 ^ (failures - 1) or 0))
        end
    end)
end

-- Waits up to `seconds`, returning early (false) once the hub is unloading.
function Life.wait(seconds)
    local deadline = os.clock() + seconds
    repeat
        -- In slices of at most 0.1s so an unload is noticed, but never past the deadline: a full
        -- 0.1s slice after a 0.11s wait's first one made it 0.2s.
        task.wait(math.min(0.1, math.max(0, deadline - os.clock())))
    until not Life.alive or os.clock() >= deadline
    Env.elevate()
    return Life.alive
end

function Life.shutdown()
    if not Life.alive then
        return
    end
    Life.alive = false
    for thread in pairs(workers) do
        if thread ~= coroutine.running() then pcall(task.cancel, thread) end
    end
    table.clear(workers)
    for index = #cleanups, 1, -1 do
        pcall(cleanups[index])
    end
    table.clear(cleanups)
end

return Life
end
__modules["shared/performance"] = function(use)
-- Performance mode, for long AFK farming: cuts what the client draws. Every property it changes is
-- written down first and put back when it goes off or the hub unloads, so nothing sticks.
--   Performance mode   shadows, post effects (bloom, blur, sun rays, colour correction, depth of
--                      field), particles, beams, trails and fire, water waves and reflections, the
--                      render quality, and the frame rate (the FPS limit)
--   3D rendering off   Roblox stops drawing the world at all; the hub's window still shows
-- Effects the game adds while it is on (weather, lightning, hatches) are switched off as they come.

local Env = use("shared/env")
local Life = use("shared/life")
local Ui = use("shared/ui")

local Performance = {}

local EFFECTS = { "ParticleEmitter", "Trail", "Beam", "Fire", "Smoke", "Sparkles", "PostEffect", "Clouds" }
local DEFAULT_FPS = 60 -- what the frame rate goes back to where the executor cannot say what it was

local saved = setmetatable({}, { __mode = "k" }) -- instance -> { property -> original value }
local savedFps
local active = false

local function set(instance, property, value)
    local ok, current = pcall(function()
        return instance[property]
    end)
    if not ok or current == value then
        return
    end
    local entry = saved[instance]
    if not entry then
        entry = {}
        saved[instance] = entry
    end
    if entry[property] == nil then
        entry[property] = current
    end
    pcall(function()
        instance[property] = value
    end)
end

local function isEffect(instance)
    for _, class in ipairs(EFFECTS) do
        if instance:IsA(class) then
            return true
        end
    end
    return false
end

local function quiet(instance)
    if isEffect(instance) then
        set(instance, "Enabled", false)
    end
end

local function applyFps()
    if active and setfpscap then
        pcall(setfpscap, Ui.Options.PerfFps.Value)
    end
end

local function enable()
    if active then
        return
    end
    active = true
    if setfpscap then
        local ok, cap = pcall(function()
            return getfpscap and getfpscap()
        end)
        savedFps = ok and tonumber(cap) or DEFAULT_FPS
        applyFps()
    end
    local lighting = game:GetService("Lighting")
    set(lighting, "GlobalShadows", false)
    local terrain = workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        set(terrain, "WaterWaveSize", 0)
        set(terrain, "WaterWaveSpeed", 0)
        set(terrain, "WaterReflectance", 0)
        set(terrain, "Decoration", false)
    end
    pcall(function()
        set(settings().Rendering, "QualityLevel", Enum.QualityLevel.Level01)
    end)
    for _, root in ipairs({ lighting, workspace }) do
        for index, instance in ipairs(root:GetDescendants()) do
            if not active then
                return
            end
            quiet(instance)
            if index % 4000 == 0 then
                task.wait() -- a big map in one go is a visible hitch
            end
        end
    end
end

local function disable()
    active = false
    for instance, properties in pairs(saved) do
        for property, value in pairs(properties) do
            pcall(function()
                instance[property] = value
            end)
        end
    end
    table.clear(saved)
    if savedFps and setfpscap then
        pcall(setfpscap, savedFps)
        savedFps = nil
    end
end

local function setRendering(on)
    pcall(Env.RunService.Set3dRenderingEnabled, Env.RunService, on)
end

-- The "Performance" box on `tab`.
function Performance.build(tab)
    local group = tab:AddGroupbox({ Side = "Left", Name = "Performance", IconName = "gauge" })
    group:AddToggle("PerfMode", {
        Text = "Performance mode",
        Default = false,
        Tooltip = "Turns off shadows, post effects, particles and water animation, lowers the render quality and limits the frame rate. All of it comes back when you switch it off.",
    })
    group:AddSlider("PerfFps", {
        Text = "FPS limit",
        Default = 30,
        Min = 5,
        Max = 240,
        Rounding = 0,
        Tooltip = setfpscap and "The frame rate while performance mode is on. Below about 15 the automation reacts more slowly."
            or "Your executor has no setfpscap, so the frame rate cannot be limited.",
    })
    group:AddToggle("PerfNoRender", {
        Text = "Turn off 3D rendering",
        Default = false,
        Tooltip = "The world is no longer drawn (a blank screen with the hub on it): the biggest saving while AFK. Everything keeps running.",
    })

    Ui.Toggles.PerfMode:OnChanged(function(on)
        if on then
            task.spawn(enable)
        else
            disable()
        end
    end)
    Ui.Options.PerfFps:OnChanged(applyFps)
    Ui.Toggles.PerfNoRender:OnChanged(function(on)
        setRendering(not on)
    end)

    for _, root in ipairs({ game:GetService("Lighting"), workspace }) do
        Life.connect(root.DescendantAdded, function(instance)
            if active then
                quiet(instance)
            end
        end)
    end
    Life.onCleanup(function()
        disable()
        setRendering(true)
    end)
    return group
end

return Performance
end
__modules["shared/settings"] = function(use)
-- Settings tab: menu options, the NOX ThemeManager and SaveManager addons (Obsidian forks, MIT; see LICENSE).
-- Each game's features/settings calls Settings.build with its config folder and what a missing
-- executor function changes there. Settings.finish() loads the autoload config; main calls it
-- after every feature is built so a saved config can switch toggles on only once their handlers
-- exist.

local Env = use("shared/env")
local Http = use("shared/http")
local Ui = use("shared/ui")
local Life = use("shared/life")

local ADDONS = "https://raw.githubusercontent.com/nox-atomic/atomic/refs/heads/main/ui/"

local Settings = {}

local function fetch(file)
    local ok, result = pcall(function()
        return Http.load(ADDONS .. file, file)()
    end)
    Env.elevate()
    return ok and result or nil, result
end

-- options.folder: where this game's configs are saved (under NOX/).
-- options.effects: { [executor function] = "what goes missing without it" }.
function Settings.build(options)
    local Library, Options = Ui.Library, Ui.Options
    local tab = Ui.Tabs.Settings

    local menu = tab:AddGroupbox({ Side = "Left", Name = "Menu", IconName = "sliders-horizontal" })
    menu:AddDropdown("NotificationSide", {
        Text = "Notification side",
        Values = { "Left", "Right" },
        Default = "Right",
        Callback = function(value)
            Library:SetNotifySide(value)
        end,
    })
    menu:AddDropdown("DPIScale", {
        Text = "DPI scale",
        Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
        Default = "100%",
        Callback = function(value)
            Library:SetDPIScale(tonumber((value:gsub("%%", ""))))
        end,
    })
    menu:AddDivider()
    menu:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
        Default = "RightShift",
        NoUI = true,
        Text = "Menu keybind",
    })
    menu:AddButton("Unload", function()
        Library:Unload()
    end)
    Library.ToggleKeybind = Options.MenuKeybind

    -- What this executor lacks and what that changes, so a bug report says it up front.
    local compat = tab:AddGroupbox({ Side = "Left", Name = "Compatibility", IconName = "cpu" })
    local lines = { "Executor: " .. Env.executor }
    for _, name in ipairs(Env.missing) do
        lines[#lines + 1] = string.format("No %s: %s.", name, options.effects[name] or "some features are limited")
    end
    if #Env.missing == 0 then
        lines[#lines + 1] = "Required function names are available. Runtime support depends on the executor."
    end
    compat:AddLabel(table.concat(lines, "\n"), true)
    local runtimeLabel = compat:AddLabel("Runtime: ready.", true)
    Life.loop("settings:runtime", 2, function()
        local messages = {}
        for name, reason in pairs(Env.requestIssues or {}) do
            messages[#messages + 1] = name .. ": " .. reason
        end
        for name, reason in pairs(Life.errors) do
            if name ~= "settings:runtime" then
                messages[#messages + 1] = name .. ": " .. (tostring(reason):match("^[^\n]+") or "unavailable")
            end
        end
        table.sort(messages)
        local extra = math.max(0, #messages - 4)
        while #messages > 4 do table.remove(messages) end
        if extra > 0 then messages[#messages + 1] = string.format("%d more runtime messages.", extra) end
        runtimeLabel:SetText(#messages > 0 and table.concat(messages, "\n") or "Runtime: ready.")
    end)

    if not Env.canSave or not Env.loadstring then
        local storage = tab:AddGroupbox({ Side = "Right", Name = "Saved settings", IconName = "save" })
        storage:AddLabel("Saved configs and custom themes are unavailable on this executor. You can still change the controls for this session.", true)
        function Settings.finish() end
        return Settings
    end

    -- Each addon is set up under pcall: one that breaks (no file functions, an upstream change)
    -- costs its own section, not the whole Settings tab.
    local SaveManager, saveError = fetch("SaveManager.lua")
    if SaveManager then
        local ok, err = pcall(function()
            SaveManager:SetLibrary(Library)
            SaveManager:IgnoreThemeSettings()
            SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
            SaveManager:SetFolder("NOX/" .. options.folder)
            SaveManager:BuildConfigSection(tab)
        end)
        Env.elevate()
        if not ok then
            SaveManager, saveError = nil, err
        end
    end
    if not SaveManager then
        Ui.notify("NOX", "Could not load the config manager: " .. tostring(saveError), 6)
    end

    local ThemeManager, themeError = fetch("ThemeManager.lua")
    if ThemeManager then
        local ok, err = pcall(function()
            ThemeManager:SetLibrary(Library)
            ThemeManager:SetFolder("NOX")
            ThemeManager:ApplyToTab(tab)
            local _, hasSavedDefault = ThemeManager:GetDefaultTheme()
            if hasSavedDefault then
                ThemeManager:LoadDefault()
            else
                Options.ThemeManager_ThemeList:SetValue("Default")
            end
        end)
        Env.elevate()
        if not ok then
            ThemeManager, themeError = nil, err
        end
    end
    if not ThemeManager then
        Ui.notify("NOX", "Could not load the theme manager: " .. tostring(themeError), 6)
    end
    Env.elevate()

    function Settings.finish()
        if SaveManager then
            local ok, err = pcall(SaveManager.LoadAutoloadConfig, SaveManager)
            Env.elevate()
            if not ok then
                Ui.notify("NOX", "Autoload failed: " .. tostring(err), 6)
            end
        end
    end

    return Settings
end

return Settings
end
__modules["shared/ui"] = function(use)
-- The window, its tabs, notifications, and small helpers features build their panels from.
-- Each game's core/ui calls Ui.create once with its footer and tabs, then returns this table.
--
-- The library is NOX UI (dark silver Obsidian fork), loaded from nox-atomic/atomic. Its public methods re-elevate the thread themselves,
-- so UI writes after a game-module call are safe without extra care in feature code.

local Env = use("shared/env")
local Life = use("shared/life")
local Http = use("shared/http")

local LIBRARY_URL = "https://raw.githubusercontent.com/nox-atomic/atomic/refs/heads/main/ui/Library.lua"

local Ui = {}

-- options.footer: the game's name under the title.
-- options.tabs: { { name, icon, description }, ... } in sidebar order.
-- options.only: a set of tab names to create (the rest are skipped), or nil for all of them.
-- options.icons: a bundled icon registry, installed before any window controls are created.
function Ui.create(options)
    local Library = options.library and options.library() or Http.load(LIBRARY_URL, "Library.lua")()
    Env.elevate()
    assert(type(Library) == "table" and type(Library.CreateWindow) == "function", "NOX: UI library did not load")
    if options.icons then
        Library:SetIconModule(options.icons)
    end
    Ui.Library = Library
    Ui.Options = Library.Options
    Ui.Toggles = Library.Toggles

    -- Register before constructing the window, so failed startup can also tear it down.
    Library:OnUnload(function()
        Env.elevate()
        Life.shutdown()
    end)

    Ui.Window = Library:CreateWindow({
        Footer = options.footer, -- the game name under the title; the title and icon come from the library
        AutoShow = true,
        Center = true,
        Resizable = true,
        ShowCustomCursor = false,
        NotifySide = "Right",
    })

    -- Created up front so the sidebar order is fixed here, whatever order features load in.
    Ui.Tabs = {}
    for _, entry in ipairs(options.tabs) do
        if not options.only or options.only[entry[1]] then
            Ui.Tabs[entry[1]] = Ui.Window:AddTab(entry[1], entry[2], entry[3])
        end
    end

    return Ui
end

function Ui.notify(title, text, seconds)
    if not Life.alive or not Ui.Library then return end
    Env.elevate()
    Ui.Library:Notify({ Title = title, Description = text, Time = seconds or 5 })
end

-- A fixed stack of labels plus a footer, for lists that change size (tasks, timers, chests).
function Ui.panel(groupbox, rows)
    local labels = {}
    for index = 1, rows do
        labels[index] = groupbox:AddLabel("", true)
        labels[index]:SetVisible(false)
    end
    groupbox:AddDivider()
    local footer = groupbox:AddLabel("", true)
    local panel = {}
    function panel.set(lines, footerText)
        if not Life.alive then return end
        Env.elevate()
        for index = 1, rows do
            local line = lines[index]
            labels[index]:SetVisible(line ~= nil)
            if line ~= nil then
                labels[index]:SetText(line)
            end
        end
        footer:SetText(footerText or "")
    end
    return panel
end

-- Toggle value that is safe to read during unload (the library clears Toggles).
function Ui.on(name)
    local toggle = Ui.Library.Toggles[name]
    return toggle ~= nil and toggle.Value == true
end

function Ui.set(name, value)
    local toggle = Ui.Library.Toggles[name]
    if toggle and toggle.Value ~= value then
        toggle:SetValue(value)
    end
end

-- Toggles that start automation. `stays` marks ones that never pull the character somewhere
-- else (clan spins, auto heal), which travelling can leave running.
local automation = {}

function Ui.automation(name, stays)
    automation[#automation + 1] = { name = name, stays = stays == true }
end

-- Switches automation off: everything, or with moversOnly just what would move the character.
function Ui.stopAll(moversOnly)
    for _, entry in ipairs(automation) do
        if not (moversOnly and entry.stays) then
            Ui.set(entry.name, false)
        end
    end
end

return Ui
end
__modules["shared/webhook"] = function(use)
-- Discord webhook alerts: the URL, a user to ping, a test button, a disconnect alert, and a queue
-- that posts one message at a time through the executor's request (Roblox's own HttpService
-- cannot reach Discord). Each game's features/webhooks calls Webhook.build and adds its alerts.
--
-- Discord allows 5 posts per webhook every 2 seconds and answers 429 with retry_after past that.
-- The queue keeps a second between posts and waits out a 429. It holds at most 20 messages: in an
-- alert storm the oldest are dropped rather than everything arriving minutes late.

local Env = use("shared/env")
local Life = use("shared/life")
local Ui = use("shared/ui")

local Webhook = {}

local SPACING = 1.1 -- seconds between two posts
local MAX_QUEUE = 20

local queue = {}
local gameName = "Roblox"
local statusLabel

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function url()
    local option = Ui.Options.WebhookUrl
    return trim(option and option.Value)
end

-- The Discord user to ping, digits only, or nil.
local function pingId()
    local option = Ui.Options.WebhookUserId
    local id = trim(option and option.Value):gsub("%D", "")
    return id ~= "" and id or nil
end

function Webhook.ready()
    return Env.request ~= nil and url():match("^https?://.+") ~= nil
end

local function setStatus(text)
    if statusLabel then
        statusLabel:SetText(text)
    end
end

-- Posts one body. Returns true, or false, why, and how long Discord asked to wait.
local function post(body)
    local ok, res = pcall(Env.request, {
        Url = url(),
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = Env.HttpService:JSONEncode(body),
    })
    Env.elevate()
    if not ok or type(res) ~= "table" then
        return false, tostring(res)
    end
    local status = tonumber(res.StatusCode) or 0
    if status >= 200 and status < 300 then
        return true
    end
    if status == 429 then
        local decoded, data = pcall(Env.HttpService.JSONDecode, Env.HttpService, res.Body or "")
        return false, "rate limited", decoded and type(data) == "table" and tonumber(data.retry_after) or 2
    end
    return false, "HTTP " .. status
end

task.spawn(function()
    while Life.alive do
        local body = queue[1]
        if body and Webhook.ready() then
            table.remove(queue, 1)
            local ok, why, retry = post(body)
            if retry then
                table.insert(queue, 1, body)
                Life.wait(retry)
            elseif ok then
                setStatus("Last message sent at " .. os.date("%H:%M:%S"))
            else
                setStatus("Last message failed: " .. tostring(why))
            end
            Life.wait(SPACING)
        else
            Life.wait(0.25)
        end
    end
end)

-- Queues an alert. message: { title, description, color, fields = { { name, value, inline } },
-- ping = ping the user set, urgent = ahead of everything already waiting }. Does nothing while
-- no webhook is set.
function Webhook.send(message)
    if not Webhook.ready() then
        return false
    end
    local id = message.ping and pingId() or nil
    local fields = {}
    for _, field in ipairs(message.fields or {}) do
        fields[#fields + 1] = { name = tostring(field[1]), value = tostring(field[2]):sub(1, 1024), inline = field[3] ~= false }
    end
    local body = {
        username = "NOX",
        content = id and ("<@" .. id .. ">") or nil,
        allowed_mentions = { parse = {}, users = id and { id } or {} },
        embeds = {
            {
                title = tostring(message.title):sub(1, 256),
                description = message.description and tostring(message.description):sub(1, 4096) or nil,
                color = message.color or 0xEB4060,
                fields = #fields > 0 and fields or nil,
                footer = { text = string.format("%s · %s", Env.LocalPlayer.Name, gameName) },
                timestamp = DateTime.now():ToIsoDate(),
            },
        },
    }
    if message.urgent then
        table.insert(queue, 1, body)
    else
        queue[#queue + 1] = body
    end
    while #queue > MAX_QUEUE do
        table.remove(queue, message.urgent and #queue or 1)
    end
    return true
end

-- The "Discord webhook" box on `tab`. options.game: the game's name for the message footer.
function Webhook.build(tab, options)
    gameName = options.game or gameName
    local group = tab:AddGroupbox({ Side = "Left", Name = "Discord webhook", IconName = "webhook" })
    group:AddInput("WebhookUrl", {
        Text = "Webhook URL",
        Default = "",
        Placeholder = "https://discord.com/api/webhooks/...",
        Finished = true,
        ClearTextOnFocus = false,
        Tooltip = "In Discord: Server settings > Integrations > Webhooks > New webhook > Copy webhook URL.",
    })
    group:AddInput("WebhookUserId", {
        Text = "Your Discord user ID (to be pinged)",
        Default = "",
        Placeholder = "optional, e.g. 123456789012345678",
        Finished = true,
        ClearTextOnFocus = false,
        Tooltip = "Rare finds and disconnects ping you. Discord: Settings > Advanced > Developer mode, then right-click your name > Copy User ID.",
    })
    group:AddToggle("WebhookDisconnect", {
        Text = "Alert when disconnected or kicked",
        Default = true,
    })
    group:AddButton({ Text = "Send a test message", Func = function()
        if not Env.request then
            Ui.notify("Webhook", "Your executor has no request function, so nothing can be sent.", 6)
        elseif not Webhook.ready() then
            Ui.notify("Webhook", "Paste your webhook URL first.", 4)
        else
            Webhook.send({
                title = "NOX is connected",
                description = "Alerts for " .. gameName .. " will arrive here.",
                fields = { { "Executor", Env.executor } },
                ping = true,
                urgent = true,
            })
            Ui.notify("Webhook", "Test message queued.", 3)
        end
    end })
    statusLabel = group:AddLabel(Env.request and "Nothing sent yet" or "Your executor has no request function: webhooks cannot be sent.", true)

    -- The error screen of a kick or a lost connection: scripts still run behind it for a moment.
    local GuiService = game:GetService("GuiService")
    Life.connect(GuiService.ErrorMessageChanged, function()
        local ok, text = pcall(GuiService.GetErrorMessage, GuiService)
        text = ok and trim(text) or ""
        if text ~= "" and Ui.on("WebhookDisconnect") then
            Webhook.send({
                title = "Disconnected",
                description = text,
                color = 0x808080,
                ping = true,
                urgent = true,
            })
        end
    end)
    return Webhook
end

return Webhook
end
__modules["vendor/icons"] = function(use) -- ../repo/ui/vendor/Lucide.lua
-- Lucide icon registry, bundled for NOX.
-- Source: https://github.com/mstudio45/lucide-roblox-direct/blob/main/source.lua
-- Retrieved 2026-10-04; upstream registry version 2026-10-01.
-- Uses upstream Roblox sprite asset IDs; no executor filesystem or HTTP calls.
--[[
MIT License

Copyright (c) 2025 deividcomsono

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local Lucide = {}

local icons = {{"align-vertical-distribute-center","chevron-down","list-restart","table-cells-split","gavel","dna-off","refresh-ccw-dot","venus","bean","circle-question-mark","folder-code","bolt","heater","feather","align-horizontal-distribute-center","grip-vertical","pill-bottle","person-standing","badge-swiss-franc","between-horizontal-end","file-braces-corner","rotate-cw","house-plus","bus-front","shield-ellipsis","between-vertical-end","globe-lock","tags","concierge-bell","bookmark-minus","plant-pot","file-down","picture-in-picture","messages-square","scissors","file-check-corner","phone-call","anchor","hand-helping","text-wrap","birdhouse","wifi-off","cloud-alert","message-square","cloud-download","folder-plus","cctv-off","notebook-dot","mirror-round","user-round","pointer","between-horizontal-start","chevrons-up-down","brush","message-circle-more","parentheses","book-up-2","flame","chevrons-up","square-dashed","square-mouse-pointer","superscript","signal","wifi-cog","hexagon","navigation-2-off","eye-off","arrows-up-from-line","file-code-corner","square-centerline-dashed-horizontal","panels-right-bottom","scaling","hash","arrow-left-from-line","ship","ticket-percent","calendar-clock","x","non-binary","voicemail","presentation","tree-palm","badge","captions-off","align-vertical-justify-center","download","mouse-right","lens-convex","shrimp-off","focus","diamond-percent","arrow-big-up","volume-x","mouse-pointer-click","face-slightly-smiling-plus","hard-drive","grid-2x2-x","package-minus","cloud","pipette","corner-left-down","badge-cent","cloud-lightning","user-round-pen","arrow-left-to-line","book-open-text","monitor-cloud","parking-meter","cat","heart-handshake","dam","trees","ham","circle-pause","chess-king","bean-off","clef-alto","separator-horizontal","ambulance","globe-code","citrus","phone-missed","calendar-off","chart-column","battery-medium","square-minus","star-check","decimals-arrow-left","folder-output","menu","bangladeshi-taka","image-down","terminal","building-complex-plus","circle-dot-dashed","medal","cake-slice","git-graph","armchair","tickets","qr-code","copy","goal","book-bookmark","trending-down","creative-commons","layers-arrow-down","ev-charger","user-star","road","nfc","align-center-horizontal","car","notebook-tabs","ear","videotape","sun-moon","chart-scatter","podium","toolbox","calendar","calendar-cog","gallery-horizontal","clipboard-x","list-sort-ascending","book-open","circle-pile","rectangle-ellipsis","badge-plus","badge-info","file-headphone","bow-arrow","clipboard-pen-line","user-round-key","folder-search","utensils-crossed","arrow-up","arrow-up-from-dot","align-vertical-justify-start","layers-minus","pause","shrub","flag","biceps-flexed","align-horizontal-distribute-end","donut","calendar-plus-2","move-vertical","file-pen-line","badge-russian-ruble","radius","pilcrow","corner-left-up","georgian-lari","cable","book-user","square-arrow-down","circle-plus","view","cctv","circle-arrow-left","square-off","octagon-alert","panel-bottom-dashed","book-a","align-end-vertical","thumbs-up","globe","rabbit","layers-plus","door-stairwell","banknote-arrow-down","message-square-off","dice-4","message-circle-x","folder-x","message-circle-warning","map","move","arrow-up-left","award","arrow-down-wide-narrow","unfold-horizontal","lens-concave","zoom-out","motorbike","music-4","zoom-in","shield-x","file-volume","disc-3","file-signal","columns-4","archive-x","zodiac-virgo","square-dashed-kanban","mouse-pointer-2","clock-arrow-up","clock-fading","pencil-sparkles","library-big","vegan","star-plus","file-check","clef-bass","message-circle-plus","user-key","credit-card-plus","zodiac-pisces","fast-forward","user-pen","chess-knight","wifi-pen","files","send-to-back","alarm-clock","microscope","zodiac-libra","zodiac-leo","zodiac-gemini","shopping-basket","send","smartphone","square-dashed-bottom","zodiac-aries","zodiac-aquarius","land-plot","wind-arrow-down","germ-off","brush-cleaning","skip-back","x-line-top","book-audio","octagon-minus","file-scan","cupcake","midi-port","message-square-dashed","shield-check","worm","chevrons-left","workflow","umbrella","skip-forward","clipboard-copy","map-pin-off","arrow-up-from-line","circle-chevron-up","wine-off","wine","circle-small","align-vertical-space-between","lamp-desk","circle-arrow-up","zap","beaker","timeline","panel-left-right-dashed","wifi-sync","paintbrush","sliders-vertical","broccoli","wifi-high","wifi","chevron-up","triangles-centerline-dashed-horizontal","whistle","pen-tool","database-check","wheat-off","form","pencil-ruler","dna","arrow-big-down-dash","chart-area","bug-off","wheat","weight-tilde","card-sim","weight","server-crash","map-pin-search","flask-round","eye-dashed","webcam-off","ellipse","spell-check","webcam","waypoints","popcorn","blocks","waves-vertical","layer-arrow-up","microchip","waves-ladder","badge-minus","cloud-sun","circle","shield-alert","waves-horizontal","phone-incoming","map-minus","waves-arrow-down","watch","separator-vertical","washing-machine","heart-minus","scan-square","ampersands","wand-sparkles","user-search","magnet","fence","wallpaper","square-user-round","wallet-minimal","wallet-cards","sunrise","strikethrough","calendar-days","folder-bookmark","wallet","banknote-arrow-up","layout-arrow-right","vote","dollar-sign","message-square-quote","volume-off","ruler-dimension-line","volume-1","list-minus","cloud-hail","volume","eye-closed","app-window-mac","volleyball","ellipsis","copy-check","clock-arrow-right","satellite","bookmark-plus","virus","folder-key","coffee","circle-power","ligature","hourglass","tickets-plane","folder-git","video","bomb","layers-2","battery-full","sparkle","line-dot-bottom-vertical","chart-gantt","folder-tree","command","badge-dollar-sign","align-start-vertical","briefcase-conveyor-belt","message-circle-question-mark","vibrate","bluetooth-off","venus-and-mars","square-square","cannabis","equal-approximately-not","book","grip-horizontal","circle-minus","audio-waveform","moon-star","arrow-down-narrow-wide","ghost","database-backup","wand","receipt-turkish-lira","vector-polygon","calendar-minus-2","copy-minus","vault","folder-input","book-image","badge-x","mouse-left","tag-plus","shirt","van","server-off","move-up","message-circle-dashed","utensils","plug-2","users-round","chess-rook","brackets","calendar-heart","list-ordered","users","star-x","mic-off","user-x","arrow-big-left","square-split-horizontal","triangle-alert","user-round-x","clover","sun-snow","sofa","user-round-search","handbag","funnel-x","map-pin","clock-2","calendar-fold","fish-off","baby","database-x","fold-vertical","user-round-group","hop","face-angry","user-round-cog","cigarette","calendar-chevrons-right","user-round-check","user-round-arrow-left","diamond-plus","refrigerator","file-chart-column","triangle-dashed","git-pull-request-closed","badge-check","user-minus","user-lock","layers-arrow-up","plug-zap","heading-4","chess-queen","graduation-cap","grid-3x2","zodiac-sagittarius","square-dashed-x-corner","square-dashed-bottom-code","clock-7","ethernet-port","scan-text","user-group","shower-head","equal-not","user-cog","move-down","clock-arrow-down","ticket-slash","ruler","settings-2","user","circle-user-round","usb-c-port","layers","list-filter","map-pin-check","egg-off","upload","cog","dog","unplug","swords","spotlight","panel-right-dashed","signal-zero","paper-bag","truck-electric","unlink","check-line","university","bubbles","bot","chart-bar-increasing","ungroup","playing-card","air-vent","unfold-vertical","dot","ice-cream-cone","mouth","file-symlink","clipboard-paste","chevron-last","book-heart","undo-2","circle-parking","globe-check","cloud-check","panel-left","circle-chevron-right","undo","underline","squares-unite","arrow-down-up","git-fork","forward","brain-circuit","between-vertical-start","database","panel-right","umbrella-off","type-outline","flower","log-out","git-branch-plus","clipboard-minus","file-text","trending-up","fire-extinguisher","fan","table-rows-split","milk-off","tv-minimal","cloud-upload","banknote","turntable","message-circle-dashed-check","drumstick","turkish-lira","calendar-search","tube-lotion","line-dot-top-vertical","bell-ring","circle-chevron-left","truck","arrow-down","arrow-up-down","folder-dot","trophy","case-lower","whole-word","monitor","disc-2","trending-up-down","folder-cog","user-shield","triangle","tv-minimal-play","circle-stop","align-vertical-space-around","switch-camera","tree-deciduous","square-chart-gantt","arrow-big-down","circle-parking-off","calendar-x-2","user-plus","move-diagonal-2","bandage","gallery-horizontal-end","panel-top-dashed","transgender","chess-bishop","tram-front","train-front-tunnel","train-front","refresh-cw-off","audio-lines","traffic-cone","tractor","toothbrush","tower-control","rocket","fish","ear-off","touchpad-off","save-check","touchpad","torus","printer","megaphone-off","tornado","arrow-big-right","section","file-clock","toothbrush-sparkles","toy-brick","square-chevron-down","dice-1","drill","app-window","robot-vacuum","hand-metal","tool-case","spell-check-2","toilet","squirrel","list-plus","toggle-left","rotate-ccw-key","timer-reset","chart-pie","paw-print","timer","copy-slash","wind","ticket-x","layout-panel-left","moon","circle-percent","ticket-minus","circle-arrow-out-down-right","square-x","italic","chart-column-increasing","layout-freeform","step-forward","message-square-diff","a-arrow-down","broom-sparkles","sticker","tic-tac-toe","move-left","thermometer-sun","thermometer-snowflake","thermometer","theater","import","badge-turkish-lira","square-terminal","file-music","logs","beef","faucet","file-user","text-quote","square-radical","lightbulb","image-upscale","book-type","text-cursor-input","signpost-big","text-cursor","cloudy","helicopter","square-percent","text-align-justify","navigation-off","arrow-left","car-taxi-front","text-align-end","mouth-off","chevrons-right-left","text-align-center","test-tubes","test-tube-diagonal","brick-wall-fire","square-stack","tent","square-dimensions","face-slightly-smiling","align-end-horizontal","layer-arrow-down","equal","megaphone","calendar-x","telescope","ice-cream-bowl","egg","tangent","save-off","ship-cargo","circle-pound-sterling","video-off","japanese-yen","tally-3","tag","tally-1","library","file-terminal","circle-chevron-down","accessibility","route","square-library","amphora","hourglass-cog","tally-2","tablets","tablet-smartphone","building-complex","remove-formatting","sheet","circle-check-big","table-properties","table-of-contents","map-pinned","corner-down-left","circuit-board","table-columns-split","table-cells-merge","table-2","table","folder-open-dot","book-dashed","syringe","lasso","bluetooth","tree-pine","receipt-indian-rupee","swiss-franc","shield-plus","sunset","sun-medium","sun-dim","can-soda","flask-conical","power","funnel","square-star","folder-sync","monitor-pc","zodiac-ophiuchus","subscript","stretch-vertical","arrow-up-narrow-wide","fishing-hook","stretch-horizontal","maximize-2","stone","frame","calendar-arrow-down","clock-12","star-minus","heart","sticky-note-x","images","lollipop","book-text","chart-no-axes-column-increasing","lamp-floor","file-plus-corner","image","equal-approximately","badge-euro","bike","angle","gap-vertical","sticky-note-check","sticky-note","stethoscope","step-back","star-off","option","banknote-check","scroll-text","server-plus","repeat","star","stamp","toggle-right","file-x","ferris-wheel","camera-off","squircle","search-slash","repeat-off","squares-exclude","square-user","group","square-text","battery","mic-audio-lines","tent-tree","square-split-vertical","rectangle-horizontal","spade","square-slash","screen-share-off","bitcoin","square-scissors","battery-plus","database-search","square-round-corner","file-diff","joystick","square-plus","square-play","spline-pointer","square-pilcrow","axis-3d","square-pi","message-square-share","binoculars","square-pause","calendar-range","square-parking","rose","euro","mail-minus","square-m","square-kanban","square-function","pyramid","clipboard-pen","bottle-wine","alarm-clock-off","square-equal","list","square-dot","square-arrow-right","dome","badge-pound-sterling","bookmark-check","square-divide","wrench-off","shopping-bag","a-arrow-up","clock-check","shrink","chevrons-down","vibrate-off","face-grinning","zodiac-cancer","square-code","file-code","square-chevron-up","carton-off","credit-card-reader","paintbrush-vertical","cassette-tape","battery-low","square-chevron-left","receipt-japanese-yen","signpost","snail","calendar-arrow-up","landmark","fish-symbol","trash-off","loader","bold","dice-2","file-type","clipboard-clock","beer","lectern","square-centerline-dashed-vertical","square-bottom-dashed-scissors","square-bookmark","binary","move-diagonal","square-asterisk","door-closed","square-arrow-up-right","layout-template","rows-4","piano","square-arrow-right-exit","bookmark-off","hand-heart","square-arrow-right-enter","scan-qr-code","message-square-check","square-arrow-out-up-right","square-arrow-out-up-left","monitor-play","brain","square-arrow-out-down-left","server-cog","square-arrow-down-right","key","clock-11","gap-horizontal","ticket-plus","arrow-up-0-1","bell-electric","square","heading","book-open-check","panel-top-close","lasso-select","sprout","spray-can","sport-shoe","shield-off","bus","search-alert","audio-lines-x","chart-no-axes-gantt","file-spreadsheet","percent","clipboard-list","speech","contact-round","speaker","keyboard-off","sparkles","file-badge","battery-warning","mail-question-mark","arrow-down-from-line","briefcase","biohazard","rectangle-circle","braces","scale-3d","panel-top-bottom-dashed","mail-x","square-dashed-mouse-pointer","square-sparkles","lock-open","file-play","pizza","list-indent-decrease","arrow-up-wide-narrow","soup","clock-5","solar-panel","rotate-ccw","align-horizontal-justify-center","soap-dispenser-droplet","antenna","memory-stick","scan-eye","snowflake","square-check","heart-plus","smartphone-nfc","map-pin-minus-inside","git-merge","gallery-vertical-end","square-dashed-plus","hand-coins","zodiac-capricorn","wifi-low","sliders-horizontal","clock","file-pen","git-compare-arrows","cloud-sun-rain","align-horizontal-justify-start","power-off","mail-badge","skull","calendar-plus","siren","arrow-down-z-a","bath","signature","unlink-2","signal-medium","shopping-cart-minus","folder-check","signal-low","book-key","ribbon","microwave","calculator","gallery-vertical","sigma","shuffle","square-dashed-text","map-pin-pen","move-up-left","shrimp","folder-heart","hard-drive-upload","monitor-speaker","shopping-cart-plus","arrow-up-a-z","package","square-dashed-top-solid","ship-wheel","shield-user","shield-question-mark","swatch-book","receipt-cent","spool","folder-archive","folder-symlink","can","ban","message-square-x","paint-roller","git-pull-request-draft","archive","shield-lock","shield-keyhole","shield-half","circle-slash-2","shield-cog-corner","cake","cloud-rain","chart-bar","shield-cog","wrench","shield-ban","shield","shelving-unit","flag-triangle-right","shell","gamepad-directional","bell","share","shapes","music-3","chart-bar-big","user-check","proportions","settings","plane","webhook-off","carrot","square-arrow-left","file-cog","circle-dashed","server","send-horizontal","search-x","germ","squares-subtract","search-code","dices","split","list-sort-descending","search","forklift","scroll","alarm-clock-minus","heart-x","eraser","square-sigma","screen-share","bluetooth-connected","rotate-ccw-square","chart-no-axes-column","cannabis-off","folder-kanban","lighthouse","mars-stroke","roller-coaster","school","scan-search","file-box","pickaxe","paint-bucket","glass-water","mic","glasses","piggy-bank","scan-face","cuboid","cloud-off","check-check","activity","axe","plane-takeoff","scan-box","cloud-rain-wind","scan-barcode","scan","copy-x","file-axis-3d","radical","chart-column-decreasing","play-off","bug-play","align-vertical-distribute-start","save-plus","waves-arrow-up","tally-5","headset","save","saudi-riyal","circle-divide","satellite-dish","sandwich","salad","life-buoy","sailboat","external-link","volume-2","battery-charging","russian-ruble","square-arrow-up-left","brick-wall-shield","footprints","rows-3","building","rows-2","router","route-off","tag-x","book-alert","link-2","astroid","bell-minus","image-up","closed-caption","drum","arrow-up-z-a","sun","rotate-cw-fading-clock","rotate-cw-clock","file-key","rotate-ccw-clock","rotate-3d","scissors-line-dashed","house-wifi","robot-arm","rewind","ticket-check","combine","reply","replace-all","mountain","mars","picture-in-picture-2","radio-off","flower-2","replace","squares-intersect","repeat-2","repeat-1","keyboard-music","star-half","playing-cards-fan","code-xml","pencil-line","mails","brain-cog","tablet","regex","pi","trash","book-down","hdmi-port","trailer","case-upper","circle-fading-arrow-up","refresh-cw","croissant","phone","computer","barcode","pin","redo","bed","circle-arrow-right","divide","grape","rectangle-vertical","party-popper","file-chart-pie","rectangle-goggles","file-x-corner","dice-6","receipt-swiss-franc","blender","receipt-russian-ruble","zap-off","square-check-big","receipt-euro","receipt","ratio","laptop-minimal","rat","rainbow","map-pin-minus","omega","chart-spline","message-square-more","radio-receiver","chart-candlestick","radio","arrow-down-a-z","radiation","radar","move-horizontal","file-sliders","quote","square-exclamation-point","cup-soda","puzzle","projector","sword","printer-check","map-pin-x","earth","slice","dice-3","milk","mouse-pointer-ban","crown","circle-slash","circle-star","rotate-cw-square","atom","package-x","bed-double","pound-sterling","circle-dot","file-exclamation-point","hand-fist","message-circle-code","folder-git-2","message-square-code","popsicle","towel-rack","layout-grid","arrow-big-left-dash","plus","dumbbell","plug","playing-cards","houses","scale","play","flashlight","panel-top-open","plane-landing","pin-off","notebook","redo-2","pill","square-menu","pilcrow-left","monitor-smartphone","laptop","scan-line","clock-4","square-arrow-up","book-minus","file-question-mark","chevrons-left-right","phone-off","save-pen","arrow-down-to-line","phone-forwarded","refresh-ccw","venetian-mask","calendar-check-2","phi","spline","banknote-x","git-pull-request-create-arrow","pentagon","circle-check","pencil-off","caravan","pen-off","pen-line","hand-platter","pc-case","timer-off","arrow-big-right-dash","bed-single","parasol","paperclip","backpack","calendar-minus","panels-left-bottom","panel-top","panel-right-open","mic-signal","arrow-down-right","panel-right-close","letters","wifi-zero","panel-left-open","panel-left-dashed","map-pin-plus","hard-drive-download","image-off","panel-bottom-close","panel-bottom","panda","engine","square-chevron-right","mail-search","package-search","bone-fracture","package-plus","package-open","crop","package-2","lambda","ampersand","ad","shopping-cart","align-vertical-justify-end","origami","alarm-smoke","orbit","file-input","clock-8","hand-grab","cloud-cog","blend","hd","radio-tower","list-tree","droplet","line-squiggle","eye","octagon-pause","square-dashed-x","banana","gpu","message-square-heart","nut-off","circle-equal","face-slightly-frowning","nut","notepad-text-dashed","notepad-text","text-initial","arrow-up-right","maximize","leafy-green","message-square-dot","file-chart-line","columns-3-cog","newspaper","network","minimize-2","nepali-rupee","navigation-2","cone","navigation","file-image","music-2","palette","barrel","gallery-thumbnails","move-up-right","cpu","move-right","thumbs-down","merge","hamburger","move-down-right","hat-glasses","code","move-down-left","move-3d","mail-check","mouse-pointer","carton","mouse-off","kanban","bone","apple","rocking-chair","bot-off","circle-arrow-out-down-left","database-arrow-down","folder","circle-arrow-out-up-left","mop","cable-car","arrow-down-left","square-activity","message-square-text","cigarette-off","monitor-up","message-circle","circle-arrow-out-up-right","car-battery","monitor-stop","fold-horizontal","shovel","calendar-1","cloud-moon","square-arrow-out-down-right","monitor-pause","clock-plus","circle-euro","cloud-snow","anvil","arrow-big-up-dash","monitor-off","log-in","monitor-dot","monitor-cog","monitor-check","list-checks","chevrons-down-up","clipboard-plus","circle-x","list-end","minus","list-collapse","chevrons-right","audio-lines-off","message-square-reply","corner-down-right","milestone","summary","lamp-wall-down","mic-vocal","layout-arrow-down","ellipsis-vertical","globe-off","square-stop","arrow-up-1-0","align-horizontal-justify-end","scan-heart","align-vertical-distribute-end","heart-crack","airplay","case-sensitive","messages-circle","message-square-warning","monitor-x","bell-check","database-minus","square-pen","message-square-plus","message-square-lock","dice-5","octagon","ticket","folder-lock","message-circle-off","briefcase-plus","bookmark","message-circle-heart","utility-pole","message-circle-check","chart-bar-decreasing","database-plus","calendar-sync","funnel-plus","store","circle-arrow-down","notebook-pen","egg-fried","compass","keyboard","corner-right-up","map-pin-x-inside","printer-3d","user-round-plus","panel-left-close","crosshair","pilcrow-right","user-round-minus","mailbox","indian-rupee","mail-plus","mail-pen","bell-off","mail-clock","mouse-pointer-2-off","drone","slash","credit-card-x","aperture","arrow-right-left","mail","vector-square","circle-gauge","circle-alert","check","text-search","arrow-down-to-dot","monitor-down","lock-keyhole-open","chef-hat","lock-keyhole","lock","file-archive","signal-high","inbox","locate-fixed","locate","image-play","align-horizontal-space-between","loader-pinwheel","calendar-check","database-zap","droplets","loader-circle","broom","corner-right-down","layout-list","file-search","list-video","alarm-clock-plus","circle-dollar-sign","usb","house","receipt-pound-sterling","list-music","list-indent-increase","id-card","mouse","minimize","list-clock","list-chevrons-up-down","galaxy","list-chevrons-down-up","book-x","mirror-rectangular","list-check","link-2-off","link","headphone-off","asterisk","line-style","octagon-x","languages","line-dot-right-horizontal","alarm-clock-check","guitar","dock","beer-off","scooter","square-parking-off","notebook-text","arrow-right-to-line","clef-treble","tally-4","zodiac-taurus","leaf","door-open","flag-triangle-left","grid-3x3","file","layout-panel-top","pocket-knife","book-copy","castle","car-front","clock-alert","reply-all","cloud-moon-rain","clipboard-type","layout-dashboard","list-todo","printer-x","bird","list-start","lamp-wall-up","a-large-small","lamp-ceiling","lamp","map-plus","key-square","file-chart-column-increasing","kayak","database-arrow-up","arrow-right-from-line","flame-kindling","square-power","iv-bag","bring-to-front","iteration-cw","iteration-ccw","bell-plus","inspection-panel","info","infinity","folders","mail-warning","image-plus","image-minus","id-card-lanyard","bridge","chart-line","file-lock","cast","circle-fading-plus","clock-10","undo-dot","target","list-filter-plus","house-plug","drama","house-heart","baseline","martini","contrast","hotel","candy-off","hospital","book-check","heart-off","book-lock","highlighter","briefcase-medical","calendars","text-align-start","heart-pulse","hop-off","warehouse","sticky-notes","drafting-compass","save-all","file-braces","heading-6","heading-5","heading-3","heading-2","fishing-rod","book-headphones","credit-card","heading-1","haze","hard-hat","shredder","panel-bottom-open","door-closed-package","eject","credit-card-check","balloon","map-pin-plus-inside","bookmark-x","badge-question-mark","pen","hand","candy-cane","hammer","grip","gamepad-2","file-type-corner","grid-2x2-check","grid-2x2","globe-x","shield-minus","circle-off","dessert","eclipse","church","git-pull-request-create","cylinder","badge-japanese-yen","columns-3","receipt-text","git-merge-conflict","git-compare","git-commit-vertical","git-commit-horizontal","file-output","disc-album","circle-ellipsis","arrow-down-0-1","captions","git-branch","gift","philippine-peso","badge-alert","gem","folder-pen","cross","gauge","chevron-right","sticky-note-minus","square-arrow-down-left","share-2","gamepad","fullscreen","fuel","folder-up","folder-search-2","folder-root","chess-pawn","folder-open","briefcase-business","folder-minus","message-circle-reply","cloud-sync","triangle-right","folder-clock","folder-closed","mop-sparkles","type","webhook","flask-conical-off","align-horizontal-distribute-start","flashlight-off","flag-off","pointer-off","turtle","camera","fingerprint-pattern","film","git-pull-request","bluetooth-searching","arrow-up-to-line","squircle-dashed","clock-3","badge-percent","face-expressionless","file-video-camera","file-up","grid-2x2-plus","file-stack","box","file-search-corner","clock-1","file-heart","house-cog","space","file-minus-corner","file-minus","file-digit","corner-up-left","clock-6","zodiac-scorpio","key-round","headphones","tv","factory","face-neutral","rss","expand","at-sign","map-pin-check-inside","sticky-note-off","music","handshake","earth-lock","circle-user","copy-plus","droplet-off","virus-off","line-dot-left-horizontal","disc","diff","search-check","clipboard-check","columns-2","diamond-minus","clipboard","align-center-vertical","diameter","delete","club","cloud-fog","mosque","currency","map-pin-house","package-check","chevron-first","pencil","boxes","list-x","copyright","copyleft","corner-up-right","cookie","clock-arrow-left","container","contact","badge-indian-rupee","construction","redo-dot","component","align-start-horizontal","chart-column-stacked","file-plus","git-pull-request-arrow","coins","decimals-arrow-right","bell-dot","folder-down","cloud-drizzle","cloud-backup","align-horizontal-space-around","door-closed-locked","clock-9","diamond","blinds","clapperboard","circle-play","book-search","git-branch-minus","circle-dashed-check","recycle","mountain-snow","luggage","chevrons-left-right-ellipsis","bot-message-square","phone-outgoing","smartphone-charging","chevron-left","train-track","cherry","chart-bar-stacked","sticky-note-plus","chart-no-axes-column-decreasing","chart-network","chart-column-big","chart-no-axes-combined","metronome","triangles-centerline-dashed-vertical","arrow-down-1-0","credit-card-minus","candy","arrow-left-right","lightbulb-off","panels-top-left","beef-off","locate-off","bug","test-tube","brick-wall","cooking-pot","boom-box","book-up","book-plus","laptop-minimal-check","mail-open","park","baggage-claim","variable","arrow-right","archive-restore"},{"rbxassetid://104502745253902","rbxassetid://89421818506275"},{[48]={{1,{24,24},{175,0}},{1,{24,24},{650,0}},{1,{24,24},{850,250}},{2,{24,24},{150,0}},{1,{24,24},{250,700}},{1,{24,24},{600,225}},{1,{24,24},{575,800}},{2,{24,24},{225,225}},{1,{24,24},{50,350}},{1,{24,24},{675,25}},{1,{24,24},{500,425}},{1,{24,24},{50,400}},{1,{24,24},{75,925}},{1,{24,24},{825,50}},{1,{24,24},{50,75}},{1,{24,24},{175,800}},{1,{24,24},{375,925}},{1,{24,24},{850,450}},{1,{24,24},{325,50}},{1,{24,24},{100,325}},{1,{24,24},{650,225}},{1,{24,24},{950,475}},{1,{24,24},{725,300}},{1,{24,24},{425,125}},{1,{24,24},{650,850}},{1,{24,24},{50,375}},{1,{24,24},{550,425}},{2,{24,24},{50,125}},{1,{24,24},{25,725}},{1,{24,24},{300,200}},{1,{24,24},{825,500}},{1,{24,24},{300,575}},{1,{24,24},{500,800}},{1,{24,24},{950,225}},{1,{24,24},{525,925}},{1,{24,24},{500,375}},{1,{24,24},{775,525}},{1,{24,24},{100,100}},{1,{24,24},{900,100}},{2,{24,24},{200,50}},{1,{24,24},{325,125}},{2,{24,24},{100,400}},{1,{24,24},{175,550}},{1,{24,24},{175,975}},{1,{24,24},{75,650}},{1,{24,24},{100,825}},{1,{24,24},{225,375}},{1,{24,24},{525,700}},{1,{24,24},{500,675}},{2,{24,24},{225,200}},{1,{24,24},{500,825}},{1,{24,24},{75,350}},{1,{24,24},{325,325}},{1,{24,24},{50,475}},{1,{24,24},{775,375}},{1,{24,24},{600,675}},{1,{24,24},{450,50}},{1,{24,24},{900,25}},{1,{24,24},{300,350}},{1,{24,24},{775,900}},{1,{24,24},{775,925}},{2,{24,24},{50,50}},{1,{24,24},{750,800}},{2,{24,24},{175,325}},{1,{24,24},{25,975}},{1,{24,24},{750,475}},{1,{24,24},{250,600}},{1,{24,24},{250,75}},{1,{24,24},{425,450}},{1,{24,24},{925,725}},{1,{24,24},{725,550}},{1,{24,24},{875,575}},{1,{24,24},{650,350}},{1,{24,24},{100,175}},{1,{24,24},{800,725}},{2,{24,24},{250,25}},{1,{24,24},{100,450}},{2,{24,24},{225,300}},{1,{24,24},{550,675}},{2,{24,24},{0,450}},{1,{24,24},{350,975}},{2,{24,24},{25,300}},{1,{24,24},{250,125}},{1,{24,24},{50,525}},{1,{24,24},{100,75}},{1,{24,24},{275,550}},{1,{24,24},{525,675}},{1,{24,24},{775,300}},{1,{24,24},{550,975}},{1,{24,24},{700,225}},{1,{24,24},{150,650}},{1,{24,24},{150,100}},{2,{24,24},{375,100}},{1,{24,24},{575,625}},{1,{24,24},{75,775}},{1,{24,24},{700,300}},{1,{24,24},{300,675}},{1,{24,24},{775,475}},{1,{24,24},{475,275}},{1,{24,24},{950,375}},{1,{24,24},{350,425}},{1,{24,24},{250,100}},{1,{24,24},{750,0}},{2,{24,24},{325,100}},{1,{24,24},{50,225}},{1,{24,24},{75,400}},{1,{24,24},{450,725}},{1,{24,24},{550,725}},{1,{24,24},{250,350}},{1,{24,24},{250,750}},{1,{24,24},{575,225}},{2,{24,24},{350,0}},{1,{24,24},{75,900}},{1,{24,24},{125,550}},{1,{24,24},{100,525}},{1,{24,24},{75,325}},{1,{24,24},{350,350}},{1,{24,24},{650,825}},{1,{24,24},{200,0}},{1,{24,24},{575,400}},{1,{24,24},{400,300}},{1,{24,24},{700,600}},{1,{24,24},{525,50}},{1,{24,24},{550,75}},{1,{24,24},{200,200}},{1,{24,24},{800,900}},{1,{24,24},{950,875}},{1,{24,24},{300,500}},{1,{24,24},{150,775}},{1,{24,24},{950,200}},{1,{24,24},{100,275}},{1,{24,24},{525,500}},{2,{24,24},{0,200}},{1,{24,24},{500,50}},{1,{24,24},{425,250}},{1,{24,24},{200,925}},{1,{24,24},{325,225}},{1,{24,24},{875,100}},{1,{24,24},{75,150}},{2,{24,24},{100,175}},{1,{24,24},{775,575}},{1,{24,24},{475,300}},{1,{24,24},{450,525}},{1,{24,24},{375,100}},{2,{24,24},{325,25}},{1,{24,24},{175,600}},{1,{24,24},{300,750}},{1,{24,24},{375,475}},{2,{24,24},{150,275}},{1,{24,24},{750,650}},{1,{24,24},{575,650}},{1,{24,24},{0,100}},{1,{24,24},{550,50}},{1,{24,24},{475,750}},{1,{24,24},{850,0}},{2,{24,24},{100,350}},{2,{24,24},{50,25}},{1,{24,24},{300,325}},{1,{24,24},{550,775}},{2,{24,24},{200,100}},{1,{24,24},{325,250}},{1,{24,24},{75,475}},{1,{24,24},{500,450}},{1,{24,24},{25,675}},{1,{24,24},{825,275}},{1,{24,24},{50,425}},{1,{24,24},{75,600}},{1,{24,24},{775,600}},{1,{24,24},{25,325}},{1,{24,24},{125,225}},{1,{24,24},{250,625}},{1,{24,24},{50,450}},{1,{24,24},{125,575}},{2,{24,24},{375,50}},{1,{24,24},{25,900}},{2,{24,24},{25,400}},{1,{24,24},{275,50}},{1,{24,24},{125,175}},{1,{24,24},{50,125}},{1,{24,24},{250,800}},{1,{24,24},{500,775}},{1,{24,24},{925,625}},{1,{24,24},{0,900}},{1,{24,24},{0,425}},{1,{24,24},{25,100}},{1,{24,24},{450,375}},{1,{24,24},{500,75}},{1,{24,24},{900,325}},{1,{24,24},{0,875}},{1,{24,24},{350,25}},{1,{24,24},{525,825}},{1,{24,24},{400,900}},{1,{24,24},{325,450}},{1,{24,24},{200,750}},{1,{24,24},{350,200}},{1,{24,24},{400,100}},{1,{24,24},{950,675}},{1,{24,24},{25,650}},{2,{24,24},{75,375}},{1,{24,24},{200,400}},{1,{24,24},{150,500}},{1,{24,24},{750,950}},{1,{24,24},{300,925}},{1,{24,24},{450,800}},{1,{24,24},{450,25}},{1,{24,24},{75,50}},{2,{24,24},{50,200}},{1,{24,24},{475,500}},{1,{24,24},{725,625}},{1,{24,24},{225,825}},{1,{24,24},{325,500}},{1,{24,24},{75,300}},{1,{24,24},{375,775}},{1,{24,24},{0,800}},{1,{24,24},{625,525}},{1,{24,24},{875,75}},{1,{24,24},{650,500}},{1,{24,24},{350,775}},{1,{24,24},{875,350}},{1,{24,24},{75,225}},{1,{24,24},{25,300}},{1,{24,24},{175,100}},{2,{24,24},{50,325}},{1,{24,24},{800,275}},{2,{24,24},{250,300}},{1,{24,24},{775,425}},{1,{24,24},{800,425}},{2,{24,24},{275,275}},{1,{24,24},{900,625}},{1,{24,24},{400,500}},{1,{24,24},{700,125}},{1,{24,24},{700,200}},{1,{24,24},{175,575}},{1,{24,24},{125,100}},{2,{24,24},{300,250}},{1,{24,24},{950,725}},{1,{24,24},{625,575}},{1,{24,24},{325,400}},{1,{24,24},{275,450}},{1,{24,24},{950,350}},{1,{24,24},{725,350}},{2,{24,24},{300,150}},{1,{24,24},{850,975}},{1,{24,24},{475,400}},{1,{24,24},{325,375}},{1,{24,24},{725,425}},{2,{24,24},{150,250}},{1,{24,24},{100,675}},{2,{24,24},{400,150}},{1,{24,24},{875,0}},{2,{24,24},{75,325}},{1,{24,24},{75,550}},{2,{24,24},{75,425}},{1,{24,24},{300,600}},{1,{24,24},{700,775}},{1,{24,24},{50,50}},{1,{24,24},{750,425}},{2,{24,24},{450,100}},{2,{24,24},{475,75}},{2,{24,24},{50,475}},{1,{24,24},{725,800}},{1,{24,24},{675,800}},{1,{24,24},{825,750}},{1,{24,24},{975,700}},{2,{24,24},{125,400}},{2,{24,24},{150,375}},{1,{24,24},{575,475}},{2,{24,24},{450,75}},{1,{24,24},{175,775}},{1,{24,24},{75,450}},{1,{24,24},{625,925}},{2,{24,24},{250,275}},{1,{24,24},{400,75}},{1,{24,24},{275,950}},{1,{24,24},{775,125}},{1,{24,24},{650,150}},{1,{24,24},{700,475}},{1,{24,24},{525,625}},{1,{24,24},{725,775}},{2,{24,24},{325,200}},{1,{24,24},{400,250}},{2,{24,24},{350,175}},{2,{24,24},{175,200}},{1,{24,24},{600,950}},{1,{24,24},{225,475}},{1,{24,24},{600,525}},{1,{24,24},{100,200}},{1,{24,24},{550,125}},{2,{24,24},{400,125}},{2,{24,24},{375,150}},{1,{24,24},{600,100}},{1,{24,24},{0,175}},{1,{24,24},{700,350}},{1,{24,24},{0,650}},{2,{24,24},{175,350}},{1,{24,24},{100,300}},{2,{24,24},{75,200}},{1,{24,24},{300,950}},{2,{24,24},{50,450}},{1,{24,24},{550,700}},{1,{24,24},{900,675}},{1,{24,24},{150,375}},{2,{24,24},{150,350}},{2,{24,24},{475,50}},{1,{24,24},{525,125}},{2,{24,24},{150,200}},{2,{24,24},{225,275}},{1,{24,24},{375,900}},{1,{24,24},{475,325}},{2,{24,24},{275,225}},{1,{24,24},{750,200}},{1,{24,24},{975,325}},{1,{24,24},{575,250}},{1,{24,24},{50,175}},{1,{24,24},{175,425}},{1,{24,24},{0,525}},{2,{24,24},{250,250}},{2,{24,24},{325,175}},{1,{24,24},{500,100}},{2,{24,24},{300,200}},{1,{24,24},{575,900}},{1,{24,24},{500,625}},{1,{24,24},{775,150}},{1,{24,24},{275,575}},{2,{24,24},{425,75}},{1,{24,24},{650,200}},{1,{24,24},{875,725}},{2,{24,24},{400,100}},{2,{24,24},{450,50}},{1,{24,24},{475,850}},{1,{24,24},{200,250}},{2,{24,24},{475,25}},{1,{24,24},{350,700}},{1,{24,24},{775,400}},{2,{24,24},{0,475}},{1,{24,24},{75,275}},{1,{24,24},{550,200}},{1,{24,24},{450,250}},{1,{24,24},{775,725}},{2,{24,24},{25,450}},{1,{24,24},{725,575}},{1,{24,24},{750,375}},{2,{24,24},{75,400}},{2,{24,24},{100,375}},{1,{24,24},{625,850}},{2,{24,24},{125,350}},{1,{24,24},{225,775}},{1,{24,24},{650,800}},{1,{24,24},{150,50}},{2,{24,24},{200,275}},{2,{24,24},{200,225}},{1,{24,24},{250,850}},{1,{24,24},{800,75}},{2,{24,24},{225,250}},{1,{24,24},{875,900}},{2,{24,24},{275,200}},{2,{24,24},{300,175}},{2,{24,24},{100,0}},{2,{24,24},{0,25}},{1,{24,24},{50,500}},{1,{24,24},{600,325}},{2,{24,24},{250,225}},{1,{24,24},{50,325}},{1,{24,24},{150,900}},{2,{24,24},{325,150}},{1,{24,24},{500,325}},{1,{24,24},{325,825}},{2,{24,24},{400,75}},{1,{24,24},{750,675}},{2,{24,24},{450,25}},{1,{24,24},{950,150}},{1,{24,24},{0,725}},{2,{24,24},{350,125}},{1,{24,24},{300,550}},{1,{24,24},{225,0}},{2,{24,24},{475,0}},{1,{24,24},{600,250}},{1,{24,24},{600,175}},{1,{24,24},{350,375}},{1,{24,24},{575,850}},{1,{24,24},{250,250}},{2,{24,24},{25,425}},{1,{24,24},{275,650}},{1,{24,24},{325,425}},{1,{24,24},{700,0}},{1,{24,24},{650,425}},{1,{24,24},{825,200}},{2,{24,24},{125,150}},{1,{24,24},{375,550}},{2,{24,24},{125,325}},{1,{24,24},{25,425}},{1,{24,24},{325,725}},{1,{24,24},{250,150}},{1,{24,24},{600,975}},{1,{24,24},{550,525}},{1,{24,24},{525,100}},{1,{24,24},{925,25}},{1,{24,24},{125,625}},{1,{24,24},{200,150}},{1,{24,24},{0,150}},{1,{24,24},{275,250}},{1,{24,24},{700,450}},{2,{24,24},{175,275}},{1,{24,24},{150,300}},{2,{24,24},{250,200}},{1,{24,24},{800,950}},{1,{24,24},{75,500}},{1,{24,24},{550,300}},{1,{24,24},{350,150}},{1,{24,24},{200,775}},{1,{24,24},{225,450}},{1,{24,24},{50,275}},{1,{24,24},{900,300}},{1,{24,24},{0,250}},{1,{24,24},{125,825}},{1,{24,24},{500,300}},{2,{24,24},{175,300}},{1,{24,24},{850,525}},{2,{24,24},{350,100}},{1,{24,24},{575,0}},{1,{24,24},{575,200}},{2,{24,24},{375,75}},{1,{24,24},{325,600}},{1,{24,24},{200,275}},{1,{24,24},{275,100}},{1,{24,24},{700,500}},{2,{24,24},{125,50}},{1,{24,24},{775,750}},{2,{24,24},{425,25}},{1,{24,24},{550,925}},{1,{24,24},{925,300}},{1,{24,24},{825,325}},{2,{24,24},{0,425}},{1,{24,24},{675,650}},{2,{24,24},{75,350}},{1,{24,24},{0,625}},{1,{24,24},{500,25}},{1,{24,24},{0,550}},{1,{24,24},{900,200}},{2,{24,24},{50,375}},{1,{24,24},{975,875}},{1,{24,24},{875,300}},{2,{24,24},{125,300}},{1,{24,24},{250,0}},{1,{24,24},{850,900}},{2,{24,24},{250,100}},{2,{24,24},{250,175}},{1,{24,24},{425,325}},{2,{24,24},{25,50}},{1,{24,24},{725,850}},{2,{24,24},{275,150}},{1,{24,24},{800,200}},{1,{24,24},{600,350}},{1,{24,24},{425,700}},{1,{24,24},{625,100}},{1,{24,24},{25,525}},{1,{24,24},{200,700}},{1,{24,24},{325,25}},{1,{24,24},{375,425}},{1,{24,24},{650,275}},{2,{24,24},{400,25}},{1,{24,24},{925,100}},{1,{24,24},{200,650}},{2,{24,24},{425,0}},{1,{24,24},{225,425}},{1,{24,24},{125,425}},{2,{24,24},{0,400}},{2,{24,24},{25,375}},{1,{24,24},{125,675}},{1,{24,24},{475,900}},{1,{24,24},{575,300}},{2,{24,24},{225,125}},{1,{24,24},{775,200}},{1,{24,24},{225,125}},{2,{24,24},{100,300}},{2,{24,24},{125,275}},{1,{24,24},{275,775}},{1,{24,24},{650,675}},{1,{24,24},{450,550}},{1,{24,24},{25,600}},{1,{24,24},{400,575}},{1,{24,24},{250,725}},{2,{24,24},{375,175}},{1,{24,24},{825,850}},{1,{24,24},{675,975}},{1,{24,24},{500,225}},{1,{24,24},{425,425}},{1,{24,24},{625,825}},{2,{24,24},{175,225}},{1,{24,24},{600,925}},{1,{24,24},{500,350}},{2,{24,24},{200,200}},{1,{24,24},{300,900}},{1,{24,24},{400,325}},{2,{24,24},{200,75}},{1,{24,24},{725,700}},{1,{24,24},{975,525}},{2,{24,24},{100,325}},{1,{24,24},{525,175}},{2,{24,24},{275,125}},{1,{24,24},{200,850}},{1,{24,24},{125,950}},{1,{24,24},{700,425}},{1,{24,24},{725,125}},{2,{24,24},{300,100}},{1,{24,24},{300,450}},{1,{24,24},{525,300}},{2,{24,24},{325,75}},{2,{24,24},{75,50}},{1,{24,24},{725,875}},{1,{24,24},{950,325}},{1,{24,24},{775,775}},{1,{24,24},{675,600}},{2,{24,24},{75,275}},{2,{24,24},{350,50}},{1,{24,24},{225,400}},{2,{24,24},{400,0}},{1,{24,24},{25,500}},{1,{24,24},{100,400}},{1,{24,24},{100,500}},{2,{24,24},{0,375}},{1,{24,24},{750,575}},{1,{24,24},{75,0}},{2,{24,24},{25,350}},{1,{24,24},{300,525}},{1,{24,24},{600,425}},{1,{24,24},{450,750}},{1,{24,24},{600,300}},{1,{24,24},{150,550}},{1,{24,24},{600,50}},{1,{24,24},{225,250}},{2,{24,24},{125,250}},{1,{24,24},{150,525}},{1,{24,24},{600,375}},{1,{24,24},{125,600}},{1,{24,24},{275,975}},{1,{24,24},{575,100}},{2,{24,24},{75,300}},{2,{24,24},{150,225}},{1,{24,24},{900,900}},{1,{24,24},{200,75}},{1,{24,24},{900,75}},{1,{24,24},{725,225}},{1,{24,24},{475,50}},{1,{24,24},{25,400}},{1,{24,24},{325,475}},{1,{24,24},{900,375}},{2,{24,24},{200,175}},{2,{24,24},{250,125}},{1,{24,24},{725,200}},{1,{24,24},{350,750}},{1,{24,24},{50,900}},{1,{24,24},{175,525}},{1,{24,24},{550,350}},{2,{24,24},{275,75}},{1,{24,24},{225,675}},{1,{24,24},{0,850}},{2,{24,24},{50,100}},{1,{24,24},{650,525}},{2,{24,24},{300,75}},{1,{24,24},{500,250}},{1,{24,24},{400,0}},{2,{24,24},{375,0}},{1,{24,24},{850,300}},{1,{24,24},{50,775}},{2,{24,24},{0,350}},{1,{24,24},{425,150}},{2,{24,24},{25,325}},{1,{24,24},{475,600}},{1,{24,24},{150,275}},{1,{24,24},{600,75}},{2,{24,24},{50,300}},{1,{24,24},{125,150}},{1,{24,24},{150,150}},{1,{24,24},{450,475}},{2,{24,24},{100,250}},{1,{24,24},{400,200}},{2,{24,24},{200,300}},{1,{24,24},{925,275}},{1,{24,24},{725,100}},{2,{24,24},{300,50}},{1,{24,24},{475,450}},{2,{24,24},{175,250}},{2,{24,24},{175,175}},{2,{24,24},{325,50}},{1,{24,24},{550,150}},{1,{24,24},{25,150}},{2,{24,24},{125,0}},{2,{24,24},{50,275}},{1,{24,24},{875,775}},{1,{24,24},{25,200}},{1,{24,24},{175,500}},{1,{24,24},{375,200}},{2,{24,24},{50,350}},{1,{24,24},{400,800}},{1,{24,24},{125,250}},{1,{24,24},{525,425}},{1,{24,24},{825,450}},{2,{24,24},{125,200}},{1,{24,24},{125,500}},{2,{24,24},{150,175}},{2,{24,24},{225,100}},{2,{24,24},{200,125}},{1,{24,24},{525,850}},{1,{24,24},{75,250}},{2,{24,24},{275,50}},{2,{24,24},{300,25}},{2,{24,24},{150,150}},{2,{24,24},{0,300}},{1,{24,24},{675,725}},{1,{24,24},{150,750}},{1,{24,24},{0,825}},{2,{24,24},{75,225}},{1,{24,24},{500,925}},{2,{24,24},{50,250}},{2,{24,24},{100,200}},{1,{24,24},{900,450}},{1,{24,24},{175,950}},{2,{24,24},{125,175}},{1,{24,24},{200,50}},{1,{24,24},{750,725}},{1,{24,24},{450,425}},{2,{24,24},{175,125}},{2,{24,24},{325,0}},{1,{24,24},{800,850}},{1,{24,24},{75,725}},{1,{24,24},{200,625}},{1,{24,24},{200,25}},{1,{24,24},{700,700}},{1,{24,24},{875,125}},{2,{24,24},{225,75}},{1,{24,24},{900,700}},{2,{24,24},{250,50}},{1,{24,24},{825,975}},{1,{24,24},{875,225}},{2,{24,24},{300,0}},{1,{24,24},{525,875}},{2,{24,24},{25,250}},{1,{24,24},{325,300}},{1,{24,24},{475,800}},{2,{24,24},{0,275}},{1,{24,24},{525,250}},{2,{24,24},{425,100}},{2,{24,24},{175,100}},{1,{24,24},{950,125}},{1,{24,24},{875,325}},{1,{24,24},{100,575}},{2,{24,24},{275,0}},{1,{24,24},{100,550}},{1,{24,24},{825,950}},{1,{24,24},{150,875}},{1,{24,24},{600,25}},{1,{24,24},{100,950}},{1,{24,24},{900,950}},{1,{24,24},{500,650}},{1,{24,24},{0,0}},{1,{24,24},{125,400}},{1,{24,24},{975,900}},{2,{24,24},{25,225}},{1,{24,24},{250,950}},{2,{24,24},{125,125}},{2,{24,24},{150,100}},{2,{24,24},{100,150}},{2,{24,24},{175,75}},{1,{24,24},{300,725}},{1,{24,24},{300,75}},{1,{24,24},{925,850}},{1,{24,24},{50,825}},{1,{24,24},{325,775}},{1,{24,24},{375,50}},{1,{24,24},{850,25}},{1,{24,24},{450,450}},{2,{24,24},{250,0}},{1,{24,24},{750,975}},{1,{24,24},{600,475}},{1,{24,24},{375,650}},{1,{24,24},{475,25}},{2,{24,24},{50,175}},{1,{24,24},{700,850}},{2,{24,24},{25,200}},{1,{24,24},{450,300}},{1,{24,24},{50,950}},{1,{24,24},{900,825}},{2,{24,24},{100,125}},{1,{24,24},{700,525}},{1,{24,24},{25,250}},{1,{24,24},{575,25}},{2,{24,24},{125,100}},{1,{24,24},{475,725}},{1,{24,24},{375,275}},{2,{24,24},{150,75}},{2,{24,24},{175,50}},{2,{24,24},{225,0}},{1,{24,24},{400,125}},{1,{24,24},{775,975}},{2,{24,24},{25,175}},{1,{24,24},{750,925}},{1,{24,24},{50,800}},{1,{24,24},{100,25}},{1,{24,24},{375,675}},{1,{24,24},{475,375}},{1,{24,24},{150,975}},{1,{24,24},{350,225}},{2,{24,24},{75,125}},{1,{24,24},{625,400}},{1,{24,24},{700,150}},{2,{24,24},{125,75}},{1,{24,24},{475,950}},{1,{24,24},{850,675}},{1,{24,24},{0,675}},{2,{24,24},{150,300}},{1,{24,24},{50,975}},{2,{24,24},{200,0}},{2,{24,24},{75,100}},{2,{24,24},{25,150}},{1,{24,24},{700,375}},{1,{24,24},{575,325}},{1,{24,24},{625,50}},{1,{24,24},{50,0}},{1,{24,24},{900,525}},{1,{24,24},{875,825}},{1,{24,24},{125,75}},{1,{24,24},{850,175}},{2,{24,24},{0,175}},{2,{24,24},{150,25}},{2,{24,24},{0,150}},{1,{24,24},{475,75}},{1,{24,24},{425,950}},{1,{24,24},{850,650}},{1,{24,24},{675,0}},{2,{24,24},{75,75}},{2,{24,24},{100,50}},{1,{24,24},{400,725}},{1,{24,24},{400,375}},{1,{24,24},{425,275}},{2,{24,24},{125,25}},{2,{24,24},{0,125}},{2,{24,24},{25,100}},{2,{24,24},{25,125}},{1,{24,24},{200,725}},{1,{24,24},{300,175}},{2,{24,24},{50,75}},{1,{24,24},{400,650}},{1,{24,24},{100,350}},{2,{24,24},{0,325}},{1,{24,24},{375,975}},{2,{24,24},{0,100}},{1,{24,24},{975,550}},{2,{24,24},{75,25}},{2,{24,24},{75,0}},{2,{24,24},{0,50}},{1,{24,24},{225,350}},{1,{24,24},{800,125}},{1,{24,24},{375,950}},{1,{24,24},{575,375}},{1,{24,24},{975,800}},{1,{24,24},{950,0}},{1,{24,24},{300,875}},{2,{24,24},{425,125}},{2,{24,24},{50,0}},{2,{24,24},{25,0}},{1,{24,24},{50,250}},{1,{24,24},{125,775}},{2,{24,24},{0,0}},{1,{24,24},{250,875}},{1,{24,24},{950,975}},{1,{24,24},{700,250}},{1,{24,24},{225,325}},{1,{24,24},{650,75}},{1,{24,24},{900,925}},{1,{24,24},{100,900}},{1,{24,24},{950,950}},{1,{24,24},{325,700}},{1,{24,24},{300,800}},{1,{24,24},{500,0}},{1,{24,24},{425,200}},{1,{24,24},{675,375}},{1,{24,24},{850,50}},{1,{24,24},{350,675}},{1,{24,24},{525,325}},{1,{24,24},{175,175}},{1,{24,24},{450,0}},{1,{24,24},{75,125}},{1,{24,24},{300,650}},{1,{24,24},{950,925}},{1,{24,24},{925,975}},{1,{24,24},{875,975}},{1,{24,24},{925,925}},{1,{24,24},{875,950}},{1,{24,24},{900,350}},{1,{24,24},{25,350}},{1,{24,24},{950,525}},{1,{24,24},{525,950}},{1,{24,24},{925,475}},{1,{24,24},{950,900}},{1,{24,24},{975,850}},{2,{24,24},{275,25}},{1,{24,24},{350,550}},{1,{24,24},{775,100}},{1,{24,24},{275,300}},{1,{24,24},{850,950}},{1,{24,24},{825,650}},{1,{24,24},{950,450}},{1,{24,24},{975,825}},{1,{24,24},{850,925}},{1,{24,24},{125,850}},{1,{24,24},{900,875}},{1,{24,24},{125,275}},{1,{24,24},{900,275}},{2,{24,24},{50,150}},{1,{24,24},{825,925}},{1,{24,24},{725,650}},{1,{24,24},{625,950}},{1,{24,24},{900,850}},{1,{24,24},{475,975}},{1,{24,24},{300,150}},{1,{24,24},{950,800}},{1,{24,24},{175,225}},{1,{24,24},{400,400}},{1,{24,24},{975,775}},{1,{24,24},{350,525}},{1,{24,24},{975,75}},{1,{24,24},{800,925}},{1,{24,24},{825,900}},{1,{24,24},{850,750}},{1,{24,24},{850,875}},{1,{24,24},{350,0}},{1,{24,24},{875,850}},{1,{24,24},{275,875}},{1,{24,24},{400,50}},{1,{24,24},{950,775}},{1,{24,24},{450,125}},{1,{24,24},{975,750}},{1,{24,24},{600,800}},{1,{24,24},{400,450}},{1,{24,24},{150,950}},{1,{24,24},{850,850}},{1,{24,24},{900,800}},{1,{24,24},{925,775}},{1,{24,24},{800,550}},{1,{24,24},{100,600}},{1,{24,24},{75,425}},{1,{24,24},{100,0}},{1,{24,24},{975,725}},{1,{24,24},{650,450}},{1,{24,24},{700,975}},{1,{24,24},{750,875}},{1,{24,24},{475,350}},{1,{24,24},{0,350}},{1,{24,24},{325,175}},{1,{24,24},{725,950}},{2,{24,24},{300,225}},{1,{24,24},{750,775}},{1,{24,24},{25,0}},{1,{24,24},{300,425}},{1,{24,24},{950,600}},{1,{24,24},{475,175}},{2,{24,24},{200,250}},{1,{24,24},{150,700}},{2,{24,24},{100,425}},{1,{24,24},{700,950}},{1,{24,24},{400,475}},{1,{24,24},{725,925}},{1,{24,24},{450,150}},{1,{24,24},{75,700}},{1,{24,24},{575,675}},{1,{24,24},{325,275}},{1,{24,24},{225,175}},{1,{24,24},{775,875}},{1,{24,24},{975,400}},{1,{24,24},{675,875}},{1,{24,24},{800,775}},{1,{24,24},{200,350}},{1,{24,24},{550,500}},{1,{24,24},{175,725}},{2,{24,24},{100,225}},{1,{24,24},{575,525}},{1,{24,24},{75,375}},{1,{24,24},{50,750}},{1,{24,24},{500,400}},{1,{24,24},{250,450}},{1,{24,24},{325,100}},{1,{24,24},{825,250}},{1,{24,24},{900,750}},{1,{24,24},{950,700}},{1,{24,24},{975,675}},{1,{24,24},{425,25}},{1,{24,24},{375,825}},{1,{24,24},{650,975}},{1,{24,24},{375,450}},{1,{24,24},{700,925}},{1,{24,24},{900,175}},{1,{24,24},{800,625}},{1,{24,24},{575,725}},{1,{24,24},{775,850}},{1,{24,24},{275,225}},{1,{24,24},{925,75}},{1,{24,24},{800,825}},{1,{24,24},{700,750}},{1,{24,24},{575,575}},{1,{24,24},{825,800}},{1,{24,24},{850,775}},{1,{24,24},{275,900}},{1,{24,24},{425,100}},{1,{24,24},{900,725}},{1,{24,24},{600,875}},{1,{24,24},{975,650}},{1,{24,24},{850,200}},{1,{24,24},{675,50}},{1,{24,24},{325,625}},{2,{24,24},{225,50}},{1,{24,24},{225,75}},{1,{24,24},{250,175}},{1,{24,24},{800,975}},{1,{24,24},{375,625}},{1,{24,24},{100,375}},{1,{24,24},{850,425}},{1,{24,24},{425,625}},{1,{24,24},{675,925}},{1,{24,24},{700,900}},{1,{24,24},{750,850}},{1,{24,24},{525,975}},{1,{24,24},{400,150}},{1,{24,24},{900,575}},{1,{24,24},{100,225}},{1,{24,24},{350,275}},{1,{24,24},{650,250}},{1,{24,24},{875,425}},{1,{24,24},{200,500}},{1,{24,24},{925,675}},{1,{24,24},{750,25}},{1,{24,24},{950,650}},{1,{24,24},{800,250}},{1,{24,24},{975,625}},{1,{24,24},{700,175}},{1,{24,24},{150,250}},{1,{24,24},{925,200}},{1,{24,24},{50,200}},{1,{24,24},{200,325}},{1,{24,24},{375,75}},{1,{24,24},{800,575}},{1,{24,24},{525,0}},{1,{24,24},{925,525}},{1,{24,24},{875,400}},{1,{24,24},{850,275}},{1,{24,24},{925,750}},{1,{24,24},{875,875}},{1,{24,24},{425,675}},{1,{24,24},{875,25}},{1,{24,24},{925,400}},{1,{24,24},{100,975}},{1,{24,24},{325,0}},{1,{24,24},{675,900}},{1,{24,24},{550,175}},{1,{24,24},{700,875}},{1,{24,24},{475,925}},{1,{24,24},{150,0}},{1,{24,24},{750,825}},{1,{24,24},{50,150}},{1,{24,24},{975,175}},{1,{24,24},{800,650}},{1,{24,24},{775,800}},{1,{24,24},{825,825}},{1,{24,24},{175,825}},{1,{24,24},{850,725}},{1,{24,24},{650,475}},{1,{24,24},{825,150}},{1,{24,24},{450,500}},{1,{24,24},{900,775}},{1,{24,24},{0,975}},{2,{24,24},{75,450}},{2,{24,24},{125,375}},{1,{24,24},{925,650}},{1,{24,24},{225,500}},{1,{24,24},{900,0}},{1,{24,24},{950,25}},{1,{24,24},{575,175}},{1,{24,24},{100,50}},{1,{24,24},{400,925}},{1,{24,24},{225,875}},{1,{24,24},{575,975}},{1,{24,24},{475,100}},{1,{24,24},{650,900}},{1,{24,24},{150,125}},{1,{24,24},{300,100}},{1,{24,24},{725,825}},{2,{24,24},{375,25}},{1,{24,24},{800,750}},{1,{24,24},{700,825}},{1,{24,24},{575,350}},{1,{24,24},{825,725}},{1,{24,24},{175,300}},{1,{24,24},{775,625}},{1,{24,24},{725,450}},{1,{24,24},{275,275}},{1,{24,24},{425,525}},{1,{24,24},{875,675}},{1,{24,24},{900,650}},{1,{24,24},{875,800}},{1,{24,24},{575,550}},{1,{24,24},{975,250}},{1,{24,24},{975,575}},{1,{24,24},{350,575}},{1,{24,24},{725,275}},{1,{24,24},{225,950}},{1,{24,24},{675,850}},{1,{24,24},{175,125}},{1,{24,24},{650,600}},{1,{24,24},{850,825}},{1,{24,24},{825,700}},{1,{24,24},{925,600}},{1,{24,24},{950,575}},{2,{24,24},{25,75}},{1,{24,24},{425,925}},{1,{24,24},{775,825}},{1,{24,24},{625,300}},{1,{24,24},{0,925}},{1,{24,24},{200,375}},{1,{24,24},{175,200}},{1,{24,24},{200,950}},{1,{24,24},{600,650}},{1,{24,24},{700,275}},{1,{24,24},{100,125}},{1,{24,24},{575,925}},{1,{24,24},{600,900}},{1,{24,24},{625,875}},{1,{24,24},{650,50}},{1,{24,24},{700,800}},{1,{24,24},{300,250}},{1,{24,24},{625,125}},{1,{24,24},{50,550}},{1,{24,24},{675,825}},{2,{24,24},{275,250}},{1,{24,24},{750,750}},{1,{24,24},{875,650}},{1,{24,24},{800,700}},{1,{24,24},{25,875}},{1,{24,24},{825,675}},{1,{24,24},{375,575}},{1,{24,24},{125,300}},{1,{24,24},{875,625}},{1,{24,24},{925,575}},{1,{24,24},{825,400}},{1,{24,24},{150,450}},{2,{24,24},{225,175}},{1,{24,24},{850,500}},{1,{24,24},{950,550}},{1,{24,24},{850,475}},{2,{24,24},{375,125}},{1,{24,24},{475,125}},{1,{24,24},{925,700}},{1,{24,24},{375,500}},{1,{24,24},{500,175}},{1,{24,24},{500,975}},{1,{24,24},{725,750}},{1,{24,24},{800,675}},{1,{24,24},{150,800}},{1,{24,24},{925,875}},{1,{24,24},{850,625}},{1,{24,24},{775,50}},{1,{24,24},{800,800}},{1,{24,24},{800,300}},{1,{24,24},{775,700}},{1,{24,24},{775,175}},{1,{24,24},{925,550}},{1,{24,24},{0,75}},{1,{24,24},{125,875}},{1,{24,24},{450,400}},{1,{24,24},{925,825}},{1,{24,24},{975,500}},{1,{24,24},{175,275}},{1,{24,24},{500,900}},{1,{24,24},{400,225}},{1,{24,24},{100,475}},{1,{24,24},{300,625}},{1,{24,24},{575,500}},{1,{24,24},{325,800}},{1,{24,24},{625,775}},{1,{24,24},{575,875}},{1,{24,24},{675,775}},{1,{24,24},{675,200}},{1,{24,24},{550,750}},{1,{24,24},{625,625}},{1,{24,24},{650,325}},{1,{24,24},{800,375}},{1,{24,24},{625,350}},{1,{24,24},{475,825}},{1,{24,24},{775,675}},{1,{24,24},{700,100}},{1,{24,24},{675,75}},{1,{24,24},{250,375}},{1,{24,24},{25,25}},{1,{24,24},{0,325}},{1,{24,24},{875,450}},{1,{24,24},{825,625}},{1,{24,24},{650,100}},{1,{24,24},{850,600}},{1,{24,24},{600,850}},{1,{24,24},{500,275}},{1,{24,24},{725,150}},{1,{24,24},{650,700}},{1,{24,24},{625,0}},{1,{24,24},{800,525}},{1,{24,24},{550,0}},{1,{24,24},{125,50}},{1,{24,24},{975,475}},{2,{24,24},{50,425}},{2,{24,24},{150,50}},{1,{24,24},{300,700}},{1,{24,24},{950,500}},{1,{24,24},{550,875}},{1,{24,24},{475,200}},{1,{24,24},{600,825}},{1,{24,24},{625,800}},{1,{24,24},{650,775}},{1,{24,24},{675,400}},{1,{24,24},{675,750}},{1,{24,24},{325,525}},{2,{24,24},{425,50}},{1,{24,24},{275,125}},{1,{24,24},{700,725}},{1,{24,24},{725,900}},{1,{24,24},{375,150}},{1,{24,24},{800,150}},{1,{24,24},{825,600}},{1,{24,24},{450,100}},{1,{24,24},{850,575}},{1,{24,24},{875,550}},{1,{24,24},{925,500}},{2,{24,24},{100,75}},{1,{24,24},{425,50}},{1,{24,24},{375,700}},{1,{24,24},{200,125}},{1,{24,24},{225,200}},{1,{24,24},{400,625}},{1,{24,24},{200,525}},{1,{24,24},{75,750}},{1,{24,24},{300,25}},{2,{24,24},{0,75}},{1,{24,24},{425,975}},{1,{24,24},{450,950}},{1,{24,24},{150,725}},{1,{24,24},{550,850}},{1,{24,24},{575,825}},{1,{24,24},{550,900}},{1,{24,24},{700,325}},{1,{24,24},{725,675}},{1,{24,24},{800,600}},{2,{24,24},{0,250}},{1,{24,24},{150,600}},{1,{24,24},{825,575}},{1,{24,24},{900,500}},{1,{24,24},{725,475}},{1,{24,24},{300,825}},{1,{24,24},{525,775}},{1,{24,24},{625,725}},{1,{24,24},{750,175}},{1,{24,24},{875,525}},{1,{24,24},{950,850}},{1,{24,24},{975,425}},{1,{24,24},{400,975}},{1,{24,24},{825,225}},{1,{24,24},{925,900}},{1,{24,24},{725,600}},{1,{24,24},{375,375}},{1,{24,24},{325,950}},{1,{24,24},{775,350}},{1,{24,24},{450,75}},{2,{24,24},{175,0}},{1,{24,24},{450,925}},{1,{24,24},{600,700}},{2,{24,24},{75,250}},{1,{24,24},{275,200}},{1,{24,24},{550,450}},{2,{24,24},{250,75}},{1,{24,24},{350,250}},{1,{24,24},{300,375}},{1,{24,24},{500,875}},{1,{24,24},{0,775}},{1,{24,24},{625,675}},{1,{24,24},{50,700}},{1,{24,24},{375,25}},{1,{24,24},{975,350}},{1,{24,24},{600,775}},{1,{24,24},{425,0}},{1,{24,24},{25,625}},{1,{24,24},{625,200}},{1,{24,24},{375,600}},{1,{24,24},{700,675}},{1,{24,24},{525,750}},{1,{24,24},{525,350}},{1,{24,24},{750,625}},{1,{24,24},{375,525}},{1,{24,24},{800,25}},{1,{24,24},{900,475}},{1,{24,24},{250,200}},{1,{24,24},{925,450}},{2,{24,24},{200,325}},{1,{24,24},{850,800}},{1,{24,24},{400,950}},{1,{24,24},{825,550}},{1,{24,24},{450,900}},{1,{24,24},{475,575}},{1,{24,24},{475,875}},{1,{24,24},{500,850}},{1,{24,24},{625,500}},{1,{24,24},{925,325}},{1,{24,24},{275,350}},{1,{24,24},{400,750}},{1,{24,24},{600,750}},{1,{24,24},{25,575}},{1,{24,24},{550,800}},{1,{24,24},{75,175}},{1,{24,24},{675,675}},{1,{24,24},{700,650}},{1,{24,24},{275,925}},{1,{24,24},{675,225}},{1,{24,24},{750,600}},{1,{24,24},{950,750}},{1,{24,24},{675,125}},{1,{24,24},{825,525}},{1,{24,24},{875,475}},{2,{24,24},{100,25}},{1,{24,24},{950,400}},{1,{24,24},{450,675}},{1,{24,24},{800,50}},{1,{24,24},{950,625}},{1,{24,24},{25,775}},{1,{24,24},{625,550}},{1,{24,24},{600,600}},{1,{24,24},{725,75}},{1,{24,24},{625,75}},{1,{24,24},{575,125}},{1,{24,24},{975,450}},{1,{24,24},{150,175}},{1,{24,24},{675,575}},{1,{24,24},{25,375}},{1,{24,24},{425,900}},{1,{24,24},{400,275}},{1,{24,24},{275,600}},{1,{24,24},{975,25}},{1,{24,24},{875,275}},{1,{24,24},{400,525}},{1,{24,24},{550,600}},{1,{24,24},{450,875}},{2,{24,24},{25,275}},{1,{24,24},{75,975}},{1,{24,24},{0,225}},{1,{24,24},{600,725}},{1,{24,24},{25,800}},{1,{24,24},{625,700}},{1,{24,24},{700,625}},{1,{24,24},{650,375}},{1,{24,24},{900,550}},{1,{24,24},{775,550}},{1,{24,24},{850,75}},{1,{24,24},{800,475}},{1,{24,24},{900,425}},{1,{24,24},{325,975}},{1,{24,24},{425,800}},{1,{24,24},{650,725}},{1,{24,24},{350,950}},{1,{24,24},{825,875}},{1,{24,24},{450,850}},{1,{24,24},{250,925}},{1,{24,24},{450,600}},{1,{24,24},{725,725}},{1,{24,24},{575,150}},{1,{24,24},{675,950}},{1,{24,24},{125,350}},{1,{24,24},{800,100}},{1,{24,24},{425,225}},{1,{24,24},{675,625}},{1,{24,24},{450,975}},{1,{24,24},{225,50}},{1,{24,24},{750,550}},{1,{24,24},{550,825}},{2,{24,24},{275,175}},{1,{24,24},{175,375}},{1,{24,24},{825,475}},{1,{24,24},{825,775}},{1,{24,24},{0,375}},{1,{24,24},{750,225}},{1,{24,24},{900,400}},{1,{24,24},{650,25}},{1,{24,24},{300,975}},{1,{24,24},{525,75}},{1,{24,24},{400,875}},{1,{24,24},{425,850}},{1,{24,24},{850,150}},{1,{24,24},{450,825}},{2,{24,24},{50,225}},{1,{24,24},{225,25}},{1,{24,24},{0,400}},{1,{24,24},{625,650}},{1,{24,24},{650,625}},{1,{24,24},{300,50}},{1,{24,24},{550,25}},{1,{24,24},{750,525}},{1,{24,24},{775,500}},{1,{24,24},{925,350}},{1,{24,24},{850,325}},{1,{24,24},{275,0}},{1,{24,24},{975,300}},{1,{24,24},{750,325}},{2,{24,24},{25,475}},{1,{24,24},{325,925}},{1,{24,24},{350,900}},{1,{24,24},{525,600}},{1,{24,24},{750,250}},{1,{24,24},{475,550}},{1,{24,24},{475,775}},{1,{24,24},{400,850}},{1,{24,24},{500,750}},{1,{24,24},{575,275}},{1,{24,24},{750,900}},{1,{24,24},{900,225}},{1,{24,24},{700,550}},{1,{24,24},{0,450}},{1,{24,24},{725,525}},{1,{24,24},{750,500}},{1,{24,24},{800,0}},{1,{24,24},{825,425}},{1,{24,24},{750,300}},{1,{24,24},{175,25}},{1,{24,24},{0,50}},{1,{24,24},{650,875}},{1,{24,24},{75,100}},{1,{24,24},{850,400}},{1,{24,24},{25,75}},{1,{24,24},{875,375}},{1,{24,24},{175,700}},{1,{24,24},{475,250}},{1,{24,24},{950,50}},{1,{24,24},{100,625}},{1,{24,24},{275,175}},{1,{24,24},{575,425}},{1,{24,24},{575,775}},{1,{24,24},{725,375}},{1,{24,24},{125,700}},{1,{24,24},{450,625}},{1,{24,24},{225,625}},{1,{24,24},{250,975}},{1,{24,24},{800,875}},{1,{24,24},{150,225}},{1,{24,24},{425,550}},{1,{24,24},{450,700}},{1,{24,24},{350,875}},{1,{24,24},{350,325}},{1,{24,24},{100,750}},{1,{24,24},{325,900}},{1,{24,24},{400,825}},{1,{24,24},{375,850}},{2,{24,24},{0,225}},{1,{24,24},{25,275}},{1,{24,24},{225,900}},{1,{24,24},{850,225}},{1,{24,24},{475,675}},{1,{24,24},{550,325}},{1,{24,24},{225,525}},{1,{24,24},{600,625}},{1,{24,24},{625,600}},{1,{24,24},{600,575}},{1,{24,24},{650,575}},{1,{24,24},{725,500}},{1,{24,24},{0,750}},{1,{24,24},{675,550}},{1,{24,24},{200,675}},{1,{24,24},{850,375}},{1,{24,24},{525,725}},{1,{24,24},{350,50}},{1,{24,24},{475,475}},{1,{24,24},{950,275}},{1,{24,24},{200,575}},{1,{24,24},{225,975}},{2,{24,24},{75,175}},{1,{24,24},{925,225}},{1,{24,24},{50,925}},{1,{24,24},{325,875}},{1,{24,24},{625,375}},{1,{24,24},{350,400}},{1,{24,24},{350,850}},{1,{24,24},{425,775}},{1,{24,24},{200,900}},{1,{24,24},{550,650}},{1,{24,24},{425,175}},{1,{24,24},{675,525}},{1,{24,24},{950,100}},{1,{24,24},{475,0}},{1,{24,24},{175,50}},{1,{24,24},{650,750}},{1,{24,24},{125,375}},{1,{24,24},{125,525}},{1,{24,24},{550,250}},{1,{24,24},{850,100}},{1,{24,24},{75,575}},{1,{24,24},{825,375}},{1,{24,24},{375,175}},{1,{24,24},{25,225}},{1,{24,24},{650,950}},{1,{24,24},{250,900}},{1,{24,24},{250,400}},{1,{24,24},{975,225}},{1,{24,24},{600,550}},{1,{24,24},{50,600}},{1,{24,24},{0,575}},{1,{24,24},{200,975}},{1,{24,24},{675,250}},{1,{24,24},{625,900}},{1,{24,24},{250,300}},{1,{24,24},{700,50}},{1,{24,24},{875,750}},{1,{24,24},{325,850}},{1,{24,24},{250,475}},{1,{24,24},{325,350}},{1,{24,24},{600,150}},{1,{24,24},{25,175}},{1,{24,24},{175,75}},{1,{24,24},{350,825}},{1,{24,24},{375,725}},{1,{24,24},{400,775}},{1,{24,24},{425,750}},{1,{24,24},{475,700}},{1,{24,24},{300,775}},{1,{24,24},{500,150}},{1,{24,24},{75,625}},{1,{24,24},{475,225}},{1,{24,24},{175,900}},{1,{24,24},{550,625}},{1,{24,24},{200,875}},{1,{24,24},{350,300}},{1,{24,24},{125,200}},{1,{24,24},{300,850}},{1,{24,24},{375,400}},{1,{24,24},{675,500}},{2,{24,24},{25,25}},{1,{24,24},{650,400}},{1,{24,24},{825,350}},{1,{24,24},{175,875}},{1,{24,24},{625,225}},{1,{24,24},{525,450}},{1,{24,24},{950,825}},{1,{24,24},{200,100}},{1,{24,24},{125,25}},{1,{24,24},{750,700}},{1,{24,24},{150,25}},{1,{24,24},{275,725}},{1,{24,24},{50,25}},{1,{24,24},{375,225}},{1,{24,24},{975,200}},{1,{24,24},{225,925}},{1,{24,24},{950,250}},{1,{24,24},{300,125}},{1,{24,24},{450,350}},{1,{24,24},{925,800}},{1,{24,24},{350,800}},{1,{24,24},{425,725}},{1,{24,24},{825,0}},{1,{24,24},{950,300}},{2,{24,24},{150,125}},{1,{24,24},{250,675}},{1,{24,24},{750,400}},{1,{24,24},{225,300}},{1,{24,24},{200,300}},{1,{24,24},{800,350}},{2,{24,24},{450,0}},{1,{24,24},{900,250}},{1,{24,24},{125,475}},{1,{24,24},{425,375}},{1,{24,24},{400,175}},{1,{24,24},{625,325}},{1,{24,24},{975,975}},{1,{24,24},{175,475}},{1,{24,24},{500,725}},{1,{24,24},{750,100}},{1,{24,24},{100,650}},{1,{24,24},{775,275}},{1,{24,24},{275,500}},{1,{24,24},{475,650}},{1,{24,24},{975,375}},{2,{24,24},{300,125}},{1,{24,24},{375,875}},{1,{24,24},{750,50}},{1,{24,24},{425,875}},{2,{24,24},{350,75}},{1,{24,24},{800,325}},{1,{24,24},{250,775}},{1,{24,24},{950,175}},{1,{24,24},{975,150}},{1,{24,24},{200,225}},{1,{24,24},{175,925}},{1,{24,24},{650,550}},{1,{24,24},{175,650}},{1,{24,24},{975,600}},{1,{24,24},{50,725}},{1,{24,24},{0,200}},{1,{24,24},{300,0}},{1,{24,24},{825,300}},{2,{24,24},{325,125}},{1,{24,24},{250,425}},{1,{24,24},{200,450}},{1,{24,24},{200,425}},{2,{24,24},{225,25}},{1,{24,24},{250,25}},{1,{24,24},{375,800}},{1,{24,24},{475,625}},{1,{24,24},{175,450}},{1,{24,24},{450,650}},{1,{24,24},{400,700}},{1,{24,24},{750,125}},{1,{24,24},{850,700}},{1,{24,24},{275,750}},{1,{24,24},{550,550}},{1,{24,24},{500,600}},{1,{24,24},{450,575}},{1,{24,24},{50,100}},{1,{24,24},{600,500}},{1,{24,24},{150,400}},{1,{24,24},{350,450}},{1,{24,24},{100,725}},{1,{24,24},{625,475}},{1,{24,24},{100,425}},{1,{24,24},{300,475}},{1,{24,24},{975,100}},{1,{24,24},{725,175}},{1,{24,24},{700,400}},{1,{24,24},{75,25}},{1,{24,24},{450,225}},{2,{24,24},{250,150}},{1,{24,24},{675,350}},{1,{24,24},{950,425}},{1,{24,24},{925,175}},{1,{24,24},{975,125}},{1,{24,24},{550,475}},{1,{24,24},{500,700}},{1,{24,24},{575,600}},{1,{24,24},{225,850}},{1,{24,24},{250,825}},{1,{24,24},{550,400}},{1,{24,24},{275,800}},{1,{24,24},{375,125}},{1,{24,24},{525,650}},{1,{24,24},{325,750}},{1,{24,24},{400,675}},{1,{24,24},{350,725}},{1,{24,24},{350,650}},{1,{24,24},{225,100}},{1,{24,24},{425,650}},{1,{24,24},{975,275}},{1,{24,24},{525,525}},{1,{24,24},{500,575}},{1,{24,24},{25,50}},{1,{24,24},{100,875}},{1,{24,24},{550,275}},{1,{24,24},{350,75}},{1,{24,24},{500,950}},{1,{24,24},{725,975}},{1,{24,24},{450,775}},{1,{24,24},{275,25}},{1,{24,24},{300,400}},{2,{24,24},{175,25}},{2,{24,24},{325,225}},{1,{24,24},{875,200}},{1,{24,24},{350,475}},{1,{24,24},{50,850}},{1,{24,24},{225,750}},{1,{24,24},{325,575}},{1,{24,24},{925,150}},{1,{24,24},{575,750}},{1,{24,24},{325,150}},{1,{24,24},{275,325}},{1,{24,24},{600,0}},{1,{24,24},{425,300}},{1,{24,24},{850,550}},{1,{24,24},{725,25}},{1,{24,24},{50,650}},{1,{24,24},{125,925}},{1,{24,24},{750,350}},{1,{24,24},{925,425}},{1,{24,24},{350,100}},{1,{24,24},{775,325}},{1,{24,24},{625,425}},{1,{24,24},{0,25}},{1,{24,24},{725,325}},{1,{24,24},{600,450}},{1,{24,24},{375,750}},{1,{24,24},{875,175}},{1,{24,24},{600,275}},{1,{24,24},{925,125}},{1,{24,24},{525,275}},{1,{24,24},{0,275}},{1,{24,24},{925,0}},{1,{24,24},{775,950}},{1,{24,24},{75,950}},{1,{24,24},{175,350}},{1,{24,24},{100,925}},{1,{24,24},{125,900}},{1,{24,24},{175,250}},{1,{24,24},{175,850}},{1,{24,24},{200,825}},{1,{24,24},{225,800}},{1,{24,24},{825,125}},{1,{24,24},{875,250}},{1,{24,24},{425,600}},{1,{24,24},{500,525}},{1,{24,24},{575,450}},{1,{24,24},{325,200}},{1,{24,24},{500,125}},{1,{24,24},{125,750}},{1,{24,24},{300,300}},{1,{24,24},{275,400}},{1,{24,24},{700,25}},{2,{24,24},{100,275}},{2,{24,24},{100,100}},{1,{24,24},{150,925}},{1,{24,24},{750,275}},{1,{24,24},{225,600}},{1,{24,24},{775,250}},{1,{24,24},{325,75}},{1,{24,24},{275,850}},{1,{24,24},{675,100}},{1,{24,24},{875,150}},{1,{24,24},{150,425}},{1,{24,24},{900,125}},{1,{24,24},{350,125}},{1,{24,24},{200,800}},{1,{24,24},{150,325}},{1,{24,24},{975,50}},{1,{24,24},{250,275}},{1,{24,24},{300,275}},{2,{24,24},{75,150}},{1,{24,24},{150,850}},{1,{24,24},{950,75}},{2,{24,24},{150,325}},{1,{24,24},{975,950}},{1,{24,24},{250,575}},{1,{24,24},{525,900}},{1,{24,24},{625,250}},{1,{24,24},{400,600}},{1,{24,24},{425,575}},{1,{24,24},{475,525}},{1,{24,24},{500,500}},{1,{24,24},{100,800}},{1,{24,24},{250,225}},{1,{24,24},{25,750}},{1,{24,24},{525,475}},{1,{24,24},{600,400}},{1,{24,24},{675,325}},{1,{24,24},{575,950}},{1,{24,24},{425,825}},{1,{24,24},{400,425}},{1,{24,24},{675,175}},{1,{24,24},{150,625}},{1,{24,24},{200,175}},{1,{24,24},{550,575}},{1,{24,24},{225,275}},{1,{24,24},{375,0}},{1,{24,24},{350,925}},{1,{24,24},{825,175}},{1,{24,24},{175,400}},{1,{24,24},{25,950}},{1,{24,24},{150,825}},{1,{24,24},{400,550}},{1,{24,24},{525,375}},{1,{24,24},{350,625}},{1,{24,24},{275,700}},{1,{24,24},{500,475}},{1,{24,24},{550,950}},{1,{24,24},{200,475}},{1,{24,24},{225,575}},{1,{24,24},{775,75}},{1,{24,24},{275,375}},{1,{24,24},{725,250}},{1,{24,24},{600,200}},{1,{24,24},{100,250}},{1,{24,24},{200,550}},{1,{24,24},{875,500}},{1,{24,24},{850,125}},{1,{24,24},{925,50}},{1,{24,24},{975,0}},{1,{24,24},{0,950}},{1,{24,24},{25,850}},{1,{24,24},{675,150}},{1,{24,24},{375,300}},{1,{24,24},{125,125}},{1,{24,24},{25,550}},{1,{24,24},{25,925}},{1,{24,24},{100,850}},{1,{24,24},{800,500}},{1,{24,24},{275,75}},{1,{24,24},{225,725}},{1,{24,24},{125,800}},{1,{24,24},{775,25}},{1,{24,24},{275,675}},{1,{24,24},{550,100}},{1,{24,24},{925,950}},{1,{24,24},{625,975}},{1,{24,24},{900,600}},{1,{24,24},{350,600}},{1,{24,24},{650,300}},{1,{24,24},{675,275}},{1,{24,24},{900,50}},{1,{24,24},{50,875}},{1,{24,24},{75,850}},{1,{24,24},{50,575}},{1,{24,24},{175,750}},{1,{24,24},{300,225}},{1,{24,24},{225,700}},{1,{24,24},{675,475}},{1,{24,24},{525,225}},{2,{24,24},{200,150}},{1,{24,24},{550,375}},{1,{24,24},{525,400}},{1,{24,24},{850,350}},{2,{24,24},{225,150}},{2,{24,24},{350,150}},{1,{24,24},{825,100}},{1,{24,24},{0,125}},{1,{24,24},{875,50}},{1,{24,24},{75,825}},{1,{24,24},{525,800}},{2,{24,24},{350,25}},{1,{24,24},{250,325}},{1,{24,24},{250,650}},{1,{24,24},{275,625}},{1,{24,24},{675,300}},{1,{24,24},{125,325}},{1,{24,24},{0,300}},{1,{24,24},{875,925}},{1,{24,24},{600,125}},{1,{24,24},{50,300}},{1,{24,24},{175,675}},{1,{24,24},{425,475}},{1,{24,24},{475,425}},{1,{24,24},{325,650}},{1,{24,24},{625,275}},{1,{24,24},{25,475}},{1,{24,24},{750,150}},{1,{24,24},{725,0}},{1,{24,24},{225,650}},{1,{24,24},{800,225}},{1,{24,24},{650,925}},{1,{24,24},{100,775}},{1,{24,24},{75,800}},{1,{24,24},{325,550}},{1,{24,24},{250,525}},{1,{24,24},{525,200}},{2,{24,24},{350,200}},{1,{24,24},{900,150}},{1,{24,24},{325,675}},{2,{24,24},{275,100}},{1,{24,24},{25,825}},{1,{24,24},{125,725}},{1,{24,24},{775,650}},{1,{24,24},{350,500}},{1,{24,24},{175,150}},{1,{24,24},{725,400}},{1,{24,24},{900,975}},{1,{24,24},{775,450}},{1,{24,24},{775,225}},{1,{24,24},{825,25}},{1,{24,24},{500,200}},{1,{24,24},{550,225}},{1,{24,24},{150,675}},{2,{24,24},{50,400}},{1,{24,24},{525,550}},{1,{24,24},{650,175}},{1,{24,24},{750,75}},{1,{24,24},{875,600}},{1,{24,24},{275,425}},{1,{24,24},{250,500}},{1,{24,24},{175,625}},{1,{24,24},{0,700}},{1,{24,24},{125,0}},{1,{24,24},{200,600}},{1,{24,24},{250,550}},{1,{24,24},{400,350}},{1,{24,24},{25,700}},{1,{24,24},{800,400}},{1,{24,24},{625,175}},{1,{24,24},{675,450}},{1,{24,24},{800,450}},{1,{24,24},{625,25}},{1,{24,24},{925,375}},{1,{24,24},{0,500}},{1,{24,24},{675,425}},{1,{24,24},{425,350}},{1,{24,24},{450,325}},{1,{24,24},{225,550}},{1,{24,24},{650,125}},{1,{24,24},{375,350}},{1,{24,24},{700,75}},{1,{24,24},{725,50}},{1,{24,24},{150,200}},{1,{24,24},{775,0}},{1,{24,24},{625,750}},{1,{24,24},{75,675}},{1,{24,24},{25,125}},{1,{24,24},{575,50}},{1,{24,24},{825,75}},{1,{24,24},{800,175}},{1,{24,24},{275,475}},{1,{24,24},{275,525}},{1,{24,24},{275,150}},{1,{24,24},{425,500}},{1,{24,24},{50,675}},{1,{24,24},{150,575}},{1,{24,24},{75,75}},{1,{24,24},{425,400}},{1,{24,24},{450,275}},{1,{24,24},{100,700}},{1,{24,24},{225,225}},{1,{24,24},{375,325}},{1,{24,24},{50,625}},{1,{24,24},{0,475}},{1,{24,24},{75,875}},{1,{24,24},{525,150}},{1,{24,24},{675,700}},{1,{24,24},{750,450}},{1,{24,24},{275,825}},{1,{24,24},{450,200}},{1,{24,24},{150,350}},{1,{24,24},{650,650}},{1,{24,24},{875,700}},{1,{24,24},{575,75}},{2,{24,24},{175,150}},{1,{24,24},{150,475}},{1,{24,24},{75,525}},{1,{24,24},{975,925}},{1,{24,24},{450,175}},{1,{24,24},{475,150}},{1,{24,24},{0,600}},{1,{24,24},{375,250}},{1,{24,24},{925,250}},{2,{24,24},{125,225}},{1,{24,24},{100,150}},{1,{24,24},{125,650}},{1,{24,24},{125,450}},{1,{24,24},{75,200}},{1,{24,24},{625,450}},{1,{24,24},{700,575}},{1,{24,24},{400,25}},{1,{24,24},{525,575}},{1,{24,24},{525,25}},{2,{24,24},{200,25}},{1,{24,24},{350,175}},{1,{24,24},{625,150}},{1,{24,24},{175,325}},{1,{24,24},{425,75}},{1,{24,24},{25,450}},{1,{24,24},{500,550}},{1,{24,24},{125,975}},{1,{24,24},{575,700}},{1,{24,24},{225,150}},{2,{24,24},{400,50}},{1,{24,24},{250,50}},{1,{24,24},{150,75}}}}}
local iconIndices: { string } = icons[1]
local idIndices: { string } = icons[2]
local iconRegistry: { [number]: { number | { number } } } = icons[3]

Lucide.Icons = iconIndices
function Lucide.GetAsset(name: string)
	local size = 48

	local iconIndex = table.find(iconIndices, name)

	if not iconIndex then
		return nil
	end

	local currentDifference = math.huge
	local currentSize = size

	for registrySize, _ in iconRegistry do
		local diff = math.abs(size - registrySize)

		if diff < currentDifference then
			currentDifference = diff
			currentSize = registrySize
		end
	end

	local icon = iconRegistry[currentSize][iconIndex]
	if icon then
		return {
			IconName = name,
			Url = idIndices[icon[1]],
			ImageRectSize = Vector2.new(icon[2][1], icon[2][2]),
			ImageRectOffset = Vector2.new(icon[3][1], icon[3][2]),
		}
	end

	return nil
end

return Lucide
end
return use("main")
