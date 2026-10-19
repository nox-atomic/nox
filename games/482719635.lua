if not game:IsLoaded() then
	game.Loaded:Wait()
end

local SCRIPT_VERSION = "v0.2"
local GAME_NAME = "Loot To Forge"
local GAME_KEY = "LootToForge"
local UI_SOURCE_URL = "https://raw.githubusercontent.com/nox-atomic/atomic-v1/main/Source.luau"
local SCRIPT_SOURCE_URL = "https://raw.githubusercontent.com/nox-atomic/atomic-v1/main/NOX_LootToForge.lua"
local DISCORD_INVITE = "https://discord.gg/Qb8edHdfU6"
local WEBSITE_LINK = "https://rscripts.net/@_NOX"
local NOX_ICON = "rbxassetid://123052226839946" -- open/close button icon

if game.GameId ~= 10684750879 then
	game:GetService("Players").LocalPlayer:Kick("NOX HUB: this script is for Loot To Forge only")
	return
end

local function createFeatureAPI(namespace)
	assert(type(namespace) == "string" and namespace ~= "", "namespace required")
	assert(type(getgenv) == "function", "getgenv unavailable")
	local env = getgenv()
	assert(type(env) == "table", "getgenv did not return a table")
	local previous = env[namespace]
	if previous ~= nil then
		assert(type(previous) == "table" and type(previous.Unload) == "function", "namespace occupied")
		local ok, err = pcall(previous.Unload)
		if not ok then
			warn("Previous cleanup: " .. tostring(err))
		end
	end

	local API = {
		State = {},
		Unloaded = false,
	}
	local cleanup = {}

	function API.Track(dispose)
		assert(type(dispose) == "function", "cleanup must be callable")
		if API.Unloaded then
			local ok, err = pcall(dispose)
			if not ok then
				warn("Cleanup: " .. tostring(err))
			end
		else
			table.insert(cleanup, dispose)
		end
		return dispose
	end

	function API.Unload()
		if API.Unloaded then
			return
		end
		API.Unloaded = true
		for index = #cleanup, 1, -1 do
			local dispose = table.remove(cleanup, index)
			local ok, err = pcall(dispose)
			if not ok then
				warn("Cleanup: " .. tostring(err))
			end
		end
		table.clear(API.State)
		if env[namespace] == API then
			env[namespace] = nil
		end
	end

	env[namespace] = API
	return API
end

local function attachUI(API, Window)
	assert(type(API) == "table" and type(API.Track) == "function", "FeatureAPI required")
	assert(type(Window) == "table" and type(Window.Destroy) == "function", "UI window required")
	API.Track(function()
		pcall(function()
			Window:Destroy()
		end)
	end)
	local gui = Window.Gui
	if typeof(gui) == "Instance" then
		local destroying = gui.Destroying:Connect(function()
			task.defer(API.Unload)
		end)
		API.Track(function()
			destroying:Disconnect()
		end)
	end
end

local API = createFeatureAPI("NOX_" .. GAME_KEY)

if not LPH_OBFUSCATED then
    local function Passthrough(fn) return fn end
    LPH_JIT, LPH_JIT_MAX, LPH_NO_VIRTUALIZE = Passthrough, Passthrough, Passthrough
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

local LSS = setmetatable({}, {
    __newindex = function(self, key, value)
        rawset(self, key, type(value) == "function" and LPH_JIT(value) or value)
    end,
})

LSS.Config = {
    SaveFolder = "NOX_LootToForge",
    Website = WEBSITE_LINK,
    UpdateLog = {
        { "2026-10-06", "Auto click rate control and typing pause\nSingle-worker fast loops\nRetry backoff for failed jobs\nString-ID training areas fixed\nAuto reconnect deduplicated\nRace and coin loops stop after unload" },
        { "2026-10-04", "Spawn Scrolls, Tickets & Stones\nDupe Whole Inventory\nAdd Season Coins (OP)\nFaster Tower farm\nRemoved keybinds from auto features\nMax Gear picks Exclusive gear\nSpawn Gear (OP)\nPotions (OP)\nFixed Auto World Boss\nBoss Server Hop\nAuto Sell keeps your best base gear\nMax Gear now goes to +20, much faster\nFixed freeze when loading the script\nUpdated for the new game version\nAuto Sell keeps items you locked\nSteadier Boss Server Hop" },
        { "2026-10-03", "Fixed World Boss, Auto Click & Codes\nImproved Auto Train\nAuto rune detection" },
    },
    ReloadSource = ([[
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(2)
local url = %q
local ok, body = pcall(game.HttpGet, game, url)
if not (ok and type(body) == "string") then
    local requester = request or http_request or (syn and syn.request) or (http and http.request)
    local sent, reply = pcall(requester, { Url = url, Method = "GET" })
    body = sent and type(reply) == "table" and reply.Body
end
if type(body) == "string" then loadstring(body)() end]]):format(SCRIPT_SOURCE_URL),
    LoadTimeout = 30,
    RemoteTimeout = 10,
    RequireTimeout = 3,
    MaxFailures = 5,
    FailWindow = 10,
    AlertTries = 20,
    AlertDelay = 0.5,
    TickDelay = 0.2,
    StatusInterval = 2,
    PumpInterval = 0.25,
    RefillAmount = 100000,
    OwnedOresLabel = "Owned ores",
    AcquireRounds = 300,
    StoneWorkers = 8,
    StoneCallsPerWorker = 15,
    TowerWorkers = 128,
    CoinFarmTimeout = 600,
    PotionStack = 100000,
    TowerCallsPerWorker = 25,
    GearForgeTries = 15,
    GearEnhanceTries = 2,
    GearEnhanceWorkers = 8,
    SlotEnhanceRounds = 200,
    ClickInterval = 0.16,
    RetryBase = 0.25, RetryMax = 2,
    ForgeTargets = {
        { name = "Great Weapon", forgeType = "Weapon", ores = 13 },
        { name = "Katana", forgeType = "Weapon", ores = 4 },
        { name = "Armor", forgeType = "Armor", ores = 11 },
        { name = "Hat", forgeType = "Armor", ores = 4 },
    },
    GearSlots = {
        { slot = "Weapon", forgeType = "Weapon", ores = 13 },
        { slot = "Armor", forgeType = "Armor", ores = 11 },
        { slot = "Hat", forgeType = "Armor", ores = 4 },
    },
    GearTypes = { "Weapon", "Armor", "Hat" },
    EnchantPriority = { "Poison_3", "Thunder_3", "Ice_3", "Fire_3", "Poison_2", "Thunder_2", "Ice_2", "Fire_2" },
    RuneMinTier = 2,
    EnchantRefill = 50,
    ForgeCountMax = 30,
    PlanSlice = 0.004,
    HuntBatch = 40,
    HuntWorkers = 4,
    HuntMaxForges = 4000,
    HuntTargetHits = 3,
    IndexInterval = 60,
    IndexLevelClaims = 50,
    ClaimIdScan = 20,
    ClaimInterval = 30,
    SeasonInterval = 60,
    BossCards = 8,
    BossAttackIds = { Katana = "K_ATK_1", Great = "G_ATK_1" },
    BossHitsPerTick = 30,
    BossHitGap = 0.02,
    BossJoinSettle = 1,
    BossClaimDelay = 3.5,
    BossStandHeight = 3,
    BossStandBack = 8,
    BossReach = 25,
    UpgradeInterval = 5,
    EquipInterval = 3,
    SellInterval = 1,
    RebirthInterval = 2,
    BossInterval = 1,
    BossHopInterval = 5,
    BossHopLead = 150,
    BossHopAfter = 8,
    BossHopFlag = "bosshop.txt",
    BossHopResume = 180,
    BossHopServers = "bossservers.json",
    HopListTtl = 120,
    HopBackoffStart = 5,
    HopBackoffMax = 60,
    HopGiveUp = 8,
    HopStall = 30,
    HopGap = 15,
    TrainRejoinDelay = 0.3,
    TrainWatchdog = 3,
    TrainAcceptWait = 1.5,
    TrainExitTries = 3,
    TrainSettle = 0.5,
    WarnCooldown = 30,
    WarnMemory = 64,
    KillAuraInterval = 0.25,
    KillDamage = 1e30,
    RaceRollDelay = 0.45,
    RejoinDelay = 5,
    CodeReplyWait = 1.5,
    Codes = { "PET" },
    Needs = {
        CollectOre = { "Remote.Stage.StageFinishedRF", "Remote.Stage.GetOreRF", "Remote.Stage.ClaimedAllOreRE", "Config.Stage.Helper", "Config.Ore.Config" },
        SuperLootAura = { "Remote.SuperLoot.KillSuperLootRE", "Remote.SuperLoot.RefreshSuperLootRE", "Remote.Stage.GetOreRF" },
        AutoWorldBoss = { "Remote.WorldBoss.IntoWorldBossFight", "Remote.WorldBoss.BossDeadRE", "Remote.Attack.UseAnyATKRE", "Remote.Attack.AttackEnemyServiceRE" },
        AutoIndex = { "Remote.Forge.ForgeRF", "Remote.Index.TryClaimIndexExpRF", "Utils.ForgeUtils", "Config.Weapon.Config", "Config.Armor.Config" },
        MaxGear = { "Utils.BalanceUtils", "Remote.Forge.ForgeRF", "Remote.Backpack.EnhantEquipmentRF", "Remote.Backpack.EnchantRE", "Config.Enhant.Config", "Config.EnchStone.Show" },
        AutoEquip = { "Utils.BalanceUtils", "Remote.Backpack.TryEquipItemRE", "Config.Weapon.Helper", "Config.Armor.Helper" },
        AutoForge = { "Remote.Forge.ForgeRF", "Remote.Backpack.TrySellItemRE", "Config.Ore.Config" },
        AutoSell = { "Remote.Backpack.TrySellItemRE", "Config.Weapon.Config", "Config.Armor.Config" },
        AutoTrain = { "Remote.Train.IntoAutoTrainRE", "Remote.Train.ExitAutoTrainRE", "Config.TrainArea.Config" },
        AutoRebirth = { "Remote.Rebirth.TryRebirthRE", "Config.Rebirth.Helper" },
        AutoUpgrade = { "Remote.Upgrade.UpgradeOnceRE", "Config.Upgrade.Config" },
        AutoTower = { "Remote.Dungeon.TryIntoDungeonRF", "Remote.Dungeon.StartRoundRE", "Remote.Dungeon.CompleteRoundRF", "Config.Dungeon.Config.LootTab" },
        AutoSeason = { "Remote.Season.TryClaimDailyTicRE", "Remote.Season.ExchangeGoodsRE", "Remote.Season.LuckRE", "Config.Season.GoodsConfig" },
        AutoClaim = { "Remote.Offline.TryClaimOfflineRewardRE", "Remote.Online.TryClaimRE" },
        AutoRace = { "Remote.Class.LuckOnceRE", "Config.Class.Config" },
        AutoBestRace = { "Remote.Class.ChangeEquipedIndexRE", "Config.Class.Config" },
        KeepOre = { "Remote.Stage.LostAllOreRF" },
    },
    KaitunToggles = { "MaxGear", "AutoEquip", "AutoForge", "AutoSell", "AutoTrain", "AutoRebirth", "AutoUpgrade", "AutoClaim", "AutoSeason", "KillAura", "SuperLootAura", "AutoWorldBoss", "AutoTower", "GodMode", "AutoBestRace" },
}

local Config = LSS.Config
local Remote = ReplicatedStorage:WaitForChild("Remote", Config.LoadTimeout)
local GameConfig = ReplicatedStorage:WaitForChild("Config", Config.LoadTimeout)

LSS.State = {
    Alive = true,
    Busy = false,
    Lock = nil,
    Failures = {},
    WorkerLoops = {},
    Halted = {},
    InTower = false,
    Entering = false,
    GearForged = false,
    TrainArea = nil,
    TrainPending = nil,
    TrainEntering = false,
    TrainGen = 0,
    TrainFiredAt = 0,
    TrainRebirth = nil,
    BossReturn = nil,
    TrainLevel = nil,
    TrainNilSince = nil,
    Warned = {},
    WarnedCount = 0,
    LastRun = {},
    Profile = nil,
    GearNote = nil,
    IndexNote = nil,
    TowerLoot = 0,
    OreLabels = {},
    SpawnLabels = {},
    GearLabels = {},
    BossHopping = false,
    HopFails = 0,
    HopBackoff = nil,
    HopBlockedUntil = 0,
    HopQueued = false,
    BossDone = nil,
    MissingLabels = {},
    OreStage = {},
    Plans = {},
    Runes = nil,
    Conns = {},
    Opt = {
        MaxGear = false,
        AutoEquip = false,
        EnhanceTarget = 20,
        GearForge = true,
        GearEnchant = true,
        GearEnhance = true,
        EnchantPriority = {},
        EnhanceSlot = "Weapon",
        ForgeSellJunk = false,
        ForgePerTick = 10,
        BossCards = true,
        SeasonSpin = true,
        SeasonGoods = { ["4"] = true, ["7"] = true },
        AutoBestRace = false,
        GodMode = false,
        KeepOre = false,
        CollectOre = false,
        FarmWorkers = 24,
        Stage = nil,
        CollectRarities = {},
        KillAura = false,
        SuperLootAura = false,
        AutoWorldBoss = false,
        BossHop = false,
        AutoForge = false,
        ForgeTarget = "Great Weapon",
        ForgeOre = nil,
        ForgeRarities = {},
        KeepPerOre = 0,
        BestOreFirst = false,
        AutoSell = false,
        SellTypes = { Weapon = true, Armor = true, Hat = true },
        SellRarities = {},
        KeepPerItem = 1,
        AutoIndex = false,
        IndexTypes = { Weapon = true, Armor = true, Hat = true },
        MissingItem = nil,
        AutoTrain = false,
        AutoClick = false,
        ClickRate = 6,
        ClickPauseTyping = true,
        AutoRebirth = false,
        AutoUpgrade = false,
        Upgrades = {},
        AutoClaim = false,
        AutoSeason = false,
        AutoTower = false,
        AutoRace = false,
        TargetRace = nil,
        SpawnItem = nil,
        SpawnAmount = 100000,
        CoinTarget = 1000000,
        SpawnGear = nil,
        GearCopies = 1,
        SpeedOn = false,
        WalkSpeed = 60,
        InfJump = false,
        AutoRejoin = false,
        LowGraphics = false,
    },
}

local State = LSS.State

LSS.GameLib = { Loaded = {}, Failed = {}, Apis = {}, Deferred = {} }

function LSS.GameLib.RequireAsGame(module)
    local done, ok, loaded = false, false, nil
    task.spawn(function()
        pcall(setthreadidentity, 2)
        local read, identity = pcall(getthreadidentity)
        if read and identity == 2 then
            ok, loaded = pcall(require, module)
        end
        done = true
    end)
    local deadline = os.clock() + Config.RequireTimeout
    while not done and os.clock() < deadline do
        task.wait()
    end
    return ok, loaded
end

function LSS.GameLib.Require(module)
    local cached = LSS.GameLib.Loaded[module]
    if cached ~= nil or LSS.GameLib.Failed[module] then return cached end

    local ok, loaded = pcall(require, module)
    if not ok then
        local firstErr = loaded
        ok, loaded = LSS.GameLib.RequireAsGame(module)
        if not ok then
            LSS.GameLib.Failed[module] = tostring(firstErr)
            warn("[LootToForge] require", module:GetFullName(), firstErr)
            return nil
        end
    end
    LSS.GameLib.Loaded[module] = loaded
    return loaded
end

function LSS.GameLib.CallAsGame(fn, ...)
    local args = table.pack(...)
    local box
    task.defer(function()
        pcall(setthreadidentity, 2)
        box = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
    end)
    local deadline = os.clock() + Config.RequireTimeout
    while not box and os.clock() < deadline do
        task.wait()
    end
    if not box then return false, "game call timed out" end
    return table.unpack(box, 1, box.n)
end

function LSS.GameLib.Call(fn, ...)
    if not LSS.GameLib.Deferred[fn] then
        local result = table.pack(pcall(fn, ...))
        if result[1] or not tostring(result[2]):find("non-RobloxScript", 1, true) then
            if not result[1] then error(result[2], 0) end
            return table.unpack(result, 2, result.n)
        end
        LSS.GameLib.Deferred[fn] = true
    end
    local result = table.pack(LSS.GameLib.CallAsGame(fn, ...))
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

function LSS.GameLib.Api(module)
    local api = LSS.GameLib.Apis[module]
    if api then return api end
    local loaded = LSS.GameLib.Need(module)
    api = setmetatable({}, {
        __index = function(self, key)
            local value = loaded[key]
            if type(value) ~= "function" then return value end
            local wrapped = function(...)
                return LSS.GameLib.Call(value, ...)
            end
            rawset(self, key, wrapped)
            return wrapped
        end,
    })
    LSS.GameLib.Apis[module] = api
    return api
end

function LSS.GameLib.Need(module)
    local loaded = LSS.GameLib.Require(module)
    if loaded == nil then
        error(("game data %s.%s can't be read on this executor"):format(module.Parent.Name, module.Name), 0)
    end
    return loaded
end

function LSS.GameLib.Find(path)
    local node = ReplicatedStorage
    for part in path:gmatch("[^%.]+") do
        node = node and node:FindFirstChild(part)
    end
    if node then return node end
    local folder, name = path:match("^Remote%.([^%.]+)%.([^%.]+)$")
    return folder and LSS.Util.FindRemote(folder, name)
end

function LSS.GameLib.Missing()
    local missing = {}
    for idx, paths in pairs(Config.Needs) do
        for _, path in ipairs(paths) do
            if not LSS.GameLib.Find(path) then
                missing[idx] = missing[idx] or {}
                table.insert(missing[idx], path)
            end
        end
    end
    return missing
end

for _, name in ipairs({ "Util", "Data", "Stage", "Ore", "Spawn", "Potion", "Forge", "Sell", "Gear", "Index", "Level", "Upgrade", "Tower", "Boss", "Season", "Claim", "SuperLoot", "Combat", "Guard", "Race", "Movement", "Session", "Scheduler" }) do
    LSS[name] = {}
end

-- Exact new names after a game update can be pinned here: ["OldFolder.OldName"] = { "NewFolder.NewName" }
Config.RemoteAliases = Config.RemoteAliases or {}

