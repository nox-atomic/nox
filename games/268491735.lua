if not game:IsLoaded() then
	game.Loaded:Wait()
end

local SCRIPT_VERSION = "v0.2"
local GAME_NAME = "1 Bite Per Click"
local GAME_KEY = "1BitePerClick"
local UI_SOURCE_URL = "https://raw.githubusercontent.com/nox-atomic/atomic-v1/main/Source.luau"
local DISCORD_INVITE = "https://discord.gg/Qb8edHdfU6"
local WEBSITE_LINK = "https://rscripts.net/@_NOX"
local NOX_ICON = "rbxassetid://123052226839946" -- open/close button icon

local hasHttpGet = typeof(game.HttpGet) == "function"
local hasLoadstring = typeof(loadstring) == "function"

local ENV = (getgenv and getgenv()) or _G

if ENV.__NOX_1BiteSmartFarm and type(ENV.__NOX_1BiteSmartFarm.Unload) == "function" then
    pcall(ENV.__NOX_1BiteSmartFarm.Unload)
end

local S = {
    Alive = true,
    Enabled = true,
    Status = "Starting",
    Mode = "BOOT",
    Route = nil,
    RouteWorld = nil,
    RouteFresh = false,
    ForceSell = false,
    Selling = false,
    SellUIOpenedAt = 0,
    LastSellAttempt = 0,
    Connections = {},
    PassCache = {},
    QuestAttemptAt = {},
    LastRebirthAttempt = 0,
    LastSpendAt = 0,
}
ENV.__NOX_1BiteSmartFarm = S

ENV.NOX_1BiteSettings = ENV.NOX_1BiteSettings or {
    BiteInterval = 0.055,          -- runtime capture showed accepted client traffic down to ~0.053s
    TargetWallHits = 75,          -- ~4.1 seconds of ideal biting at the default interval
    WallTimeoutPadding = 7,
    WalkArrivalDistance = 3.25,
    WalkStuckSeconds = 1.35,
    WalkMaxRepaths = 8,
    WalkWaypointSpacing = 6,
    WalkJumpWhenStuck = true,
    CollectLoot = true,
    SmartLoot = true,
    SmartLootRoomWindow = 2,        -- only normal-loot the strongest few rooms current Bite can efficiently farm
    SmartLootValuePercent = 0.35,   -- within a worthwhile room, ignore weak rolls below this share of the best known value
    SmartLootNewIndex = true,       -- still collect undiscovered catalogue items for permanent Index progression
    AutoSell = true,
    SellOnlyWhenFull = true,          -- keep high-value loot across autoplay cycles; sell when capacity is actually reached
    AutoRebirth = true,
    AutoWorld = true,
    AutoBuyBites = true,
    AutoBuyAuras = true,
    AutoUtilityUpgrades = true,
    AutoQuestRewards = true,
    AutoRewards = true,
    AutoCodes = true,
    AutoBestTrainingBurger = true,
    UseSpawnTeleport = true,         -- mirrors the game's "Teleport to Spawn" button (BaseTeleport)
    UseAutoPlayTeleport = true,      -- mirrors built-in autoplay repositioning (AutoPlayTeleport)
    BuyRepeatableLuckyBlocks = true, -- only after useful permanent quest rewards are owned
    Debug = false,
}
S.Settings = ENV.NOX_1BiteSettings

-- Backfill settings when re-executing over an older settings table.
local __settingDefaults = {
    WalkArrivalDistance = 3.25,
    WalkStuckSeconds = 1.35,
    WalkMaxRepaths = 8,
    WalkWaypointSpacing = 6,
    WalkJumpWhenStuck = true,
    UseSpawnTeleport = true,
    UseAutoPlayTeleport = true,
    SmartLoot = true,
    SmartLootRoomWindow = 2,
    SmartLootValuePercent = 0.35,
    SmartLootNewIndex = true,
    SellOnlyWhenFull = true,
}
for __key, __value in pairs(__settingDefaults) do
    if S.Settings[__key] == nil then
        S.Settings[__key] = __value
    end
end