do
    local REMOTE_CLASSES = { RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true }
    local GENERIC = { try = true, re = true, rf = true, event = true, func = true, ["function"] = true, remote = true, request = true, once = true }
    local SYNONYM = {
        into = "enter", enter = "enter", join = "enter",
        exit = "exit", leave = "exit", quit = "exit",
        finish = "finish", finished = "finish", complete = "finish", completed = "finish",
        claim = "claim", claimed = "claim",
    }

    -- "TryIntoDungeonRF" -> { into/enter, dungeon } (the Try/RE/RF noise is dropped, synonyms are merged)
    local function Tokens(name)
        local text = name:gsub("R[EF]$", ""):gsub("Events?$", ""):gsub("Functions?$", ""):gsub("Func$", "")
        text = text:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
        local set, size = {}, 0
        for word in text:lower():gmatch("%w+") do
            word = SYNONYM[word] or word
            if not GENERIC[word] and not set[word] then
                set[word] = true
                size += 1
            end
        end
        return set, size
    end

    local function Subset(a, b)
        for token in pairs(a) do
            if not b[token] then return false end
        end
        return true
    end

    -- a name ending in RF must be a RemoteFunction, RE must be an event, anything else may be either
    local function ClassFits(name, className)
        if name:find("RF$") or name:find("Function$") then return className == "RemoteFunction" end
        if name:find("RE$") or name:find("Event$") then return className ~= "RemoteFunction" end
        return true
    end

    local index, indexAt = {}, -10
    local function Index(force)
        if not force and os.clock() - indexAt < 2 then return index end
        indexAt = os.clock()
        local list = {}
        local ok, all = pcall(function() return ReplicatedStorage:GetDescendants() end)
        for _, inst in ipairs(ok and all or {}) do
            if REMOTE_CLASSES[inst.ClassName] then
                local tokens, size = Tokens(inst.Name)
                list[#list + 1] = {
                    Inst = inst,
                    Name = inst.Name,
                    Class = inst.ClassName,
                    Folder = inst.Parent and inst.Parent.Name or "",
                    Path = inst:GetFullName():lower(),
                    Tokens = tokens,
                    Size = size,
                    InRemote = Remote ~= nil and inst:IsDescendantOf(Remote),
                }
            end
        end
        index = list
        return list
    end

    local function Resolve(folder, name)
        local want, wantSize = Tokens(name)
        if wantSize == 0 then return nil end
        local folderKey = folder:lower()
        local best, bestScore, second = nil, 0, 0

        for _, c in ipairs(Index()) do
            if ClassFits(name, c.Class) then
                local sameFolder = c.Folder:lower() == folderKey
                local inPath = c.Path:find(folderKey, 1, true) ~= nil
                local score = 0
                if c.Name == name then
                    score = 100
                elseif c.Size > 0 and (Subset(want, c.Tokens) or Subset(c.Tokens, want)) then
                    local common = 0
                    for token in pairs(want) do
                        if c.Tokens[token] then common += 1 end
                    end
                    -- a one-word name only matches a longer one when it sits in the same folder
                    if c.Size == wantSize or inPath or math.min(c.Size, wantSize) > 1 then
                        score = 50 + 30 * common / (wantSize + c.Size - common)
                    end
                end
                if score > 0 then
                    if sameFolder then score += 20 elseif inPath then score += 10 end
                    if c.InRemote then score += 5 end
                    if score > bestScore then
                        second = bestScore
                        best, bestScore = c, score
                    elseif score > second and c.Inst ~= best.Inst then
                        second = score
                    end
                end
            end
        end
        if best and bestScore >= 60 and bestScore - second >= 5 then return best.Inst end
        return nil
    end

    local resolved, missUntil, announced, deadUntil = {}, {}, {}, {}

    local function FromAlias(key)
        for _, alias in ipairs(Config.RemoteAliases[key] or {}) do
            local aliasFolder, aliasName = alias:match("^([^%.]+)%.([^%.]+)$")
            local holder = aliasFolder and Remote:FindFirstChild(aliasFolder)
            local hit = holder and holder:FindFirstChild(aliasName) or Remote:FindFirstChild(aliasName or alias, true)
            if hit then return hit end
        end
        return nil
    end

    function LSS.Util.FindRemote(folder, name)
        if not Remote then return nil end
        local holder = Remote:FindFirstChild(folder)
        local direct = holder and holder:FindFirstChild(name)
        if direct then return direct end

        local key = folder .. "." .. name
        local cached = resolved[key]
        if cached and cached.Parent then return cached end
        if (missUntil[key] or 0) > os.clock() then return nil end

        local hit = FromAlias(key) or Resolve(folder, name)
        if hit then
            resolved[key] = hit
            if not announced[key] then
                announced[key] = true
                print(("[LootToForge] remote %s -> %s"):format(key, hit:GetFullName()))
            end
            return hit
        end
        missUntil[key] = os.clock() + 3
        return nil
    end

    local dumped = false
    function LSS.Util.DumpRemotes(missing)
        if dumped and not missing then return end
        dumped = true

        local lines = {
            ("-- Loot To Forge remote dump | GameId %s | PlaceId %s"):format(tostring(game.GameId), tostring(game.PlaceId)),
            "",
            "== unresolved ==",
        }
        for idx, paths in pairs(missing or {}) do
            lines[#lines + 1] = idx .. ": " .. table.concat(paths, ", ")
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "== ReplicatedStorage children =="
        for _, child in ipairs(ReplicatedStorage:GetChildren()) do
            lines[#lines + 1] = child:GetFullName() .. " [" .. child.ClassName .. "]"
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "== remotes =="
        local rows = {}
        for _, c in ipairs(Index(true)) do
            rows[#rows + 1] = c.Inst:GetFullName() .. " [" .. c.Class .. "]"
        end
        table.sort(rows)
        for _, row in ipairs(rows) do
            lines[#lines + 1] = row
        end
        local text = table.concat(lines, "\n")

        local saved = pcall(function()
            if makefolder and isfolder and not isfolder(Config.SaveFolder) then makefolder(Config.SaveFolder) end
            writefile(Config.SaveFolder .. "/remotes_dump.txt", text)
        end)
        local copy = setclipboard or toclipboard
        local copied = copy ~= nil and pcall(copy, text)
        warn(("[LootToForge] some game remotes were renamed. %d remotes listed%s%s"):format(
            #rows,
            saved and (" in " .. Config.SaveFolder .. "/remotes_dump.txt") or "",
            copied and " (copied to clipboard)" or ""))
    end

    function LSS.Util.Remote(folder, name)
        local remote = LSS.Util.FindRemote(folder, name)
        if remote then return remote end

        local key = folder .. "." .. name
        if (deadUntil[key] or 0) > os.clock() then
            error(("remote %s not found"):format(key), 0)
        end

        local deadline = os.clock() + Config.RemoteTimeout
        while not remote and os.clock() < deadline do
            task.wait(0.25)
            missUntil[key] = nil
            remote = LSS.Util.FindRemote(folder, name)
        end
        if remote then return remote end

        deadUntil[key] = os.clock() + 30
        LSS.Util.DumpRemotes()
        error(("remote %s not found"):format(key), 0)
    end
end

function LSS.Util.HttpGet(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and type(body) == "string" then return body end

    local send = request or http_request or (syn and syn.request) or (http and http.request)
    if not send then return nil, tostring(body) end
    local sent, response = pcall(send, { Url = url, Method = "GET" })
    if not sent then return nil, tostring(response) end
    if type(response) ~= "table" or response.StatusCode ~= 200 or type(response.Body) ~= "string" then
        return nil, "HTTP " .. tostring(type(response) == "table" and response.StatusCode)
    end
    return response.Body
end

function LSS.Util.Alert(text, detail)
    -- Tidak ada notifikasi samping; cukup log ke console.
    warn("[LootToForge] menu:", text, detail or "")
end

function LSS.Util.WarnJob(key, err)
    local stamp = key .. tostring(err):match("[^\n]*")
    local now = os.clock()
    if now - (State.Warned[stamp] or -Config.WarnCooldown) < Config.WarnCooldown then return end

    if not State.Warned[stamp] then
        State.WarnedCount += 1
        if State.WarnedCount > Config.WarnMemory then
            table.clear(State.Warned)
            State.WarnedCount = 1
        end
    end
    State.Warned[stamp] = now
    warn("[LootToForge]", key, err)
end

function LSS.Util.Try(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        warn("[LootToForge]", err)
    end
    return ok, err
end

function LSS.Util.Tier(id)
    return tonumber(tostring(id):match("%d+")) or 0
end

function LSS.Util.Abbreviate(number)
    local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp" }
    local index = 1
    while number >= 1000 and index < #units do
        number /= 1000
        index += 1
    end
    return (index == 1 and "%d%s" or "%.2f%s"):format(number, units[index])
end

function LSS.Util.HighestKey(configTable)
    local bestKey, bestTier = nil, -1
    for key in pairs(configTable) do
        local tier = LSS.Util.Tier(key)
        if tier > bestTier then
            bestKey, bestTier = key, tier
        end
    end
    return bestKey
end

function LSS.Util.WaitAll(workers, job)
    local pending = workers
    for _ = 1, workers do
        task.spawn(function()
            LSS.Util.Try(job)
            pending -= 1
        end)
    end
    local deadline = os.clock() + Config.RemoteTimeout * 3
    while pending > 0 and os.clock() < deadline do
        task.wait(0.1)
    end
end

function LSS.Util.RarityNames()
    local helper = LSS.GameLib.Api(GameConfig.Rarity.Helper)
    local names = {}
    for level = 1, 20 do
        local name = helper.GetRarityByLevel(level)
        if not name then break end
        table.insert(names, name)
    end
    return names
end

function LSS.Util.AllSet(list)
    local set = {}
    for _, name in ipairs(list) do
        set[name] = true
    end
    return set
end

function LSS.Util.Exclusive(name, fn, ...)
    if State.Lock then return false end
    State.Lock = name
    local ok, result = LSS.Util.Try(fn, ...)
    State.Lock = nil
    return ok, result
end

function LSS.Data.Get()
    State.Profile = LSS.Util.Remote("Profile", "GetTotalDataRF"):InvokeServer()
    return State.Profile
end

function LSS.Data.Count(profile, itemId)
    local total = 0
    for _, entry in pairs(profile.Backpack.have) do
        if entry.ID == itemId then
            total += entry.Number or 1
        end
    end
    return total
end

function LSS.Data.Uuid(profile, itemId)
    for uuid, entry in pairs(profile.Backpack.have) do
        if entry.ID == itemId and (entry.Number or 0) >= 1 then
            return uuid
        end
    end
    return nil
end

function LSS.Data.Snapshot()
    local seen = {}
    for uuid in pairs(LSS.Data.Get().Backpack.have) do
        seen[uuid] = true
    end
    return seen
end

function LSS.Data.NewGear(before)
    local fresh = {}
    for uuid, entry in pairs(LSS.Data.Get().Backpack.have) do
        if not before[uuid] and entry.Type ~= "Ore" and entry.Type ~= "Material" and entry.Type ~= "EnchStone" then
            fresh[uuid] = entry
        end
    end
    return fresh
end

function LSS.Ore.Rarity(oreId)
    local configs = LSS.GameLib.Need(GameConfig.Ore.Config)
    local oreConfig = configs[oreId] or configs[tostring(oreId)]
    local numeric = tonumber(oreId)
    if not oreConfig and numeric then oreConfig = configs[numeric] end
    if not oreConfig then return nil end
    return LSS.GameLib.Api(GameConfig.Rarity.Helper).GetRarityByLevel(tonumber(oreConfig.Rarity) or oreConfig.Rarity)
end

function LSS.Ore.Allows(rarities, name)
    if not rarities then return true end
    if not name then return false end
    if rarities[name] then return true end
    local wanted = tostring(name):lower():match("^%s*(.-)%s*$")
    for key, selected in pairs(rarities) do
        local value = type(key) == "number" and selected or key
        if selected and tostring(value):lower():match("^%s*(.-)%s*$") == wanted then return true end
    end
    return false
end

function LSS.Ore.Owned(profile)
    local ores = {}
    for uuid, entry in pairs(profile.Backpack.have) do
        if entry.Type == "Ore" and (entry.Number or 0) >= 1 then
            table.insert(ores, {
                uuid = uuid,
                id = entry.ID,
                tier = LSS.Util.Tier(entry.ID),
                number = math.floor(entry.Number),
                rarity = LSS.Ore.Rarity(entry.ID),
            })
        end
    end
    table.sort(ores, function(a, b) return a.tier > b.tier end)
    return ores
end

function LSS.Ore.Ids()
    local ids = {}
    for oreId in pairs(LSS.GameLib.Need(GameConfig.Ore.Config)) do
        table.insert(ids, oreId)
    end
    table.sort(ids, function(a, b) return LSS.Util.Tier(a) > LSS.Util.Tier(b) end)
    return ids
end

function LSS.Ore.Choices()
    local oreShow = LSS.GameLib.Need(GameConfig.Ore.Show)
    local labels, idByLabel = {}, {}
    for _, oreId in ipairs(LSS.Ore.Ids()) do
        local label = ("%s (%s)"):format(oreShow[oreId] and oreShow[oreId].DisplayName or oreId, LSS.Ore.Rarity(oreId) or "?")
        if idByLabel[label] then
            label = ("%s #%d"):format(label, LSS.Util.Tier(oreId))
        end
        idByLabel[label] = oreId
        table.insert(labels, label)
    end
    State.OreLabels = idByLabel
    return labels
end

function LSS.Ore.ForgeChoices()
    local labels = LSS.Ore.Choices()
    table.insert(labels, 1, Config.OwnedOresLabel)
    return labels
end

function LSS.Ore.Add(uuid, amount)
    LSS.Util.Remote("Backpack", "TrySellItemRE"):FireServer(uuid, -math.abs(amount))
end

function LSS.Ore.Ensure(oreId, need)
    local profile = LSS.Data.Get()
    local uuid = LSS.Data.Uuid(profile, oreId)
    if not uuid then
        if not LSS.Stage.AcquireOre(oreId) then return nil end
        task.wait(0.4)
        profile = LSS.Data.Get()
        uuid = LSS.Data.Uuid(profile, oreId)
    end
    if uuid and LSS.Data.Count(profile, oreId) < need then
        LSS.Ore.Add(uuid, math.max(Config.RefillAmount, need))
        task.wait(0.4)
    end
    return uuid
end

function LSS.Ore.Top(minimum)
    local top = LSS.Ore.Owned(LSS.Data.Get())[1]
    if not top then
        LSS.Stage.Collect(LSS.Stage.Best(), nil)
        top = LSS.Ore.Owned(LSS.Data.Get())[1]
    end
    if top and top.number < minimum then
        LSS.Ore.Add(top.uuid, Config.RefillAmount)
        task.wait(0.4)
    end
    return top
end

function LSS.Spawn.Choices()
    local labels, byLabel = LSS.Ore.Choices(), {}
    for label, oreId in pairs(State.OreLabels) do
        byLabel[label] = { id = oreId, kind = "Ore" }
    end
    local stoneShow = LSS.GameLib.Need(GameConfig.EnchStone.Show)
    local stones = {}
    for stoneId in pairs(stoneShow) do
        table.insert(stones, stoneId)
    end
    table.sort(stones, function(a, b)
        local ta, tb = LSS.Util.Tier(a), LSS.Util.Tier(b)
        if ta ~= tb then return ta > tb end
        return a < b
    end)
    for _, stoneId in ipairs(stones) do
        local label = stoneShow[stoneId].DisplayName or stoneId
        byLabel[label] = { id = stoneId, kind = "EnchStone" }
        table.insert(labels, label)
    end
    local materialModule = LSS.GameLib.Find("Config.Material.Show")
    local materialShow = materialModule and LSS.GameLib.Require(materialModule)
    if type(materialShow) == "table" then
        local materials = {}
        for materialId, show in pairs(materialShow) do
            table.insert(materials, { materialId, show.DisplayName or materialId })
        end
        table.sort(materials, function(a, b) return a[2] < b[2] end)
        for i, entry in ipairs(materials) do
            byLabel[entry[2]] = { id = entry[1], kind = "Material" }
            table.insert(labels, i, entry[2])
        end
    end
    State.SpawnLabels = byLabel
    return labels
end

function LSS.Spawn.Stack(counts)
    local list = {}
    for uuid, amount in pairs(counts) do
        list[uuid] = -math.abs(amount)
    end
    LSS.Util.Remote("Forge", "ForgeRF"):InvokeServer({ ConfigType = "Weapon", UUIDList = list })
end

function LSS.Spawn.Give(itemId, kind, amount)
    if kind == "Ore" then
        local uuid = LSS.Ore.Ensure(itemId, 0)
        if not uuid then return false end
        LSS.Ore.Add(uuid, amount)
        return true
    end
    local uuid = LSS.Data.Uuid(LSS.Data.Get(), itemId)
    if not uuid then return false end
    if kind == "Material" then
        LSS.Spawn.Stack({ [uuid] = amount })
    else
        LSS.Ore.Add(uuid, amount)
    end
    return true
end

function LSS.Potion.Owned()
    local owned = {}
    local stock = LSS.Data.Get().Potion or {}
    for potionId in pairs(LSS.GameLib.Need(GameConfig.Potion.Config)) do
        if stock[potionId] ~= nil then table.insert(owned, potionId) end
    end
    table.sort(owned)
    return owned
end

function LSS.Potion.Add(potionId, amount)
    LSS.Util.Remote("Potion", "TryUsePotionRE"):FireServer(potionId, -math.abs(amount))
end

function LSS.Potion.MaxBuffs()
    local use = LSS.Util.Remote("Potion", "TryUsePotionRE")
    local owned = LSS.Potion.Owned()
    for _, potionId in ipairs(owned) do
        LSS.Potion.Add(potionId, Config.PotionStack)
        use:FireServer(potionId, Config.PotionStack)
    end
    return #owned
end

function LSS.Spawn.DupeAll(amount)
    local materials, touched = {}, 0
    for uuid, entry in pairs(LSS.Data.Get().Backpack.have) do
        if type(entry) ~= "table" or not entry.Number then continue end
        touched += 1
        if entry.Type == "Material" then
            materials[uuid] = amount
        else
            LSS.Ore.Add(uuid, amount)
        end
    end
    if next(materials) then LSS.Spawn.Stack(materials) end
    return touched
end

function LSS.Stage.List()
    local stages = {}
    for stageId in pairs(LSS.GameLib.Api(GameConfig.Stage.Helper).GetStageEnemyConfig()) do
        table.insert(stages, stageId)
    end
    table.sort(stages, function(a, b) return LSS.Util.Tier(a) > LSS.Util.Tier(b) end)
    return stages
end

function LSS.Stage.Best()
    return LSS.Stage.List()[1]
end

-- Keep failed/unclaimed batches so retries never open a new stage over pending loot.
function LSS.Stage.Collect(stageId, rarities, keepRunning)
    local function active()
        return State.Alive and (not keepRunning or keepRunning())
    end
    while State.CollectBusy do
        if not active() then return end
        task.wait(0.01)
    end
    if not active() or not stageId then return end
    State.CollectBusy = true
    local ok, result = pcall(function()
        local batch = State.OreBatch
        if not batch then
            local drops = LSS.Util.Remote("Stage", "StageFinishedRF"):InvokeServer(stageId)
            if type(drops) ~= "table" then error("Stage did not return a loot batch", 0) end
            batch = {stage=stageId, drops=drops, ores={}, stones={}, done={}, rarities=rarities and table.clone(rarities)}
            State.OreBatch = batch
        end
        -- Internal callers must not broaden an unfinished auto-farm batch's filter.
        if not rarities and batch.rarities then rarities = batch.rarities end
        -- Preserve raw drops before classification; unknown rarity must not silently lose loot.
        if not batch.classified then
            local ores, stones = {}, {}
            local configs = LSS.GameLib.Need(GameConfig.Ore.Config)
            for uuid, drop in pairs(batch.drops) do
                if type(drop) == "table" then
                    table.insert(stones, uuid)
                else
                    local rarity = LSS.Ore.Rarity(drop)
                    if rarities and not rarity then error("Cannot resolve ore rarity: " .. tostring(drop), 0) end
                    local config = configs[drop] or configs[tostring(drop)] or configs[tonumber(drop)]
                    table.insert(ores, {uuid=uuid, rarity=rarity, rank=tonumber(config and config.Rarity) or 0})
                end
            end
            table.sort(ores, function(left, right)
                if left.rank ~= right.rank then return left.rank > right.rank end
                return tostring(left.uuid) < tostring(right.uuid)
            end)
            batch.ores, batch.stones, batch.classified = ores, stones, true
        end
        if not active() then return end
        if #batch.stones > 0 then
            local pickStone = LSS.Util.Remote("Stage", "GetEnhantStoneRE")
            for _, uuid in ipairs(batch.stones) do
                if not active() then return end
                if not batch.done[uuid] then
                    pickStone:FireServer(uuid)
                    batch.done[uuid] = true
                end
            end
        end
        local ores = {}
        for _, ore in ipairs(batch.ores) do
            if not batch.done[ore.uuid] and LSS.Ore.Allows(rarities, ore.rarity) then table.insert(ores, ore.uuid) end
        end
        if #ores > 0 then
            local pickOre = LSS.Util.Remote("Stage", "GetOreRF")
            local workers = math.min(#ores, math.clamp(math.floor(tonumber(State.Opt.FarmWorkers) or 24), 1, 999))
            local nextOre, pending, failure = 1, workers, nil
            local completion = Instance.new("BindableEvent")
            for _ = 1, workers do
                task.spawn(function()
                    local worked, err = pcall(function()
                        while active() do
                            local index = nextOre
                            nextOre += 1
                            if index > #ores then break end
                            local uuid = ores[index]
                            local lastError
                            for attempt = 1, 3 do
                                if not active() then break end
                                local accepted, response = pcall(pickOre.InvokeServer, pickOre, uuid)
                                if accepted and response ~= false then
                                    batch.done[uuid] = true
                                    lastError = nil
                                    break
                                end
                                lastError = accepted and "Ore pickup was rejected" or response
                                if attempt < 3 and active() then task.wait(0.02 * attempt) end
                            end
                            if lastError then failure = failure or lastError end
                        end
                    end)
                    if not worked then failure = failure or err end
                    pending -= 1
                    if pending == 0 then completion:Fire() end
                end)
            end
            -- Resume as soon as the last worker returns, without a polling-frame delay.
            if pending > 0 then completion.Event:Wait() end
            completion:Destroy()
            if failure then error(failure, 0) end
        end
        if not active() then return end
        -- Failed pickups never reach this claim; the next call resumes their UUIDs.
        LSS.Util.Remote("Stage", "ClaimedAllOreRE"):FireServer()
        State.OreBatch = nil
    end)
    State.CollectBusy = false
    if not ok then
        if keepRunning and not State.FarmRetryNotified then
            State.FarmRetryNotified = true
            State.FarmNotice = {kind="Warning", text={EN="Ore pickup delayed; unfinished selected ore will be retried", ID="Pickup ore tertunda; ore pilihan yang belum selesai akan dicoba lagi", TH="เก็บแร่ล่าช้า จะลองแร่ที่เลือกอีกครั้ง"}}
        end
        error(result, 0)
    end
    if not State.OreBatch and State.FarmRetryNotified then
        State.FarmRetryNotified = false
        State.FarmNotice = {kind="Success", text={EN="Pending selected ore batch completed", ID="Batch ore pilihan yang tertunda sudah selesai", TH="เก็บแร่ที่เลือกและค้างอยู่เสร็จแล้ว"}}
    end
end

function LSS.Stage.StartCollecting()
    LSS.Scheduler.StartLoop("CollectOre", function()
        if State.Lock then return end
        local selected = false
        for _, enabled in pairs(State.Opt.CollectRarities or {}) do
            if enabled then selected = true; break end
        end
        if not selected then return end
        local ok, err = LSS.Util.Exclusive("Farm", function()
            LSS.Stage.Collect(State.Opt.Stage or LSS.Stage.Best(),
                State.Opt.CollectRarities,
                function() return State.Opt.CollectOre end)
        end)
        if not ok and err ~= nil then error(err, 0) end
    end, function() return 0 end, 0)
end

function LSS.Stage.FarmStones(stageId)
    if State.OreBatch then LSS.Stage.Collect(stageId, nil) end
    local finished = LSS.Util.Remote("Stage", "StageFinishedRF")
    local pickStone = LSS.Util.Remote("Stage", "GetEnhantStoneRE")
    LSS.Util.WaitAll(Config.StoneWorkers, function()
        for _ = 1, Config.StoneCallsPerWorker do
            local drops = finished:InvokeServer(stageId)
            for uuid, drop in pairs(type(drops) == "table" and drops or {}) do
                if type(drop) == "table" then
                    pickStone:FireServer(uuid)
                end
            end
        end
    end)
end

function LSS.Stage.AcquireOre(oreId)
    local stages = LSS.Stage.List()
    local known = State.OreStage[oreId]
    local target = LSS.Util.Tier(oreId) * #stages / LSS.Util.Tier(LSS.Util.HighestKey(LSS.GameLib.Need(GameConfig.Ore.Config)))
    table.sort(stages, function(a, b)
        if a == known or b == known then return a == known end
        return math.abs(LSS.Util.Tier(a) - target) < math.abs(LSS.Util.Tier(b) - target)
    end)

    local finished = LSS.Util.Remote("Stage", "StageFinishedRF")
    local pickOre = LSS.Util.Remote("Stage", "GetOreRF")
    for round = 1, Config.AcquireRounds do
        local stageId = stages[(round - 1) % math.min(#stages, 4) + 1]
        local drops = finished:InvokeServer(stageId)
        for uuid, drop in pairs(type(drops) == "table" and drops or {}) do
            if drop == oreId and pickOre:InvokeServer(uuid) then
                LSS.Util.Remote("Stage", "ClaimedAllOreRE"):FireServer()
                State.OreStage[oreId] = stageId
                return true
            end
        end
    end
    return false
end

function LSS.Stage.ExitFight()
    LSS.GameLib.Api(LocalPlayer.PlayerScripts.Manager.StageManager.StageUtils).ExitFight(true)
end

function LSS.Forge.Target()
    for _, target in ipairs(Config.ForgeTargets) do
        if target.name == State.Opt.ForgeTarget then
            return target
        end
    end
    return Config.ForgeTargets[1]
end

function LSS.Forge.Run(forgeType, oreList)
    return LSS.Util.Remote("Forge", "ForgeRF"):InvokeServer({ ConfigType = forgeType, UUIDList = oreList })
end

function LSS.Forge.PickOwned(profile, count)
    local opt = State.Opt
    local candidates = {}
    for _, ore in ipairs(LSS.Ore.Owned(profile)) do
        local spare = ore.number - opt.KeepPerOre
        if opt.ForgeRarities[ore.rarity] and spare > 0 then
            ore.spare = spare
            table.insert(candidates, ore)
        end
    end
    if not opt.BestOreFirst then
        table.sort(candidates, function(a, b) return a.tier < b.tier end)
    end

    local pick, need = {}, count
    for _, ore in ipairs(candidates) do
        if need <= 0 then break end
        local take = math.min(need, ore.spare)
        pick[ore.uuid] = take
        need -= take
    end
    return need <= 0 and pick or nil
end

function LSS.Forge.Pick(count)
    local oreId = State.OreLabels[State.Opt.ForgeOre]
    if not oreId then
        return LSS.Forge.PickOwned(LSS.Data.Get(), count)
    end
    local uuid = LSS.Ore.Ensure(oreId, count * State.Opt.ForgePerTick)
    return uuid and { [uuid] = count }
end

function LSS.Forge.Once()
    local target = LSS.Forge.Target()
    local pick = LSS.Forge.Pick(target.ores)
    if not pick then return false end
    local result = LSS.Forge.Run(target.forgeType, pick)
    return result ~= nil and result ~= false
end

function LSS.Forge.Burst()
    local target = LSS.Forge.Target()
    local perTick = State.Opt.ForgePerTick
    local pick = LSS.Forge.Pick(target.ores * perTick)
    if not pick then return 0 end
    local completed = 0
    local uuid = next(pick)
    if next(pick, uuid) == nil then
        for _ = 1, perTick do
            local result = LSS.Forge.Run(target.forgeType, { [uuid] = target.ores })
            if result ~= nil and result ~= false then completed += 1 end
        end
        return completed
    end
    for _ = 1, perTick do
        if not LSS.Forge.Once() then break end
        completed += 1
    end
    return completed
end

function LSS.Forge.Step()
    if not State.Opt.ForgeSellJunk then return LSS.Forge.Burst() end
    local before = LSS.Data.Snapshot()
    local completed = LSS.Forge.Burst()
    local fresh = LSS.Data.NewGear(before)
    local profile = State.Profile
    local keep = {}
    for uuid, entry in pairs(fresh) do
        local worn = profile.Backpack.equiped[entry.Type]
        local wornEntry = worn and profile.Backpack.have[worn]
        if not wornEntry or LSS.Gear.Score(entry, true) > LSS.Gear.Score(wornEntry, true) then
            keep[uuid] = true
        end
    end
    LSS.Sell.Fresh(fresh, keep)
    return completed
end

function LSS.Sell.Rarity(entry)
    local folder = entry.Type == "Weapon" and "Weapon" or "Armor"
    local itemConfig = LSS.GameLib.Need(GameConfig[folder].Config)[entry.ID]
    return itemConfig and itemConfig.Rarity
end

function LSS.Sell.Anchors(profile)
    local anchors, bestPower = {}, {}
    for uuid, entry in pairs(profile.Backpack.have) do
        if not (entry.Type == "Weapon" or entry.Type == "Armor" or entry.Type == "Hat") then continue end
        local helper = LSS.GameLib.Api(entry.Type == "Weapon" and GameConfig.Weapon.Helper or GameConfig.Armor.Helper)
        local ok, percent = pcall(helper.CheckIsBestPercent, entry.ID)
        if not ok or percent then continue end
        local powerOk, power = pcall(helper.GetMainAffix, entry.ID)
        if powerOk and type(power) == "number" and power > (bestPower[entry.Type] or 0) then
            bestPower[entry.Type] = power
            anchors[entry.Type] = uuid
        end
    end
    local keep = {}
    for _, uuid in pairs(anchors) do
        keep[uuid] = true
    end
    local backpack = LSS.GameLib.Require(ReplicatedStorage.LocalData.BackpackData)
    if type(backpack) == "table" and type(backpack.IsLocked) == "function" then
        for uuid in pairs(profile.Backpack.have) do
            local ok, locked = pcall(backpack.IsLocked, uuid)
            if ok and locked then keep[uuid] = true end
        end
    end
    return keep
end

function LSS.Sell.Run(profile)
    local opt = State.Opt
    local equipped = LSS.Sell.Anchors(profile)
    for _, uuid in pairs(profile.Backpack.equiped) do
        equipped[uuid] = true
    end

    local byId = {}
    for uuid, entry in pairs(profile.Backpack.have) do
        if opt.SellTypes[entry.Type] and not equipped[uuid] then
            byId[entry.ID] = byId[entry.ID] or {}
            table.insert(byId[entry.ID], { uuid = uuid, entry = entry })
        end
    end

    local sell = LSS.Util.Remote("Backpack", "TrySellItemRE")
    for _, items in pairs(byId) do
        table.sort(items, function(a, b) return (a.entry.Level or 0) > (b.entry.Level or 0) end)
        for index, gear in ipairs(items) do
            if index > opt.KeepPerItem and opt.SellRarities[LSS.Sell.Rarity(gear.entry)] then
                sell:FireServer(gear.uuid, 1)
            end
        end
    end
end

function LSS.Sell.Fresh(fresh, keep)
    local equipped = LSS.Sell.Anchors(State.Profile)
    for _, uuid in pairs(State.Profile.Backpack.equiped) do
        equipped[uuid] = true
    end
    local sell = LSS.Util.Remote("Backpack", "TrySellItemRE")
    for uuid in pairs(fresh) do
        if not equipped[uuid] and not (keep and keep[uuid]) then
            sell:FireServer(uuid, 1)
        end
    end
end

function LSS.Gear.Score(entry, atTarget)
    local balance = LSS.GameLib.Api(ReplicatedStorage.Utils.BalanceUtils)
    local backpack = (State.Profile or LSS.Data.Get()).Backpack
    local potential = table.clone(entry)
    if atTarget then potential.Level = math.max(entry.Level or 0, State.Opt.EnhanceTarget) end
    local value = entry.Type == "Weapon" and balance.GetWeaponTrainValue or balance.GetArmorValue
    local ok, power = pcall(value, LocalPlayer, potential, backpack)
    if not ok or type(power) ~= "number" then return 0 end
    return power * (1 + (entry.Level or 0) * 1e-6 + #(entry.EnchanceList or {}) * 1e-9)
end

function LSS.Gear.BestOwned(profile, slot, atTarget)
    local bestUuid, bestScore = nil, -1
    for uuid, entry in pairs(profile.Backpack.have) do
        if entry.Type == slot then
            local score = LSS.Gear.Score(entry, atTarget)
            if score > bestScore then
                bestUuid, bestScore = uuid, score
            end
        end
    end
    return bestUuid, bestScore
end

function LSS.Gear.EquipBest()
    local profile = LSS.Data.Get()
    local equip = LSS.Util.Remote("Backpack", "TryEquipItemRE")
    local changed = 0
    local atTarget = State.Opt.MaxGear and State.Opt.GearEnhance
    for _, slot in ipairs(Config.GearTypes) do
        local best, bestScore = LSS.Gear.BestOwned(profile, slot, atTarget)
        local current = profile.Backpack.equiped[slot]
        local currentEntry = current and profile.Backpack.have[current]
        if best and best ~= current and bestScore > (currentEntry and LSS.Gear.Score(currentEntry, atTarget) or -1) then
            equip:FireServer(best, slot)
            changed += 1
        end
    end
    return changed
end

function LSS.Gear.ForgeBest()
    local before = LSS.Data.Snapshot()
    for _, spec in ipairs(Config.GearSlots) do
        local top = LSS.Ore.Top(spec.ores * Config.GearForgeTries)
        if top then
            for _ = 1, Config.GearForgeTries do
                LSS.Forge.Run(spec.forgeType, { [top.uuid] = spec.ores })
            end
        end
        local best = LSS.Gear.BestOwned(LSS.Data.Get(), spec.slot, true)
        if best then
            LSS.Util.Remote("Backpack", "TryEquipItemRE"):FireServer(best, spec.slot)
        end
    end
    task.wait(1)
    LSS.Sell.Fresh(LSS.Data.NewGear(before))
end

function LSS.Gear.MissingForEnhance(profile, level)
    local cost = LSS.GameLib.Need(GameConfig.Enhant.Config)[level + 1]
    if not cost then return nil end
    if LSS.Data.Count(profile, "EnhantStone_2") < (cost.EnhantStone_2 or 0) then return "EnhantStone_2" end
    if LSS.Data.Count(profile, "EnhantStone_1") < (cost.EnhantStone_1 or 0) then return "EnhantStone_1" end
    if profile.Eco.coin < (cost.NeedCoin or 0) then return "Coin" end
    return nil
end

function LSS.Gear.Gather(missing)
    State.GearNote = missing
    if missing == "Coin" then
        LSS.Forge.Step()
        LSS.Sell.Run(LSS.Data.Get())
    elseif missing == "EnhantStone_1" then
        LSS.Stage.FarmStones(LSS.Stage.Best())
    elseif not LSS.Tower.FarmStep() then
        State.GearNote = "NoTicket"
    end
end

function LSS.Gear.RuneOrder()
    if State.Runes then return State.Runes end
    local show = LSS.GameLib.Find("Config.EnchStone.Show")
    local stones = show and LSS.GameLib.Require(show)
    if not stones then return Config.EnchantPriority end

    local known = {}
    for index, stoneId in ipairs(Config.EnchantPriority) do
        known[stoneId] = index
    end
    local runes = {}
    for stoneId in pairs(stones) do
        if LSS.Util.Tier(stoneId) >= Config.RuneMinTier then runes[#runes + 1] = stoneId end
    end
    table.sort(runes, function(a, b)
        local ta, tb = LSS.Util.Tier(a), LSS.Util.Tier(b)
        if ta ~= tb then return ta > tb end
        local ka, kb = known[a] or math.huge, known[b] or math.huge
        if ka ~= kb then return ka < kb end
        return a < b
    end)
    State.Runes = runes
    return runes
end

function LSS.Gear.Priority()
    return #State.Opt.EnchantPriority > 0 and State.Opt.EnchantPriority or LSS.Gear.RuneOrder()
end

function LSS.Gear.StockEnchants(profile)
    for _, stoneId in ipairs(LSS.Gear.Priority()) do
        local uuid = LSS.Data.Uuid(profile, stoneId)
        if uuid and LSS.Data.Count(profile, stoneId) < Config.EnchantRefill then
            LSS.Ore.Add(uuid, Config.EnchantRefill)
        end
    end
end

function LSS.Gear.Enchant(profile, uuid)
    local entry = profile.Backpack.have[uuid]
    local used = {}
    for slot = 1, entry.EnchanceNum or 0 do
        local current = entry.EnchanceList and entry.EnchanceList[slot]
        local currentId = current and current.ID
        local wanted
        for _, stoneId in ipairs(LSS.Gear.Priority()) do
            if not used[stoneId] and (stoneId == currentId or LSS.Data.Count(profile, stoneId) > 0) then
                wanted = stoneId
                break
            end
        end
        if wanted then
            used[wanted] = true
            if wanted ~= currentId then
                if currentId then
                    LSS.Util.Remote("Backpack", "UnEnchantRE"):FireServer(uuid, slot)
                    task.wait(0.3)
                end
                LSS.Util.Remote("Backpack", "EnchantRE"):FireServer(uuid, LSS.Data.Uuid(profile, wanted), slot)
                task.wait(0.3)
            end
        end
    end
end

function LSS.Gear.Enhance(profile)
    local target = math.min(State.Opt.EnhanceTarget, LSS.Util.Tier(LSS.Util.HighestKey(LSS.GameLib.Need(GameConfig.Enhant.Config))))
    local enhance = LSS.Util.Remote("Backpack", "EnhantEquipmentRF")
    for _, spec in ipairs(Config.GearSlots) do
        local uuid = profile.Backpack.equiped[spec.slot]
        local entry = uuid and profile.Backpack.have[uuid]
        if entry and (entry.Level or 0) < target then
            local missing = LSS.Gear.MissingForEnhance(profile, entry.Level or 0)
            if missing then
                LSS.Gear.Gather(missing)
                return false
            end
            State.GearNote = "Enhancing"
            local useProtect = LSS.Data.Count(profile, "EnhantProtect") > 0 and (entry.Level or 0) >= LSS.GameLib.Api(GameConfig.Enhant.Helper).GetFailLevel()
            LSS.Util.WaitAll(Config.GearEnhanceWorkers, function()
                for _ = 1, Config.GearEnhanceTries do
                    if not enhance:InvokeServer(uuid, { UseProtect = useProtect }) then return end
                end
            end)
            return false
        end
    end
    return true
end

function LSS.Gear.MaxStep()
    local opt = State.Opt
    if opt.GearForge and not State.GearForged then
        LSS.Gear.ForgeBest()
        State.GearForged = true
    end
    if opt.GearEnchant then
        local profile = LSS.Data.Get()
        LSS.Gear.StockEnchants(profile)
        profile = LSS.Data.Get()
        for _, spec in ipairs(Config.GearSlots) do
            local uuid = profile.Backpack.equiped[spec.slot]
            if uuid then LSS.Gear.Enchant(profile, uuid) end
        end
    end
    if not opt.GearEnhance or LSS.Gear.Enhance(LSS.Data.Get()) then
        State.GearNote = "Done"
    end
end

function LSS.Gear.EnhanceSlot(slot, target)
    local enhance = LSS.Util.Remote("Backpack", "EnhantEquipmentRF")
    local failLevel = LSS.GameLib.Api(GameConfig.Enhant.Helper).GetFailLevel()
    local level = 0
    for _ = 1, Config.SlotEnhanceRounds do
        local profile = LSS.Data.Get()
        local uuid = profile.Backpack.equiped[slot]
        local entry = uuid and profile.Backpack.have[uuid]
        if not entry then return nil end
        level = entry.Level or 0
        if level >= target then return level end
        local missing = LSS.Gear.MissingForEnhance(profile, level)
        if missing == "EnhantStone_1" then
            LSS.Stage.FarmStones(LSS.Stage.Best())
        elseif missing then
            return level
        else
            enhance:InvokeServer(uuid, { UseProtect = level >= failLevel and LSS.Data.Count(profile, "EnhantProtect") > 0 })
        end
    end
    return level
end

function LSS.Gear.EquippedNames(profile)
    local names = {}
    for _, spec in ipairs(Config.GearSlots) do
        local uuid = profile.Backpack.equiped[spec.slot]
        local entry = uuid and profile.Backpack.have[uuid]
        if entry then
            local shows = LSS.GameLib.Require(GameConfig[entry.Type == "Weapon" and "Weapon" or "Armor"].Show)
            local show = shows and shows[entry.ID]
            table.insert(names, ("%s +%d"):format(show and show.DisplayName or entry.ID, entry.Level or 0))
        end
    end
    return table.concat(names, " · ")
end

function LSS.Index.GearCatalog()
    local gear = {}
    local armorHelper = LSS.GameLib.Api(GameConfig.Armor.Helper)
    for weaponId, weapon in pairs(LSS.GameLib.Need(GameConfig.Weapon.Config)) do
        table.insert(gear, { id = weaponId, slot = "Weapon", forgeType = "Weapon", forgeable = weapon.TLevel ~= nil })
    end
    for armorId, armor in pairs(LSS.GameLib.Need(GameConfig.Armor.Config)) do
        table.insert(gear, { id = armorId, slot = armorHelper.GetBigType(armorId) or "Armor", forgeType = "Armor", forgeable = armor.TLevel ~= nil })
    end
    return gear
end

function LSS.Index.Missing()
    local unlocked = LSS.Data.Get().Index.unlocked
    local missing = {}
    for _, gear in ipairs(LSS.Index.GearCatalog()) do
        if State.Opt.IndexTypes[gear.slot] and not unlocked[gear.slot .. "-" .. gear.id] then
            table.insert(missing, gear)
        end
    end
    table.sort(missing, function(a, b)
        if a.forgeable ~= b.forgeable then return a.forgeable end
        return a.id < b.id
    end)
    return missing
end

function LSS.Index.Plan(gear)
    local cached = State.Plans[gear.id]
    if cached then return cached[1], cached[2], cached[3] end

    local forgeUtils = LSS.GameLib.Api(ReplicatedStorage.Utils.ForgeUtils)
    local helper = LSS.GameLib.Api(gear.forgeType == "Weapon" and GameConfig.Weapon.Helper or GameConfig.Armor.Helper)
    local bestChance, bestOre, bestCount = 0, nil, nil
    local sliceStart = os.clock()
    for count = 1, Config.ForgeCountMax do
        local split = helper.GetForgePercentByNumber(count)
        if not split then continue end
        for _, oreId in ipairs(LSS.Ore.Ids()) do
            if os.clock() - sliceStart > Config.PlanSlice then
                task.wait()
                sliceStart = os.clock()
            end
            local list = { [oreId] = count }
            local ok, chance = pcall(function()
                local low, high = forgeUtils.GetForgeOreResult(list)
                local power = forgeUtils.GetOreAvgPower(list)
                local total = 0
                for subType, share in pairs(split) do
                    if share > 0 then
                        total += share * (forgeUtils.GetEquPercent(gear.forgeType, count, low, high, power, subType)[gear.id] or 0)
                    end
                end
                return total
            end)
            if ok and chance > bestChance then
                bestChance, bestOre, bestCount = chance, oreId, count
            end
        end
    end
    State.Plans[gear.id] = { bestChance, bestOre, bestCount }
    return bestChance, bestOre, bestCount
end

function LSS.Index.Label(gear)
    local show = LSS.GameLib.Need(GameConfig[gear.forgeType].Show)[gear.id]
    local name = ("%s [%s]"):format(show and show.DisplayName or gear.id, gear.slot)
    if not gear.forgeable then return name .. " - event" end
    local chance = LSS.Index.Plan(gear)
    return chance > 0 and ("%s - %.2f%%"):format(name, chance * 100) or name .. " - no recipe"
end

function LSS.Index.Choices()
    local labels, byLabel = {}, {}
    for _, gear in ipairs(LSS.Index.Missing()) do
        local label = LSS.Index.Label(gear)
        byLabel[label] = gear
        table.insert(labels, label)
    end
    State.MissingLabels = byLabel
    return labels
end

function LSS.Index.Hunt(gear, copies)
    local chance, oreId, count = LSS.Index.Plan(gear)
    if chance <= 0 then return false end
    local budget = math.min(Config.HuntMaxForges * (copies or 1), math.ceil(Config.HuntTargetHits * (copies or 1) / chance))
    local key = gear.slot .. "-" .. gear.id
    local forged, got = 0, 0
    while forged < budget and State.Alive do
        local uuid = LSS.Ore.Ensure(oreId, count * Config.HuntBatch)
        if not uuid then return false end
        local before = LSS.Data.Snapshot()
        local perWorker = math.ceil(Config.HuntBatch / Config.HuntWorkers)
        LSS.Util.WaitAll(Config.HuntWorkers, function()
            for _ = 1, perWorker do
                LSS.Forge.Run(gear.forgeType, { [uuid] = count })
            end
        end)
        forged += perWorker * Config.HuntWorkers
        State.IndexNote = ("%s %d/%d"):format(gear.id, forged, budget)
        local fresh = LSS.Data.NewGear(before)
        local keep = {}
        for freshUuid, entry in pairs(fresh) do
            if entry.ID == gear.id and (not copies or got < copies) then
                keep[freshUuid] = true
                got += 1
            end
        end
        LSS.Sell.Fresh(fresh, keep)
        if copies then
            State.IndexNote = ("%s %d/%d"):format(gear.id, got, copies)
            if got >= copies then return true end
        elseif State.Profile.Index.unlocked[key] or next(keep) then
            return true
        end
    end
    return false
end

function LSS.Spawn.GearChoices(slot)
    local labels, byLabel, list = {}, {}, {}
    for _, gear in ipairs(LSS.Index.GearCatalog()) do
        if not gear.forgeable or gear.slot ~= slot then continue end
        local helper = LSS.GameLib.Api(gear.forgeType == "Weapon" and GameConfig.Weapon.Helper or GameConfig.Armor.Helper)
        local ok, power = pcall(helper.GetMainAffix, gear.id)
        table.insert(list, { gear, ok and tonumber(power) or 0 })
    end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    for _, pair in ipairs(list) do
        local label = LSS.Index.Label(pair[1])
        byLabel[label] = pair[1]
        table.insert(labels, label)
    end
    State.GearLabels = byLabel
    return labels
end

function LSS.Index.HuntAll()
    local found, tried = 0, 0
    for _, gear in ipairs(LSS.Index.Missing()) do
        if not State.Opt.AutoIndex and State.Lock ~= "Index" then break end
        if gear.forgeable and LSS.Index.Plan(gear) > 0 then
            tried += 1
            if LSS.Index.Hunt(gear) then found += 1 end
        end
    end
    LSS.Index.ClaimAll()
    if tried > 0 then State.IndexNote = ("Found %d/%d"):format(found, tried) end
    return found, tried
end

function LSS.Index.CollectOres()
    for _, stageId in ipairs(LSS.Stage.List()) do
        LSS.Stage.Collect(stageId, nil)
    end
    LSS.Index.ClaimAll()
end

function LSS.Index.ClaimAll()
    local index = LSS.Data.Get().Index
    local claimExp = LSS.Util.Remote("Index", "TryClaimIndexExpRF")
    for key in pairs(index.unlocked) do
        local itemType, itemId = key:match("^(.-)%-(.+)$")
        if itemType and not index.claimed[key] then
            claimExp:InvokeServer(itemType, itemId)
        end
    end
    local claimLevel = LSS.Util.Remote("Index", "TryClaimLevelRewardRF")
    for _ = 1, Config.IndexLevelClaims do
        if not claimLevel:InvokeServer() then break end
    end
end

function LSS.Index.Progress()
    local index = LSS.Data.Get().Index
    local unlocked = 0
    for _ in pairs(index.unlocked) do
        unlocked += 1
    end
    return unlocked, index.level
end

function LSS.Level.FindBestArea(gen)
    local areas = LSS.GameLib.Need(GameConfig.TrainArea.Config)
    local ids,seen = {},{}
    for areaId,area in pairs(areas) do
        local id=tonumber(areaId)
        if id and not seen[id] and type(area)=="table" then
            seen[id]=true
            table.insert(ids,{id=id,basic=tonumber(area.Basic) or 0})
        end
    end
    table.sort(ids,function(a,b) return a.basic==b.basic and a.id>b.id or a.basic>b.basic end)

    local function Live()
        return State.Alive and State.Opt.AutoTrain and State.TrainGen == gen
    end

    local into = LSS.Util.Remote("Train", "IntoAutoTrainRE")
    for _, entry in ipairs(ids) do
        local areaId=entry.id
        if not Live() then State.TrainPending=nil;return nil end
        State.TrainPending = areaId
        into:FireServer(areaId)
        local deadline = os.clock() + Config.TrainAcceptWait
        while Live() and os.clock() < deadline and tonumber(LocalPlayer:GetAttribute("AutoTrainAreaID")) ~= areaId do
            task.wait(0.1)
        end
        if Live() and tonumber(LocalPlayer:GetAttribute("AutoTrainAreaID")) == areaId then
            State.TrainPending = nil
            return areaId
        end
    end
    State.TrainPending = nil
    return nil
end

function LSS.Level.Enter()
    if not State.Opt.AutoTrain or State.TrainEntering then return end
    if State.TrainArea then
        if os.clock() - State.TrainFiredAt < Config.TrainAcceptWait then return end
        State.TrainFiredAt = os.clock()
        LSS.Util.Remote("Train", "IntoAutoTrainRE"):FireServer(State.TrainArea)
        return
    end

    local gen = State.TrainGen
    State.TrainEntering = true
    local ok, areaId = pcall(LSS.Level.FindBestArea, gen)
    State.TrainEntering = false
    if not ok then error(areaId, 0) end
    if State.TrainGen == gen and areaId then
        State.TrainArea = areaId
        State.TrainFiredAt = os.clock()
    end
end

function LSS.Level.Leave()
    local exit = LSS.Util.Remote("Train", "ExitAutoTrainRE")
    for _ = 1, Config.TrainExitTries do
        local areaId = LocalPlayer:GetAttribute("AutoTrainAreaID") or State.TrainPending or State.TrainArea
        if not areaId then return end
        exit:FireServer(areaId)
        if not State.Alive then
            State.TrainPending = nil
            return
        end

        task.wait(Config.TrainSettle)
        if State.Opt.AutoTrain then return end
        if not LocalPlayer:GetAttribute("AutoTrainAreaID") then
            State.TrainPending = nil
            return
        end
    end
    warn("[LootToForge] training area still set after", Config.TrainExitTries, "exits")
end

function LSS.Level.SetTraining(enabled)
    State.TrainGen += 1
    if enabled then
        LSS.Level.Enter()
    else
        LSS.Level.Leave()
    end
end

function LSS.Level.Bind()
    table.insert(State.Conns, LocalPlayer:GetAttributeChangedSignal("AutoTrainAreaID"):Connect(function()
        if not State.Opt.AutoTrain or LocalPlayer:GetAttribute("AutoTrainAreaID") then return end
        task.delay(Config.TrainRejoinDelay, function()
            if State.Opt.AutoTrain and not LocalPlayer:GetAttribute("AutoTrainAreaID") then
                LSS.Util.Try(LSS.Level.Enter)
            end
        end)
    end))
end

function LSS.Level.UsePotions(profile)
    local potionConfig = LSS.GameLib.Need(GameConfig.Potion.Config)
    local now = workspace:GetAttribute("ServerTime") or os.time()
    local buffs = profile.Buff or {}
    for potionName, count in pairs(profile.Potion or {}) do
        local buffId = potionConfig[potionName] and potionConfig[potionName].BuffID
        local active = buffId and type(buffs[buffId]) == "number" and buffs[buffId] > now
        if type(count) == "number" and count > 0 and not active then
            LSS.Util.Remote("Potion", "TryUsePotionRE"):FireServer(potionName, 1)
        end
    end
end

function LSS.Level.TrainStep()
    local profile = LSS.Data.Get()
    LSS.Level.UsePotions(profile)
    if profile.Eco.rebirth ~= State.TrainRebirth or profile.Eco.level ~= State.TrainLevel then
        State.TrainRebirth = profile.Eco.rebirth
        State.TrainLevel = profile.Eco.level
        State.TrainArea = nil
    end

    if LocalPlayer:GetAttribute("AutoTrainAreaID") then
        State.TrainNilSince = nil
        return
    end
    State.TrainNilSince = State.TrainNilSince or os.clock()
    if os.clock() - State.TrainNilSince < Config.TrainWatchdog then return end
    LSS.Level.Enter()
end

function LSS.Level.Rebirth()
    LSS.Util.Remote("Rebirth", "TryRebirthRE"):FireServer()
end

function LSS.Level.RebirthStep()
    local profile = LSS.Data.Get()
    local ok, needLevel = pcall(LSS.GameLib.Api(GameConfig.Rebirth.Helper).GetNeedLevel, profile.Eco.rebirth + 1)
    if ok and needLevel and profile.Eco.level >= needLevel then
        LSS.Level.Rebirth()
    end
end

function LSS.Level.ClickOnce()
    LSS.GameLib.Api(ReplicatedStorage.CTRL.TrainCTRL).TrainOnce()
end

function LSS.Level.CanClick()
    if not State.Alive or not State.Opt.AutoClick then return false end
    local hum=LSS.Movement.Humanoid()
    if not hum or hum.Health<=0 then return false end
    if State.Opt.ClickPauseTyping then
        local ok,focused=pcall(UserInputService.GetFocusedTextBox,UserInputService)
        if ok and focused then return false end
    end
    return true
end

function LSS.Level.StartClicking()
    LSS.Scheduler.StartLoop("AutoClick",function()
        if LSS.Level.CanClick() then LSS.Level.ClickOnce() end
    end,function() return 1/math.clamp(tonumber(State.Opt.ClickRate) or 6,1,25) end)
end

function LSS.Upgrade.Names()
    local names = {}
    for name in pairs(LSS.GameLib.Need(GameConfig.Upgrade.Config)) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function LSS.Upgrade.BuySelected()
    local buy = LSS.Util.Remote("Upgrade", "UpgradeOnceRE")
    for name, selected in pairs(State.Opt.Upgrades) do
        if selected then buy:FireServer(name) end
    end
end

function LSS.Tower.LastRound()
    return #LSS.GameLib.Need(GameConfig.Dungeon.Config.LootTab)
end

function LSS.Tower.Enter()
    local deadline = os.clock() + 10
    while State.Entering and os.clock() < deadline do
        task.wait(0.1)
    end
    if State.InTower then return true end
    State.Entering = true
    local ok, entered = pcall(function()
        return LSS.Util.Remote("Dungeon", "TryIntoDungeonRF"):InvokeServer(1)
    end)
    State.Entering = false
    State.InTower = ok and entered and true or false
    return State.InTower
end

function LSS.Tower.Exit()
    if not State.InTower then return end
    State.InTower = false
    LSS.Util.Remote("Dungeon", "ExitDungeonRE"):FireServer()
end

function LSS.Tower.FarmStep()
    if not LSS.Tower.Enter() then return false end
    local round = LSS.Tower.LastRound()
    local start = LSS.Util.Remote("Dungeon", "StartRoundRE")
    local complete = LSS.Util.Remote("Dungeon", "CompleteRoundRF")
    start:FireServer(round)
    LSS.Util.WaitAll(Config.TowerWorkers, function()
        for _ = 1, Config.TowerCallsPerWorker do
            if complete:InvokeServer(round) then
                State.TowerLoot += 1
            end
        end
    end)
    return true
end

function LSS.Tower.FarmCoins(target)
    local start = (LSS.Season.Current() or {}).SeasonCoin or 0
    local deadline = os.clock() + Config.CoinFarmTimeout
    local gained = 0
    while State.Alive and gained < target and os.clock() < deadline do
        if not State.InTower and LSS.Data.Count(LSS.Data.Get(), "Dungeon_Ticket") < 1 then break end
        if not LSS.Tower.FarmStep() then break end
        gained = ((LSS.Season.Current() or {}).SeasonCoin or 0) - start
    end
    LSS.Tower.Exit()
    return gained
end

function LSS.Boss.AttackId()
    local weapon = LocalPlayer:GetAttribute("WeaponType")
    return Config.BossAttackIds[weapon]
end

function LSS.Boss.Join()
    LSS.Util.Remote("WorldBoss", "IntoWorldBossFight"):FireServer()
    local char = LocalPlayer.Character
    if char and not State.BossReturn then State.BossReturn = char:GetPivot() end
end

function LSS.Boss.StandNear(boss)
    local char = LocalPlayer.Character
    if not char then return end
    local pos = boss:GetPivot().Position
    if (char:GetPivot().Position - pos).Magnitude > Config.BossReach then
        char:PivotTo(CFrame.new(pos + Vector3.new(0, Config.BossStandHeight, Config.BossStandBack), pos))
    end
end

function LSS.Boss.Step()
    local bossName = workspace:GetAttribute("CurrentWorldBoss")
    if not bossName then return end
    local attackId = LSS.Boss.AttackId()
    if not attackId then return end
    if LocalPlayer:GetAttribute("IntoFight") ~= "WorldBoss" then
        LSS.Boss.Join()
        task.wait(Config.BossJoinSettle)
    end

    local enemyFolder = workspace:FindFirstChild("EnemyFolder_Server") or workspace:FindFirstChild("EnemyFolder")
    local boss = enemyFolder and enemyFolder:FindFirstChild(bossName)
    if not boss or boss:GetAttribute("Dead") then return end
    LSS.Boss.StandNear(boss)
    local announce = LSS.Util.Remote("Attack", "UseAnyATKRE")
    local attack = LSS.Util.Remote("Attack", "AttackEnemyServiceRE")
    for _ = 1, Config.BossHitsPerTick do
        if not (State.Opt.AutoWorldBoss and boss.Parent) then return end
        announce:FireServer(attackId, workspace:GetServerTimeNow())
        attack:FireServer({ bossName }, { Phase = 1, SkillID = attackId, Attacker = LocalPlayer }, workspace:GetServerTimeNow())
        task.wait(Config.BossHitGap)
    end
end

function LSS.Boss.ClaimCards()
    local claim = LSS.Util.FindRemote("WorldBoss", "TryClaimBossRewardRE")
    if not claim then return end
    for card = 1, Config.BossCards do
        if claim.ClassName == "RemoteFunction" then
            task.spawn(claim.InvokeServer, claim, tostring(card))
        else
            task.spawn(claim.FireServer, claim, tostring(card))
        end
    end
end

LSS.Boss.ExitWords = { exit = true, leave = true, quit = true, out = true, back = true, ["end"] = true, finish = true, ["return"] = true }
LSS.Boss.SkipWords = { into = true, enter = true, join = true, dead = true, escape = true, claim = true, reward = true, attack = true, atk = true, cards = true, card = true, tick = true }

function LSS.Boss.NameWords(name)
    local words = {}
    for word in name:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2"):lower():gmatch("%a+") do
        words[#words + 1] = word
    end
    return words
end

function LSS.Boss.ExitRemote()
    local cached = State.BossExit
    if cached and cached.Parent then return cached end
    State.BossExit = nil

    -- 1) the original name, a pinned alias (Config.RemoteAliases) or the generic renamed-remote resolver
    local direct = LSS.Util.FindRemote("WorldBoss", "ExitWorldBossFight")
    if direct then
        State.BossExit = direct
        return direct
    end

    -- 2) any remote under a "boss" path whose name says exit / leave / quit / back ...
    local best, bestScore = nil, 0
    local ok, all = pcall(function() return ReplicatedStorage:GetDescendants() end)
    for _, inst in ipairs(ok and all or {}) do
        local class = inst.ClassName
        if class == "RemoteEvent" or class == "RemoteFunction" or class == "UnreliableRemoteEvent" then
            local path = inst:GetFullName():lower()
            if path:find("boss", 1, true) then
                local isExit, skip, score = false, false, 0
                for _, word in ipairs(LSS.Boss.NameWords(inst.Name)) do
                    if LSS.Boss.ExitWords[word] then isExit = true; score += 10 end
                    if LSS.Boss.SkipWords[word] then skip = true end
                    if word == "boss" then score += 3 elseif word == "world" or word == "fight" then score += 1 end
                end
                if isExit and not skip then
                    if inst.Parent and inst.Parent.Name:lower():find("boss", 1, true) then score += 5 end
                    if score > bestScore or (score == bestScore and best and inst:GetFullName() < best:GetFullName()) then
                        best, bestScore = inst, score
                    end
                end
            end
        end
    end
    if best then
        State.BossExit = best
        print(("[LootToForge] boss exit remote -> %s"):format(best:GetFullName()))
    end
    return best
end

function LSS.Boss.Leave()
    local exit = LSS.Boss.ExitRemote()
    if exit then
        if exit.ClassName == "RemoteFunction" then
            task.spawn(function() pcall(exit.InvokeServer, exit) end)
        else
            pcall(exit.FireServer, exit)
        end
    else
        -- the game has no separate exit remote any more: use the game's own client-side exit
        if not State.BossExitWarned then
            State.BossExitWarned = true
            warn("[LootToForge] boss exit remote not found, using the game's own ExitFight instead")
        end
        pcall(LSS.Stage.ExitFight)
    end
    LocalPlayer:SetAttribute("IntoFight", nil)
    local char = LocalPlayer.Character
    if State.BossReturn and char then char:PivotTo(State.BossReturn) end
    State.BossReturn = nil
end

function LSS.Boss.Bind()
    table.insert(State.Conns, LSS.Util.Remote("WorldBoss", "BossDeadRE").OnClientEvent:Connect(function()
        if not State.Opt.AutoWorldBoss then return end
        task.delay(Config.BossClaimDelay, function()
            if State.Opt.BossCards then LSS.Util.Try(LSS.Boss.ClaimCards) end
            LSS.Util.Try(LSS.Boss.Leave)
            State.BossDone = os.clock()
        end)
    end))
    local escape = LSS.Util.FindRemote("WorldBoss", "BossEscapeRE")
    if escape and escape.ClassName ~= "RemoteFunction" then
        table.insert(State.Conns, escape.OnClientEvent:Connect(function()
            if State.Opt.AutoWorldBoss then LSS.Util.Try(LSS.Boss.Leave) end
        end))
    end
end

function LSS.Season.Current()
    local seasons = LSS.Data.Get().Season or {}
    local bestKey = LSS.Util.HighestKey(seasons)
    return bestKey and seasons[bestKey]
end

function LSS.Season.Goods()
    local goods = LSS.GameLib.Need(GameConfig.Season.GoodsConfig)
    local ids = {}
    for goodId in pairs(goods) do
        table.insert(ids, goodId)
    end
    table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
    local labels, byLabel = {}, {}
    for _, goodId in ipairs(ids) do
        local good = goods[goodId]
        local label = ("%s x%d (%d coin)"):format(good.ID, good.Number, good.NeedSeasonCoin)
        byLabel[label] = goodId
        table.insert(labels, label)
    end
    return labels, byLabel
end

function LSS.Season.BuyExclusive()
    local goods = LSS.GameLib.Need(GameConfig.Season.GoodsConfig)
    local exchange = LSS.Util.Remote("Season", "ExchangeGoodsRE")
    local bought = 0
    for goodId, good in pairs(goods) do
        if good.Type ~= "Weapon" and good.Type ~= "Armor" and good.Type ~= "Hat" then continue end
        local season = LSS.Season.Current()
        if not season or ((season.Goods or {})[goodId] or 0) >= (good.Store or 1) then continue end
        local short = good.NeedSeasonCoin - (season.SeasonCoin or 0)
        if short > 0 then LSS.Tower.FarmCoins(short) end
        exchange:FireServer(goodId)
        bought += 1
        task.wait(0.5)
    end
    return bought
end

function LSS.Season.BuyGoods()
    local goods = LSS.GameLib.Need(GameConfig.Season.GoodsConfig)
    local exchange = LSS.Util.Remote("Season", "ExchangeGoodsRE")
    for goodId, wanted in pairs(State.Opt.SeasonGoods) do
        local good = goods[goodId]
        if not (wanted and good) then continue end
        for _ = 1, good.Store or 1 do
            local season = LSS.Season.Current()
            if not season or (season.SeasonCoin or 0) < good.NeedSeasonCoin then break end
            exchange:FireServer(goodId)
            task.wait(0.3)
        end
    end
end

function LSS.Season.Step()
    for _, claimName in ipairs({ "TryClaimDailyTicRE", "TryClaimAllRewardRE" }) do
        local sent, err = pcall(function()
            LSS.Util.Remote("Season", claimName):FireServer()
        end)
        if not sent then LSS.Util.WarnJob("AutoSeason", err) end
    end
    task.wait(0.5)
    LSS.Season.BuyGoods()
    local season = LSS.Season.Current()
    if not (season and State.Opt.SeasonSpin) then return end
    local luck = LSS.Util.Remote("Season", "LuckRE")
    for _ = 1, season.SeasonTicket or 0 do
        luck:FireServer(1)
        task.wait(0.5)
    end
end

function LSS.Claim.All()
    -- one missing remote must not stop the other claims
    local function Fire(folder, name, ...)
        local args = table.pack(...)
        local sent, err = pcall(function()
            LSS.Util.Remote(folder, name):FireServer(table.unpack(args, 1, args.n))
        end)
        if not sent then LSS.Util.WarnJob("AutoClaim", err) end
        return sent
    end

    Fire("Offline", "TryClaimOfflineRewardRE")
    Fire("Dungeon", "TryClaimDailyDunTicRE")
    LSS.Util.Try(LSS.Index.ClaimAll)

    local hasQuest, claimQuest = pcall(LSS.Util.Remote, "EnhantEvent", "TryClaimQuestRE")
    local hasUpdate, claimUpdate = pcall(LSS.Util.Remote, "UpdateLog", "TryClaimUPDRewardRE")
    if not hasQuest then LSS.Util.WarnJob("AutoClaim", claimQuest) end
    if not hasUpdate then LSS.Util.WarnJob("AutoClaim", claimUpdate) end
    for id = 1, Config.ClaimIdScan do
        if hasQuest then claimQuest:FireServer(id) end
        if hasUpdate then claimUpdate:FireServer(id) end
    end

    local ok, rewards = pcall(LSS.GameLib.Api(GameConfig.Online.Helper).GetOnlineRewardConfig)
    for rewardName in pairs(ok and type(rewards) == "table" and rewards or {}) do
        if not Fire("Online", "TryClaimRE", rewardName) then break end
    end
end

function LSS.Claim.Code(code)
    local message
    local hasListener, messageEvent = pcall(LSS.Util.Remote, "Message", "MessageRE")
    local conn = hasListener and messageEvent.OnClientEvent:Connect(function(text)
        message = message or tostring(text)
    end)
    local ok, err = pcall(function()
        return LSS.Util.Remote("Code", "TryUseCodeRF"):InvokeServer(code)
    end)
    local deadline = os.clock() + Config.CodeReplyWait
    while conn and not message and os.clock() < deadline do task.wait(0.05) end
    if conn then conn:Disconnect() end
    if not ok then return "failed: " .. tostring(err) end
    return message or "no reply"
end

function LSS.Claim.AllCodes()
    local results = {}
    for _, code in ipairs(Config.Codes) do
        table.insert(results, ("%s: %s"):format(code, LSS.Claim.Code(code)))
    end
    return table.concat(results, "\n")
end

function LSS.SuperLoot.Kill(uuid)
    LSS.Util.Remote("SuperLoot", "KillSuperLootRE"):FireServer(uuid)
    task.wait(0.2)
    LSS.Util.Remote("Stage", "GetOreRF"):InvokeServer(uuid)
    LSS.Util.Remote("Stage", "ClaimedAllOreRE"):FireServer()
end

function LSS.SuperLoot.KillExisting()
    for _, enemy in ipairs(workspace.EnemyFolder:GetChildren()) do
        local enemyId = enemy:GetAttribute("EnemyID")
        if enemyId and enemyId:find("^Super") then
            task.spawn(LSS.Util.Try, LSS.SuperLoot.Kill, enemy.Name)
        end
    end
end

function LSS.SuperLoot.Bind()
    table.insert(State.Conns, LSS.Util.Remote("SuperLoot", "RefreshSuperLootRE").OnClientEvent:Connect(function(_, uuid)
        if State.Opt.SuperLootAura then
            task.spawn(LSS.Util.Try, LSS.SuperLoot.Kill, uuid)
        end
    end))
end

function LSS.Combat.KillAll()
    local folder=workspace:FindFirstChild("EnemyFolder")
    if not folder then return false end
    local hit = LSS.GameLib.Api(ReplicatedStorage.Utils.CommunicationUtils).TryGetBindableEvent("Attack", "EnemyHitBE")
    local hitInfo = { SkillID = "K_ATK_1", IsCrit = true, Damage = Config.KillDamage }
    for _, enemy in ipairs(folder:GetChildren()) do
        local enemyId = enemy:GetAttribute("EnemyID")
        if enemyId and not enemyId:find("^Super") then
            hit:Fire(enemy.Name, Config.KillDamage, hitInfo)
        end
    end
end

function LSS.Combat.Start()
    LSS.Scheduler.StartLoop("KillAura",LSS.Combat.KillAll,function() return Config.KillAuraInterval end)
end

function LSS.Guard.HookDamage()
    if State.RestoreDamage then return true end
    local hpCtrl = LSS.GameLib.Require(ReplicatedStorage.CTRL.HPCTRL)
    local damageOnce = hpCtrl and hpCtrl.DamageOnce
    if type(damageOnce) ~= "function" then return false end

    hpCtrl.DamageOnce = function(target, damage)
        if target == LocalPlayer and State.Opt.GodMode then return false end
        return damageOnce(target, damage)
    end
    State.RestoreDamage = function()
        hpCtrl.DamageOnce = damageOnce
        State.RestoreDamage = nil
    end
    return true
end

function LSS.Guard.HookOreLoss()
    if State.RestoreNamecall then return true end
    local compat = LSS.Compat
    if not (compat and compat.Caps.Namecall) then return false end
    local found, lostOre = pcall(LSS.Util.Remote, "Stage", "LostAllOreRF")
    if not found then
        warn("[LootToForge] keep ore:", lostOre)
        return false
    end

    local original, restore
    original, restore = compat.HookMeta(game, "__namecall", function(self, ...)
        if self == lostOre and State.Opt.KeepOre and getnamecallmethod() == "InvokeServer" then
            return {}
        end
        return original(self, ...)
    end)
    if not original then return false end

    State.RestoreNamecall = function()
        State.RestoreNamecall = nil
        restore()
    end
    return true
end

function LSS.Guard.UnhookOreLoss()
    if State.RestoreNamecall then State.RestoreNamecall() end
end

function LSS.Guard.Stop()
    if State.RestoreDamage then State.RestoreDamage() end
    LSS.Guard.UnhookOreLoss()
end

function LSS.Race.Choices()
    local classConfig = LSS.GameLib.Need(GameConfig.Class.Config)
    local show = LSS.GameLib.Need(GameConfig.Class.Show)
    local ids = {}
    for classId in pairs(classConfig) do
        table.insert(ids, classId)
    end
    table.sort(ids, function(a, b) return classConfig[a].Weight < classConfig[b].Weight end)

    local labels, idByLabel = {}, {}
    for _, classId in ipairs(ids) do
        local label = ("%s (%s)"):format(show[classId] and show[classId].DisplayName or classId, classConfig[classId].Rarity)
        idByLabel[label] = classId
        table.insert(labels, label)
    end
    return labels, idByLabel
end

function LSS.Race.EquipBest()
    local classData = LSS.Data.Get().Class
    local classConfig = LSS.GameLib.Need(GameConfig.Class.Config)
    local bestSlot, bestWeight = nil, math.huge
    for slot, classId in pairs(classData.have) do
        local weight = classConfig[classId] and classConfig[classId].Weight or math.huge
        if weight < bestWeight then bestSlot, bestWeight = slot, weight end
    end
    if not bestSlot or tostring(bestSlot) == tostring(classData.equiped) then return false end
    LSS.Util.Remote("Class", "ChangeEquipedIndexRE"):FireServer(tostring(bestSlot))
    return true
end

function LSS.Race.RollUntil(targetId)
    if not targetId then return "target" end
    local roll = LSS.Util.Remote("Class", "LuckOnceRE")
    while State.Alive and State.Opt.AutoRace do
        local classData = LSS.Data.Get().Class
        if classData.have[classData.equiped] == targetId then return "got" end
        if (classData.luckTimes or 0) <= 0 then return "empty" end
        roll:FireServer(tostring(classData.equiped))
        task.wait(Config.RaceRollDelay)
    end
    return "stopped"
end

function LSS.Movement.Humanoid()
    return LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
end

function LSS.Movement.Apply()
    local hum = LSS.Movement.Humanoid()
    if not hum then return end
    hum.WalkSpeed = State.Opt.SpeedOn and State.Opt.WalkSpeed or (LocalPlayer:GetAttribute("OriWalkSpeed") or 22)
end

function LSS.Movement.Bind()
    table.insert(State.Conns, UserInputService.JumpRequest:Connect(function()
        local hum = LSS.Movement.Humanoid()
        if State.Opt.InfJump and hum then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end))
    table.insert(State.Conns, LocalPlayer.CharacterAdded:Connect(function()
        task.wait(1)
        LSS.Movement.Apply()
    end))
end

function LSS.Session.SetLowGraphics(enabled)
    RunService:Set3dRenderingEnabled(not enabled)
end

function LSS.Session.Rejoin()
    local queue = queue_on_teleport or queueonteleport
    if queue then queue(Config.ReloadSource) end
    TeleportService:Teleport(game.PlaceId, LocalPlayer)
end

function LSS.Boss.HopFlag(enabled)
    local flag = Config.SaveFolder .. "/" .. Config.BossHopFlag
    pcall(function()
        if enabled then
            if not isfolder(Config.SaveFolder) then makefolder(Config.SaveFolder) end
            writefile(flag, tostring(os.time()))
        elseif isfile(flag) then
            delfile(flag)
        end
    end)
end

function LSS.Boss.SinceLastHop()
    local ok, stamp = pcall(readfile, Config.SaveFolder .. "/" .. Config.BossHopFlag)
    if not ok or not tonumber(stamp) then return nil end
    return os.time() - tonumber(stamp)
end

function LSS.Boss.HopWanted()
    local since = LSS.Boss.SinceLastHop()
    return since ~= nil and since < Config.BossHopResume
end

function LSS.Boss.LoadServers()
    local ok, text = pcall(readfile, Config.SaveFolder .. "/" .. Config.BossHopServers)
    if not ok then return {}, 0 end
    local decoded
    ok, decoded = pcall(HttpService.JSONDecode, HttpService, text)
    if not ok or type(decoded) ~= "table" or type(decoded.ids) ~= "table" then return {}, 0 end
    local fetchedAt = tonumber(decoded.at) or 0
    if os.time() - fetchedAt > Config.HopListTtl then return {}, 0 end
    return decoded.ids, fetchedAt
end

function LSS.Boss.SaveServers(ids, fetchedAt)
    pcall(function()
        if not isfolder(Config.SaveFolder) then makefolder(Config.SaveFolder) end
        writefile(Config.SaveFolder .. "/" .. Config.BossHopServers, HttpService:JSONEncode({ at = fetchedAt, ids = ids }))
    end)
end

function LSS.Boss.FetchServers()
    if os.clock() < State.HopBlockedUntil then return {} end
    local body = LSS.Util.HttpGet(("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId))
    local ok, list = pcall(HttpService.JSONDecode, HttpService, body or "")
    local ids = {}
    for _, server in ipairs(ok and type(list) == "table" and type(list.data) == "table" and list.data or {}) do
        if server.id ~= game.JobId and server.playing < server.maxPlayers then table.insert(ids, server.id) end
    end
    if #ids > 0 then
        State.HopFails, State.HopBackoff = 0, nil
        return ids
    end
    State.HopFails += 1
    State.HopBackoff = math.min((State.HopBackoff or Config.HopBackoffStart / 2) * 2, Config.HopBackoffMax)
    State.HopBlockedUntil = os.clock() + State.HopBackoff
    warn("[LootToForge] server list refused, retry in", State.HopBackoff, "s, fail", State.HopFails)
    return {}
end

function LSS.Boss.PickServer()
    local ids, fetchedAt = LSS.Boss.LoadServers()
    if #ids == 0 then
        ids, fetchedAt = LSS.Boss.FetchServers(), os.time()
    end
    while #ids > 0 do
        local serverId = table.remove(ids, math.random(#ids))
        if serverId ~= game.JobId then
            LSS.Boss.SaveServers(ids, fetchedAt)
            return serverId
        end
    end
    LSS.Boss.SaveServers(ids, fetchedAt)
    return nil
end

function LSS.Boss.Hop()
    local serverId = LSS.Boss.PickServer()
    if not serverId then return end
    State.BossHopping = os.clock()
    LSS.Boss.HopFlag(true)
    local queue = queue_on_teleport or queueonteleport
    if queue and not State.HopQueued then
        queue(Config.ReloadSource)
        State.HopQueued = true
    end
    TeleportService:TeleportToPlaceInstance(game.PlaceId, serverId, LocalPlayer)
end

function LSS.Boss.WorthStaying()
    local boss = workspace:GetAttribute("CurrentWorldBoss")
    if boss and not State.BossDone then return true end
    if State.BossDone then return os.clock() - State.BossDone < Config.BossHopAfter end
    local nextTick, serverTime = workspace:GetAttribute("NextWorldBossTick"), workspace:GetAttribute("ServerTime")
    if not nextTick or not serverTime then return true end
    return nextTick - serverTime <= Config.BossHopLead
end

function LSS.Boss.HopGiveUp()
    State.Opt.BossHop = false
    LSS.Boss.HopFlag(false)
    table.insert(State.Halted, { "BossHop", "no server list from Roblox, try again later" })
end

function LSS.Boss.HopStep()
    if State.BossHopping then
        if os.clock() - State.BossHopping < Config.HopStall then return end
        State.BossHopping = false
    end
    if LSS.Boss.WorthStaying() then return end
    if (LSS.Boss.SinceLastHop() or Config.HopGap) < Config.HopGap then return end
    if State.HopFails >= Config.HopGiveUp then
        LSS.Boss.HopGiveUp()
        return
    end
    LSS.Boss.Hop()
end

function LSS.Session.Bind()
    table.insert(State.Conns, TeleportService.TeleportInitFailed:Connect(function()
        if not State.BossHopping then return end
        State.BossHopping = false
        task.delay(1, LSS.Util.Try, LSS.Boss.HopStep)
    end))
    table.insert(State.Conns, LocalPlayer.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end))
    table.insert(State.Conns,GuiService.ErrorMessageChanged:Connect(function(msg)
        State.LastErrorText=msg
        if not State.Opt.AutoRejoin or msg=="" or State.RejoinQueued then return end
        State.RejoinQueued=true
        task.delay(Config.RejoinDelay,function()
            State.RejoinQueued=false
            if State.Alive and State.Opt.AutoRejoin and State.LastErrorText~="" then
                LSS.Util.Try(LSS.Session.Rejoin)
            end
        end)
    end))
end

LSS.Scheduler.Jobs = {
    { key = "MaxGear", every = 0, run = function()
        local ok, err = LSS.Util.Exclusive("Gear", LSS.Gear.MaxStep)
        if not ok and err ~= nil then error(err, 0) end
    end },
    { key = "AutoForge", every = 0, run = function() LSS.Forge.Step() end },
    { key = "AutoEquip", every = Config.EquipInterval, run = function() LSS.Gear.EquipBest() end },
    { key = "AutoSell", every = Config.SellInterval, run = function() LSS.Sell.Run(LSS.Data.Get()) end },
    { key = "AutoTrain", every = 1, run = function() LSS.Level.TrainStep() end },
    { key = "AutoRebirth", every = Config.RebirthInterval, run = function() LSS.Level.RebirthStep() end },
    { key = "AutoUpgrade", every = Config.UpgradeInterval, run = function() LSS.Upgrade.BuySelected() end },
    { key = "AutoTower", every = 0, run = function() LSS.Tower.FarmStep() end },
    { key = "AutoWorldBoss", every = Config.BossInterval, run = function() LSS.Boss.Step() end },
    { key = "BossHop", every = Config.BossHopInterval, run = function() LSS.Boss.HopStep() end },
    { key = "AutoClaim", every = Config.ClaimInterval, run = function() LSS.Claim.All() end },
    { key = "AutoSeason", every = Config.SeasonInterval, run = function() LSS.Season.Step() end },
    { key = "AutoBestRace", every = 10, run = function() LSS.Race.EquipBest() end },
    { key = "AutoIndex", every = Config.IndexInterval, run = function()
        local ok, err = LSS.Util.Exclusive("Index", LSS.Index.HuntAll)
        if not ok and err ~= nil then error(err, 0) end
    end },
}

function LSS.Scheduler.Run(key,fn)
    if not State.Alive or not State.Opt[key] then return false end
    local failures=State.Failures
    local streak=failures[key]
    local now=os.clock()
    if streak and now<(streak.nextTry or 0) then return false end
    local ok,result=pcall(fn)
    if ok then failures[key]=nil;return true,result end
    now=os.clock()
    if not streak then
        streak={count=0,since=now}
        failures[key]=streak
        LSS.Util.WarnJob(key,result)
    end
    streak.count+=1
    streak.nextTry=now+math.min(Config.RetryMax,Config.RetryBase*2^math.min(streak.count-1,8))
    if streak.count>=Config.MaxFailures and now-streak.since>=Config.FailWindow then
        failures[key]=nil
        State.Opt[key]=false
        local reason=tostring(result):match("[^\n]*")
        warn("[LootToForge]",key,"stopped:",reason)
        table.insert(State.Halted,{key,reason})
    end
    return false,result
end

-- One persistent worker per fast feature, including rapid off/on toggles.
function LSS.Scheduler.StartLoop(key,fn,interval,minimum)
    if State.WorkerLoops[key] then return end
    State.WorkerLoops[key]=true
    task.spawn(function()
        local ok,err=pcall(function()
            while State.Alive do
                local started = os.clock()
                if State.Opt[key] then LSS.Scheduler.Run(key,fn) end
                local delay=State.Opt[key] and interval() or 0.1
                local period = math.max(minimum == nil and 0.04 or minimum,tonumber(delay) or 0.1)
                local elapsed = os.clock() - started
                -- Account for call time without replaying missed ticks after a stall.
                task.wait(elapsed < period and math.max(0.001,period-elapsed) or period)
            end
        end)
        State.WorkerLoops[key]=nil
        if not ok then LSS.Util.WarnJob(key,err) end
    end)
end

function LSS.Scheduler.Step()
    if State.Lock then return end
    local now = os.clock()
    for _, job in ipairs(LSS.Scheduler.Jobs) do
        if not State.Opt[job.key] or State.Lock then continue end
        if now - (State.LastRun[job.key] or 0) < job.every then continue end
        State.LastRun[job.key] = now
        LSS.Scheduler.Run(job.key, job.run)
    end
end

function LSS.Scheduler.Start()
    task.spawn(function()
        while State.Alive do
            if not State.Busy then
                State.Busy = true
                LSS.Util.Try(LSS.Scheduler.Step)
                State.Busy = false
            end
            task.wait(Config.TickDelay)
        end
    end)
end

function LSS.Scheduler.Boot()
    for _, bind in ipairs({ LSS.Movement.Bind, LSS.Level.Bind, LSS.SuperLoot.Bind, LSS.Boss.Bind, LSS.Session.Bind }) do
        LSS.Util.Try(bind)
    end
    LSS.Scheduler.Start()
end

function LSS.Scheduler.Stop()
    State.Alive = false
    for _, conn in ipairs(State.Conns) do
        conn:Disconnect()
    end
    table.clear(State.Conns)
    if State.Opt.AutoTrain then
        State.Opt.AutoTrain = false
        task.spawn(LSS.Util.Try, LSS.Level.SetTraining, false)
    end
    if State.Opt.SpeedOn then
        State.Opt.SpeedOn = false
        LSS.Movement.Apply()
    end
    if State.Opt.LowGraphics then
        LSS.Session.SetLowGraphics(false)
    end
    LSS.Util.Try(LSS.Tower.Exit)
    if LocalPlayer:GetAttribute("IntoFight") == "WorldBoss" then LSS.Util.Try(LSS.Boss.Leave) end
    LSS.Guard.Stop()
end

local function BuildInterface()
    local NoxLibrary
    do
        local okLibrary, loaded = pcall(function()
            return loadstring(game:HttpGet(UI_SOURCE_URL))()
        end)
        if not okLibrary or type(loaded) ~= "table" then
            LSS.Util.Alert("Could not load the menu. Check your connection and run it again.", tostring(loaded))
            return
        end
        NoxLibrary = loaded
    end
    NoxLibrary:LoadFont({ Name = "ValleySans" })
    NoxLibrary:SetDefaultTheme("Mono")

    local NoxWindow
    local Options = {}
    local Library = { Options = Options, Window = nil }

    local TAB_ICONS = {
        ["Main"] = "layout-dashboard",
        ["Combat & Farm"] = "swords",
        ["Forge"] = "hammer",
        ["Sell"] = "coins",
        ["Upgrade & Rebirth"] = "crown",
        ["Tower"] = "castle",
        ["Spawn Items"] = "package",
        ["Player"] = "user",
        ["Settings"] = "settings",
    }

    function Library:T(en)
        return en
    end
    function Library:Translate(text)
        return text
    end
    function Library:OnLanguageChanged() end
    function Library:Feedback() end
    function Library:Notify(_, text, _seconds, kind)
        -- Tanpa toast di layar (pojok kanan bawah). Hanya error yang dicatat ke console.
        if kind == "Error" then
            warn("[LootToForge]", tostring(text))
        end
    end
    function Library:OnUnload(callback)
        API.Track(callback)
    end
    function Library:Unload()
        API.Unload()
    end
    function Library:Every(interval, callback)
        task.spawn(function()
            while not API.Unloaded do
                pcall(callback)
                task.wait(interval)
            end
        end)
    end

    Library.Compat = { Caps = {} }
    function Library.Compat.Block(option, reason)
        pcall(function()
            option.Element:SetDisabled(true)
        end)
        warn("[NOX] feature blocked:", reason)
    end
    function Library.Compat.NeedCap(option, capability)
        if capability == "Namecall" and not (type(hookmetamethod) == "function" and type(getnamecallmethod) == "function") then
            Library.Compat.Block(option, "Not available on this executor")
        end
    end
    LSS.Compat = Library.Compat

    local function listToSet(list)
        local set = {}
        if type(list) == "table" then
            for _, item in ipairs(list) do
                set[item] = true
            end
        end
        return set
    end

    local Group = {}
    Group.__index = Group

    local function wrap(element, key, value)
        local object = { Element = element, Value = value }
        function object:SetValue(newValue)
            self.Element:Set(newValue)
        end
        function object:SetValues(list)
            if self.Element.SetOptions then
                self.Element:SetOptions(list, { KeepSelection = true, Silent = true })
            end
        end
        if key then
            Options[key] = object
        end
        return object
    end

    function Group:AddToggle(key, def)
        local object
        local element = self.Raw:CreateToggle({
            Name = def.Text,
            Desc = def.Description,
            CurrentValue = def.Default == true,
            Flag = (not def.NoSave) and key or nil,
            Callback = function(value)
                if object then
                    object.Value = value
                end
                if def.Callback then
                    def.Callback(value)
                end
            end,
        })
        object = wrap(element, key, def.Default == true)
        local rawSet = element.Set
        function object:SetValue(newValue)
            if self.Value == newValue then
                return
            end
            self.Value = newValue
            element:Set(newValue)
        end
        local group = self
        function object:AddKeyPicker(pickerKey)
            group.Raw:CreateKeybind({
                Name = tostring(def.Text) .. " key",
                CurrentKeybind = nil,
                Flag = pickerKey,
                Callback = function()
                    object:SetValue(not object.Value)
                end,
            })
            return object
        end
        return object
    end
    Group.AddCheckbox = Group.AddToggle

    function Group:AddDropdown(key, def)
        local object
        local multi = def.Multi == true
        local values = def.Values or {}
        local default = def.Default
        if multi then
            if type(default) ~= "table" then
                default = {}
            end
        elseif type(default) == "number" then
            default = values[default]
        end
        local function convert(value)
            if multi then
                return listToSet(value)
            end
            if type(value) == "table" then
                return value[1]
            end
            return value
        end
        local element = self.Raw:CreateDropdown({
            Name = def.Text,
            Desc = def.Description,
            Options = values,
            CurrentOption = default,
            MultipleOptions = multi,
            AllowNone = multi,
            Searchable = def.Searchable,
            Flag = (not def.NoSave) and key or nil,
            Callback = function(value)
                local converted = convert(value)
                if object then
                    object.Value = converted
                end
                if def.Callback then
                    def.Callback(converted)
                end
            end,
        })
        object = wrap(element, key, convert(default))
        return object
    end

    function Group:AddSlider(key, def)
        local object
        local element = self.Raw:CreateSlider({
            Name = def.Text,
            Desc = def.Description,
            Range = { def.Min, def.Max },
            Increment = 10 ^ -(def.Rounding or 0),
            CurrentValue = def.Default,
            Flag = (not def.NoSave) and key or nil,
            Callback = function(value)
                if object then
                    object.Value = value
                end
                if def.Callback then
                    def.Callback(value)
                end
            end,
        })
        object = wrap(element, key, def.Default)
        return object
    end

    function Group:AddInput(key, def)
        local object
        local element = self.Raw:CreateInput({
            Name = def.Text,
            Desc = def.Description,
            PlaceholderText = def.Placeholder,
            CurrentValue = def.Default,
            Numeric = def.Numeric,
            Flag = (not def.NoSave) and key or nil,
            Callback = function(value)
                if object then
                    object.Value = value
                end
                if def.Callback then
                    def.Callback(value)
                end
            end,
        })
        object = wrap(element, key, def.Default)
        return object
    end

    function Group:AddButton(def)
        local style = def.Style
        if style ~= "Primary" and style ~= "Danger" then
            style = nil
        end
        self.Raw:CreateButton({
            Name = def.Text,
            Style = style,
            Confirm = def.Risky and true or nil,
            Callback = def.Func,
        })
        return self
    end

    function Group:AddDivider()
        self.Raw:CreateDivider()
    end

    function Group:AddLabel(text)
        local handle = self.Raw:CreateLabel({ Text = tostring(text) })
        return {
            SetText = function(_, newText)
                handle:Set(tostring(newText))
            end,
        }
    end

    function Group:AddParagraph(def)
        self.Raw:CreateParagraph({ Title = def.Title, Content = def.Content })
    end

    function Group:AddStatCard(def)
        local title = tostring(def.Title)
        local handle = self.Raw:CreateLabel({ Text = title .. ": " .. tostring(def.Value or "-") })
        local card = {}
        function card:SetValue(value)
            handle:Set(title .. ": " .. tostring(value))
        end
        function card:SetStatus() end
        return card
    end

    local Tab = {}
    Tab.__index = Tab

    function Tab:AddLeftGroupbox(title)
        return setmetatable({ Raw = self.Raw:AddLeftGroupbox({ Name = tostring(title) }) }, Group)
    end
    function Tab:AddRightGroupbox(title)
        return setmetatable({ Raw = self.Raw:AddRightGroupbox({ Name = tostring(title) }) }, Group)
    end

    local function newTab(title)
        local raw = NoxWindow:CreateTab({ Name = tostring(title), Icon = TAB_ICONS[title] or "circle" })
        return setmetatable({ Raw = raw }, Tab)
    end

    local WindowShim = {}
    function WindowShim:AddTabSection() end
    function WindowShim:AddTab(title)
        return newTab(title)
    end
    function WindowShim:AddSettingsTab()
        return newTab("Settings")
    end
    function WindowShim:SetSessionStatus() end

    local T = function(en) return en end
    local opt = State.Opt
    local featureNames = {}
    local uiQueue = {}
    local dashboard = {}
    local activityLabel

    local function Source(fn)
        local ok, first, second = pcall(fn)
        if not ok then
            warn("[LootToForge] menu data:", first)
            return {}, {}
        end
        return first or {}, second or {}
    end

    local rarityNames = Source(LSS.Util.RarityNames)

    local function Later(fn, ...)
        local args = table.pack(...)
        table.insert(uiQueue, function()
            fn(table.unpack(args, 1, args.n))
        end)
    end

    local function Notify(text, kind, seconds)
        Later(Library.Notify, Library, "NOX HUB", text, seconds or 4, kind or "Info")
    end

    local function TurnOff(key)
        local toggle = Options[key]
        if toggle and toggle.Value then toggle:SetValue(false) end
    end

    local function AllOff()
        TurnOff("Kaitun")
        for key in pairs(featureNames) do TurnOff(key) end
        if Library.Window then Library.Window:SetSessionStatus("Stopped", 0, "Off") end
    end

    local function SetList(idx, values, pickFirst)
        local dropdown = Options[idx]
        if not dropdown then return end
        dropdown:SetValues(values)
        if pickFirst and values[1] then
            dropdown:SetValue(values[1])
        elseif dropdown.Value ~= opt[idx] then
            dropdown:SetValue(dropdown.Value)
        end
    end

    local function NeedModule(option, module)
        if LSS.GameLib.Require(module) then return end
        LSS.Compat.Block(option, T("Not available on this executor", "ใช้กับ executor นี้ไม่ได้"))
    end

    local function BlockMissing()
        local missing = LSS.GameLib.Missing()
        local deadline = os.clock() + 6
        while next(missing) and os.clock() < deadline do
            task.wait(1)
            missing = LSS.GameLib.Missing()
        end
        if next(missing) then LSS.Util.DumpRemotes(missing) end
        for idx, paths in pairs(missing) do
            warn("[LootToForge]", idx, "blocked, missing:", table.concat(paths, ", "))
            if Options[idx] then LSS.Compat.Block(Options[idx], T("Not available after a game update", "ใช้ไม่ได้หลังเกมอัปเดต")) end
        end
    end

    local function Pump()
        local notice = State.FarmNotice
        if notice then
            State.FarmNotice = nil
            Notify(notice.text, notice.kind)
        end
        for _, halt in ipairs(State.Halted) do
            TurnOff(halt[1])
            Notify(("%s stopped: %s"):format(featureNames[halt[1]] or halt[1], halt[2]), "Warning")
        end
        table.clear(State.Halted)

        local jobs = uiQueue
        uiQueue = {}
        for _, job in ipairs(jobs) do
            LSS.Util.Try(job)
        end
    end

    local function Action(action, feedback)
        return function()
            task.defer(function()
                local ok, result = LSS.Util.Try(action)
                if not ok then
                    Later(Library.Feedback, Library, "Error")
                    Notify("Action failed; check the console", "Error")
                elseif feedback and (result == true or (type(result) == "number" and result > 0)) then
                    Later(Library.Feedback, Library, feedback)
                    Notify(feedback .. " completed", "Success")
                elseif feedback then
                    Notify("No confirmed result yet", "Warning")
                end
            end)
        end
    end

    local function LongAction(name, action, done)
        return function()
            task.defer(function()
                if State.Lock then return Notify("Busy: " .. State.Lock, "Warning") end
                Notify(name .. "...")
                local outcome
                local completed = LSS.Util.Exclusive(name, function() outcome = action() end)
                if not completed then
                    Notify(name .. " failed; check the console", "Error")
                elseif done then
                    Notify(done(outcome), "Success")
                end
            end)
        end
    end

    local function Toggle(group, key, text, description, onChange, risky)
        featureNames[key] = text
        return group:AddToggle(key, {
            Text = text,
            Description = description,
            Risky = risky,
            Default = opt[key],
            Callback = function(value)
                opt[key] = value
                State.Failures[key] = nil
                if onChange then
                    onChange(value)
                end
            end,
        })
    end

    local Feature = Toggle

    local function HotkeyFeature(group, key, text, description, onChange, risky)
        return Toggle(group, key, text, description, onChange, risky):AddKeyPicker(key .. "Key", { Default = "None", Mode = "Toggle" })
    end

    local function Check(group, key, text)
        return group:AddCheckbox(key, {
            Text = text,
            Default = opt[key],
            Callback = function(value)
                opt[key] = value
                State.Failures[key] = nil
            end,
        })
    end

    local function MultiSelect(group, key, text, description, values)
        opt[key] = LSS.Util.AllSet(values)
        return group:AddDropdown(key, {
            Text = text,
            Description = description,
            Values = values,
            Multi = true,
            Default = values,
            Searchable = #values > 8,
            Callback = function(selected)
                opt[key] = selected
            end,
        })
    end

    local function Pick(group, key, text, description, source, noSave, risky)
        local values = Source(source)
        opt[key] = values[1]
        return group:AddDropdown(key, {
            Text = text,
            Description = description,
            Risky = risky,
            Values = values,
            Default = 1,
            Searchable = #values > 8,
            NoSave = noSave,
            Callback = function(value)
                opt[key] = value
                State.Failures[key] = nil
            end,
        })
    end

    local function NumberInput(group, key, text, description, minimum)
        return group:AddInput(key, {
            Text = text,
            Description = description,
            Default = tostring(opt[key]),
            Numeric = true,
            Finished = true,
            Callback = function(value)
                opt[key] = math.max(minimum or 0, math.floor(tonumber(value) or opt[key]))
            end,
        })
    end

    local function RefreshButton(idx, list)
        return { Text = T("Refresh", "รีเฟรช"), Func = function()
            task.defer(function()
                Later(SetList, idx, (Source(list)))
            end)
        end }
    end

    local function BuildMain(tab)
        local statusBox = tab:AddLeftGroupbox(T("Session dashboard", "สถานะเซสชัน"), "chart")
        dashboard.Level = statusBox:AddStatCard({ Title = T("Level", "เลเวล"), Value = "—", Icon = "level-up", Status = "Waiting" })
        dashboard.Coins = statusBox:AddStatCard({ Title = T("Coins", "เหรียญ"), Value = "—", Icon = "coin-stack", Status = "Waiting" })
        dashboard.Rebirth = statusBox:AddStatCard({ Title = T("Rebirth", "รีเบิร์ธ"), Value = "—", Icon = "rebirth", Status = "Waiting" })
        local activity = tab:AddRightGroupbox(T("Live activity", "งานปัจจุบัน"), "signal")
        dashboard.Task = activity:AddStatCard({ Title = T("Current task", "งานปัจจุบัน"), Value = "Idle", Icon = "clock", Status = "Off" })
        dashboard.Gear = activity:AddStatCard({ Title = T("Equipped gear", "อุปกรณ์ที่ใส่"), Value = "—", Icon = "armor", Status = "Waiting", Multiline = true })
        dashboard.Tower = activity:AddStatCard({ Title = T("Tower loot", "ของจากหอคอย"), Value = "0", Icon = "chest", Status = "Off" })
        activityLabel = activity:AddLabel(T("• Off / No active features", "• ปิด / ไม่มีงาน", "• Mati / Tidak ada fitur aktif"), true)

        local kaitunBox = tab:AddLeftGroupbox(T("Kaitun", "ไก่ตัน"), "robot-work")
        kaitunBox:AddToggle("Kaitun", {
            Text = T("Kaitun (All-in-one)", "ไก่ตัน (ทำทุกอย่าง)"),
            Description = T("Best gear, money, level, rewards and bosses all at once", "ของดีสุด เงิน เลเวล รางวัล และบอส ทำพร้อมกันทั้งหมด"),
            NoSave = true,
            Callback = function(value)
                for _, key in ipairs(Config.KaitunToggles) do
                    if Options[key] then Options[key]:SetValue(value) end
                end
            end,
        })
        kaitunBox:AddButton({ Text = T("Panic - All Off", "ฉุกเฉิน ปิดทั้งหมด"), Style = "Danger", Func = function()
            AllOff()
        end })

        local gearBox = tab:AddRightGroupbox(T("Max Gear", "อุปกรณ์สูงสุด"), "crown")
        Feature(gearBox, "MaxGear", T("Max Gear", "อุปกรณ์สูงสุด"),
            T("Best gear and runes, enhanced to your target. Finds anything missing by itself", "ของดีสุด รูนดีสุด ตีบวกถึงเป้า ขาดอะไรหาเองหมด"),
            function()
                State.GearForged = false
            end)
        Check(gearBox, "GearForge", T("Forge best gear", "หลอมของดีสุด"))
        Check(gearBox, "GearEnchant", T("Best runes", "ใส่รูนดีสุด"))
        Check(gearBox, "GearEnhance", T("Enhance", "ตีบวก"))
        gearBox:AddSlider("EnhanceTarget", {
            Text = T("Enhance Target", "ตีบวกถึง"),
            Description = T("Above +10 the success rate gets very low and can take a long time", "เกิน +10 โอกาสสำเร็จต่ำมาก อาจใช้เวลานาน"),
            Min = 5, Max = 20, Default = opt.EnhanceTarget, Rounding = 0, Prefix = "+",
            Callback = function(value)
                opt.EnhanceTarget = value
            end,
        })
        local runes = LSS.Gear.RuneOrder()
        opt.EnchantPriority = table.clone(runes)
        gearBox:AddDropdown("EnchantPriority", {
            Text = T("Runes To Use", "รูนที่ใช้"),
            Description = T("Stronger runes go in first", "รูนที่แรงกว่าใส่ก่อน"),
            Values = runes,
            Multi = true,
            Default = runes,
            Searchable = #runes > 8,
            Callback = function(selected)
                local order = {}
                for _, stoneId in ipairs(runes) do
                    if selected[stoneId] then order[#order + 1] = stoneId end
                end
                if #order == 0 then Notify("No rune selected, using all runes", "Warning") end
                opt.EnchantPriority = order
            end,
        })

        local equipBox = tab:AddLeftGroupbox(T("Equip", "ใส่ของ"), "armor")
        Feature(equipBox, "AutoEquip", T("Auto Equip Best", "ใส่ของดีสุดอัตโนมัติ"), T("Always wears your strongest weapon, armor and hat, counting enhance level", "ใส่อาวุธ เกราะ และหมวกที่แรงที่สุดเสมอ นับระดับตีบวกด้วย"))
        equipBox:AddButton({ Text = T("Equip Best Now", "ใส่ของดีสุดเดี๋ยวนี้"), Func = function()
            task.defer(function()
                local changed = LSS.Gear.EquipBest()
                Notify(changed > 0 and ("Equipped %d better item(s)"):format(changed) or "Already wearing your best gear")
            end)
        end })

        equipBox:AddDivider()
        equipBox:AddDropdown("EnhanceSlot", {
            Text = T("Enhance Slot", "ช่องที่ตีบวก"),
            Values = Config.GearTypes,
            Default = opt.EnhanceSlot,
            Callback = function(value)
                opt.EnhanceSlot = value or opt.EnhanceSlot
            end,
        })
        equipBox:AddButton({ Text = T("Enhance To Target", "ตีบวกถึงเป้า"), Style = "Primary", Func = LongAction("Enhance", function()
            return LSS.Gear.EnhanceSlot(opt.EnhanceSlot, opt.EnhanceTarget)
        end, function(level) return level and ("%s is +%d"):format(opt.EnhanceSlot, level) or "Nothing equipped there" end) })

        local rewardBox = tab:AddRightGroupbox(T("Rewards", "รางวัล"), "chest-open")
        Feature(rewardBox, "AutoClaim", T("Auto Claim", "รับรางวัลอัตโนมัติ"), T("Claims every free reward, including index", "รับรางวัลฟรีทุกอย่าง รวมสมุดสะสม"))
        rewardBox:AddButton({ Text = T("Claim Now", "รับเดี๋ยวนี้"), Style = "Success", Func = Action(LSS.Claim.All) })
        rewardBox:AddButton({ Text = T("Redeem All Codes", "ใช้โค้ดทั้งหมด"), Style = "Primary", Func = Action(function()
            Notify(LSS.Claim.AllCodes(), "Success", 6)
        end) })
        rewardBox:AddInput("Code", {
            Text = T("Redeem Code", "ใส่โค้ด"),
            Placeholder = T("Code", "โค้ด"),
            Finished = true,
            NoSave = true,
            Callback = function(value)
                if value == "" then return end
                task.defer(function()
                    Notify("Code: " .. tostring(LSS.Claim.Code(value)))
                end)
            end,
        })
    end

    local function BuildFarm(tab)
        local stageBox = tab:AddLeftGroupbox(T("Stage", "ด่าน"), "map-scroll")
        Pick(stageBox, "Stage", T("Stage", "ด่าน"), T("Any stage, no unlock needed", "เลือกด่านไหนก็ได้ ไม่ต้องปลดล็อก"), LSS.Stage.List)
        Feature(stageBox, "CollectOre", T("Auto Collect Ore", "เก็บแร่อัตโนมัติ"), Library:T("Rarity filter always applies; highest rarity picked first", "เก็บตามตัวกรองและเลือกแร่หายากก่อน", "Selalu mengikuti filter; ore rarity tertinggi diambil dulu"), function(value)
            if value then
                LSS.Stage.StartCollecting()
                Notify(Library:T("Ore farm started: selected rarities only", "เริ่มเก็บแร่ตามตัวกรอง", "Farm ore aktif: hanya rarity pilihan"), "Success")
            else
                Notify(Library:T("Ore farm paused; pending requests will finish", "หยุดเก็บแร่ รอคำขอที่ส่งแล้ว", "Farm ore dijeda; request yang sedang berjalan akan diselesaikan"), "Info")
            end
        end)
        stageBox:AddSlider("FarmWorkers", {Text=Library:T("Ore pickup workers", "จำนวนตัวเก็บแร่", "Worker pengambil ore"), Min=1, Max=999, Default=opt.FarmWorkers, Rounding=0, Callback=function(value) opt.FarmWorkers=value end})
        MultiSelect(stageBox, "CollectRarities", T("Ore Rarity Filter", "กรอง rarity แร่"), T("Only collect these rarities", "เก็บเฉพาะ rarity ที่เลือก"), rarityNames)

        local combatBox = tab:AddLeftGroupbox(T("Combat", "ต่อสู้"), "sword")
        local killAura = Feature(combatBox, "KillAura", T("Kill Aura", "ฆ่ารอบตัว"), T("Every monster in your fight dies instantly", "มอนสเตอร์ทุกตัวในการต่อสู้ตายทันที"), function(value)
            if value then LSS.Combat.Start() end
        end)
        NeedModule(killAura, ReplicatedStorage.Utils.CommunicationUtils)
        Feature(combatBox, "SuperLootAura", T("Kill Ore Boss", "ฆ่าบอสแร่"), T("Kills rare ore bosses the moment they spawn", "ฆ่าบอสแร่หายากทันทีที่เกิด"), function(value)
            if value then LSS.SuperLoot.KillExisting() end
        end)
        combatBox:AddButton({ Text = T("Exit Fight Now", "ออกจากการต่อสู้เดี๋ยวนี้"), Style = "Warning", Func = Action(LSS.Stage.ExitFight) })

        local bossBox = tab:AddRightGroupbox(T("World Boss", "บอสโลก"), "boss")
        Feature(bossBox, "AutoWorldBoss", T("Auto World Boss", "บอสโลกอัตโนมัติ"), T("Joins every world boss and kills it", "เข้าบอสโลกทุกรอบแล้วฆ่า"), function(value)
            if not value and LocalPlayer:GetAttribute("IntoFight") == "WorldBoss" then task.spawn(LSS.Util.Try, LSS.Boss.Leave) end
        end)
        Check(bossBox, "BossCards", T("Take every reward card", "เปิดการ์ดรางวัลทุกใบ"))
        Feature(bossBox, "BossHop", T("Boss Server Hop", "ย้ายเซิร์ฟหาบอส"), T("Hops to servers where the boss is up or about to spawn, kills it, then moves on", "ย้ายไปเซิร์ฟที่บอสเกิดอยู่หรือใกล้เกิด ฆ่าแล้วย้ายต่อ"), function(value)
            LSS.Boss.HopFlag(value)
            if value and Options.AutoWorldBoss and not Options.AutoWorldBoss.Value then Options.AutoWorldBoss:SetValue(true) end
        end, true)

        local indexBox = tab:AddRightGroupbox(T("Index", "สมุดสะสม"), "book")
        MultiSelect(indexBox, "IndexTypes", T("Index Types", "ประเภทที่จะเก็บ"), nil, Config.GearTypes)
        Pick(indexBox, "MissingItem", T("Missing Item", "ของที่ยังไม่มี"), T("Chance shown is per forge with the best ore", "เปอร์เซ็นต์ = โอกาสต่อการหลอมหนึ่งครั้งด้วยแร่ที่ดีที่สุด"), function()
            return { "..." }
        end, true)
        task.defer(function()
            local ok, labels = pcall(LSS.Index.Choices)
            if ok then
                Later(SetList, "MissingItem", labels, true)
            else
                warn("[LootToForge] index list:", labels)
            end
        end)
        indexBox:AddButton({ Text = T("Get Selected", "หาชิ้นนี้"), Style = "Primary", Func = LongAction("Index", function()
            local gear = State.MissingLabels[opt.MissingItem]
            return gear and LSS.Index.Hunt(gear)
        end, function(got)
            Later(SetList, "MissingItem", (Source(LSS.Index.Choices)))
            return got and "Got it!" or "Not found this time, press again"
        end) }):AddButton(RefreshButton("MissingItem", LSS.Index.Choices))
        Feature(indexBox, "AutoIndex", T("Auto Complete Index", "เก็บสมุดสะสมอัตโนมัติ"), T("Forges every missing weapon, armor and hat, then claims rewards", "หลอมอาวุธ เกราะ หมวกที่ยังไม่มีทุกชิ้น แล้วรับรางวัล"), nil, true)
        indexBox:AddButton({ Text = T("Collect All Ores", "เก็บแร่ทุกชนิด"), Func = LongAction("Ores", LSS.Index.CollectOres, function()
            local count, level = LSS.Index.Progress()
            return ("Index %d, level %d"):format(count, level)
        end) }):AddButton({ Text = T("Claim Rewards", "รับรางวัล"), Style = "Success", Func = Action(LSS.Index.ClaimAll) })
    end

    local function BuildForge(tab)
        local forgeBox = tab:AddLeftGroupbox(T("Forge", "หลอม"), "anvil")
        local targetNames = {}
        for _, target in ipairs(Config.ForgeTargets) do
            targetNames[#targetNames + 1] = target.name
        end
        forgeBox:AddDropdown("ForgeTarget", {
            Text = T("Target Gear", "อุปกรณ์ที่จะหลอม"),
            Values = targetNames,
            Default = 1,
            Callback = function(value)
                opt.ForgeTarget = value or opt.ForgeTarget
            end,
        })
        Pick(forgeBox, "ForgeOre", T("Ore To Use", "แร่ที่ใช้หลอม"), T("Pick an ore and it never runs out", "เลือกแร่แล้วไม่มีวันหมด"), LSS.Ore.ForgeChoices, nil, true)
        Feature(forgeBox, "AutoForge", T("Auto Forge", "หลอมอัตโนมัติ"), T("Forges the target gear nonstop", "หลอมอุปกรณ์ที่เลือกไม่หยุด"))
        forgeBox:AddButton({ Text = T("Forge Now", "หลอมเดี๋ยวนี้"), Style = "Primary", Func = Action(LSS.Forge.Step, "Forge") })
        forgeBox:AddSlider("ForgePerTick", {
            Text = T("Forges Per Round", "หลอมต่อรอบ"),
            Min = 1, Max = 50, Default = opt.ForgePerTick, Rounding = 0,
            Callback = function(value)
                opt.ForgePerTick = value
            end,
        })
        Check(forgeBox, "ForgeSellJunk", T("Sell worse gear right away", "ขายของที่แย่กว่าที่ใส่ทันที"))

        local oreUseBox = tab:AddRightGroupbox(T("Ore Usage", "การใช้แร่"), "ore")
        oreUseBox:AddLabel(T("Used when Ore To Use is Owned ores", "ใช้ตอนแร่ที่ใช้หลอม = Owned ores"))
        Toggle(oreUseBox, "BestOreFirst", T("Spend Best Ore First", "ใช้แร่ดีสุดก่อน"), T("Off = spend the weakest ore first", "ปิด = ใช้แร่ที่อ่อนที่สุดก่อน"))
        MultiSelect(oreUseBox, "ForgeRarities", T("Forge Ore Rarity", "rarity แร่ที่ใช้หลอม"), T("Only these ore rarities are used for forging", "ใช้แร่เฉพาะ rarity ที่เลือกในการหลอม"), rarityNames)
        NumberInput(oreUseBox, "KeepPerOre", T("Keep Per Ore", "เก็บแร่ไว้ชนิดละ"), T("Never forge below this amount of each ore", "ไม่หลอมจนแร่แต่ละชนิดต่ำกว่าจำนวนนี้"))
    end

    local function BuildSell(tab)
        local sellBox = tab:AddLeftGroupbox(T("Auto Sell", "ขายอัตโนมัติ"), "coinbag")
        Feature(sellBox, "AutoSell", T("Auto Sell", "ขายอัตโนมัติ"), T("Sells gear that matches your filters. Equipped gear is never sold", "ขายอุปกรณ์ที่ตรงตัวกรอง ของที่ใส่อยู่จะไม่ขาย"))
        sellBox:AddButton({ Text = T("Sell All Now", "ขายทั้งหมดเดี๋ยวนี้"), Style = "Primary", Func = Action(function()
            LSS.Sell.Run(LSS.Data.Get())
            Notify("Sold", "Coin")
        end) })

        local filterBox = tab:AddRightGroupbox(T("Filters", "ตัวกรอง"), "filter")
        MultiSelect(filterBox, "SellTypes", T("Sell Item Types", "ประเภทที่จะขาย"), nil, Config.GearTypes)
        MultiSelect(filterBox, "SellRarities", T("Sell Rarity Filter", "กรอง rarity ที่จะขาย"), T("Only sell these rarities", "ขายเฉพาะ rarity ที่เลือก"), rarityNames)
        NumberInput(filterBox, "KeepPerItem", T("Keep Per Item", "เก็บไว้ชิ้นละ"), T("Keeps this many of each item, highest enhance first", "เก็บแต่ละไอเทมไว้ตามจำนวนนี้ เลือกตัวตีบวกสูงสุดก่อน"))
    end

    local function BuildProgress(tab)
        local trainBox = tab:AddLeftGroupbox(T("Training", "ฝึก"), "xp")
        Feature(trainBox, "AutoTrain", T("Auto Train", "ฝึกอัตโนมัติ"), T("Trains at the best area nonstop and drinks your potions", "ฝึกโซนดีสุดไม่หยุด ใช้ยาให้เอง"), function(value)
            task.spawn(LSS.Util.Try, LSS.Level.SetTraining, value)
        end)
        local autoClick = Feature(trainBox, "AutoClick", T("Auto Click", "คลิกอัตโนมัติ"), Library:T("Steady training clicks; pauses while typing or respawning", "คลิกฝึกสม่ำเสมอ หยุดตอนพิมพ์หรือเกิดใหม่", "Klik latihan stabil; jeda saat mengetik atau respawn"), function(value)
            if value then LSS.Level.StartClicking() end
        end)
        NeedModule(autoClick, ReplicatedStorage.CTRL.TrainCTRL)
        trainBox:AddSlider("ClickRate",{Text=Library:T("Clicks per second","คลิกต่อวินาที","Klik per detik"),Min=1,Max=25,Default=opt.ClickRate,Rounding=0,Callback=function(value) opt.ClickRate=value end})
        trainBox:AddToggle("ClickPauseTyping",{Text=Library:T("Pause while typing","หยุดขณะพิมพ์","Jeda saat mengetik"),Default=opt.ClickPauseTyping,Callback=function(value) opt.ClickPauseTyping=value end})
        Feature(trainBox, "AutoRebirth", T("Auto Rebirth", "รีเบิร์ธอัตโนมัติ"), T("Rebirths as soon as your level is high enough", "รีเบิร์ธทันทีเมื่อเลเวลถึง"))
        trainBox:AddButton({ Text = T("Rebirth Now", "รีเบิร์ธเดี๋ยวนี้"), Func = Action(LSS.Level.Rebirth) })

        local upgradeBox = tab:AddRightGroupbox(T("Upgrades", "อัปเกรด"), "level-up")
        MultiSelect(upgradeBox, "Upgrades", T("Upgrades To Buy", "อัปเกรดที่จะซื้อ"), nil, (Source(LSS.Upgrade.Names)))
        Feature(upgradeBox, "AutoUpgrade", T("Auto Buy Upgrades", "ซื้ออัปเกรดอัตโนมัติ"), T("Buys the selected upgrades whenever possible", "ซื้ออัปเกรดที่เลือกทุกครั้งที่ซื้อได้"))
        upgradeBox:AddButton({ Text = T("Buy Upgrade Now", "ซื้ออัปเกรดเดี๋ยวนี้"), Func = Action(LSS.Upgrade.BuySelected) })
    end

    local function BuildTower(tab)
        local towerBox = tab:AddLeftGroupbox(T("Tower", "หอคอย"), "tower")
        Feature(towerBox, "AutoTower", T("Auto Farm Tower", "ฟาร์มหอคอยอัตโนมัติ"), T("Top floor loot nonstop on one ticket: rare stones and season coins", "ของชั้นบนสุดไม่หยุดด้วยตั๋วใบเดียว ได้หินหายากและเหรียญซีซั่น"), function(value)
            task.defer(function()
                if not value then return LSS.Util.Try(LSS.Tower.Exit) end
                if not LSS.Tower.Enter() then Notify("No tower ticket", "Warning") end
            end)
        end)
        towerBox:AddButton({ Text = T("Exit Tower Now", "ออกจากหอคอยเดี๋ยวนี้"), Style = "Warning", Func = function()
            Options.AutoTower:SetValue(false)
            task.spawn(LSS.Util.Try, LSS.Tower.Exit)
        end })

        local seasonBox = tab:AddRightGroupbox(T("Season", "ซีซั่น"), "star-medal")
        local goodLabels, goodIds = Source(LSS.Season.Goods)
        local goodDefault = {}
        for label, goodId in pairs(goodIds) do
            if opt.SeasonGoods[goodId] then table.insert(goodDefault, label) end
        end
        Feature(seasonBox, "AutoSeason", T("Auto Season", "ซีซั่นอัตโนมัติ"), T("Daily ticket, pass rewards, spins and shop", "ตั๋วรายวัน รางวัลพาส สุ่ม และร้าน"))
        seasonBox:AddButton({ Text = T("Season Now", "ซีซั่นเดี๋ยวนี้"), Func = Action(LSS.Season.Step) })
        Check(seasonBox, "SeasonSpin", T("Spin every ticket", "สุ่มตั๋วทุกใบ"))
        seasonBox:AddDropdown("SeasonGoods", {
            Text = T("Shop Items To Buy", "ของในร้านที่จะซื้อ"),
            Values = goodLabels,
            Multi = true,
            Default = goodDefault,
            Searchable = #goodLabels > 8,
            Callback = function(selected)
                local wanted = {}
                for label, on in pairs(selected) do
                    if on and goodIds[label] then wanted[goodIds[label]] = true end
                end
                opt.SeasonGoods = wanted
            end,
        })
    end

    local function BuildPlayer(tab)
        local raceBox = tab:AddLeftGroupbox(T("Race", "เผ่า"), "robot-idle")
        local raceLabels, raceIds = Source(LSS.Race.Choices)
        opt.TargetRace = raceIds[raceLabels[1]]
        raceBox:AddDropdown("TargetRace", {
            Text = T("Target Race", "เผ่าที่ต้องการ"),
            Values = raceLabels,
            Default = 1,
            Searchable = #raceLabels > 8,
            Callback = function(value)
                opt.TargetRace = raceIds[value]
            end,
        })
        Feature(raceBox, "AutoRace", T("Auto Roll Race", "สุ่มเผ่าอัตโนมัติ"), T("Uses your race rolls until you get the chosen race", "สุ่มเผ่าจนกว่าจะได้เผ่าที่เลือก"), function(value)
            if not value or State.Rolling then return end
            State.Rolling = true
            task.defer(function()
                local ok, outcome = pcall(LSS.Race.RollUntil, opt.TargetRace)
                State.Rolling = false
                if ok and outcome == "got" then
                    Notify("Got the race!", "Success")
                elseif ok and outcome == "empty" then
                    Notify("No race rolls left", "Warning")
                elseif ok and outcome == "target" then
                    Notify("Pick a race first", "Warning")
                end
                Later(TurnOff, "AutoRace")
            end)
        end)
        Feature(raceBox, "AutoBestRace", T("Use Best Race Slot", "ใช้ช่องเผ่าที่ดีสุด"), T("Switches to your rarest race", "สลับไปใช้เผ่าที่หายากที่สุด"))
        raceBox:AddButton({ Text = T("Switch Now", "สลับเดี๋ยวนี้"), Func = Action(function()
            Notify(LSS.Race.EquipBest() and "Switched race slot" or "Already on your best race")
        end) })

        local moveBox = tab:AddRightGroupbox(T("Movement", "การเคลื่อนที่"), "speed")
        HotkeyFeature(moveBox, "SpeedOn", T("Speed", "ความเร็ว"), nil, LSS.Movement.Apply)
        moveBox:AddSlider("WalkSpeed", {
            Text = T("Walk Speed", "ความเร็วเดิน"),
            Min = 16, Max = 200, Default = opt.WalkSpeed, Rounding = 0,
            Callback = function(value)
                opt.WalkSpeed = value
                LSS.Movement.Apply()
            end,
        })
        HotkeyFeature(moveBox, "InfJump", T("Infinite Jump", "กระโดดไม่จำกัด"))

        local guardBox = tab:AddRightGroupbox(T("Survival", "เอาตัวรอด"), "health")
        local godMode = Feature(guardBox, "GodMode", T("Invincible", "อมตะ"), T("Monsters and bosses can't kill you", "มอนสเตอร์และบอสฆ่าไม่ตาย"), function(value)
            if not value then
                if State.RestoreDamage then State.RestoreDamage() end
            elseif not LSS.Guard.HookDamage() then
                Notify("Invincible is not available on this executor", "Warning")
                task.defer(TurnOff, "GodMode")
            end
        end)
        NeedModule(godMode, ReplicatedStorage.CTRL.HPCTRL)
        local keepOre = Feature(guardBox, "KeepOre", T("Keep Ore On Death", "ตายแล้วแร่ไม่หาย"), nil, function(value)
            if not value then
                LSS.Guard.UnhookOreLoss()
            elseif not LSS.Guard.HookOreLoss() then
                Notify("Keep Ore On Death is not supported on this executor", "Warning")
                task.defer(TurnOff, "KeepOre")
            end
        end)
        LSS.Compat.NeedCap(keepOre, "Namecall")
    end


    local function BuildSettings(window)
        local settingsTab = window:AddSettingsTab()
        local menuBox = settingsTab:AddLeftGroupbox(T("Menu"))
        menuBox.Raw:CreateKeybind({
            Name = "Toggle UI",
            CurrentKeybind = "RightControl",
            Flag = "ToggleUIKey",
            Callback = function() end,
            OnChanged = function(key)
                NoxWindow:SetKeybind(key)
            end,
        })
        menuBox.Raw:CreateDropdown({
            Name = "Toggle button",
            Options = { "Mobile only", "Mobile & PC" },
            CurrentOption = "Mobile only",
            AllowNone = false,
            Flag = "ToggleButtonPlatform",
            Callback = function(option)
                local selected = if type(option) == "table" then option[1] else option
                NoxWindow:SetToggleButtonPlatform(selected == "Mobile & PC" and "Both" or "Mobile")
            end,
        })
        menuBox:AddButton({ Text = "Unload NOX HUB", Style = "Danger", Func = function()
            Library:Unload()
        end })

        pcall(function()
            settingsTab.Raw:CreateConfigManager({ Name = "Configs", Side = "Left" })
        end)
        pcall(function()
            settingsTab.Raw:CreateThemeManager({ Name = "Themes", Side = "Right" })
        end)

        local linkBox = settingsTab:AddRightGroupbox(T("Links"))
        local function CopyLink(link, label)
            local copy = setclipboard or toclipboard
            if copy then copy(link) end
            Notify(copy and (label .. " link copied") or link)
        end
        linkBox:AddButton({ Text = "Copy Discord Link", Style = "Primary", Func = function()
            CopyLink(DISCORD_INVITE, "Discord")
        end })
        linkBox:AddButton({ Text = "Copy Website Link", Func = function()
            CopyLink(WEBSITE_LINK, "Website")
        end })

        local logBox = settingsTab:AddRightGroupbox(T("Update Log"))
        for i = 1, math.min(2, #Config.UpdateLog) do
            local entry = Config.UpdateLog[i]
            logBox:AddParagraph({ Title = entry[1], Content = entry[2] })
        end

        local sessionBox = settingsTab:AddLeftGroupbox(T("Session"))
        Toggle(sessionBox, "AutoRejoin", T("Auto Rejoin"), T("Rejoins the game by itself after a disconnect"))
        Toggle(sessionBox, "LowGraphics", T("FPS Boost"), T("Turns off 3D rendering to save CPU and GPU"), function(value)
            LSS.Session.SetLowGraphics(value)
        end)
        sessionBox:AddButton({ Text = T("Rejoin Now"), Func = Action(LSS.Session.Rejoin) })
    end

    local noteText = {
        EnhantStone_1 = "farming enhance stones",
        EnhantStone_2 = "farming rare enhance stones",
        Coin = "farming coins",
        Enhancing = "enhancing",
        NoTicket = "need a tower ticket",
        Done = "all at target",
    }

    local function TaskText()
        if State.Lock == "Index" then return Library:Translate("Index") .. " " .. Library:Translate(State.IndexNote or "planning") end
        if State.Lock then return Library:Translate(State.Lock) end
        if opt.MaxGear then return Library:Translate("Max Gear") .. ", " .. Library:Translate(noteText[State.GearNote] or "starting") end
        return "Idle"
    end

    local function UpdateStatus()
        if not dashboard.Level then return end
        local ok, profile = pcall(LSS.Data.Get)
        if not State.Alive then return end
        if not (ok and profile and profile.Eco) then
            Later(dashboard.Task.SetStatus, dashboard.Task, "Waiting", "Profile unavailable")
            Later(Library.Window.SetSessionStatus, Library.Window, "Waiting for profile", 0, "Waiting")
            return
        end
        local eco = profile.Eco
        local running = {}
        for key, name in pairs(featureNames) do
            if opt[key] then running[#running + 1] = Library:Translate(name) end
        end
        table.sort(running)
        local count = #running
        local task = TaskText()
        local waiting = opt.MaxGear and State.GearNote == "NoTicket"
        local status = waiting and "Waiting" or ((State.Lock or count > 0) and "Running" or "Off")
        Later(dashboard.Level.SetValue, dashboard.Level, eco.level)
        Later(dashboard.Level.SetStatus, dashboard.Level, "Success", "Current")
        Later(dashboard.Coins.SetValue, dashboard.Coins, LSS.Util.Abbreviate(eco.coin))
        Later(dashboard.Coins.SetStatus, dashboard.Coins, "Success", "Current")
        Later(dashboard.Rebirth.SetValue, dashboard.Rebirth, eco.rebirth)
        Later(dashboard.Rebirth.SetStatus, dashboard.Rebirth, "Success", "Current")
        Later(dashboard.Gear.SetValue, dashboard.Gear, LSS.Gear.EquippedNames(profile))
        Later(dashboard.Gear.SetStatus, dashboard.Gear, "Success", "Current")
        Later(dashboard.Task.SetValue, dashboard.Task, task)
        Later(dashboard.Task.SetStatus, dashboard.Task, status, Library:T(count .. " enabled", "เปิด " .. count, count .. " diaktifkan"))
        Later(dashboard.Tower.SetValue, dashboard.Tower, State.TowerLoot or 0)
        Later(dashboard.Tower.SetStatus, dashboard.Tower, "Success", "Collected")
        Later(activityLabel.SetText, activityLabel, count > 0 and (Library:Translate("Active features") .. " / " .. table.concat(running, "\n> ")) or Library:Translate("No active features"))
        Later(Library.Window.SetSessionStatus, Library.Window, task, count, status)
    end

    Library:OnLanguageChanged(function()
        if State.Alive and dashboard.Level then task.defer(UpdateStatus) end
    end)

    local function BuildTabs()
        local Window = Library.Window
        Window:AddTabSection(T("Farm", "ฟาร์ม"))
        local MainTab = Window:AddTab(T("Main", "หลัก"), "castle-gate", T("Status, all-in-one mode and rewards", "สถานะ โหมดทำทุกอย่าง และรางวัล"))
        local FarmTab = Window:AddTab(T("Combat & Farm", "ต่อสู้และฟาร์ม"), "sword", T("Stages, monsters, bosses and index", "ด่าน มอนสเตอร์ บอส และสมุดสะสม"))
        local ForgeTab = Window:AddTab(T("Forge", "หลอม"), "anvil", T("Forge gear from any ore", "หลอมอุปกรณ์จากแร่ไหนก็ได้"))
        local SellTab = Window:AddTab(T("Sell", "ขาย"), "coinbag", T("Sell gear by type and rarity", "ขายอุปกรณ์ตามประเภทและ rarity"))
        Window:AddTabSection(T("Progress", "ความคืบหน้า"))
        local ProgressTab = Window:AddTab(T("Upgrade & Rebirth", "อัปเกรดและรีเบิร์ธ"), "crown", T("Training, rebirth and upgrades", "ฝึก รีเบิร์ธ และอัปเกรด"))
        local TowerTab = Window:AddTab(T("Tower", "หอคอย"), "tower", T("Tower loot and season pass", "ของจากหอคอย และซีซั่นพาส"))
        Window:AddTabSection(T("Other", "อื่นๆ"))
        local PlayerTab = Window:AddTab(T("Player", "ผู้เล่น"), "compass", T("Race, movement and survival", "เผ่า การเคลื่อนที่ และเอาตัวรอด"))

        local sections = {
            { BuildMain, MainTab },
            { BuildFarm, FarmTab },
            { BuildForge, ForgeTab },
            { BuildSell, SellTab },
            { BuildProgress, ProgressTab },
            { BuildTower, TowerTab },
            { BuildPlayer, PlayerTab },
            { BuildSettings, Window },
        }
        for _, section in ipairs(sections) do
            LSS.Util.Try(section[1], section[2])
        end
        task.spawn(LSS.Util.Try, BlockMissing)

        Library:Every(Config.PumpInterval, Pump)
        task.spawn(function()
            while State.Alive do
                UpdateStatus()
                task.wait(Config.StatusInterval)
            end
        end)
    end


    Library:OnUnload(LSS.Scheduler.Stop)

    NoxWindow = NoxLibrary:CreateWindow({
        Name = "NOX HUB",
        LoadingSubtitle = SCRIPT_VERSION,
        ToggleUIKeybind = "RightControl",
        ConfigurationSaving = {
            Enabled = true,
            FolderName = "NOX/" .. GAME_KEY,
            FileName = "default",
        },
        ToggleButton = { Platform = "Mobile", Icon = NOX_ICON },
        DefaultTheme = "Mono",
        CornerRadius = 20,
        DragStyle = "Off",
        Backdrop = { Weather = "Snow", Mode = "UI" },
        BackgroundTransparency = 0.8, -- 20% opacity
        Home = {
            Title = "Welcome to " .. GAME_NAME .. "!",
            Tier = SCRIPT_VERSION,
            Discord = DISCORD_INVITE,
            Website = WEBSITE_LINK,
            Stats = { "Players", "Session", "FPS", "Ping" },
        },
    })
    Library.Window = WindowShim
    attachUI(API, NoxWindow)

    BuildTabs()
    NoxWindow:LoadAutoload()
    LSS.Util.Try(LSS.Scheduler.Boot)
    if LSS.Boss.HopWanted() and Options.BossHop then Options.BossHop:SetValue(true) end
end

BuildInterface()