S.Services = {
    Players = game:GetService("Players"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    Workspace = game:GetService("Workspace"),
    PathfindingService = game:GetService("PathfindingService"),
    CollectionService = game:GetService("CollectionService"),
    MarketplaceService = game:GetService("MarketplaceService"),
    RunService = game:GetService("RunService"),
}

S.Player = S.Services.Players.LocalPlayer
while S.Alive and not S.Player do
    task.wait()
    S.Player = S.Services.Players.LocalPlayer
end

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local function dprint(...)
    if S.Settings.Debug then
        print("[NOX 1Bite]", ...)
    end
end

local function setStatus(text, mode)
    S.Status = tostring(text or "")
    if mode then
        S.Mode = tostring(mode)
    end
    dprint(S.Mode, S.Status)
end

local function safeRequire(name)
    local shared = S.Services.ReplicatedStorage:FindFirstChild("Shared")
    local module = shared and shared:FindFirstChild(name)
    if not module then
        return nil
    end
    local ok, result = pcall(require, module)
    if ok then
        return result
    end
    warn("[NOX 1Bite] Could not require Shared." .. name .. ": " .. tostring(result))
    return nil
end

S.Modules = {
    WallConfig = safeRequire("WallConfig"),
    AutoPlayConfig = safeRequire("AutoPlayConfig"),
    LevelConfig = safeRequire("LevelConfig"),
    RebirthBonus = safeRequire("RebirthBonus"),
    WorldPortalConfig = safeRequire("WorldPortalConfig"),
    BiteConfig = safeRequire("BiteConfig"),
    AuraConfig = safeRequire("AuraConfig"),
    CarryUpgradeConfig = safeRequire("CarryUpgradeConfig"),
    WalkspeedUpgradeConfig = safeRequire("WalkspeedUpgradeConfig"),
    QualityLevelConfig = safeRequire("QualityLevelConfig"),
    ItemCatalogue = safeRequire("ItemCatalogue"),
    RarityConfig = safeRequire("RarityConfig"),
    QuestRewardConfig = safeRequire("QuestRewardConfig"),
    TrainingPassConfig = safeRequire("TrainingPassConfig"),
    HackerBurgerClaimConfig = safeRequire("HackerBurgerClaimConfig"),
}

S.BestLootValueByWorld = S.BestLootValueByWorld or {}
S.PowerFrontierRoom = nil
S.PowerFrontierHits = nil

S.RemotesFolder = S.Services.ReplicatedStorage:WaitForChild("Remotes", 20)
S.Remotes = {}

local REMOTE_NAMES = {
    "Bite",
    "BuyBite",
    "BuyAura",
    "EquipAura",
    "BuyUpgrade",
    "SellItems",
    "Rebirth",
    "AutoPlayRoute",
    "AutoPlayTeleport",
    "BaseTeleport",
    "RequestWorldTeleport",
    "GetQuests",
    "BuyQuestReward",
    "ClaimDailyReward",
    "ClaimPlaytimeReward",
    "ClaimGroupReward",
    "GetOfflineEarnings",
    "ClaimOfflineEarnings",
    "RedeemCode",
    "ClaimHackerBurger",
    "LuckyBlockOpen",
    "LuckyBlockClaimed",
    "InventoryFull",
}

if S.RemotesFolder then
    for _, name in ipairs(REMOTE_NAMES) do
        S.Remotes[name] = S.RemotesFolder:FindFirstChild(name)
    end
end

local function getRemote(name)
    local remote = S.Remotes[name]
    if remote and remote.Parent then
        return remote
    end
    if S.RemotesFolder then
        remote = S.RemotesFolder:FindFirstChild(name)
        S.Remotes[name] = remote
    end
    return remote
end

local function invoke(name, ...)
    local remote = getRemote(name)
    if not remote then
        return false, nil
    end
    local args = table.pack(...)
    if remote:IsA("RemoteFunction") then
        local ok, result = pcall(function()
            return remote:InvokeServer(table.unpack(args, 1, args.n))
        end)
        return ok, result
    end
    if remote:IsA("RemoteEvent") then
        local ok, result = pcall(function()
            remote:FireServer(table.unpack(args, 1, args.n))
        end)
        return ok, result
    end
    return false, nil
end

local function addConnection(connection)
    if connection then
        table.insert(S.Connections, connection)
    end
    return connection
end

local function character()
    return S.Player and S.Player.Character
end

local function root()
    local char = character()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function humanoid()
    local char = character()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function waitForCharacter(timeout)
    local deadline = os.clock() + (timeout or 10)
    repeat
        local r = root()
        local h = humanoid()
        if r and h and h.Health > 0 then
            return r, h
        end
        task.wait(0.15)
    until not S.Alive or os.clock() >= deadline
    return nil, nil
end

local function getCashObject()
    local leaderstats = S.Player and S.Player:FindFirstChild("leaderstats")
    return leaderstats and leaderstats:FindFirstChild("Cash")
end

local function getRebirthObject()
    local leaderstats = S.Player and S.Player:FindFirstChild("leaderstats")
    return leaderstats and leaderstats:FindFirstChild("Rebirths")
end

local function getBiteObject()
    local stats = S.Player and S.Player:FindFirstChild("stats")
    return stats and stats:FindFirstChild("BiteStrength")
end

local function cashValue()
    local obj = getCashObject()
    return obj and tonumber(obj.Value) or 0
end

local function rebirthValue()
    local obj = getRebirthObject()
    return obj and tonumber(obj.Value) or 0
end

local function biteValue()
    local obj = getBiteObject()
    return obj and tonumber(obj.Value) or 0
end

local function currentWorld()
    local world = tonumber(S.Player:GetAttribute("CurrentWorld"))
    if world and world >= 1 then
        return math.floor(world)
    end
    return 1
end

local function abbreviate(value)
    local n = tonumber(value) or 0
    local abs = math.abs(n)
    local suffixes = {
        {1e63, "Vg"}, {1e60, "Nv"}, {1e57, "Od"}, {1e54, "Sd"},
        {1e51, "Sxd"}, {1e48, "Qid"}, {1e45, "Qad"}, {1e42, "Td"},
        {1e39, "Dd"}, {1e36, "Ud"}, {1e33, "Dc"}, {1e30, "No"},
        {1e27, "Oc"}, {1e24, "Sp"}, {1e21, "Sx"}, {1e18, "Qi"},
        {1e15, "Qa"}, {1e12, "T"}, {1e9, "B"}, {1e6, "M"}, {1e3, "K"},
    }
    for _, entry in ipairs(suffixes) do
        if abs >= entry[1] then
            return string.format("%.2f%s", n / entry[1], entry[2])
        end
    end
    if abs >= 100 then
        return string.format("%.0f", n)
    end
    return string.format("%.2f", n)
end

local function flatDistance(a, b)
    local av = Vector3.new(a.X, 0, a.Z)
    local bv = Vector3.new(b.X, 0, b.Z)
    return (av - bv).Magnitude
end

local function cancelWalking()
    S.MoveGeneration = (tonumber(S.MoveGeneration) or 0) + 1
    local r, h = root(), humanoid()
    if r and h then
        pcall(function()
            h:Move(Vector3.zero, false)
            h:MoveTo(r.Position)
        end)
    end
end

local function walkTo(position, lookAt, options)
    if typeof(position) ~= "Vector3" then
        return false
    end

    options = options or {}
    local r, h = waitForCharacter(5)
    if not r or not h or h.Health <= 0 then
        return false
    end

    local generation = (tonumber(S.MoveGeneration) or 0) + 1
    S.MoveGeneration = generation

    local arrival = tonumber(options.arrival) or tonumber(S.Settings.WalkArrivalDistance) or 3.25
    local stuckSeconds = tonumber(options.stuckSeconds) or tonumber(S.Settings.WalkStuckSeconds) or 1.35
    local maxRepaths = math.max(1, math.floor(tonumber(options.maxRepaths) or tonumber(S.Settings.WalkMaxRepaths) or 8))
    local allowWhenPaused = options.allowWhenPaused == true
    local initialDistance = (Vector3.new(r.Position.X, 0, r.Position.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
    local speed = math.max(tonumber(h.WalkSpeed) or 16, 8)
    local timeout = tonumber(options.timeout) or math.clamp((initialDistance / speed) * 3.25 + 10, 10, 120)
    local finalDeadline = os.clock() + timeout
    local repaths = 0

    local function stillActive()
        return S.Alive
            and S.MoveGeneration == generation
            and (allowWhenPaused or S.Enabled)
            and h.Parent
            and h.Health > 0
            and r.Parent
    end

    local function flatTo(target)
        return flatDistance(r.Position, target)
    end

    if flatTo(position) <= arrival then
        return true
    end

    while stillActive() and os.clock() < finalDeadline and repaths < maxRepaths do
        repaths += 1

        local waypoints = nil
        local okPath, path = pcall(function()
            local created = S.Services.PathfindingService:CreatePath({
                AgentRadius = 2,
                AgentHeight = 5,
                AgentCanJump = true,
                AgentCanClimb = true,
                WaypointSpacing = tonumber(S.Settings.WalkWaypointSpacing) or 6,
            })
            created:ComputeAsync(r.Position, position)
            return created
        end)

        if okPath and path and path.Status == Enum.PathStatus.Success then
            waypoints = path:GetWaypoints()
        else
            waypoints = {
                {Position = position, Action = Enum.PathWaypointAction.Walk}
            }
        end

        local needRepath = false
        for _, waypoint in ipairs(waypoints) do
            if not stillActive() or os.clock() >= finalDeadline then
                break
            end
            if flatTo(position) <= arrival then
                return true
            end

            local waypointPosition = waypoint.Position or position
            if waypoint.Action == Enum.PathWaypointAction.Jump then
                h.Jump = true
            end

            h:MoveTo(waypointPosition)
            local lastPos = r.Position
            local lastMovedAt = os.clock()

            while stillActive() and os.clock() < finalDeadline do
                if flatTo(position) <= arrival then
                    h:MoveTo(r.Position)
                    return true
                end

                local waypointDistance = (r.Position - waypointPosition).Magnitude
                if waypointDistance <= math.max(arrival, 2.75) then
                    break
                end

                if (r.Position - lastPos).Magnitude >= 0.8 then
                    lastPos = r.Position
                    lastMovedAt = os.clock()
                elseif os.clock() - lastMovedAt >= stuckSeconds then
                    if S.Settings.WalkJumpWhenStuck ~= false then
                        h.Jump = true
                    end
                    needRepath = true
                    break
                end
                task.wait(0.08)
            end

            if needRepath then
                break
            end
        end

        if flatTo(position) <= arrival then
            return true
        end

        if not needRepath then
            -- Path was exhausted but the target was not reached; request a fresh path.
            task.wait(0.05)
        else
            task.wait(0.12)
        end
    end

    if stillActive() then
        -- Final direct MoveTo attempt; still no CFrame/PivotTo movement.
        h:MoveTo(position)
        local directDeadline = math.min(finalDeadline, os.clock() + 2.5)
        while stillActive() and os.clock() < directDeadline do
            if flatTo(position) <= arrival then
                return true
            end
            task.wait(0.08)
        end
    end
    return flatTo(position) <= arrival
end

local function closestPointOnPart(part, point)
    local localPoint = part.CFrame:PointToObjectSpace(point)
    local half = part.Size / 2
    local clamped = Vector3.new(
        math.clamp(localPoint.X, -half.X, half.X),
        math.clamp(localPoint.Y, -half.Y, half.Y),
        math.clamp(localPoint.Z, -half.Z, half.Z)
    )
    return part.CFrame:PointToWorldSpace(clamped)
end

local function standoffPoint(part, reference, distance)
    local closest = closestPointOnPart(part, reference)
    local delta = Vector3.new(reference.X - closest.X, 0, reference.Z - closest.Z)
    if delta.Magnitude < 0.1 then
        local look = -part.CFrame.LookVector
        delta = Vector3.new(look.X, 0, look.Z)
    end
    if delta.Magnitude < 0.1 then
        delta = Vector3.new(0, 0, 1)
    end
    return closest + delta.Unit * (distance or 3.25)
end

local function positionOf(instance)
    if not instance then
        return nil
    end
    if instance:IsA("BasePart") then
        return instance.Position
    end
    if instance:IsA("Model") then
        local ok, cf = pcall(instance.GetPivot, instance)
        if ok and cf then
            return cf.Position
        end
    end
    local part = instance:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function bestPart(instance)
    if not instance then
        return nil
    end
    if instance:IsA("BasePart") then
        return instance
    end
    if instance:IsA("Model") and instance.PrimaryPart then
        return instance.PrimaryPart
    end
    local best, volume = nil, -1
    for _, child in ipairs(instance:GetDescendants()) do
        if child:IsA("BasePart") then
            local v = child.Size.X * child.Size.Y * child.Size.Z
            if v > volume then
                volume = v
                best = child
            end
        end
    end
    return best
end

local function worldInfo(world)
    local config = S.Modules.WorldPortalConfig
    if config and type(config.get) == "function" then
        local ok, info = pcall(config.get, world)
        if ok and info then
            return info
        end
    end
    return {
        index = world,
        lobby = world == 1 and "Lobby" or ("Lobby" .. tostring(world)),
    }
end

local function lobbyForWorld(world)
    local info = worldInfo(world)
    local name = info and info.lobby or (world == 1 and "Lobby" or ("Lobby" .. world))
    return S.Services.Workspace:FindFirstChild(name)
end

local function wallAttribute(room, wall)
    local config = S.Modules.WallConfig
    if config and type(config.attributeName) == "function" then
        local ok, result = pcall(config.attributeName, room, wall)
        if ok and result then
            return result
        end
    end
    return string.format("Wall_%d_%d", room, wall)
end

local function wallHP(room, wall)
    local value = S.Player:GetAttribute(wallAttribute(room, wall))
    return tonumber(value) or 0
end

local function roomRemainingHP(room)
    local total = 0
    for wall = 1, 8 do
        local hp = wallHP(room, wall)
        if hp > 0 then
            total += hp
        end
    end
    return total
end

local function biggestRemainingWall(room)
    local biggest = 0
    for wall = 1, 8 do
        local hp = wallHP(room, wall)
        if hp > biggest then
            biggest = hp
        end
    end
    return biggest
end

local function wallPart(room, wall)
    local config = S.Modules.WallConfig
    local roomsName = (config and config.ROOMS_FOLDER) or "Rooms"
    local wallsName = (config and config.WALLS_FOLDER) or "Walls"
    local rooms = S.Services.Workspace:FindFirstChild(roomsName)
    local roomModel = rooms and rooms:FindFirstChild("Room" .. tostring(room))
    local walls = roomModel and roomModel:FindFirstChild(wallsName)
    local part = walls and walls:FindFirstChild("Wall" .. tostring(wall))
    if part and part:IsA("BasePart") then
        return part
    end
    return nil
end

local function nextWallInRoom(room, reference)
    local chosen, chosenPart, bestDistance = nil, nil, nil
    for wall = 1, 8 do
        if wallHP(room, wall) > 0 then
            local part = wallPart(room, wall)
            if part then
                local distance = reference and (closestPointOnPart(part, reference) - reference).Magnitude or wall
                if bestDistance == nil or distance < bestDistance then
                    chosen = wall
                    chosenPart = part
                    bestDistance = distance
                end
            elseif chosen == nil then
                chosen = wall
            end
        end
    end
    return chosen, chosenPart
end

local function carriedTools()
    local items = {}
    local function scan(container)
        if not container then
            return
        end
        for _, item in ipairs(container:GetChildren()) do
            if item:IsA("Tool") and item:GetAttribute("Rarity") ~= nil and item:GetAttribute("Banked") ~= true then
                table.insert(items, item)
            end
        end
    end
    scan(S.Player:FindFirstChild("Backpack"))
    scan(character())
    return items
end

local function carryCapacity()
    return tonumber(S.Player:GetAttribute("CarrySpace")) or 3
end

local function carriedCount()
    return #carriedTools()
end

local function inventoryFull()
    local capacity = math.max(math.floor(tonumber(carryCapacity()) or 3), 1)
    return carriedCount() >= capacity
end

local function routeFromServer(force)
    local world = currentWorld()
    if not force and S.Route and S.RouteWorld == world then
        return S.Route
    end
    local ok, result = invoke("AutoPlayRoute")
    if ok and type(result) == "table" and result.start and type(result.rooms) == "table" and #result.rooms > 0 then
        S.Route = result
        S.RouteWorld = world
        S.RouteFresh = true
        table.sort(S.Route.rooms, function(a, b)
            return (tonumber(a.room) or 0) < (tonumber(b.room) or 0)
        end)
        return S.Route
    end
    S.Route = nil
    S.RouteWorld = nil
    S.RouteFresh = false
    return nil
end

local function waitForTeleportMovement(beforePosition, timeout)
    local deadline = os.clock() + (timeout or 4)
    repeat
        local r = root()
        if r then
            if not beforePosition or flatDistance(r.Position, beforePosition) >= 8 then
                return true
            end
        end
        task.wait(0.08)
    until not S.Alive or os.clock() >= deadline
    return false
end

local function useSpawnTeleport(reason)
    if S.Settings.UseSpawnTeleport == false then
        return false
    end
    local remote = getRemote("BaseTeleport")
    if not remote then
        return false
    end
    local r = root()
    local before = r and r.Position or nil
    cancelWalking()
    setStatus(reason or "Teleporting to spawn", "TELEPORT")
    local ok = invoke("BaseTeleport")
    if not ok then
        return false
    end
    waitForTeleportMovement(before, 4.5)
    task.wait(0.12)
    return true
end

local function useAutoPlayTeleport(route, reason)
    if S.Settings.UseAutoPlayTeleport == false then
        return false
    end
    route = route or routeFromServer(false)
    if not route or typeof(route.start) ~= "Vector3" then
        return false
    end
    local r = root()
    if r and flatDistance(r.Position, route.start) <= 25 then
        return true
    end
    if not getRemote("AutoPlayTeleport") then
        return false
    end
    cancelWalking()
    setStatus(reason or "Using Autoplay to reach the course", "AUTOPLAY")
    local ok = invoke("AutoPlayTeleport")
    if not ok then
        return false
    end
    local deadline = os.clock() + 6
    repeat
        r = root()
        if r and flatDistance(r.Position, route.start) <= 25 then
            task.wait(0.08)
            return true
        end
        task.wait(0.12)
    until not S.Alive or os.clock() >= deadline
    return false
end

local function highestUnlockedWorld()
    local config = S.Modules.WorldPortalConfig
    if config and type(config.unlockedWorldFromAttributes) == "function" then
        local ok, value = pcall(config.unlockedWorldFromAttributes, S.Player)
        if ok and tonumber(value) then
            return math.clamp(math.floor(value), 1, 4)
        end
    end
    local r = rebirthValue()
    if r >= 67 and S.Player:GetAttribute("World4PortalOwned") == true then
        return 4
    elseif r >= 40 and S.Player:GetAttribute("World3PortalOwned") == true then
        return 3
    elseif r >= 23 and S.Player:GetAttribute("World2PortalOwned") == true then
        return 2
    end
    return 1
end

local function portalNameScore(instance, wantedWorld)
    local tokenA = "world" .. tostring(wantedWorld)
    local tokenB = "lobby" .. tostring(wantedWorld)
    local tokenC = "w" .. tostring(wantedWorld)
    local node = instance
    local depth = 0
    local sawPortal = false
    local sawTarget = false
    local score = 1000
    while node and node ~= S.Services.Workspace and depth < 6 do
        local name = string.lower(node.Name or "")
        if string.find(name, "portal", 1, true) then
            sawPortal = true
        end
        if string.find(name, tokenA, 1, true) or string.find(name, tokenB, 1, true) or string.find(name, tokenC, 1, true) then
            sawTarget = true
            score = math.min(score, 5 + depth)
        elseif string.find(name, tostring(wantedWorld), 1, true) then
            sawTarget = true
            score = math.min(score, 20 + depth)
        end
        node = node.Parent
        depth += 1
    end
    if sawPortal and sawTarget then
        return score
    end
    return nil
end

local function findWorldPortalPart(wantedWorld)
    local r = root()
    local candidates = {}
    for _, node in ipairs(S.Services.Workspace:GetDescendants()) do
        if node:IsA("BasePart") then
            local score = portalNameScore(node, wantedWorld)
            if score then
                local distance = r and flatDistance(r.Position, node.Position) or 0
                table.insert(candidates, {part = node, score = score, distance = distance})
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.score == b.score then
            return a.distance < b.distance
        end
        return a.score < b.score
    end)
    return candidates[1] and candidates[1].part or nil
end

local function ensureBestWorld()
    if not S.Settings.AutoWorld then
        return false
    end
    local wanted = highestUnlockedWorld()
    local current = currentWorld()
    if wanted == current then
        return false
    end

    local portal = findWorldPortalPart(wanted)
    if not portal then
        setStatus(string.format("World %d portal not found; staying in World %d", wanted, current), "WORLD")
        return false
    end

    setStatus(string.format("Walking to World %d portal", wanted), "WALK")
    local reached = walkTo(portal.Position, nil, {arrival = 5, timeout = 120})
    if not reached then
        setStatus(string.format("Could not walk to World %d portal", wanted), "WORLD")
        return false
    end

    -- Give the physical touch/portal logic a chance to move us first.
    local touchDeadline = os.clock() + 2.5
    repeat
        task.wait(0.1)
    until not S.Alive or currentWorld() == wanted or os.clock() >= touchDeadline

    -- Some revisions use RequestWorldTeleport as the server handshake for the portal.
    -- Only fire it after we have physically walked to the portal; never from across the map.
    if currentWorld() ~= wanted and root() and flatDistance(root().Position, portal.Position) <= 10 then
        setStatus(string.format("Entering World %d portal", wanted), "WORLD")
        invoke("RequestWorldTeleport", wanted)
    end

    local deadline = os.clock() + 6
    repeat
        task.wait(0.15)
    until not S.Alive or currentWorld() == wanted or os.clock() >= deadline

    if currentWorld() == wanted then
        S.Route = nil
        S.RouteWorld = nil
        S.RouteFresh = true
        return true
    end
    return false
end

local function currentLevel()
    local config = S.Modules.LevelConfig
    if not config or type(config.getProgress) ~= "function" then
        return 0
    end
    local ok, level = pcall(function()
        return select(1, config.getProgress(biteValue()))
    end)
    return ok and (tonumber(level) or 0) or 0
end

local function requiredRebirthLevel()
    local config = S.Modules.RebirthBonus
    if not config or type(config.requiredLevel) ~= "function" then
        return math.huge
    end
    local ok, level = pcall(config.requiredLevel, rebirthValue())
    return ok and (tonumber(level) or math.huge) or math.huge
end

local function canRebirth()
    return currentLevel() >= requiredRebirthLevel()
end

local function tryRebirth()
    if not S.Settings.AutoRebirth or not canRebirth() then
        return false
    end
    if os.clock() - S.LastRebirthAttempt < 1.5 then
        return false
    end
    S.LastRebirthAttempt = os.clock()
    local before = rebirthValue()
    setStatus(string.format("Rebirthing at level %d", currentLevel()), "REBIRTH")
    local ok, result = invoke("Rebirth")
    if not ok or result == false then
        return false
    end
    local deadline = os.clock() + 4
    repeat
        task.wait(0.15)
    until not S.Alive or rebirthValue() > before or os.clock() >= deadline
    if rebirthValue() > before then
        S.Route = nil
        S.RouteWorld = nil
        task.wait(0.25)
        ensureBestWorld()
        return true
    end
    return false
end

local function parseOwned(config, attribute, method)
    if not config or type(config[method]) ~= "function" then
        return {}
    end
    local ok, result = pcall(config[method], S.Player:GetAttribute(attribute))
    return ok and type(result) == "table" and result or {}
end

local function bestOwnedAuraId()
    local config = S.Modules.AuraConfig
    if not config then
        return nil, 1
    end
    local owned = parseOwned(config, "OwnedAuras", "parseOwned")
    local bestId, bestMultiplier = nil, 1
    local list = config.AURAS or {}
    for _, aura in ipairs(list) do
        if owned[aura.id] then
            local multiplier = 1
            if type(config.multiplierOf) == "function" then
                local ok, result = pcall(config.multiplierOf, aura.id, owned)
                if ok and tonumber(result) then
                    multiplier = tonumber(result)
                end
            else
                multiplier = tonumber(aura.boost) or 1
            end
            if multiplier > bestMultiplier then
                bestMultiplier = multiplier
                bestId = aura.id
            end
        end
    end
    return bestId, bestMultiplier
end

local function equipBestAura()
    local id = bestOwnedAuraId()
    if id and S.Player:GetAttribute("EquippedAura") ~= id then
        invoke("EquipAura", id)
        task.wait(0.12)
        return true
    end
    return false
end

local function buyBestBite()
    if not S.Settings.AutoBuyBites then
        return false
    end

    local config = S.Modules.BiteConfig
    if not config then
        return false
    end

    local money = cashValue()
    local owned = parseOwned(config, "OwnedBites", "parseOwned")
    local equipped = S.Player:GetAttribute("EquippedBite") or config.DEFAULT_BITE or "Bone"
    local shopWorld = currentWorld()

    -- The shop uses one BuyBite remote for BOTH buying and equipping. Build the
    -- active world's shop pool, but always include already-owned bites as well
    -- because packs/daily rewards can grant a strong bite out of sequence.
    local pool = {}
    if type(config.BITES) == "table" then
        for _, bite in ipairs(config.BITES) do
            local biteWorld = tonumber(bite.world) or 1
            if owned[bite.name] or biteWorld == shopWorld then
                table.insert(pool, bite)
            end
        end
    elseif type(config.forWorld) == "function" then
        local ok, list = pcall(config.forWorld, shopWorld)
        if ok and type(list) == "table" then
            for _, bite in ipairs(list) do
                table.insert(pool, bite)
            end
        end
    else
        return false
    end

    -- Pick the strongest bite that is either already owned or affordable for cash.
    -- This intentionally ignores Robux-only entries unless the player already owns
    -- them; the autofarm never initiates a Robux purchase.
    local target, targetOwned = nil, false
    local targetStrength = -math.huge
    for _, bite in ipairs(pool) do
        local name = bite.name
        local strength = tonumber(bite.strength) or 0
        local isOwned = name ~= nil and owned[name] == true
        local price = tonumber(bite.cashPrice)
        local affordable = isOwned or (price ~= nil and price >= 0 and price <= money)
        if affordable and name and strength > targetStrength then
            target = bite
            targetOwned = isOwned
            targetStrength = strength
        end
    end

    if not target or target.name == equipped then
        return false
    end

    local equippedStrength = 0
    if type(config.strengthOf) == "function" then
        local ok, value = pcall(config.strengthOf, equipped)
        if ok and tonumber(value) then
            equippedStrength = tonumber(value)
        end
    end
    if targetStrength <= equippedStrength then
        return false
    end

    local targetName = target.name

    if targetOwned then
        setStatus("Equipping best bite: " .. tostring(targetName), "SHOP")
        local success, result = invoke("BuyBite", targetName)
        if not success or result == false then
            return false
        end
        local deadline = os.clock() + 1.5
        repeat
            if S.Player:GetAttribute("EquippedBite") == targetName then
                return true
            end
            task.wait(0.06)
        until not S.Alive or os.clock() >= deadline
        return S.Player:GetAttribute("EquippedBite") == targetName
    end

    setStatus(string.format("Buying best bite: %s ($%s)", tostring(targetName), abbreviate(target.cashPrice)), "SHOP")
    local success, result = invoke("BuyBite", targetName)
    if not success or result == false then
        dprint("Best bite purchase rejected", targetName, "price", tostring(target.cashPrice), "cash", money)
        return false
    end

    -- A successful cash purchase can leave the bite owned but not equipped. Wait for
    -- ownership replication, then invoke the SAME game remote again exactly like the
    -- shop's EQUIP button does.
    local purchaseDeadline = os.clock() + 2
    repeat
        if S.Player:GetAttribute("EquippedBite") == targetName then
            return true
        end
        local nowOwned = parseOwned(config, "OwnedBites", "parseOwned")
        if nowOwned[targetName] then
            owned = nowOwned
            break
        end
        task.wait(0.06)
    until not S.Alive or os.clock() >= purchaseDeadline

    local nowOwned = parseOwned(config, "OwnedBites", "parseOwned")
    if nowOwned[targetName] and S.Player:GetAttribute("EquippedBite") ~= targetName then
        setStatus("Equipping purchased bite: " .. tostring(targetName), "SHOP")
        local equipOK, equipResult = invoke("BuyBite", targetName)
        if equipOK and equipResult ~= false then
            local equipDeadline = os.clock() + 1.5
            repeat
                if S.Player:GetAttribute("EquippedBite") == targetName then
                    return true
                end
                task.wait(0.06)
            until not S.Alive or os.clock() >= equipDeadline
        end
    end

    -- The purchase itself still counts as progression even if the equipped attribute
    -- takes longer than expected to replicate; the next spending pass will re-equip it.
    return nowOwned[targetName] == true or S.Player:GetAttribute("EquippedBite") == targetName
end

local function buyBestAura()
    if not S.Settings.AutoBuyAuras then
        return false
    end
    local config = S.Modules.AuraConfig
    if not config or type(config.forWorld) ~= "function" then
        return false
    end
    local money = cashValue()
    local world = currentWorld()
    local owned = parseOwned(config, "OwnedAuras", "parseOwned")
    local ok, list = pcall(config.forWorld, world)
    if not ok or type(list) ~= "table" then
        return false
    end
    local best = nil
    for _, aura in ipairs(list) do
        local price = tonumber(aura.cashCost)
        if price and price >= 0 and price <= money and not owned[aura.id] then
            if not best or (tonumber(aura.boost) or 1) > (tonumber(best.boost) or 1) then
                best = aura
            end
        end
    end
    if best then
        setStatus("Buying aura: " .. tostring(best.name or best.id), "SHOP")
        local success, result = invoke("BuyAura", best.id)
        if success and result ~= false then
            task.wait(0.15)
            equipBestAura()
            return true
        end
    end
    equipBestAura()
    return false
end

local function nextCorePrice()
    local result = math.huge
    local money = cashValue()
    local world = currentWorld()
    local bites = S.Modules.BiteConfig
    if bites and type(bites.forWorld) == "function" then
        local owned = parseOwned(bites, "OwnedBites", "parseOwned")
        local ok, list = pcall(bites.forWorld, world)
        if ok and type(list) == "table" then
            for _, item in ipairs(list) do
                local price = tonumber(item.cashPrice)
                if price and price > money and not owned[item.name] and price < result then
                    result = price
                end
            end
        end
    end
    local auras = S.Modules.AuraConfig
    if auras and type(auras.forWorld) == "function" then
        local owned = parseOwned(auras, "OwnedAuras", "parseOwned")
        local ok, list = pcall(auras.forWorld, world)
        if ok and type(list) == "table" then
            for _, item in ipairs(list) do
                local price = tonumber(item.cashCost)
                if price and price > money and not owned[item.id] and price < result then
                    result = price
                end
            end
        end
    end
    return result
end

local function waitForAttributeChange(attribute, before, timeout)
    local deadline = os.clock() + (timeout or 1.25)
    repeat
        local now = S.Player:GetAttribute(attribute)
        if now ~= before then
            return true, now
        end
        task.wait(0.05)
    until not S.Alive or os.clock() >= deadline
    return false, S.Player:GetAttribute(attribute)
end

local function buyUpgradeVerified(id, attribute, before, cost)
    cost = tonumber(cost)
    if not cost or cost <= 0 or cost > cashValue() then
        return false
    end
    local ok, result = invoke("BuyUpgrade", id)
    if not ok or result == false then
        dprint("Upgrade rejected", id, "cost", cost, "cash", cashValue(), "result", result)
        return false
    end
    local changed, after = waitForAttributeChange(attribute, before, 1.35)
    if changed then
        dprint("Upgrade bought", id, tostring(before), "->", tostring(after), "cost", cost)
        return true
    end
    task.wait(0.15)
    after = S.Player:GetAttribute(attribute)
    if after ~= before then
        dprint("Upgrade bought (late replication)", id, tostring(before), "->", tostring(after))
        return true
    end
    dprint("Upgrade remote returned without attribute change", id, "before", tostring(before))
    return false
end

local function unlockedWorldForUpgradeCosts()
    local config = S.Modules.WorldPortalConfig
    if config and type(config.unlockedWorldFromAttributes) == "function" then
        local ok, value = pcall(config.unlockedWorldFromAttributes, S.Player)
        if ok and tonumber(value) then
            return math.max(1, math.floor(tonumber(value)))
        end
    end
    return highestUnlockedWorld()
end

local function buyUtilityUpgrade()
    if not S.Settings.AutoUtilityUpgrades then
        return false
    end

    local carryConfig = S.Modules.CarryUpgradeConfig
    if carryConfig and type(carryConfig.nextCost) == "function" then
        local cap = tonumber(S.Player:GetAttribute("CarrySpace"))
            or tonumber(carryConfig.BASE_CAPACITY)
            or 3
        local unlockedWorld = unlockedWorldForUpgradeCosts()
        local ok, cost = pcall(carryConfig.nextCost, cap, unlockedWorld)
        cost = ok and tonumber(cost) or nil
        if cost and cost <= cashValue() then
            setStatus(string.format("Upgrading carry capacity %d -> %d", cap, cap + (tonumber(carryConfig.INCREMENT) or 1)), "UPGRADE")
            if buyUpgradeVerified("CarrySpace", "CarrySpace", S.Player:GetAttribute("CarrySpace"), cost) then
                return true
            end
        end
    end

    local speedConfig = S.Modules.WalkspeedUpgradeConfig
    if speedConfig and type(speedConfig.nextCost) == "function" then
        local speed = tonumber(S.Player:GetAttribute("WalkSpeed"))
            or tonumber(speedConfig.BASE_WALKSPEED)
            or 16
        local ok, cost = pcall(speedConfig.nextCost, speed)
        cost = ok and tonumber(cost) or nil
        if cost and cost <= cashValue() then
            setStatus(string.format("Upgrading walkspeed %d -> %d", speed, speed + (tonumber(speedConfig.INCREMENT) or 1)), "UPGRADE")
            if buyUpgradeVerified("Walkspeed", "WalkSpeed", S.Player:GetAttribute("WalkSpeed"), cost) then
                return true
            end
        end
    end

    local qualityConfig = S.Modules.QualityLevelConfig
    if qualityConfig and type(qualityConfig.nextCost) == "function" then
        local level = tonumber(S.Player:GetAttribute("QualityMachineLevel"))
            or tonumber(qualityConfig.MIN_LEVEL)
            or 1
        local ok, cost = pcall(qualityConfig.nextCost, level, currentWorld())
        cost = ok and tonumber(cost) or nil
        if cost and cost <= cashValue() then
            setStatus("Upgrading quality machine", "UPGRADE")
            if buyUpgradeVerified("QualityMachine", "QualityMachineLevel", S.Player:GetAttribute("QualityMachineLevel"), cost) then
                return true
            end
        end
    end
    return false
end

local QUEST_PRIORITY = {
    "bite_125", "bite_150", "bite_175", "bite_200", "bite_225", "bite_250",
    "cash_125", "cash_150", "cash_175", "cash_200",
    "aura_ethereal", "aura_galaxy", "aura_heaven",
    "speed_1", "speed_2",
}

local function ownsQuestReward(reward)
    if not reward then
        return true
    end
    if S.Player:GetAttribute("QuestRewardOwned_" .. reward.id) == true then
        return true
    end
    if reward.mode == "aura" and reward.auraId and S.Modules.AuraConfig then
        local owned = parseOwned(S.Modules.AuraConfig, "OwnedAuras", "parseOwned")
        return owned[reward.auraId] == true
    end
    return false
end

local function permanentQuestRewardsDone()
    local config = S.Modules.QuestRewardConfig
    if not config or not config.BY_ID then
        return true
    end
    for _, id in ipairs(QUEST_PRIORITY) do
        local reward = config.BY_ID[id]
        if reward and not ownsQuestReward(reward) then
            -- Galaxy/Heaven do not beat Ethereal once Ethereal is owned.
            if (id == "aura_galaxy" or id == "aura_heaven") and ownsQuestReward(config.BY_ID["aura_ethereal"]) then
                continue
            end
            return false
        end
    end
    return true
end

local function buyQuestRewardSmart()
    if not S.Settings.AutoQuestRewards then
        return false
    end
    local config = S.Modules.QuestRewardConfig
    if not config or not config.BY_ID then
        return false
    end
    local tokens = tonumber(S.Player:GetAttribute("Tokens")) or 0
    for _, id in ipairs(QUEST_PRIORITY) do
        local reward = config.BY_ID[id]
        if reward and not ownsQuestReward(reward) then
            if (id == "aura_galaxy" or id == "aura_heaven") and ownsQuestReward(config.BY_ID["aura_ethereal"]) then
                continue
            end
            local requirementMet = true
            if reward.requires then
                local required = config.BY_ID[reward.requires]
                requirementMet = required and ownsQuestReward(required) or false
            end
            local lastTry = S.QuestAttemptAt[id] or 0
            if requirementMet and tokens >= (tonumber(reward.cost) or math.huge) and os.clock() - lastTry >= 8 then
                S.QuestAttemptAt[id] = os.clock()
                setStatus("Buying quest reward: " .. tostring(reward.title), "QUEST")
                local success, result = invoke("BuyQuestReward", id)
                if success and result ~= false then
                    task.wait(0.15)
                    equipBestAura()
                    return true
                end
            end
        end
    end
    if S.Settings.BuyRepeatableLuckyBlocks and permanentQuestRewardsDone() then
        local repeats = {"item_divine", "item_ethereal", "item_secret", "item_mythic"}
        for _, id in ipairs(repeats) do
            local reward = config.BY_ID[id]
            if reward and tokens >= (tonumber(reward.cost) or math.huge) then
                local lastTry = S.QuestAttemptAt[id] or 0
                if os.clock() - lastTry >= 2 then
                    S.QuestAttemptAt[id] = os.clock()
                    setStatus("Buying " .. tostring(reward.title), "QUEST")
                    local success, result = invoke("BuyQuestReward", id)
                    if success and result ~= false then
                        task.wait(0.15)
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function spendSmart(maxSteps)
    if os.clock() - S.LastSpendAt < 0.2 then
        return
    end
    S.LastSpendAt = os.clock()
    local steps = maxSteps or 8
    for _ = 1, steps do
        if not S.Alive or not S.Enabled then
            return
        end
        -- Bite strength is the primary progression gate. Buy/equip the strongest
        -- available bite first; utility upgrades still run immediately whenever the
        -- next bite is not affordable, so carry/walkspeed do not get starved.
        if buyBestBite() then
            continue
        end
        if buyUtilityUpgrade() then
            continue
        end
        if buyBestAura() then
            continue
        end
        if buyQuestRewardSmart() then
            continue
        end
        break
    end
end

local PACK_OWNERSHIP = {
    [1] = {[7] = "ProPackBought", [9] = "OPPackBought"},
    [2] = {[6] = "ExpansionPackBought", [9] = "GodPackBought"},
}

local WORLD1_BURGER_MODELS = {
    Hacker = "BurgerHacker",
    Lucky = "BurgerLUCK",
    Angel = "BurgerArchangel",
}

local function gamepassOwned(passId, world, zone)
    if S.Player:GetAttribute("AllGamepassesBought") == true then
        return true
    end
    local pack = PACK_OWNERSHIP[world]
    local attr = pack and pack[zone]
    if attr and S.Player:GetAttribute(attr) == true then
        return true
    end
    local cached = S.PassCache[passId]
    if cached and os.clock() - cached.at < 120 then
        return cached.owned
    end
    local owned = false
    local ok, result = pcall(function()
        return S.Services.MarketplaceService:UserOwnsGamePassAsync(S.Player.UserId, passId)
    end)
    if ok then
        owned = result == true
    end
    S.PassCache[passId] = {owned = owned, at = os.clock()}
    return owned
end

local function hasFreeHackerBurger()
    if S.Player:GetAttribute("HackerBurgerGranted") == true then
        return true
    end
    local claimedAt = tonumber(S.Player:GetAttribute("HackerBurgerClaimedAt")) or 0
    local config = S.Modules.HackerBurgerClaimConfig
    if config and type(config.hasAccess) == "function" then
        local ok, result = pcall(config.hasAccess, claimedAt)
        return ok and result == true
    end
    return claimedAt > 0 and os.time() < claimedAt + 86400
end

local function trainingCandidates(world)
    local candidates = {{name = "BurgerNormal", multiplier = 1, label = "Normal"}}
    local config = S.Modules.TrainingPassConfig
    if S.Settings.AutoBestTrainingBurger and config and type(config.LADDERS) == "table" then
        local ladder = config.LADDERS[world] or {}
        for _, entry in ipairs(ladder) do
            if entry.passId and gamepassOwned(entry.passId, world, entry.zone) then
                local modelName = world == 1 and WORLD1_BURGER_MODELS[entry.burger] or ("Burger" .. tostring(entry.burger))
                table.insert(candidates, {
                    name = modelName,
                    multiplier = tonumber(entry.multiplier) or 1,
                    label = tostring(entry.burger),
                })
            end
        end
    end
    if world == 1 and hasFreeHackerBurger() then
        table.insert(candidates, {name = "BurgerHacker", multiplier = 15, label = "Hacker (free)"})
    end
    table.sort(candidates, function(a, b)
        return a.multiplier > b.multiplier
    end)
    return candidates
end

local function bestTrainingBurger(world)
    local lobby = lobbyForWorld(world)
    local trainArea = lobby and lobby:FindFirstChild("TrainArea")
    local food = trainArea and trainArea:FindFirstChild("Food")
    if not food then
        return nil, nil
    end
    for _, candidate in ipairs(trainingCandidates(world)) do
        local burger = food:FindFirstChild(candidate.name)
        if burger then
            return burger, candidate
        end
    end
    return food:FindFirstChild("BurgerNormal"), {name = "BurgerNormal", multiplier = 1, label = "Normal"}
end

local function moveToTrainingBurger()
    local world = currentWorld()
    local burger, info = bestTrainingBurger(world)
    local r = root()
    local burgerPos = burger and positionOf(burger) or nil

    -- The game's Teleport to Spawn button exists specifically to return from the
    -- wall course to the lobby. Use that instead of walking the entire course back.
    if not burger or (r and burgerPos and flatDistance(r.Position, burgerPos) > 45) then
        useSpawnTeleport("Teleport to Spawn for training")
        task.wait(0.15)
        burger, info = bestTrainingBurger(world)
    end

    if not burger then
        return false, nil
    end
    local part = bestPart(burger)
    r = root()
    if part and r then
        local point = standoffPoint(part, r.Position, 2.8)
        walkTo(point, part.Position)
    else
        local position = positionOf(burger)
        if not position then
            return false, nil
        end
        walkTo(position + Vector3.new(0, 0, 2.5), position)
    end
    return true, info
end

local function wallTargetRatio(room)
    local biggest = biggestRemainingWall(room)
    local bite = math.max(biteValue(), 1)
    return biggest / bite
end

local function trainUntilRoomEfficient(room)
    local ok, burger = moveToTrainingBurger()
    if not ok then
        return false
    end
    setStatus(string.format("Training on %s for Room %d", burger and burger.label or "burger", room), "TRAIN")
    local lastBite = biteValue()
    local lastProgress = os.clock()
    while S.Alive and S.Enabled do
        if tryRebirth() then
            return true
        end
        local ratio = wallTargetRatio(room)
        if ratio <= (tonumber(S.Settings.TargetWallHits) or 75) then
            local route = routeFromServer(false)
            useAutoPlayTeleport(route, "Autoplay returning to the wall course")
            return true
        end
        local nowBite = biteValue()
        if nowBite > lastBite then
            lastBite = nowBite
            lastProgress = os.clock()
        elseif os.clock() - lastProgress > 3.5 then
            -- Reposition if streaming/collision left us outside the burger hit range.
            moveToTrainingBurger()
            lastProgress = os.clock()
        end
        task.wait(0.16)
    end
    return false
end

local Smart = {}

function Smart.configuredWallHP(room, wall)
    local config = S.Modules.WallConfig
    if config and type(config.maxHP) == "function" then
        local ok, value = pcall(config.maxHP, room, wall)
        if ok and tonumber(value) then
            return math.max(tonumber(value), 0)
        end
    end
    return wallHP(room, wall)
end

function Smart.configuredBiggestWall(room)
    local biggest = 0
    for wall = 1, 8 do
        local hp = Smart.configuredWallHP(room, wall)
        if hp > biggest then
            biggest = hp
        end
    end
    if biggest <= 0 then
        biggest = biggestRemainingWall(room)
    end
    return biggest
end

function Smart.roomHits(room)
    return Smart.configuredBiggestWall(room) / math.max(biteValue(), 1)
end

function Smart.frontier(route)
    if not route or type(route.rooms) ~= "table" then
        return nil, nil, nil
    end
    local targetHits = math.max(tonumber(S.Settings.TargetWallHits) or 75, 1)
    local frontierRoom, frontierIndex, frontierHits = nil, nil, nil

    -- Rooms are sequential. The first room that is too expensive is the real
    -- frontier even if a later room happens to have an unusual HP adjustment.
    for index, entry in ipairs(route.rooms) do
        local room = tonumber(entry.room)
        if room then
            local hits = Smart.roomHits(room)
            if hits <= targetHits then
                frontierRoom, frontierIndex, frontierHits = room, index, hits
            else
                break
            end
        end
    end

    if not frontierRoom and route.rooms[1] then
        frontierRoom = tonumber(route.rooms[1].room)
        frontierIndex = 1
        frontierHits = frontierRoom and Smart.roomHits(frontierRoom) or nil
    end

    S.PowerFrontierRoom = frontierRoom
    S.PowerFrontierHits = frontierHits
    return frontierRoom, frontierIndex, frontierHits
end

function Smart.routeIndex(route, room)
    if not route or type(route.rooms) ~= "table" then
        return nil
    end
    for index, entry in ipairs(route.rooms) do
        if tonumber(entry.room) == tonumber(room) then
            return index
        end
    end
    return nil
end

function Smart.roomWorthNormalLoot(room, route)
    if S.Settings.SmartLoot == false then
        return true, nil
    end
    local frontierRoom, frontierIndex = Smart.frontier(route)
    local roomIndex = Smart.routeIndex(route, room)
    if not frontierIndex or not roomIndex then
        return true, frontierRoom
    end
    local window = math.max(0, math.floor(tonumber(S.Settings.SmartLootRoomWindow) or 2))
    return roomIndex >= math.max(1, frontierIndex - window), frontierRoom
end

function Smart.readAttr(item, name)
    if not item then
        return nil
    end
    local value = item:GetAttribute(name)
    if value ~= nil then
        return value
    end
    for _, child in ipairs(item:GetDescendants()) do
        if child:IsA("Tool") or child:IsA("Model") or child:IsA("BasePart") then
            value = child:GetAttribute(name)
            if value ~= nil then
                return value
            end
        end
    end
    return nil
end

function Smart.itemName(item)
    local explicit = Smart.readAttr(item, "ItemName") or Smart.readAttr(item, "LootName") or Smart.readAttr(item, "DisplayName")
    if explicit and tostring(explicit) ~= "" then
        return tostring(explicit)
    end
    local tool = item:IsA("Tool") and item or item:FindFirstChildWhichIsA("Tool", true)
    if tool then
        return tool.Name
    end
    local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt and prompt.ObjectText and prompt.ObjectText ~= "" then
        return prompt.ObjectText
    end
    return item.Name
end

function Smart.itemInfo(item)
    local rarity = Smart.readAttr(item, "Rarity")
    rarity = rarity and tostring(rarity) or nil
    local name = Smart.itemName(item)
    local sell = tonumber(Smart.readAttr(item, "SellValue")) or 0
    local quality = tonumber(Smart.readAttr(item, "QualityMultiplier")) or 1

    -- Some server revisions keep the value attributes on the catalogue Tool
    -- template rather than on the floating wrapper. Resolve that transparently.
    local catalogue = S.Modules.ItemCatalogue
    if sell <= 0 and catalogue and rarity and name and type(catalogue.entryFor) == "function" then
        local ok, entry = pcall(catalogue.entryFor, rarity, name)
        local template = ok and entry and entry.template or nil
        if template then
            sell = tonumber(template:GetAttribute("SellValue")) or sell
            quality = tonumber(Smart.readAttr(template, "QualityMultiplier")) or quality
        end
    end

    local rarityRank = 0
    local rarityConfig = S.Modules.RarityConfig
    if rarityConfig and type(rarityConfig.INDEX) == "table" and rarity then
        rarityRank = tonumber(rarityConfig.INDEX[rarity]) or 0
    end

    local discovered = true
    if rarity and name and catalogue and type(catalogue.parseDiscovered) == "function" then
        local ok, set = pcall(catalogue.parseDiscovered, S.Player:GetAttribute("DiscoveredItems"))
        if ok and type(set) == "table" then
            local key
            if type(catalogue.keyFor) == "function" then
                local keyOk, result = pcall(catalogue.keyFor, rarity, name)
                key = keyOk and result or nil
            end
            key = key or (rarity .. "/" .. name)
            discovered = set[key] == true
        end
    end

    return {
        name = name,
        rarity = rarity,
        rarityRank = rarityRank,
        sell = sell,
        quality = quality,
        value = math.max(sell, 0) * math.max(quality, 0),
        undiscovered = not discovered,
    }
end

function Smart.lootBelongsToRoom(item, room)
    local node = item
    local wanted = "Room" .. tostring(room)
    while node and node ~= S.Services.Workspace do
        if node.Name == wanted then
            return true
        end
        node = node.Parent
    end
    return false
end

function Smart.isOurLoot(item)
    local owner = item and item:GetAttribute("OwnerUserId")
    return owner == nil or tonumber(owner) == tonumber(S.Player.UserId)
end

function Smart.roomLoot(room)
    local r = root()
    local candidates = {}
    local bestValue = 0
    local bestRank = 0
    for _, item in ipairs(S.Services.CollectionService:GetTagged("FloatingItem")) do
        if item and item.Parent and Smart.isOurLoot(item) and Smart.lootBelongsToRoom(item, room) then
            local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
            local position = positionOf(item)
            if prompt and position then
                local info = Smart.itemInfo(item)
                local distance = r and (position - r.Position).Magnitude or 0
                bestValue = math.max(bestValue, tonumber(info.value) or 0)
                bestRank = math.max(bestRank, tonumber(info.rarityRank) or 0)
                table.insert(candidates, {
                    item = item,
                    info = info,
                    position = position,
                    distance = distance,
                })
            end
        end
    end

    if bestValue > 0 then
        local world = currentWorld()
        S.BestLootValueByWorld[world] = math.max(tonumber(S.BestLootValueByWorld[world]) or 0, bestValue)
    end

    table.sort(candidates, function(a, b)
        if a.info.undiscovered ~= b.info.undiscovered then
            return a.info.undiscovered
        end
        if a.info.value ~= b.info.value then
            return a.info.value > b.info.value
        end
        if a.info.rarityRank ~= b.info.rarityRank then
            return a.info.rarityRank > b.info.rarityRank
        end
        if a.info.quality ~= b.info.quality then
            return a.info.quality > b.info.quality
        end
        return a.distance < b.distance
    end)

    return candidates, bestValue, bestRank
end

function Smart.carriedCheapestValue()
    local cheapest = nil
    for _, tool in ipairs(carriedTools()) do
        local value = (tonumber(tool:GetAttribute("SellValue")) or 0) * (tonumber(tool:GetAttribute("QualityMultiplier")) or 1)
        if value > 0 and (cheapest == nil or value < cheapest) then
            cheapest = value
        end
    end
    return cheapest
end

function Smart.shouldPick(candidate, room, route, roomBestValue, roomBestRank)
    if not candidate or not candidate.info then
        return false, "invalid"
    end
    if S.Settings.SmartLoot == false then
        return true, "smart loot disabled"
    end

    local info = candidate.info

    local normalRoom, frontierRoom = Smart.roomWorthNormalLoot(room, route)
    local roomIndex = Smart.routeIndex(route, room)
    local _, frontierIndex = Smart.frontier(route)
    local window = math.max(0, math.floor(tonumber(S.Settings.SmartLootRoomWindow) or 2))
    local used = #carriedTools()
    local capacity = carryCapacity()

    -- Index discoveries are useful, but they must not sabotage cash progression.
    -- Only take a cheap new discovery when it is reasonably close to the current
    -- Bite-power frontier and the bag still has comfortable spare capacity.
    if S.Settings.SmartLootNewIndex ~= false and info.undiscovered then
        local nearFrontier = not roomIndex
            or not frontierIndex
            or roomIndex >= math.max(1, frontierIndex - math.max(window + 2, 4))
        local hasSpare = used <= math.floor(math.max(capacity, 1) * 0.6)
        if normalRoom or (nearFrontier and hasSpare) then
            return true, "new index item"
        end
    end

    -- Exceptionally rare/quality rolls are worth taking even from a push-through room.
    local mythicRank = 6
    local rarityConfig = S.Modules.RarityConfig
    if rarityConfig and type(rarityConfig.INDEX) == "table" then
        mythicRank = tonumber(rarityConfig.INDEX.Mythic) or mythicRank
    end
    local jackpot = (tonumber(info.rarityRank) or 0) >= mythicRank or (tonumber(info.quality) or 1) >= 10

    if not normalRoom and not jackpot then
        return false, "below bite-power loot frontier"
    end

    local percent = math.clamp(tonumber(S.Settings.SmartLootValuePercent) or 0.35, 0, 1)
    local observedBest = tonumber(S.BestLootValueByWorld[currentWorld()]) or 0
    local referenceValue = math.max(tonumber(roomBestValue) or 0, observedBest)
    if info.value > 0 and referenceValue > 0 and info.value < referenceValue * percent and not jackpot then
        return false, "low value roll"
    end

    -- When space is nearly gone, never spend the final slot on something worse
    -- than what is already being carried.
    if used >= math.max(capacity - 1, 1) and info.value > 0 then
        local cheapest = Smart.carriedCheapestValue()
        if cheapest and info.value <= cheapest and not jackpot then
            return false, "worse than carried loot"
        end
    end

    -- Floating-item value/rarity attributes can arrive a little after the model/tag.
    -- If this is already a Bite-power-worthy room, missing metadata must never turn
    -- into a blanket rejection: the room tier itself is the fallback value signal.
    if info.value <= 0 and normalRoom then
        return true, frontierRoom and ("room-tier fallback · frontier R" .. tostring(frontierRoom)) or "room-tier fallback"
    end

    return true, frontierRoom and ("frontier R" .. tostring(frontierRoom)) or "worthwhile"
end

local function pickupLootCandidate(candidate)
    if not candidate or not candidate.item or not candidate.item.Parent then
        return false
    end

    local item = candidate.item
    local prompt = item:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not prompt then
        return false
    end

    local before = carriedCount()
    local pickupTimeout = 6
    local config = S.Modules.AutoPlayConfig
    if config then
        pickupTimeout = tonumber(config.PICKUP_TIMEOUT) or pickupTimeout
    end

    local firePrompt = rawget(ENV, "fireproximityprompt") or rawget(_G, "fireproximityprompt")
    if type(firePrompt) == "function" then
        pcall(firePrompt, prompt)
    else
        -- Match the game's autoplay: begin the prompt and keep it held until the
        -- floating item disappears (or the authoritative timeout expires).
        pcall(function()
            prompt:InputHoldBegin()
        end)
    end

    local deadline = os.clock() + pickupTimeout
    local picked = false
    repeat
        task.wait(0.08)
        if not item.Parent or carriedCount() > before then
            picked = true
            break
        end
    until not S.Alive or not S.Enabled or os.clock() >= deadline

    if type(firePrompt) ~= "function" then
        pcall(function()
            prompt:InputHoldEnd()
        end)
    end

    return picked or not item.Parent or carriedCount() > before
end

local function collectRoomLoot(room, route)
    if not S.Settings.CollectLoot then
        return
    end

    local normalRoom, frontierRoom = Smart.roomWorthNormalLoot(room, route)
    if S.Settings.SmartLoot ~= false and not normalRoom then
        -- Cheap push-through rooms are intentionally skipped, but jackpot / new
        -- Index drops are still allowed to override the skip if they appear.
        setStatus(string.format(
            "Room %d cleared · pushing toward Bite frontier R%s",
            room,
            frontierRoom and tostring(frontierRoom) or "?"
        ), "PUSH")
    else
        setStatus(string.format(
            "Waiting for smart loot R%d · Bite frontier R%s",
            room,
            frontierRoom and tostring(frontierRoom) or tostring(room)
        ), "LOOT")
    end

    -- These are the exact timings used by the game's own AutoPlay module in the
    -- supplied W4 dump. The important fix is LOOT_RESPAWN_WAIT: loot is not
    -- guaranteed to exist the instant the final wall reaches 0 HP.
    local config = S.Modules.AutoPlayConfig
    local collectTimeout = config and tonumber(config.COLLECT_TIMEOUT) or 45
    local respawnWait = config and tonumber(config.LOOT_RESPAWN_WAIT) or 5
    -- Do not add a 5-second delay to intentionally skipped weak rooms. The full
    -- game wait is preserved on rooms we actually intend to loot; push-through
    -- rooms only get a short grace period for an immediately visible jackpot.
    local effectiveRespawnWait = normalRoom and respawnWait or math.min(respawnWait, 0.75)
    local deadline = os.clock() + collectTimeout
    local emptySince = nil
    local pickupFailures = 0

    while S.Alive and S.Enabled and os.clock() < deadline do
        if S.ForceSell or inventoryFull() then
            S.ForceSell = true
            cancelWalking()
            return
        end

        local candidates, roomBestValue, roomBestRank = Smart.roomLoot(room)
        if #candidates == 0 then
            emptySince = emptySince or os.clock()
            local waited = os.clock() - emptySince
            if waited >= effectiveRespawnWait then
                dprint("No more loot after respawn wait", room, string.format("%.2fs", waited))
                return
            end
            if normalRoom then
                setStatus(string.format(
                    "Waiting for Room %d loot · %.1f/%.1fs",
                    room,
                    waited,
                    effectiveRespawnWait
                ), "LOOT")
            end
            task.wait(0.15)
            continue
        end

        -- Loot exists now, so restart the no-loot timer. This mirrors the game:
        -- after every successful pickup it allows another respawn window for the
        -- next drop from the same room.
        emptySince = nil

        local chosen, reason = nil, nil
        for _, candidate in ipairs(candidates) do
            local pick, why = Smart.shouldPick(candidate, room, route, roomBestValue, roomBestRank)
            if pick then
                chosen, reason = candidate, why
                break
            end
        end

        if not chosen then
            -- Items are present but every one is deliberately below the current
            -- Bite-power/value threshold. Waiting longer cannot improve these rolls.
            dprint("Skipping present low-value room loot", room, "frontier", tostring(frontierRoom))
            return
        end

        local info = chosen.info
        setStatus(string.format(
            "Picking %s %s · $%s x%.2f · %s",
            tostring(info.rarity or "?"),
            tostring(info.name or "item"),
            abbreviate(info.sell),
            tonumber(info.quality) or 1,
            tostring(reason or "smart")
        ), "LOOT")

        if chosen.position then
            local reached = walkTo(chosen.position, chosen.position, {arrival = 4.5, timeout = 45})
            if not reached then
                pickupFailures += 1
                if pickupFailures >= 3 then
                    dprint("Loot walk failed 3 times", room)
                    return
                end
                task.wait(0.12)
                continue
            end
        end

        if pickupLootCandidate(chosen) then
            pickupFailures = 0
            if inventoryFull() then
                S.ForceSell = true
                cancelWalking()
                return
            end
            task.wait(0.08)
        else
            pickupFailures += 1
            dprint("Loot pickup failed", room, tostring(info.name), pickupFailures)
            if pickupFailures >= 3 then
                return
            end
            task.wait(0.15)
        end
    end
end

local function exactSellTarget()
    local lobby = lobbyForWorld(currentWorld())
    if not lobby then
        return nil
    end

    local shops = lobby:FindFirstChild("Shops")
    local sell = shops and shops:FindFirstChild("Sell")
    if not sell then
        return nil
    end
    if sell:IsA("BasePart") then
        return sell
    end

    -- Prefer an actual touch/zone part over decorative sign geometry.
    for _, wanted in ipairs({"Trigger", "Hitbox", "Zone", "Touch", "Pad", "Base"}) do
        local node = sell:FindFirstChild(wanted, true)
        if node and node:IsA("BasePart") then
            return node
        end
    end
    if sell:IsA("Model") and sell.PrimaryPart then
        return sell.PrimaryPart
    end

    local best, bestScore = nil, -math.huge
    for _, node in ipairs(sell:GetDescendants()) do
        if node:IsA("BasePart") then
            local volume = node.Size.X * node.Size.Y * node.Size.Z
            local score = volume + (node.CanTouch and 100000 or 0) + (node.CanCollide and 1000 or 0)
            if score > bestScore then
                best, bestScore = node, score
            end
        end
    end
    return best
end

local function fireSellAllUntilEmpty(before, attempts)
    attempts = math.max(math.floor(tonumber(attempts) or 3), 1)
    local previous = tonumber(before) or carriedCount()
    for _ = 1, attempts do
        invoke("SellItems") -- no argument = the game's SELL ALL button
        local deadline = os.clock() + 0.75
        repeat
            task.wait(0.06)
            local now = carriedCount()
            if now <= 0 then
                return true
            end
            if now < previous then
                previous = now
                break
            end
        until os.clock() >= deadline or not S.Alive
    end
    return carriedCount() <= 0
end

local function sellNameScore(instance)
    local node = instance
    local depth = 0
    local score = nil
    while node and node ~= S.Services.Workspace and depth < 5 do
        local name = string.lower(node.Name or "")
        if string.find(name, "sellarea", 1, true) or string.find(name, "sellzone", 1, true) then
            score = math.min(score or 100, 0 + depth)
        elseif string.find(name, "sell", 1, true) then
            score = math.min(score or 100, 10 + depth)
        elseif string.find(name, "cashin", 1, true) or string.find(name, "cashout", 1, true) then
            score = math.min(score or 100, 20 + depth)
        end
        node = node.Parent
        depth += 1
    end
    return score
end

local function sellTargets()
    local r = root()
    local world = currentWorld()
    local lobby = lobbyForWorld(world)
    local roots = {}
    if lobby then
        table.insert(roots, lobby)
    end
    table.insert(roots, S.Services.Workspace)

    local seen = {}
    local targets = {}
    for _, scanRoot in ipairs(roots) do
        for _, node in ipairs(scanRoot:GetDescendants()) do
            if node:IsA("BasePart") and not seen[node] then
                local score = sellNameScore(node)
                if score ~= nil then
                    seen[node] = true
                    local distance = r and flatDistance(r.Position, node.Position) or 0
                    table.insert(targets, {part = node, score = score, distance = distance})
                end
            end
        end
        if #targets > 0 then
            break
        end
    end

    table.sort(targets, function(a, b)
        if a.score == b.score then
            return a.distance < b.distance
        end
        return a.score < b.score
    end)
    return targets
end

local function walkToSellAndSell(before)
    -- Full-bag sell path: use the game's Teleport to Spawn button, then physically
    -- enter Lobby*.Shops.Sell so the server opens the sell station, then mirror
    -- the SELL ALL button with SellItems:FireServer().
    useSpawnTeleport("Inventory full · Teleport to Spawn")
    task.wait(0.15)

    local openedBefore = tonumber(S.SellUIOpenedAt) or 0
    local exact = exactSellTarget()
    if exact and exact.Parent then
        setStatus("Inventory full · going to SELL ALL", "SELL")
        walkTo(exact.Position, nil, {arrival = 2.75, timeout = 90})
        task.wait(0.25)

        -- Give the normal sell-zone touch enough time to emit OpenSellUI.
        local zoneDeadline = os.clock() + 1.25
        while S.Alive and os.clock() < zoneDeadline and (tonumber(S.SellUIOpenedAt) or 0) <= openedBefore do
            task.wait(0.05)
        end

        if fireSellAllUntilEmpty(before, 4) then
            return true
        end
    end

    -- Fallback for streamed or renamed variants of the station.
    local candidates = sellTargets()
    local attempts = math.min(#candidates, 8)
    for index = 1, attempts do
        local candidate = candidates[index]
        local part = candidate and candidate.part
        if part and part.Parent then
            setStatus(string.format("Finding sell station (%d/%d)", index, attempts), "SELL")
            walkTo(part.Position, nil, {arrival = 3.25, timeout = 90})
            task.wait(0.2)
            if fireSellAllUntilEmpty(carriedCount(), 2) then
                return true
            end
        end
    end

    -- Re-use the real spawn button and retry the exact station once more.
    useSpawnTeleport("Retrying full-bag sell")
    task.wait(0.2)
    exact = exactSellTarget()
    if exact and exact.Parent then
        walkTo(exact.Position, nil, {arrival = 2.75, timeout = 90})
        task.wait(0.2)
    end
    return fireSellAllUntilEmpty(carriedCount(), 4)
end

local function sellInventory(force)
    if not S.Settings.AutoSell or S.Selling then
        return false
    end

    local before = carriedCount()
    if before <= 0 then
        S.ForceSell = false
        return false
    end

    local full = inventoryFull()
    if not force then
        if S.Settings.SellOnlyWhenFull ~= false and not full then
            return false
        end
        if S.Settings.SellOnlyWhenFull == false and before < carryCapacity() then
            return false
        end
    end

    S.Selling = true
    S.LastSellAttempt = os.clock()
    S.ForceSell = true
    cancelWalking()
    setStatus(string.format("FULL %d/%d · going to SELL ALL", before, carryCapacity()), "SELL")

    local sold = walkToSellAndSell(before)
    local after = carriedCount()

    -- A SELL ALL trip is only complete once active carried loot is gone.
    if after <= 0 then
        S.ForceSell = false
    else
        S.ForceSell = true
    end
    S.Selling = false

    if sold or after < before then
        spendSmart(10)
        S.RouteFresh = true
        if after <= 0 then
            local route = routeFromServer(false)
            useAutoPlayTeleport(route, "Sold bag · Autoplay returning to course")
        end
        return true
    end

    setStatus(string.format("SELL ALL failed · %d item%s remain", after, after == 1 and "" or "s"), "SELL")
    return false
end

local function farmRoom(routeEntry, route)
    local room = tonumber(routeEntry.room)
    if not room then
        return false
    end
    local position = routeEntry.position
    local frontierRoom = route and select(1, Smart.frontier(route)) or nil
    if frontierRoom and room < frontierRoom then
        setStatus(string.format("Power pushing R%d -> Bite frontier R%d", room, frontierRoom), "PUSH")
    end
    if typeof(position) == "Vector3" then
        walkTo(position, position + Vector3.new(0, 0, -1))
    end
    local roomDeadline = os.clock() + 60
    while S.Alive and S.Enabled and roomRemainingHP(room) > 0 and os.clock() < roomDeadline do
        if S.ForceSell or S.Selling or inventoryFull() then
            S.ForceSell = true
            return false
        end
        if tryRebirth() then
            return false
        end
        if wallTargetRatio(room) > (tonumber(S.Settings.TargetWallHits) or 75) then
            if not trainUntilRoomEfficient(room) then
                return false
            end
            if currentWorld() ~= S.RouteWorld then
                return false
            end
        end
        local r = root()
        local wall, part = nextWallInRoom(room, r and r.Position or position)
        if not wall then
            task.wait(0.15)
            continue
        end
        if not part then
            task.wait(0.25)
            continue
        end
        local hpBefore = wallHP(room, wall)
        local ref = typeof(position) == "Vector3" and position or (r and r.Position) or part.Position
        local stand = standoffPoint(part, ref, 3.25)
        walkTo(stand, part.Position)
        local bite = math.max(biteValue(), 1)
        local hitEstimate = hpBefore / bite
        setStatus(string.format(
            "R%d W%d · %s HP · Bite %s · %.1f hits%s",
            room,
            wall,
            abbreviate(hpBefore),
            abbreviate(bite),
            hitEstimate,
            frontierRoom and (" · frontier R" .. tostring(frontierRoom)) or ""
        ), "WALL")
        local predicted = (hpBefore / bite) * (tonumber(S.Settings.BiteInterval) or 0.055)
        local timeout = math.clamp(predicted * 2 + (tonumber(S.Settings.WallTimeoutPadding) or 7), 6, 35)
        local deadline = os.clock() + timeout
        local lastHp = hpBefore
        local lastProgress = os.clock()
        while S.Alive and S.Enabled and wallHP(room, wall) > 0 and os.clock() < deadline do
            local hpNow = wallHP(room, wall)
            if hpNow < lastHp then
                lastHp = hpNow
                lastProgress = os.clock()
            elseif os.clock() - lastProgress > 2.5 then
                local currentPart = wallPart(room, wall)
                if currentPart then
                    local currentRoot = root()
                    local currentRef = typeof(position) == "Vector3" and position or (currentRoot and currentRoot.Position) or currentPart.Position
                    local newStand = standoffPoint(currentPart, currentRef, 3.1)
                    walkTo(newStand, currentPart.Position)
                end
                lastProgress = os.clock()
            end
            task.wait(0.08)
        end
        if wallHP(room, wall) > 0 then
            -- If wall damage stalled, training is more productive than spinning here.
            trainUntilRoomEfficient(room)
        end
        task.wait(0.08)
    end
    if roomRemainingHP(room) <= 0 then
        task.wait(0.18)
        collectRoomLoot(room, route)
        if S.ForceSell or inventoryFull() then
            sellInventory(true)
        end
        return true
    end
    return false
end

local function firstRemainingRouteRoom(route)
    if not route or type(route.rooms) ~= "table" then
        return nil
    end
    for _, entry in ipairs(route.rooms) do
        local room = tonumber(entry.room)
        if room and roomRemainingHP(room) > 0 then
            return entry
        end
    end
    return nil
end

local function resetAutoPlayCycle(route)
    -- Keep valuable smart-loot across cycles. Only interrupt for a sell when the
    -- bag is truly full (unless the user explicitly disables full-only selling).
    if S.ForceSell or inventoryFull() then
        sellInventory(true)
    elseif S.Settings.SellOnlyWhenFull == false and carriedCount() > 0 then
        sellInventory(true)
    end
    spendSmart(12)
    if not useAutoPlayTeleport(route, "Autoplay resetting the wall cycle") then
        setStatus("Walking back to the start of the wall cycle", "WALK")
        if route and route.start then
            walkTo(route.start, nil, {arrival = 6, timeout = 120})
        end
    end
    S.RouteFresh = false
    task.wait(0.2)
end

local function claimRewardsOnce(includeCodes)
    if not S.Settings.AutoRewards then
        return
    end
    if includeCodes and S.Settings.AutoCodes then
        -- These were the non-expired codes in the supplied W4 game dump.
        invoke("RedeemCode", "10KPLAYERS")
        task.wait(0.08)
        invoke("RedeemCode", "WORLD4")
    end
    invoke("ClaimDailyReward")
    task.wait(0.05)
    invoke("ClaimGroupReward")
    task.wait(0.05)
    invoke("ClaimOfflineEarnings")
    task.wait(0.05)
    invoke("ClaimHackerBurger")
    for index = 1, 7 do
        invoke("ClaimPlaytimeReward", index)
        task.wait(0.04)
    end
end


local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local Lighting = game:GetService("Lighting")
local GuiService = game:GetService("GuiService")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local function characterParts()
	local character = LocalPlayer.Character
	if not character then
		return nil, nil, nil
	end
	return character, character:FindFirstChild("HumanoidRootPart"), character:FindFirstChildOfClass("Humanoid")
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



local API = createFeatureAPI("NOX_1BitePerClick")
API.Track(function()
	if S.Unload then S.Unload() end
end)

local Flags = {
	AutoReconnect = false,
	Disable3DRendering = false,
	FpsBoost = false,
	AntiAfk = true,
}

local PlayerApi = {}
local fpsSnapshots = setmetatable({}, { __mode = "k" })
local fpsConnection = nil
local reconnectConnections = {}
local renderPrior = nil
local renderCover = nil

function PlayerApi.setAutoReconnect(value)
	Flags.AutoReconnect = value == true
	for _, conn in ipairs(reconnectConnections) do
		conn:Disconnect()
	end
	table.clear(reconnectConnections)
	if not Flags.AutoReconnect then
		return
	end
	local attemptToken = 0
	local function reconnect()
		if API.Unloaded or not Flags.AutoReconnect then
			return
		end
		attemptToken += 1
		local token = attemptToken
		task.spawn(function()
			task.wait(1.5)
			if API.Unloaded or not Flags.AutoReconnect or token ~= attemptToken then
				return
			end
			pcall(function()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
			end)
			task.wait(4)
			if API.Unloaded or not Flags.AutoReconnect or token ~= attemptToken then
				return
			end
			pcall(function()
				TeleportService:Teleport(game.PlaceId, LocalPlayer)
			end)
		end)
	end
	table.insert(reconnectConnections, GuiService.ErrorMessageChanged:Connect(function()
		if Flags.AutoReconnect then
			reconnect()
		end
	end))
	table.insert(reconnectConnections, TeleportService.TeleportInitFailed:Connect(function(player)
		if player == LocalPlayer and Flags.AutoReconnect then
			reconnect()
		end
	end))
	API.Track(function()
		for _, conn in ipairs(reconnectConnections) do
			conn:Disconnect()
		end
		table.clear(reconnectConnections)
	end)
end

function PlayerApi.setDisable3D(value)
	Flags.Disable3DRendering = value == true
	if Flags.Disable3DRendering then
		if renderPrior == nil and typeof(RunService.Set3dRenderingEnabled) == "function" then
			renderPrior = true
		end
		pcall(function()
			RunService:Set3dRenderingEnabled(false)
		end)
		if not renderCover then
			local gui = Instance.new("ScreenGui")
			gui.Name = "NOXRenderCover"
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = -100
			gui.ResetOnSpawn = false
			local frame = Instance.new("Frame")
			frame.BackgroundColor3 = Color3.new(0, 0, 0)
			frame.Size = UDim2.fromScale(1, 1)
			frame.BorderSizePixel = 0
			frame.Parent = gui
			gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
			renderCover = gui
			API.Track(function()
				if renderCover then
					renderCover:Destroy()
					renderCover = nil
				end
			end)
		end
	else
		pcall(function()
			RunService:Set3dRenderingEnabled(true)
		end)
		if renderCover then
			renderCover:Destroy()
			renderCover = nil
		end
	end
end

local FPS_CLASSES = {
	ParticleEmitter = true,
	Trail = true,
	Beam = true,
	Fire = true,
	Smoke = true,
	Sparkles = true,
}

local function softenEffect(inst)
	if fpsSnapshots[inst] ~= nil then
		return
	end
	if FPS_CLASSES[inst.ClassName] then
		fpsSnapshots[inst] = { kind = "enabled", value = inst.Enabled }
		inst.Enabled = false
	end
end

function PlayerApi.setFpsBoost(value)
	Flags.FpsBoost = value == true
	if fpsConnection then
		fpsConnection:Disconnect()
		fpsConnection = nil
	end
	if not Flags.FpsBoost then
		for inst, prior in pairs(fpsSnapshots) do
			if inst.Parent and prior.kind == "enabled" then
				inst.Enabled = prior.value
			end
			fpsSnapshots[inst] = nil
		end
		if fpsSnapshots.lighting then
			local prior = fpsSnapshots.lighting
			Lighting.GlobalShadows = prior.GlobalShadows
			Lighting.FogEnd = prior.FogEnd
			fpsSnapshots.lighting = nil
		end
		return
	end
	fpsSnapshots.lighting = {
		GlobalShadows = Lighting.GlobalShadows,
		FogEnd = Lighting.FogEnd,
	}
	Lighting.GlobalShadows = false
	Lighting.FogEnd = 1e6
	local scanned = 0
	for _, inst in ipairs(Workspace:GetDescendants()) do
		softenEffect(inst)
		scanned += 1
		if scanned >= 4000 then
			break
		end
	end
	fpsConnection = Workspace.DescendantAdded:Connect(function(inst)
		if Flags.FpsBoost then
			softenEffect(inst)
		end
	end)
	API.Track(function()
		if fpsConnection then
			fpsConnection:Disconnect()
			fpsConnection = nil
		end
	end)
end

local MenuApi = {}
local antiAfkConnection = nil
local antiAfkGen = 0

function MenuApi.setAntiAfk(value)
	Flags.AntiAfk = value == true
	antiAfkGen += 1
	local gen = antiAfkGen
	if antiAfkConnection then
		antiAfkConnection:Disconnect()
		antiAfkConnection = nil
	end
	if not Flags.AntiAfk then
		return
	end
	antiAfkConnection = LocalPlayer.Idled:Connect(function()
		if API.Unloaded or not Flags.AntiAfk then
			return
		end
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
	task.spawn(function()
		while not API.Unloaded and Flags.AntiAfk and gen == antiAfkGen do
			task.wait(60)
			if API.Unloaded or not Flags.AntiAfk or gen ~= antiAfkGen then
				break
			end
			pcall(function()
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.new())
			end)
		end
	end)
	API.Track(function()
		if antiAfkConnection then
			antiAfkConnection:Disconnect()
			antiAfkConnection = nil
		end
		antiAfkGen += 1
	end)
end


if not hasHttpGet or not hasLoadstring then
	error("UI load requires HttpGet and loadstring", 0)
end

local okLibrary, Library = pcall(function()
	return loadstring(game:HttpGet(UI_SOURCE_URL))()
end)
if not okLibrary or type(Library) ~= "table" then
	error("failed to load UI library: " .. tostring(Library), 0)
end
if not S.Alive then return end

Library:LoadFont({ Name = "ValleySans" })
Library:SetDefaultTheme("Mono")

local Window = Library:CreateWindow({
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
S.Window = Window

attachUI(API, Window)

local Main = Window:CreateTab({ Name = "Main", Icon = "utensils" })
local Settings = Window:CreateTab({ Name = "Settings", Icon = "settings" })

local function notify(message)
	if S.Alive then
		pcall(function()
			Library:Notify({ Title = GAME_NAME, Content = tostring(message), Duration = 2 })
		end)
	end
end

local function readFlag(name, default)
	local entry = Library.Flags and Library.Flags[name]
	if entry == nil then
		return default
	end
	if type(entry) == "table" then
		if type(entry.Get) == "function" then
			local ok, value = pcall(entry.Get, entry)
			if ok then
				return value
			end
		end
		if entry.Value ~= nil then
			return entry.Value
		end
		return default
	end
	return entry
end

local RuntimeStatusLabel, RuntimeStatsLabel

-- Recommended defaults are applied before the controls are built, so everything
-- starts on and saved configs (loaded afterwards) simply override them.
local function applyRecommended()
	local s = S.Settings
	s.CollectLoot, s.SmartLoot, s.SmartLootNewIndex, s.AutoSell, s.SellOnlyWhenFull = true, true, true, true, true
	s.SmartLootRoomWindow = 2
	s.SmartLootValuePercent = 0.35
	s.AutoBestTrainingBurger, s.AutoRebirth, s.AutoWorld = true, true, true
	s.AutoBuyBites, s.AutoBuyAuras, s.AutoUtilityUpgrades, s.AutoQuestRewards = true, true, true, true
	s.AutoRewards, s.AutoCodes, s.BuyRepeatableLuckyBlocks = true, true, true
	s.UseSpawnTeleport, s.UseAutoPlayTeleport, s.WalkJumpWhenStuck = true, true, true
	s.TargetWallHits = 75
	s.BiteInterval = 0.055
	s.WalkArrivalDistance = 3.25
	s.WalkStuckSeconds = 1.35
	s.WalkMaxRepaths = 8
end
applyRecommended()

local function buildMainTab()
	local FarmBox = Main:AddLeftGroupbox({ Name = "Auto Farm", Icon = "zap" })
	RuntimeStatusLabel = FarmBox:CreateLabel({ Text = "Starting..." })
	RuntimeStatsLabel = FarmBox:CreateLabel({ Text = "Loading progression data..." })
	FarmBox:CreateToggle({
		Name = "Auto Farm",
		CurrentValue = S.Enabled,
		Flag = "BP_Enabled",
		Callback = function(value)
			S.Enabled = value == true
			if not S.Enabled then
				cancelWalking()
				setStatus("Paused", "PAUSED")
			else
				setStatus("Resuming auto farm", "START")
			end
		end,
	})

	local AutoBox = Main:AddRightGroupbox({ Name = "Features", Icon = "cog" })
	AutoBox:CreateToggle({
		Name = "Auto Loot + Sell",
		CurrentValue = true,
		Flag = "BP_AutoLootSell",
		Callback = function(value)
			local enabled = value == true
			S.Settings.CollectLoot = enabled
			S.Settings.SmartLoot = enabled
			S.Settings.AutoSell = enabled
			if enabled then
				S.Settings.SellOnlyWhenFull = true
				S.Settings.SmartLootNewIndex = true
			end
		end,
	})
	AutoBox:CreateToggle({
		Name = "Auto Progression",
		CurrentValue = true,
		Flag = "BP_AutoProgression",
		Callback = function(value)
			local enabled = value == true
			S.Settings.AutoBestTrainingBurger = enabled
			S.Settings.AutoRebirth = enabled
			S.Settings.AutoWorld = enabled
			S.Settings.AutoBuyBites = enabled
			S.Settings.AutoBuyAuras = enabled
			S.Settings.AutoUtilityUpgrades = enabled
			S.Settings.AutoQuestRewards = enabled
		end,
	})
	AutoBox:CreateToggle({
		Name = "Auto Rewards",
		CurrentValue = true,
		Flag = "BP_AutoRewards",
		Callback = function(value)
			local enabled = value == true
			S.Settings.AutoRewards = enabled
			S.Settings.AutoCodes = enabled
			S.Settings.BuyRepeatableLuckyBlocks = enabled
		end,
	})
end

buildMainTab()

local function buildSettingsTab()
	local ClientBox = Settings:AddLeftGroupbox({ Name = "Client", Icon = "monitor" })
	ClientBox:CreateToggle({
		Name = "Auto Reconnect on Kick",
		CurrentValue = false,
		Flag = "AutoReconnect",
		Callback = function(value)
			PlayerApi.setAutoReconnect(value)
		end,
	})
	ClientBox:CreateToggle({
		Name = "Disable 3D Rendering",
		CurrentValue = false,
		Flag = "Disable3DRendering",
		Callback = function(value)
			PlayerApi.setDisable3D(value)
		end,
	})
	ClientBox:CreateToggle({
		Name = "FPS Boost",
		CurrentValue = false,
		Flag = "FpsBoost",
		Callback = function(value)
			PlayerApi.setFpsBoost(value)
		end,
	})
	ClientBox:CreateToggle({
		Name = "Hide UI On Start",
		CurrentValue = false,
		Flag = "HideUIOnStart",
		Callback = function() end,
	})

	local Interface = Settings:AddRightGroupbox({ Name = "Menu", Icon = "monitor" })
	Interface:CreateKeybind({
		Name = "Toggle UI",
		CurrentKeybind = "RightControl",
		Flag = "ToggleUIKey",
		Callback = function() end,
		OnChanged = function(key)
			Window:SetKeybind(key)
		end,
	})
	Interface:CreateDropdown({
		Name = "Toggle button",
		Options = { "Mobile only", "Mobile & PC" },
		CurrentOption = "Mobile only",
		AllowNone = false,
		Flag = "ToggleButtonPlatform",
		Callback = function(option)
			local selected = if type(option) == "table" then option[1] else option
			Window:SetToggleButtonPlatform(selected == "Mobile & PC" and "Both" or "Mobile")
		end,
	})
	Interface:CreateToggle({
		Name = "Anti AFK",
		CurrentValue = true,
		Flag = "AntiAfk",
		Callback = function(value)
			MenuApi.setAntiAfk(value)
		end,
	})
	Interface:CreateButton({
		Name = "Unload",
		Icon = "power",
		Callback = function()
			Library:Confirm({
				Title = "Unload?",
				ConfirmText = "Unload",
				Callback = function()
					Window:Destroy()
				end,
			})
		end,
	})
	Settings:CreateConfigManager({ Name = "Configs", Side = "Left" })
	Settings:CreateThemeManager({ Name = "Themes", Side = "Right" })
end


buildSettingsTab()

MenuApi.setAntiAfk(true)

Window:LoadAutoload()

if readFlag("HideUIOnStart", false) == true then
	Window:Toggle(false)
end

-- Keep the status labels live and recover if nothing has progressed for a while.
task.spawn(function()
    local lastSignature, lastProgressAt = nil, os.clock()
    while S.Alive and not API.Unloaded do
        local okSig, signature = pcall(function()
            return table.concat({
                tostring(currentWorld()), tostring(rebirthValue()), tostring(currentLevel()),
                tostring(biteValue()), tostring(cashValue()), tostring(#carriedTools()),
            }, "|")
        end)
        if okSig then
            if signature ~= lastSignature then
                lastSignature, lastProgressAt = signature, os.clock()
            elseif S.Enabled and os.clock() - lastProgressAt > 90 then
                -- No Bite, cash, level, world or loot change for 90 seconds: reset the
                -- walk/route state so the main loop starts again from a clean slate.
                lastProgressAt = os.clock()
                cancelWalking()
                S.Route, S.RouteWorld, S.RouteFresh = nil, nil, false
                setStatus("No progress detected, recovering", "RECOVER")
            end
        end
        if RuntimeStatusLabel and RuntimeStatusLabel.Set then
            RuntimeStatusLabel:Set(string.format("[%s] %s", S.Mode, S.Status))
        end
        if RuntimeStatsLabel and RuntimeStatsLabel.Set then
            pcall(function()
                RuntimeStatsLabel:Set(string.format(
                    "World %d · Rebirths %d · Level %d/%s\nBite %s · Frontier R%s · Cash $%s\nCarry %d/%d · Speed %d · Best loot $%s",
                    currentWorld(),
                    rebirthValue(),
                    currentLevel(),
                    requiredRebirthLevel() == math.huge and "?" or tostring(requiredRebirthLevel()),
                    abbreviate(biteValue()),
                    S.PowerFrontierRoom and tostring(S.PowerFrontierRoom) or "?",
                    abbreviate(cashValue()),
                    #carriedTools(),
                    carryCapacity(),
                    tonumber(S.Player:GetAttribute("WalkSpeed")) or 16,
                    abbreviate(S.BestLootValueByWorld[currentWorld()] or 0)
                ))
            end)
        end
        task.wait(0.25)
    end
end)

function S.Unload()
    if not S.Alive then
        return
    end
    S.Alive = false
    S.Enabled = false
    cancelWalking()
    for _, connection in ipairs(S.Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    S.Connections = {}
    pcall(function()
        Window:Destroy()
    end)
    if ENV.__NOX_1BiteSmartFarm == S then
        ENV.__NOX_1BiteSmartFarm = nil
    end
    print("[NOX 1Bite] Unloaded")
end

-- Track the real sell-zone UI opening so SELL ALL is fired after entering the station.
do
    local remote = getRemote("OpenSellUI")
    if remote and remote:IsA("RemoteEvent") then
        addConnection(remote.OnClientEvent:Connect(function()
            S.SellUIOpenedAt = os.clock()
        end))
    end
end

-- Immediate full-bag interrupt. The game's InventoryFull event is authoritative and
-- catches any edge case where the local carried-count check is a frame late.
do
    local remote = getRemote("InventoryFull")
    if remote and remote:IsA("RemoteEvent") then
        addConnection(remote.OnClientEvent:Connect(function()
            S.ForceSell = true
            cancelWalking()
            if S.Settings.AutoSell and not S.Selling then
                task.spawn(function()
                    sellInventory(true)
                end)
            end
        end))
    end
end

-- Lucky-block rewards normally wait on the long reveal + manual CLAIM button.
-- Claim the server reward immediately, then release the local claim UI when the executor supports firesignal.
do
    local openRemote = getRemote("LuckyBlockOpen")
    if openRemote and openRemote:IsA("RemoteEvent") then
        addConnection(openRemote.OnClientEvent:Connect(function()
            task.delay(0.35, function()
                if S.Alive then
                    invoke("LuckyBlockClaimed")
                end
            end)
        end))
    end
    local playerGui = S.Player:FindFirstChild("PlayerGui")
    if playerGui then
        addConnection(playerGui.ChildAdded:Connect(function(child)
            if child.Name ~= "LuckyBlockClaim" then
                return
            end
            task.delay(0.05, function()
                local fireSignal = rawget(ENV, "firesignal") or rawget(_G, "firesignal")
                if type(fireSignal) ~= "function" or not child.Parent then
                    return
                end
                local button = child:FindFirstChildWhichIsA("GuiButton", true)
                if button then
                    pcall(fireSignal, button.MouseButton1Click)
                end
            end)
        end))
    end
end


-- High-rate bite worker. Movement determines whether bites hit a wall, a training burger, or just add normal Bite.
task.spawn(function()
    while S.Alive do
        if S.Enabled then
            local biteRemote = getRemote("Bite")
            if biteRemote and biteRemote:IsA("RemoteEvent") then
                pcall(function()
                    biteRemote:FireServer()
                end)
            end
        end
        task.wait(math.max(tonumber(S.Settings.BiteInterval) or 0.055, 0.03))
    end
end)

-- Reward worker.
task.spawn(function()
    task.wait(1)
    claimRewardsOnce(true)
    local slowTick = 0
    while S.Alive do
        if S.Enabled and S.Settings.AutoRewards then
            for index = 1, 7 do
                invoke("ClaimPlaytimeReward", index)
                task.wait(0.03)
            end
            slowTick += 1
            if slowTick >= 15 then -- roughly every five minutes
                slowTick = 0
                claimRewardsOnce(false)
            end
        end
        task.wait(20)
    end
end)

-- Background spending catches cash gained while another progression step is running.
task.spawn(function()
    while S.Alive do
        if S.Enabled then
            spendSmart(4)
        end
        task.wait(1.2)
    end
end)

-- Main progression brain.
task.spawn(function()
    local dataDeadline = os.clock() + 15
    while S.Alive and S.Player:GetAttribute("DataLoaded") == false and os.clock() < dataDeadline do
        task.wait(0.15)
    end
    waitForCharacter(15)
    spendSmart(12)
    ensureBestWorld()
    equipBestAura()

    while S.Alive do
        if not S.Enabled then
            task.wait(0.2)
            continue
        end

        local r, h = waitForCharacter(5)
        if not r or not h then
            setStatus("Waiting for character", "RESPAWN")
            task.wait(0.3)
            continue
        end

        if S.ForceSell or inventoryFull() then
            sellInventory(true)
            task.wait(0.1)
            continue
        end

        if tryRebirth() then
            spendSmart(8)
            task.wait(0.15)
            continue
        end

        if ensureBestWorld() then
            spendSmart(8)
            task.wait(0.3)
            continue
        end

        local route = routeFromServer(false)
        if not route then
            setStatus("Waiting for server autoplay route", "ROUTE")
            task.wait(0.7)
            route = routeFromServer(true)
            if not route then
                task.wait(1)
                continue
            end
        end

        if S.RouteFresh then
            S.RouteFresh = false
            local currentRoot = root()
            if route.start and currentRoot and flatDistance(currentRoot.Position, route.start) > 25 then
                if not useAutoPlayTeleport(route, "Autoplay moving to the wall-course start") then
                    setStatus("Walking to the wall-course start", "WALK")
                    walkTo(route.start, nil, {arrival = 7, timeout = 120})
                end
            end
        end

        local entry = firstRemainingRouteRoom(route)
        if not entry then
            resetAutoPlayCycle(route)
            task.wait(0.2)
            continue
        end

        local room = tonumber(entry.room)
        if room and wallTargetRatio(room) > (tonumber(S.Settings.TargetWallHits) or 75) then
            trainUntilRoomEfficient(room)
            task.wait(0.05)
            continue
        end

        Smart.frontier(route)
        farmRoom(entry, route)
        task.wait(0.05)
    end
end)
