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
-- Tap Simulator: Reborn. The game's data and remotes; everything else comes from shared/env.
--
-- Player data is a MadStudio Replica, read through the client's DataController
-- (ReplicatedStorage.Controllers.Core.DataController): Env.data() is its live Data table. Nothing
-- here writes it -- the server owns it and replicates down -- so every feature works by firing the
-- game's own request remotes and watching the replica change.
--
-- Remotes use sleitnick Comm: each service is a folder under ReplicatedStorage.RemoteServices with
-- an RE subfolder (RemoteEvents) and an RF subfolder (RemoteFunctions). Env.remote resolves either.

local Env = use("shared/env")

Env.checkMissing({
    { "queue_on_teleport", Env.queueOnTeleport },
    { "setclipboard", Env.setClipboard },
})
for _, name in ipairs({ "readfile", "writefile", "isfile", "isfolder", "makefolder", "listfiles", "delfile" }) do
    Env.checkMissing({ { name, Env.files[name] } })
end
table.sort(Env.missing)

local RS = Env.ReplicatedStorage

-- The DataController singleton, required lazily (it is loaded by the game long before the hub).
local dataController
local function controller()
    if dataController == nil then
        local ok, module = Env.call(function()
            local core = Env.need(Env.need(RS, "Controllers", 20), "Core", 10)
            return require(Env.need(core, "DataController", 10))
        end)
        dataController = ok and module or false
    end
    return dataController or nil
end
Env.preloadData = controller

-- The player's Replica, or nil before it has replicated.
function Env.replica()
    local dc = controller()
    if not dc then
        return nil
    end
    local ok, replica = Env.call(function()
        return dc.GetReplica and dc:GetReplica() or dc.Get and dc:Get()
    end)
    return ok and replica or nil
end

-- The live player Data table (Currencies, Progression, Eggs, Pets, Upgrades, ...), or nil.
function Env.data()
    local replica = Env.replica()
    return replica and replica.Data or nil
end

-- One field of Currencies (Coins, Gems, Tokens, PaidTokens), as a number, or 0.
function Env.currency(name)
    local data = Env.data()
    local value = data and type(data.Currencies) == "table" and data.Currencies[name]
    return tonumber(value) or 0
end

-- A RemoteEvent or RemoteFunction under RemoteServices.<service>.(RE|RF).<name>, cached.
local remotes = {}
function Env.remote(service, name)
    local key = service .. "/" .. name
    local found = remotes[key]
    if not found or not found.Parent then
        local svc = Env.need(Env.need(RS, "RemoteServices", 30), service, 15)
        local node
        local deadline = os.clock() + 10
        repeat
            local re, rf = svc:FindFirstChild("RE"), svc:FindFirstChild("RF")
            node = (re and re:FindFirstChild(name)) or (rf and rf:FindFirstChild(name))
            if not node then
                task.wait(0.1)
            end
        until node or os.clock() >= deadline
        Env.elevate()
        assert(node, "NOX: remote " .. key .. " is missing")
        remotes[key] = node
        found = node
    end
    return found
end

-- Fires a RemoteEvent request (RemoteServices.<service>.RE.<name>) with one payload table.
function Env.fire(service, name, payload)
    local remote = Env.remote(service, name)
    Env.elevate()
    remote:FireServer(payload)
end

-- Invokes a RemoteFunction (RemoteServices.<service>.RF.<name>) and restores the thread after.
-- Returns ok, ... like pcall. InvokeServer has no timeout of its own, and one reply that never
-- comes would otherwise stall the feature that asked (and anything waiting on it), so after
-- INVOKE_TIMEOUT seconds this gives up with false, "timeout"; a late reply is dropped.
local INVOKE_TIMEOUT = 10
function Env.invoke(service, name, ...)
    local remote = Env.remote(service, name)
    local args = table.pack(...)
    local done, result = false, nil
    task.spawn(function()
        result = table.pack(Env.call(function()
            return remote:InvokeServer(table.unpack(args, 1, args.n))
        end))
        done = true
    end)
    local deadline = os.clock() + INVOKE_TIMEOUT
    while not done and os.clock() < deadline do
        task.wait(0.03)
    end
    Env.elevate()
    if not done then
        return false, "timeout"
    end
    return table.unpack(result, 1, result.n)
end

-- Where the hub's own overlays go, out of the game's PlayerGui.
function Env.guiParent()
    local ok, hidden = pcall(function()
        return gethui and gethui()
    end)
    return ok and hidden or game:GetService("CoreGui")
end

return Env
end
__modules["core/ready"] = function(use)
-- Waits until the game has loaded what the hub reads, before any feature is built. Executed on
-- join, the hub used to start while the replica and character were still on their way.

local Env = use("core/env")

local Ready = {}

local MAX_WAIT = 180
local NOTE_EVERY = 15

local StarterGui = game:GetService("StarterGui")
local RS = Env.ReplicatedStorage
local lp = Env.LocalPlayer

local function notify(text, duration)
    pcall(StarterGui.SetCore, StarterGui, "SendNotification", {
        Title = "NOX",
        Text = text,
        Duration = duration or 5,
    })
    Env.elevate()
end

local function characterReady()
    local char = lp.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    return char ~= nil and char:FindFirstChild("HumanoidRootPart") ~= nil and humanoid ~= nil and humanoid.Health > 0
end

local CHECKLIST = {
    { "the game's remotes", function()
        return RS:FindFirstChild("RemoteServices") ~= nil and RS:FindFirstChild("Controllers") ~= nil
    end },
    { "your save data", function()
        local data = Env.data()
        return data ~= nil and type(data.Currencies) == "table"
    end },
    { "your character", characterReady },
}

-- Blocks until the game is ready (or MAX_WAIT passed). Returns the labels that never became ready.
function Ready.wait()
    local started = os.clock()
    task.spawn(pcall, Env.preloadData)
    local nextNote = started + 3
    local missing
    while true do
        missing = {}
        for _, entry in ipairs(CHECKLIST) do
            local ok, done = pcall(entry[2])
            if not ok or not done then
                missing[#missing + 1] = entry[1]
            end
        end
        Env.elevate()
        if #missing == 0 then
            break
        end
        local now = os.clock()
        if now - started >= MAX_WAIT then
            notify(string.format("Still no %s after %ds. Loading anyway.", table.concat(missing, ", "), MAX_WAIT), 10)
            break
        end
        if now >= nextNote then
            notify(string.format("Waiting for the game to load: %s (%ds)", table.concat(missing, ", "), math.floor(now - started)), 5)
            nextNote = now + NOTE_EVERY
        end
        task.wait(0.5)
    end
    return missing
end

return Ready
end
__modules["core/ui"] = function(use)
-- Tap Simulator's window and tabs.

local Ui = use("shared/ui")

return Ui.create({
    icons = use("vendor/icons"),
    footer = "Tap Simulator",
    tabs = {
        { "Home", "house", "Welcome to NOX" },
        { "Tapping", "hand", "Auto tap, auto clicker, rebirth and upgrades" },
        { "Pets", "egg", "Auto hatch eggs, equip your strongest pets and feed them treats" },
        { "Craft", "hammer", "Golden, Diamond and Rainbow machines, and potions" },
        { "Skills", "git-branch", "Auto unlock the skill tree" },
        { "Rewards", "gift", "Offline earnings, quests, Pet Index, chests, spins, ducks, balloons and digging" },
        { "Settings", "settings", "Menu, themes and configs" },
    },
})
end
__modules["features/craft"] = function(use)
-- Craft tab: the pet machines (Normal -> Golden -> Diamond -> Rainbow). Potions are features/potions.
--
-- Golden and Diamond take same-name pets of the source tier and roll a chance that rises with how
-- many go in (MachineConfig.Chances, plus the Golden mastery bonus, scaled by your enchant craft
-- bonus). A failed roll destroys every pet put in, so the cheapest safe batch is the fewest pets
-- that already reach 100%; "Best value" instead takes the lowest expected pets per success.
-- Rainbow (the "Shiny" machine) is a timed queue of up to three: Durations[count], and 5 Diamonds
-- finish in 30 seconds where 2 take five hours.
--
-- The game's own Craft All (MachineCraftRequested { Action = "CraftAll" }) does up to 60 of those
-- 100% batches in one request, keeping equipped, team, locked, mutated, enchanted, signed and
-- Secret pets (Shared.Pets.CraftAllPlan), so "Never fail" uses it and asks that same plan whether
-- there is anything to craft before flying anywhere.
--
-- The server checks distance ("You must be near the Golden Machine"), and the machines' interaction
-- points only exist once streamed in, so a pass teleports to each machine that has work, waits for
-- its InteractionPoint, stands in it, crafts, and goes back to where you were.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local tab = Ui.Tabs.Craft

-- Rules ----------------------------------------------------------------------------------------

-- The values from the shipped MachineConfig, used only if the module cannot be required.
local FALLBACK_CONFIG = {
    Golden = { SourceTier = "Normal", Chances = { 13, 32, 40, 63, 80, 100 } },
    Diamond = { SourceTier = "Golden", Chances = { 20, 40, 60, 80, 100 } },
    Shiny = { SourceTier = "Diamond", MinPets = 2, MaxQueue = 3, Durations = { 28800, 18000, 9000, 3600, 30 } },
}

local MachineConfig, Mastery, EnchantFormula, CraftAllPlan
do
    local okPlan, plan = Env.call(function()
        local module = RS.Shared.Pets:FindFirstChild("CraftAllPlan")
        return module and require(module)
    end)
    CraftAllPlan = okPlan and type(plan) == "table" and plan or nil
    local ok, config = Env.call(function()
        return require(RS.Shared.Pets.MachineConfig)
    end)
    MachineConfig = ok and type(config) == "table" and config.Golden and config or FALLBACK_CONFIG
    local okMastery, mastery = Env.call(function()
        return require(RS.Shared.Progression.MasteryFormula)
    end)
    Mastery = okMastery and mastery or nil
    local okEnchant, formula = Env.call(function()
        return require(RS.Shared.Pets.EnchantFormula)
    end)
    EnchantFormula = okEnchant and formula or nil
end

-- Where each machine stands; a machine can stand in several places and the nearest one is used.
-- `model` is the machine's model (its pivot is readable once it exists, even far away); `fallback`
-- is where its interaction point was when the hub was written. The Shadow Realm has its own Golden
-- machine beside the Rainbow one and the Void egg, so a hatch-and-craft loop barely moves.
local MACHINES = {
    Golden = { label = "Golden", point = "Golden", places = {
        { model = { "Ts2Islands", "Shadow Realm", "Folder", "GoldenMachine" }, fallback = Vector3.new(47, 7679, -1723) },
        { model = { "GoldenMachine" }, fallback = Vector3.new(14.5, -516, -1885.6) },
    } },
    Diamond = { label = "Diamond", point = "Diamond", places = {
        { model = { "DiamondMachine" }, fallback = Vector3.new(-186.6, 5444.4, -2002.3) },
    } },
    Shiny = { label = "Rainbow", point = "Rainbow", places = {
        { model = { "Ts2Islands", "Shadow Realm", "Folder", "RainbowMachine" }, fallback = Vector3.new(90.7, 7677.6, -1933.5) },
    } },
}
local ORDER = { "Golden", "Diamond", "Shiny" } -- low tier first, so one pass chains upward

local NEVER_FAIL, BEST_VALUE = "Never fail (fewest pets at 100%)", "Best value (fewest pets per success)"
local RAINBOW_SPEEDS = { "5 pets - 30s", "4 pets - 1h", "3 pets - 2.5h", "2 pets - 5h" }
local RAINBOW_COUNT = { ["5 pets - 30s"] = 5, ["4 pets - 1h"] = 4, ["3 pets - 2.5h"] = 3, ["2 pets - 5h"] = 2 }
local RAINBOW_WAIT = 35 -- stay at the machine for a craft finishing this soon instead of flying back later

-- The chance the machine will roll, computed the way the game's own machine screen does.
local function chance(key, count, data)
    local base = MachineConfig[key].Chances[count]
    if type(base) ~= "number" then
        return 0
    end
    if key == "Golden" and Mastery then
        local ok, bonus = Env.call(Mastery.GetBonus, data, "MachineGoldenChance")
        if ok and type(bonus) == "number" then
            base += math.floor(bonus * 100 + 0.5)
        end
    end
    if EnchantFormula then
        local ok, scaled = Env.call(EnchantFormula.ApplyCraftChance, data, base)
        if ok and type(scaled) == "number" then
            return scaled
        end
    end
    return math.clamp(base, 0, 100)
end

-- How many pets go into one Golden or Diamond craft, and the chance that gives.
local function batchSize(key, data)
    local max = #MachineConfig[key].Chances
    if Options.CraftStrategy.Value ~= BEST_VALUE then
        for count = 1, max do
            local roll = chance(key, count, data)
            if roll >= 100 then
                return count, roll
            end
        end
        return max, chance(key, max, data)
    end
    local best, bestCost, bestRoll
    for count = 1, max do
        local roll = chance(key, count, data)
        if roll > 0 then
            local cost = count / (roll / 100)
            -- On a tie the surer roll wins: same pets per success, less variance.
            if not best or cost < bestCost - 1e-9 or (math.abs(cost - bestCost) <= 1e-9 and roll > bestRoll) then
                best, bestCost, bestRoll = count, cost, roll
            end
        end
    end
    return best or max, bestRoll or 0
end

local function rainbowCount()
    return RAINBOW_COUNT[Options.RainbowSpeed.Value] or 5
end

-- Pets of `tier` that may be crafted, grouped by name, each group in the order the game itself
-- sacrifices them: unequipped, unmutated, lowest level, lowest XP.
local function groups(tier, data)
    local equipped = {}
    for _, id in pairs(type(data.Pets.Equipped) == "table" and data.Pets.Equipped or {}) do
        equipped[id] = true
    end
    local never = Options.CraftNever.Value or {}
    local keepEquipped, keepMutated = Ui.on("CraftKeepEquipped"), Ui.on("CraftKeepMutated")
    local byName = {}
    for id, pet in pairs(type(data.Pets.Owned) == "table" and data.Pets.Owned or {}) do
        if type(pet) == "table" and pet.Tier == tier and pet.Locked ~= true and pet.Frozen == nil
            and not never[pet.Name]
            and not (keepEquipped and equipped[id])
            and not (keepMutated and pet.Mutation ~= nil) then
            local group = byName[pet.Name]
            if not group then
                group = { name = pet.Name, entries = {} }
                byName[pet.Name] = group
            end
            group.entries[#group.entries + 1] = { id = id, pet = pet, equipped = equipped[id] == true }
        end
    end
    local list = {}
    for _, group in pairs(byName) do
        table.sort(group.entries, function(a, b)
            if a.equipped ~= b.equipped then
                return not a.equipped
            end
            local mutatedA, mutatedB = a.pet.Mutation ~= nil, b.pet.Mutation ~= nil
            if mutatedA ~= mutatedB then
                return not mutatedA
            end
            local levelA, levelB = a.pet.Level or 1, b.pet.Level or 1
            if levelA ~= levelB then
                return levelA < levelB
            end
            local xpA, xpB = a.pet.XP or 0, b.pet.XP or 0
            if xpA ~= xpB then
                return xpA < xpB
            end
            return tostring(a.id) < tostring(b.id)
        end)
        list[#list + 1] = group
    end
    -- Biggest pile first: that is the one most worth turning into the next tier.
    table.sort(list, function(a, b)
        if #a.entries ~= #b.entries then
            return #a.entries > #b.entries
        end
        return a.name < b.name
    end)
    return list
end

-- The next batch of `count` same-name pet ids for `key`, or nil.
local function nextBatch(key, count, data)
    for _, group in ipairs(groups(MachineConfig[key].SourceTier, data)) do
        if #group.entries >= count then
            local ids = {}
            for index = 1, count do
                ids[index] = group.entries[index].id
            end
            return ids, group.name
        end
    end
    return nil
end

local function rainbowQueue(data)
    local shiny = type(data.Machines) == "table" and data.Machines.Shiny
    local queue = type(shiny) == "table" and type(shiny.Queue) == "table" and shiny.Queue or {}
    local now = workspace:GetServerTimeNow()
    local entries, ready, soonest = 0, {}, nil
    for id, craft in pairs(queue) do
        entries += 1
        local ends = type(craft) == "table" and tonumber(craft.EndTime) or 0
        if ends <= now then
            ready[#ready + 1] = id
        else
            soonest = math.min(soonest or math.huge, ends - now)
        end
    end
    return entries, ready, soonest
end

-- Craft All ------------------------------------------------------------------------------------

-- Craft All unlocks per machine with its mastery ("Reach Goldens Mastery Lv. 4 to unlock Craft
-- All!"). A refusal parks it for that machine a while, so every pass is not one wasted request.
local craftAllBlocked = {} -- machine key -> os.clock() until which single batches are used
local CRAFT_ALL_RETRY = 600

local function useCraftAll(key)
    return CraftAllPlan ~= nil and Options.CraftStrategy.Value ~= BEST_VALUE and os.clock() >= (craftAllBlocked[key] or 0)
end

-- The pet names Craft All may use: every source-tier name outside the "Never craft" list, or nil
-- (all of them) when that list is empty.
local function allowedNames(key, data)
    local never = Options.CraftNever.Value or {}
    if next(never) == nil then
        return nil
    end
    local names, seen = {}, {}
    local tier = MachineConfig[key].SourceTier
    for _, pet in pairs(type(data.Pets.Owned) == "table" and data.Pets.Owned or {}) do
        if type(pet) == "table" and pet.Tier == tier and not never[pet.Name] and not seen[pet.Name] then
            seen[pet.Name] = true
            names[#names + 1] = pet.Name
        end
    end
    return names
end

-- Whether the game's own Craft All plan would make at least one batch right now.
local function craftAllReady(key, data)
    local needed = batchSize(key, data)
    local names = allowedNames(key, data)
    local tier = MachineConfig[key].SourceTier
    local ok, ready = Env.call(function()
        if names == nil then
            return CraftAllPlan.Ready(data, tier, needed)
        end
        local set = {}
        for _, name in ipairs(names) do
            set[name] = true
        end
        local plan = CraftAllPlan.Build(data, tier, needed, set)
        return type(plan) == "table" and type(plan.Batches) == "table" and #plan.Batches > 0
    end)
    return ok and ready == true
end

-- Whether a machine has anything to do right now (checked before flying anywhere).
local function hasWork(key, data)
    if key == "Shiny" then
        local entries, ready = rainbowQueue(data)
        return #ready > 0 or (entries < (MachineConfig.Shiny.MaxQueue or 3) and nextBatch("Shiny", rainbowCount(), data) ~= nil)
    end
    if useCraftAll(key) then
        return craftAllReady(key, data)
    end
    return nextBatch(key, (batchSize(key, data)), data) ~= nil
end

-- Movement -------------------------------------------------------------------------------------

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function modelPivot(path)
    local node = workspace
    for _, name in ipairs(path) do
        node = node and node:FindFirstChild(name)
    end
    if not node then
        return nil
    end
    local ok, pivot = pcall(node.GetPivot, node)
    return ok and pivot.Position or nil
end

local function findPoint(name, near)
    local best, bestDistance
    local function consider(part)
        if part and part:IsA("BasePart") and part.Name == name then
            local distance = (part.Position - near).Magnitude
            if distance < 400 and (not best or distance < bestDistance) then
                best, bestDistance = part, distance
            end
        end
    end
    for _, part in ipairs(Env.CollectionService:GetTagged("InteractionPoint")) do
        consider(part)
    end
    local folder = workspace:FindFirstChild("InteractionPoints")
    consider(folder and folder:FindFirstChild(name))
    return best
end

local function teleport(cframe)
    local hrp = root()
    if not hrp then
        return false
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = cframe
    return true
end

-- Stands in a machine's interaction point, trying its places nearest first. False when none of
-- them streamed in.
local function goTo(def)
    local hrp = root()
    if not hrp then
        return false
    end
    local here = hrp.Position
    local places = {}
    for _, place in ipairs(def.places) do
        places[#places + 1] = modelPivot(place.model) or place.fallback
    end
    table.sort(places, function(a, b)
        return (a - here).Magnitude < (b - here).Magnitude
    end)
    for _, target in ipairs(places) do
        local point = findPoint(def.point, target)
        if not point then
            pcall(function()
                Env.LocalPlayer:RequestStreamAroundAsync(target, 10)
            end)
            Env.elevate()
            if not teleport(CFrame.new(target + Vector3.new(0, 6, 0))) then
                return false
            end
            local deadline = os.clock() + 8
            while Life.alive and os.clock() < deadline and not point do
                Life.wait(0.2)
                point = findPoint(def.point, target)
            end
        end
        if point then
            teleport(point.CFrame)
            Life.wait(0.35) -- give the server a beat to see us inside before the first request
            return true
        end
    end
    return false
end

-- Requests -------------------------------------------------------------------------------------

-- One machine request at a time, answered on MachineCraftResult, the way the machine screen does.
local waiting
Life.spawn("craft:results", function()
    local remote = Env.remote("MachineService", "MachineCraftResult")
    Life.connect(remote.OnClientEvent, function(payload)
        if waiting and type(payload) == "table" and payload.Machine == waiting.machine then
            waiting.result = payload
        end
    end, "craft:result")
end)

local function request(machine, payload)
    local slot = { machine = machine }
    waiting = slot
    Env.fire("MachineService", "MachineCraftRequested", payload)
    local deadline = os.clock() + 6
    while Life.alive and not slot.result and os.clock() < deadline do
        Life.wait(0.05)
    end
    if waiting == slot then
        waiting = nil
    end
    return slot.result
end

local function tooFar(result)
    return type(result) == "table" and string.find(string.lower(tostring(result.Reason or "")), "near", 1, true) ~= nil
end

-- UI -------------------------------------------------------------------------------------------

local box = tab:AddGroupbox({ Side = "Left", Name = "Pet machines", IconName = "hammer" })
box:AddToggle("AutoCraft", {
    Text = "Auto craft pets",
    Default = false,
    Tooltip = "Turns duplicates into Golden, Golden into Diamond and Diamond into Rainbow pets. Teleports to each machine that has work and brings you back.",
})
Ui.automation("AutoCraft")
box:AddDropdown("CraftMachines", {
    Text = "Machines",
    Values = { "Golden", "Diamond", "Rainbow" },
    Multi = true,
    Default = { "Golden", "Diamond", "Rainbow" },
})
box:AddDropdown("CraftStrategy", {
    Text = "Golden / Diamond",
    Values = { NEVER_FAIL, BEST_VALUE },
    Default = NEVER_FAIL,
    Tooltip = "A failed roll destroys every pet put in. 'Never fail' uses the fewest pets that already reach 100%. 'Best value' gambles when that costs fewer pets per success on average.",
})
box:AddDropdown("RainbowSpeed", {
    Text = "Rainbow",
    Values = RAINBOW_SPEEDS,
    Default = RAINBOW_SPEEDS[1],
    Tooltip = "Pets per Rainbow craft. 5 finishes in 30 seconds; 2 uses fewer Diamonds but takes five hours.",
})
box:AddToggle("CraftKeepEquipped", {
    Text = "Keep equipped pets",
    Default = true,
    Tooltip = "Never puts a pet from your team into a machine. In 'Never fail' the game's Craft All keeps equipped, team, locked, mutated, enchanted and Secret pets anyway.",
})
box:AddToggle("CraftKeepMutated", {
    Text = "Keep mutated pets",
    Default = true,
})
box:AddDropdown("CraftNever", {
    Text = "Never craft",
    Values = {},
    Multi = true,
    Searchable = true,
    Default = {},
    Tooltip = "Pets that are never put into a machine, whatever their tier.",
})
box:AddSlider("CraftEvery", {
    Text = "Check every",
    Default = 10,
    Min = 3,
    Max = 120,
    Rounding = 0,
    Suffix = "s",
})
box:AddToggle("CraftReturn", {
    Text = "Return to where I was",
    Default = true,
})

local statusBox = tab:AddGroupbox({ Side = "Right", Name = "Crafting", IconName = "activity" })
local panel = Ui.panel(statusBox, 5)

-- The "Never craft" list follows the pets you own.
local nameSignature
Life.loop("craft:names", 5, function()
    local data = Env.data()
    if not data or type(data.Pets) ~= "table" then
        return
    end
    local seen, names = {}, {}
    for _, pet in pairs(type(data.Pets.Owned) == "table" and data.Pets.Owned or {}) do
        if type(pet) == "table" and type(pet.Name) == "string" and not seen[pet.Name] then
            seen[pet.Name] = true
            names[#names + 1] = pet.Name
        end
    end
    table.sort(names)
    local joined = table.concat(names, "\0")
    if joined ~= nameSignature then
        nameSignature = joined
        Env.elevate()
        Options.CraftNever:SetValues(names)
    end
end)

-- Passes ---------------------------------------------------------------------------------------

local session = { Golden = 0, Diamond = 0, Shiny = 0, failed = 0 }
local lastNote = "Idle."
local busy = false

local function machineOn(key)
    local picked = Options.CraftMachines.Value or {}
    return picked[MACHINES[key].label] == true
end

local function keepGoing(manual)
    return Life.alive and (manual or Ui.on("AutoCraft"))
end

-- Every Golden or Diamond batch there is, at that machine: Craft All requests (60 batches each)
-- in "Never fail", single batches in "Best value" or if the server refuses Craft All this pass.
local function runTier(key, manual)
    local def = MACHINES[key]
    local arrived, retried = false, false
    local craftAll = useCraftAll(key)
    while keepGoing(manual) do
        local data = Env.data()
        if not data then
            return
        end
        local count, roll = batchSize(key, data)
        local ids, name
        if craftAll then
            if not craftAllReady(key, data) then
                return
            end
        else
            ids, name = nextBatch(key, count, data)
            if not ids then
                return
            end
        end
        if not arrived then
            Ui.status = "Going to the " .. def.label .. " machine"
            if not goTo(def) then
                lastNote = def.label .. " machine did not load; will try again next pass."
                return
            end
            arrived = true
        end
        local result
        if craftAll then
            Ui.status = string.format("Crafting all at the %s machine (%d per craft)", def.label, count)
            result = request(key, { Action = "CraftAll", Machine = key, Names = allowedNames(key, data) })
        else
            Ui.status = string.format("Crafting %s x%d at %d%%", name, count, roll)
            result = request(key, { Action = "Craft", Machine = key, PetIds = ids })
        end
        if not result then
            lastNote = def.label .. ": the server did not answer."
            return
        end
        if result.Success then
            if craftAll then
                local made = tonumber(result.Crafted) or (result.Crafted and 1) or 0
                session[key] += made
                if made <= 0 then
                    return -- the plan said yes but nothing was made: do not spin on it
                end
            elseif result.Crafted then
                session[key] += 1
            else
                session.failed += 1
            end
        elseif tooFar(result) and not retried then
            retried, arrived = true, false
        elseif craftAll then
            lastNote = string.format("%s: %s Crafting single batches meanwhile.", def.label, tostring(result.Reason or "Craft All refused."))
            craftAllBlocked[key] = os.clock() + CRAFT_ALL_RETRY
            craftAll = false
        else
            lastNote = def.label .. ": " .. tostring(result.Reason or "refused")
            return
        end
        Life.wait(0.15)
    end
end

-- Claims finished Rainbows and keeps the queue full, staying for crafts that are nearly done.
local function runRainbow(manual)
    local def = MACHINES.Shiny
    local arrived = false
    local maxQueue = MachineConfig.Shiny.MaxQueue or 3
    while keepGoing(manual) do
        local data = Env.data()
        if not data then
            return
        end
        local entries, ready, soonest = rainbowQueue(data)
        local count = rainbowCount()
        local ids, name = nextBatch("Shiny", count, data)
        local canStart = ids ~= nil and entries < maxQueue
        if #ready == 0 and not canStart then
            -- Nothing to claim or start: wait here only if a craft is about to finish, and only when
            -- auto hatch is off -- otherwise hatching is worth more than the wait, and a later pass
            -- comes back for the claim.
            if not (arrived and soonest and soonest <= RAINBOW_WAIT and keepGoing(manual) and not Ui.on("AutoHatch")) then
                return
            end
            Ui.status = string.format("Waiting %ds for a Rainbow", math.ceil(soonest))
            Life.wait(math.min(soonest + 0.5, RAINBOW_WAIT))
            continue
        end
        if not arrived then
            Ui.status = "Going to the Rainbow machine"
            if not goTo(def) then
                lastNote = "Rainbow machine did not load; will try again next pass."
                return
            end
            arrived = true
        end
        if #ready > 0 then
            local result = request("Shiny", { Machine = "Shiny", Action = "Claim", CraftId = ready[1] })
            if result and result.Success then
                session.Shiny += 1
            elseif result then
                lastNote = "Rainbow claim: " .. tostring(result.Reason or "refused")
                return
            else
                lastNote = "Rainbow: the server did not answer."
                return
            end
        elseif canStart then
            Ui.status = string.format("Starting Rainbow %s x%d", name, count)
            local result = request("Shiny", { Machine = "Shiny", Action = "Start", PetIds = ids })
            if not (result and result.Success) then
                lastNote = "Rainbow start: " .. tostring(result and result.Reason or "no answer")
                return
            end
        end
        Life.wait(0.2)
    end
end

local function runPass(manual)
    -- Auto hatch walking to its egg, or an enchant trip, owns the character until it is done.
    if busy or Ui.hatchMoving or Ui.travelling then
        return
    end
    local data = Env.data()
    if not data or type(data.Pets) ~= "table" then
        return
    end
    local work = {}
    if manual or Ui.on("AutoCraft") then
        for _, key in ipairs(ORDER) do
            if machineOn(key) and hasWork(key, data) then
                work[#work + 1] = key
            end
        end
    end
    if #work == 0 then
        return
    end
    busy = true
    Ui.travelling = true -- auto hatch sends nothing new from here on
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        -- The whole order, not just `work`: Golden crafted this pass can give Diamond its batch.
        for _, key in ipairs(ORDER) do
            if machineOn(key) and keepGoing(manual) then
                if key == "Shiny" then
                    runRainbow(manual)
                else
                    runTier(key, manual)
                end
            end
        end
    end)
    Env.elevate()
    if not ok then
        Life.errors["craft:pass"] = tostring(err)
    end
    if home and Ui.on("CraftReturn") then
        teleport(home)
    end
    Ui.travelling = false
    busy = false
    if Ui.status and (Ui.status:find("Crafting") or Ui.status:find("machine") or Ui.status:find("Rainbow")) then
        Ui.status = "Idle"
    end
end

box:AddButton({
    Text = "Craft everything now",
    Func = function()
        Life.spawn("craft:manual", runPass, true)
    end,
})

Life.spawn("craft:auto", function()
    local last = -math.huge
    while Life.alive do
        local every = math.clamp(tonumber(Options.CraftEvery.Value) or 10, 3, 120)
        if Ui.on("AutoCraft") and os.clock() - last >= every then
            last = os.clock()
            runPass(false)
        end
        Life.wait(0.5)
    end
end)

-- What each machine would do with the pets you have right now.
Life.loop("craft:panel", 1, function()
    local data = Env.data()
    if not data or type(data.Pets) ~= "table" then
        panel.set({ "Waiting for your data..." })
        return
    end
    local lines = {}
    for _, key in ipairs({ "Golden", "Diamond" }) do
        local count, roll = batchSize(key, data)
        local batches = 0
        for _, group in ipairs(groups(MachineConfig[key].SourceTier, data)) do
            batches += math.floor(#group.entries / count)
        end
        lines[#lines + 1] = string.format("%s: %d pets per craft at %d%%, %d crafts available", key, count, roll, batches)
    end
    local entries, ready, soonest = rainbowQueue(data)
    local count = rainbowCount()
    local batches = 0
    for _, group in ipairs(groups(MachineConfig.Shiny.SourceTier, data)) do
        batches += math.floor(#group.entries / count)
    end
    lines[#lines + 1] = string.format("Rainbow: queue %d/%d, %d ready%s, %d crafts available", entries,
        MachineConfig.Shiny.MaxQueue or 3, #ready, soonest and string.format(", next in %ds", math.ceil(soonest)) or "", batches)
    lines[#lines + 1] = string.format("Session: %d Golden, %d Diamond, %d Rainbow, %d failed rolls",
        session.Golden, session.Diamond, session.Shiny, session.failed)
    lines[#lines + 1] = lastNote
    panel.set(lines, busy and "Crafting now..." or "")
end)

Life.onCleanup(function()
    Ui.travelling = false
end)

return {}
end
__modules["features/defense"] = function(use)
-- Rewards tab: Pet Defense, the wave defense on Mushroom island (ColosseumService in the game's
-- code). Pets walk three tracks toward your bone pit; a tap hits the one closest to it, and every
-- few seconds a critical does 10x damage and pushes it back. Three escapes end the run. Every
-- cleared wave raises the relic you win (a ring with click multiplier and other boosts) and adds
-- treats, dials and, from wave 11, totems. One run every 30 minutes (Data.Colosseum.Cooldown).
--
-- A run is played through the game's own Pet Defense screen so you can watch it:
--   start     the controller's WaveDefenseForceStart handler (its attemptStartGame: the arena door,
--             StartWaveDefense, the board, the critical buttons). It needs you at the arena
--             entrance, so the hub stands you there first; the server then puts you in the arena.
--   taps      ColosseumClientAdapter.Signals "PlayerTapped", the game's own tap button: it picks
--             the pet closest to the pit, keeps the game's 0.14s tap cooldown and shows the hit.
--   critical  the critical button the game spawns every 5-10 seconds, pressed through its own
--             handler.
-- Without getconnections the same run is played on the remotes directly (StartWaveDefense,
-- AttackOpponent, CriticalAttackOpponent), and the fight is not drawn.
--
-- When the run ends the pending reward is claimed: ClaimMinigameReward "replace" takes the new
-- relic, "keep" keeps yours, and the treats and items come either way.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local tab = Ui.Tabs.Rewards

local COOLDOWN = 1800
local TAP_GAP = 0.15 -- the game's own cooldown is ClickCooldown - grace + 0.02 = 0.14s
local RUN_LIMIT = 20 * 60
local ENTRANCE_FALLBACK = Vector3.new(-170, 2020, -1795)
local RING_ORDER = { BronzeRing = 1, SilverRing = 2, GoldRing = 3, PlatinumRing = 4, DiamondRing = 5 }

local function load(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = RS
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and type(module) == "table" and module or nil
end

local World = load("Shared", "Minigames", "ColosseumWorld")
local Adapter = load("Controllers", "Minigames", "ColosseumClientAdapter")

local KEEP_BETTER, LET_ME = "Keep the better ring", "Let me choose"
local box = tab:AddGroupbox({ Side = "Left", Name = "Pet Defense", IconName = "shield" })
box:AddToggle("AutoDefense", {
    Text = "Auto Pet Defense",
    Default = false,
    Tooltip = "Plays Pet Defense on Mushroom island every 30 minutes, to the last heart, and comes back. Auto hatch pauses while a run lasts (a few minutes).",
})
Ui.automation("AutoDefense", false)
box:AddSlider("DefenseStopAt", {
    Text = "Stop at wave",
    Default = 0,
    Min = 0,
    Max = 60,
    Rounding = 0,
    Tooltip = "0 plays until the last heart. A lower stop banks the run sooner (the relic is rolled from the wave you reach).",
})
box:AddDropdown("DefenseRelic", {
    Text = "New relic",
    Values = { KEEP_BETTER, LET_ME },
    Default = KEEP_BETTER,
    Tooltip = "Keep the better ring: a higher ring wins (Bronze, Silver, Gold, Platinum, Diamond), then the bigger click multiplier. Let me choose leaves the game's reward screen open.",
})
box:AddToggle("DefenseReturn", {
    Text = "Return to where I was",
    Default = true,
})
local label = box:AddLabel("Auto Pet Defense is off.", true)

local session = { runs = 0, best = 0, last = nil, note = "" }

local function colosseum(data)
    return data and type(data.Colosseum) == "table" and data.Colosseum or {}
end

local function readyIn(data)
    local cooldown = tonumber(colosseum(data).Cooldown) or 0
    return math.max(0, cooldown + COOLDOWN - os.time())
end

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

-- The game's own handler on one of its remotes (ReplicatedStorage code, not the hub's).
local function gameHandler(signal)
    if type(getconnections) ~= "function" then
        return nil
    end
    local ok, connections = pcall(getconnections, signal)
    for _, connection in ipairs(ok and type(connections) == "table" and connections or {}) do
        local fine, source = pcall(function()
            return connection.Function and debug.info(connection.Function, "s")
        end)
        if fine and type(source) == "string" and source:find("^ReplicatedStorage%.") then
            return connection.Function
        end
    end
    return nil
end

local function standAtEntrance()
    local hrp = root()
    if not hrp then
        return false
    end
    local entrance = World and World.GetEntrance()
    if not entrance then
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(ENTRANCE_FALLBACK, 10)
        end)
        Env.elevate()
        hrp.CFrame = CFrame.new(ENTRANCE_FALLBACK + Vector3.new(0, 4, 0))
        local deadline = os.clock() + 8
        while Life.alive and not entrance and os.clock() < deadline do
            Life.wait(0.2)
            entrance = World and World.GetEntrance()
        end
    end
    if not entrance then
        return false
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = entrance.CFrame + Vector3.new(0, 3, 0)
    Life.wait(0.8)
    return true
end

-- The game's Pet Defense screens. Its wave events show the wave board whether or not its own
-- controller started the run, and only that controller hides it again, so a run it did not draw
-- (the direct mode, a run cut short) would leave the board over the screen. Outside a run the
-- game has these off.
local SCREENS = { "WaveDefense", "WaveStartMessage" }
local function clearScreens()
    if Env.LocalPlayer:GetAttribute("ColosseumActive") == true then
        return
    end
    local gui = Env.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, name in ipairs(SCREENS) do
        local screen = gui and gui:FindFirstChild(name)
        if screen and screen:IsA("ScreenGui") and screen.Enabled then
            screen.Enabled = false
        end
    end
end

-- The run, as the server tells it.
local run
local function newRun()
    return { active = true, over = false, wave = 0, hearts = 3, opponents = {}, result = nil }
end

Life.spawn("defense:events", function()
    local function on(name, handler)
        Life.connect(Env.remote("ColosseumService", name).OnClientEvent, function(payload)
            if run and type(payload) == "table" then
                handler(payload)
            end
        end)
    end
    on("WaveDefenseOpponentSpawned", function(opponent)
        if opponent.Id ~= nil then
            run.opponents[opponent.Id] = opponent
        end
    end)
    on("WaveDefenseOpponentDefeated", function(event)
        run.opponents[event.OpponentId] = nil
    end)
    on("WaveDefenseHeartLost", function(event)
        run.opponents[event.OpponentId] = nil
        run.hearts = tonumber(event.Hearts) or run.hearts
    end)
    on("WaveDefenseWaveComplete", function(event)
        run.wave = tonumber(event.WaveCompleted) or run.wave
        run.hearts = tonumber(event.Hearts) or run.hearts
    end)
    on("WaveDefenseGameOver", function(event)
        run.over = true
        run.result = event
    end)
end)

-- The pet nearest the pit, for the direct mode.
local function urgent()
    local now = workspace:GetServerTimeNow()
    local best
    for _, opponent in pairs(run.opponents) do
        if (tonumber(opponent.SpawnTime) or 0) <= now
            and (not best or (tonumber(opponent.ArrivalTime) or math.huge) < (tonumber(best.ArrivalTime) or math.huge)) then
            best = opponent
        end
    end
    return best
end

-- Presses the game's critical button if one is up: "pressed", "none", or "unreachable" when its
-- handler cannot be read (the run then sends criticals itself).
local function pressCritical()
    local gui = Env.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local hud = gui and gui:FindFirstChild("WaveDefense")
    local criticals = hud and hud:FindFirstChild("WaveHUD") and hud.WaveHUD:FindFirstChild("Criticals")
    local active = criticals and criticals:FindFirstChild("CriticalActive")
    local button = active and active:FindFirstChild("Button")
    if not button then
        return "none"
    end
    local handler = gameHandler(button.Activated)
    if handler then
        Life.spawn("defense:critical", handler)
        return "pressed"
    end
    return "unreachable"
end

local function attackDirect(critical)
    local target = urgent()
    if not target then
        return
    end
    local ok, result = Env.invoke("ColosseumService", critical and "CriticalAttackOpponent" or "AttackOpponent", target.Id)
    if ok and type(result) == "table" then
        if result.Defeated then
            run.opponents[target.Id] = nil
        elseif result.NewArrivalTime then
            target.ArrivalTime = result.NewArrivalTime
        end
    end
end

-- Plays one run to its end. Returns true when it was played.
local function playRun()
    local forceStart = gameHandler(Env.remote("ColosseumService", "WaveDefenseForceStart").OnClientEvent)
    local visual = forceStart ~= nil and Adapter ~= nil and type(Adapter.Signals) == "table"
    run = newRun()
    if visual then
        Life.spawn("defense:start", forceStart)
        local deadline = os.clock() + 15
        while Life.alive and os.clock() < deadline and Env.LocalPlayer:GetAttribute("ColosseumActive") ~= true do
            Life.wait(0.2)
        end
        if Env.LocalPlayer:GetAttribute("ColosseumActive") ~= true then
            session.note = "The game did not start the run."
            run = nil
            return false
        end
    else
        local ok, start = Env.invoke("ColosseumService", "StartWaveDefense")
        if not ok or type(start) ~= "table" or start.Error or start.OnCooldown then
            session.note = "Start refused: " .. tostring(type(start) == "table" and (start.Error or "on cooldown") or start)
            run = nil
            return false
        end
        run.hearts = tonumber(start.Hearts) or 3
        for _, opponent in ipairs(type(start.PendingSpawns) == "table" and start.PendingSpawns or {}) do
            if opponent.Id ~= nil then
                run.opponents[opponent.Id] = opponent
            end
        end
    end
    Ui.status = "Playing Pet Defense"
    local started = os.clock()
    local nextCritical = os.clock() + 5 + math.random() * 3
    local ownCriticals = not visual
    while Life.alive and not run.over and os.clock() - started < RUN_LIMIT do
        local stopAt = tonumber(Options.DefenseStopAt.Value) or 0
        if not Ui.on("AutoDefense") or (stopAt > 0 and run.wave >= stopAt) then
            Env.invoke("ColosseumService", "EndWaveDefense")
            break
        end
        if visual then
            Env.call(Adapter.Signals.Fire, "PlayerTapped")
            if pressCritical() == "unreachable" then
                ownCriticals = true
            end
        end
        if ownCriticals and os.clock() >= nextCritical then
            nextCritical = os.clock() + 5 + math.random() * 3
            attackDirect(true)
        elseif not visual then
            attackDirect(false)
        end
        if not visual then
            clearScreens() -- a board with no pets on it is only in the way
        end
        Life.wait(TAP_GAP)
    end
    if not run.over and os.clock() - started >= RUN_LIMIT then
        Env.invoke("ColosseumService", "EndWaveDefense")
    end
    local deadline = os.clock() + 8
    while Life.alive and not run.over and os.clock() < deadline do
        Life.wait(0.2)
    end
    local reached = tonumber(type(run.result) == "table" and run.result.WavesCompleted) or run.wave
    session.runs += 1
    session.best = math.max(session.best, reached)
    session.last = reached
    if not visual then
        Env.invoke("ColosseumService", "ReturnFromArena")
    end
    run = nil
    return true
end

-- A ring's worth: its tier first, then its click multiplier, then everything else it gives.
local function ringScore(relic)
    if type(relic) ~= "table" then
        return -1
    end
    local click, rest = 0, 0
    for _, boost in ipairs(type(relic.Boosts) == "table" and relic.Boosts or {}) do
        local value = tonumber(boost.Value) or 0
        if boost.Type == "ClickMultiplier" then
            click += value
        else
            rest += value
        end
    end
    return (RING_ORDER[relic.Name] or 0) * 1000 + click * 100 + rest
end

local function claimReward()
    if Options.DefenseRelic.Value == LET_ME then
        return
    end
    local deadline = os.clock() + 10
    local pending
    repeat
        pending = colosseum(Env.data()).PendingReward
        if not pending then
            Life.wait(0.3)
        end
    until pending or not Life.alive or os.clock() > deadline
    if type(pending) ~= "table" then
        return
    end
    local current = colosseum(Env.data()).Relic
    local choice = ringScore(pending.NewRelic) > ringScore(current) and "replace" or "keep"
    local ok, result = Env.invoke("ColosseumService", "ClaimMinigameReward", choice)
    if ok and result then
        local relic = type(pending.NewRelic) == "table" and pending.NewRelic.Name or "relic"
        session.note = choice == "replace" and ("Took the new " .. tostring(relic) .. ".")
            or ("Kept your ring over the new " .. tostring(relic) .. ".")
    else
        session.note = "Reward claim refused; it is waiting in the game's reward screen."
    end
end

local busy = false
local function trip()
    if busy or Ui.hatchMoving or Ui.travelling then
        return
    end
    busy = true
    Ui.travelling = "defense"
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        Ui.status = "Going to Pet Defense"
        if not standAtEntrance() then
            session.note = "Could not reach the Pet Defense arena."
            return
        end
        if playRun() then
            Life.wait(3) -- the game's own end screen and its trip out of the arena
            claimReward()
        end
    end)
    Env.elevate()
    if not ok then
        Life.errors["defense:trip"] = tostring(err)
        session.note = "Pet Defense error: " .. tostring(err)
    end
    run = nil
    -- The game's end screen runs ~4s (banner, fade, its trip out of the arena); then nothing of the
    -- run may stay on screen.
    local settled = os.clock() + 6
    while Life.alive and Env.LocalPlayer:GetAttribute("ColosseumActive") == true and os.clock() < settled do
        Life.wait(0.2)
    end
    clearScreens()
    if home and Ui.on("DefenseReturn") then
        local back = root()
        if back then
            back.AssemblyLinearVelocity = Vector3.zero
            back.CFrame = home
        end
    end
    if Ui.status == "Playing Pet Defense" or Ui.status == "Going to Pet Defense" then
        Ui.status = "Idle"
    end
    Ui.travelling = false
    busy = false
end

local nextTry = 0
Life.loop("defense:auto", 1, function()
    local data = Env.data()
    if not data then
        return
    end
    -- Leftovers from a run that was not drawn (an older hub, a cut-short run) are cleared outside
    -- a run, whether or not auto Pet Defense is on.
    if not busy then
        clearScreens()
    end
    local wait = readyIn(data)
    local best = tonumber(colosseum(data).BestWave) or 0
    local lines = {}
    if run then
        lines[1] = string.format("Wave %d, %d hearts left.", run.wave + 1, run.hearts)
    elseif wait > 0 then
        lines[1] = string.format("Next run in %d:%02d. Best wave %d.", wait // 60, wait % 60, best)
    else
        lines[1] = string.format("A run is ready. Best wave %d.", best)
    end
    if session.runs > 0 then
        lines[#lines + 1] = string.format("%d runs this session, last reached wave %d.", session.runs, session.last or 0)
    end
    if session.note ~= "" then
        lines[#lines + 1] = session.note
    end
    if not Ui.on("AutoDefense") then
        label:SetText("Off. " .. table.concat(lines, "\n"))
        return
    end
    label:SetText(table.concat(lines, "\n"))
    -- A reward left from an earlier run (or one played by hand) is claimed where you stand.
    if colosseum(data).PendingReward and not busy and not run and Options.DefenseRelic.Value ~= LET_ME
        and os.clock() >= nextTry then
        nextTry = os.clock() + 30
        Life.spawn("defense:claim", claimReward)
        return
    end
    if wait == 0 and not busy and os.clock() >= nextTry and not colosseum(data).PendingReward then
        nextTry = os.clock() + 60 -- a refused start is not retried at once
        Life.spawn("defense:trip", trip)
    end
end)

Life.onCleanup(function()
    if busy then
        Ui.travelling = false
    end
end)

return {}
end
__modules["features/dig"] = function(use)
-- Rewards tab: the Autumn island dig site. Ten digs an hour, each a timing game: a cursor sweeps a
-- bar and a hit inside the highlighted zone takes one layer off the buried treat (RegularTreat or
-- BagOfTreats); a miss puts two back.
--
-- DigService.Begin() starts a dig (or resumes the treat already buried for you) and answers with
-- the round: Epoch, Phase, Speed, Center, Width and a Sequence. Hit(Id, Sequence, time) is judged
-- at that server time with the game's own DigConfig.Cursor, so the hit is timed for the moment the
-- cursor crosses the middle of the zone, never sooner than MinHitInterval after the last one. The
-- server only accepts hits from someone standing on the dig site (DigWorld.Contains), so a dig is
-- a trip like a craft: auto hatch pauses, the dig runs, and you go back where you were.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local RunService = game:GetService("RunService")
local tab = Ui.Tabs.Rewards

local DigConfig, DigWorld
do
    local ok, config = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Minigames.DigConfig)
    end)
    DigConfig = ok and type(config) == "table" and config or nil
    local ok2, world = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Minigames.DigWorld)
    end)
    DigWorld = ok2 and type(world) == "table" and world or nil
end

-- The dig site is Persistent for streaming once loaded, but a fresh server may not have sent it.
local SITE_FALLBACK = Vector3.new(-82, 873, -1623)
-- How close to the zone's middle a hit aims, as a share of its width; the zone shrinks as the
-- cursor speeds up, so the middle leaves room for the request's travel time.
local AIM = { 0.25, 0.6, 1 }

local box = tab:AddGroupbox({ Side = "Right", Name = "Dig site", IconName = "shovel" })
box:AddToggle("AutoDig", {
    Text = "Auto dig",
    Default = false,
    Tooltip = "Goes to the Autumn dig site whenever a dig is free (10 an hour), plays it without missing, and comes back. Each dig gives a Treat or a Bag of Treats.",
})
Ui.automation("AutoDig", false)
box:AddToggle("DigReturn", {
    Text = "Return to where I was",
    Default = true,
})
local label = box:AddLabel("Auto dig is off.", true)

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function digging(data)
    return data and type(data.Digging) == "table" and data.Digging or nil
end

-- Digs left this hour and seconds until the hour resets.
local function allowance(data)
    local state = digging(data)
    if not (state and DigConfig) then
        return 0, 0
    end
    local ok, left, wait = Env.call(DigConfig.Allowance, state, os.time())
    if ok and type(left) == "number" then
        return left, tonumber(wait) or 0
    end
    return 0, 0
end

local function digZone()
    local site = DigWorld and DigWorld.GetSite()
    return site and site:FindFirstChild("DigZone")
end

local function standOnSite()
    local hrp = root()
    if not hrp then
        return false
    end
    local zone = digZone()
    if not zone then
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(SITE_FALLBACK, 10)
        end)
        Env.elevate()
        hrp.CFrame = CFrame.new(SITE_FALLBACK + Vector3.new(0, 4, 0))
        local deadline = os.clock() + 8
        while Life.alive and not zone and os.clock() < deadline do
            Life.wait(0.2)
            zone = digZone()
        end
    end
    if not zone then
        return false
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = zone.CFrame * CFrame.new(0, 3, 0)
    local deadline = os.clock() + 3
    while Life.alive and os.clock() < deadline do
        Life.wait(0.15)
        local character = Env.LocalPlayer.Character
        if character and DigWorld.Contains(zone, character) then
            Life.wait(0.3) -- let the server see us there too
            return true
        end
    end
    return false
end

-- The first server time after `from` at which the cursor is within `share` of the zone's middle.
local function aimAt(round, from)
    for _, share in ipairs(AIM) do
        local half = round.Width * share / 2
        for t = from, from + 8, 0.004 do
            if math.abs(DigConfig.Cursor(round, t) - round.Center) <= half then
                return t
            end
        end
    end
    return nil
end

local session = { digs = 0, hits = 0, misses = 0, treats = {} }
local note = ""

-- Plays one dig to the end. Returns the reward name, or nil and why not. A dig that stops early is
-- cancelled, as the game's Stop button does; the treat stays buried for the next one.
local function playDig()
    local ok, state = Env.invoke("DigService", "Begin")
    if not ok or type(state) ~= "table" then
        return nil, "the dig did not start"
    end
    local id = state.Id
    local function stop(why)
        if id then
            Env.invoke("DigService", "Cancel", id)
        end
        return nil, why
    end
    local lastHit = workspace:GetServerTimeNow()
    for _ = 1, 60 do
        if not Life.alive then
            return stop("unloaded")
        end
        if state.Complete then
            return tostring(state.Reward or "a treat")
        end
        if state.Error then
            return stop(tostring(state.Error))
        end
        local round = state.Round
        if type(round) ~= "table" or not state.Id then
            return stop("unexpected answer from the dig site")
        end
        id = state.Id
        local from = math.max(workspace:GetServerTimeNow() + 0.06, round.Epoch + 0.02,
            lastHit + DigConfig.MinHitInterval + 0.02)
        local target = aimAt(round, from)
        if not target then
            return stop("no hit window found")
        end
        while workspace:GetServerTimeNow() < target do
            RunService.Heartbeat:Wait()
        end
        local at = workspace:GetServerTimeNow()
        if DigConfig.IsHit(round, at) then
            session.hits += 1
        else
            session.misses += 1
        end
        lastHit = at
        local ok2, answer = Env.invoke("DigService", "Hit", id, round.Sequence, at)
        if not ok2 or type(answer) ~= "table" then
            return stop("a hit got no answer")
        end
        if answer.Error == "TooSoon" or answer.Error == "Busy" then
            Life.wait(0.2) -- same round again
        else
            state = answer
        end
    end
    return stop("the dig never finished")
end

local busy = false
local function digTrip()
    if busy or Ui.hatchMoving or Ui.travelling then
        return
    end
    busy = true
    Ui.travelling = "dig"
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        Ui.status = "Digging"
        if not standOnSite() then
            note = "Could not reach the dig site."
            return
        end
        while Life.alive and Ui.on("AutoDig") and allowance(Env.data()) > 0 do
            local reward, why = playDig()
            if not reward then
                note = "Last dig stopped: " .. tostring(why) .. "."
                break
            end
            session.digs += 1
            session.treats[reward] = (session.treats[reward] or 0) + 1
            note = "Last dig: " .. reward .. "."
            Life.wait(0.6)
        end
    end)
    Env.elevate()
    if not ok then
        Life.errors["dig:trip"] = tostring(err)
        note = "Dig error: " .. tostring(err)
    end
    if home and Ui.on("DigReturn") then
        local back = root()
        if back then
            back.AssemblyLinearVelocity = Vector3.zero
            back.CFrame = home
        end
    end
    if Ui.status == "Digging" then
        Ui.status = "Idle"
    end
    Ui.travelling = false
    busy = false
end

local nextTry = 0
Life.loop("dig:auto", 1, function()
    local data = Env.data()
    local left, wait = allowance(data)
    local pending = digging(data) and digging(data).PendingReward
    local parts = {}
    for name, count in pairs(session.treats) do
        parts[#parts + 1] = string.format("%d %s", count, name)
    end
    table.sort(parts)
    local status = left > 0 and string.format("%d digs free now", left)
        or string.format("next digs in %dm %02ds", math.floor(wait / 60), math.floor(wait % 60))
    local summary = string.format("%s. %d digs this session%s (%d hits, %d misses).%s%s", status, session.digs,
        #parts > 0 and (": " .. table.concat(parts, ", ")) or "", session.hits, session.misses,
        pending and ("\nBuried for you: " .. tostring(pending) .. ".") or "", note ~= "" and ("\n" .. note) or "")
    if not (DigConfig and DigWorld) then
        label:SetText("The game's dig config could not be read.")
        return
    end
    if not Ui.on("AutoDig") then
        label:SetText("Off. " .. summary)
        return
    end
    label:SetText(summary)
    if left > 0 and os.clock() >= nextTry and not busy then
        nextTry = os.clock() + 20 -- a failed trip is not retried at once
        Life.spawn("dig:trip", digTrip)
    end
end)

Life.onCleanup(function()
    if busy then
        Ui.travelling = false
    end
end)

return {}
end
__modules["features/enchant"] = function(use)
-- Pets tab: auto enchant, run by the game's own server-side enchant loop.
--
-- EnchantService takes one table per call: AutoStart { PetId, Slot, Replace } rolls that pet's
-- slot over and over at your enchant speed until it lands a trait in your keep list (SetFilters,
-- a list of names), then stops with AutoEvent { Kind = "Stop", Reason }; Claim() hands the pet back.
-- Replace is not a flag: the game leaves it out, and only sends the current trait's name to confirm
-- rolling over a protected (rare) one -- anything else is refused as InvalidRequest. Each roll costs
-- gems (EnchantConfig.GetRollPrice), and the server only starts it while you stand in the Enchant
-- machine's interaction point ("VisitEnchantMachine"); once started it keeps rolling wherever you
-- go, so the hub walks you there, starts it, and goes straight back to what you were doing.
--
-- "Equipped team" works through your equipped pets strongest first, skipping any whose slot
-- already holds a kept enchant, so the whole team ends up with the traits you chose.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local tab = Ui.Tabs.Pets

local EnchantConfig
do
    local ok, module = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Pets.EnchantConfig)
    end)
    EnchantConfig = ok and type(module) == "table" and module or nil
end

local POINT, POINT_FALLBACK = "Enchant", Vector3.new(127, 7687, -1803) -- Shadow Realm

-- Data -----------------------------------------------------------------------------------------

local function enchanting(data)
    return type(data.Enchanting) == "table" and data.Enchanting or {}
end

local function keptSet(data)
    local set = {}
    local filters = enchanting(data).Filters
    if type(filters) == "table" then
        for key, value in pairs(filters) do
            if type(key) == "string" and value == true then
                set[key] = true
            elseif type(value) == "string" then
                set[value] = true
            end
        end
    end
    return set
end

local function slotCount(pet)
    if EnchantConfig then
        local ok, count = Env.call(EnchantConfig.GetSlotCount, pet)
        if ok and type(count) == "number" then
            return count
        end
    end
    return 1
end

local function rollPrice(pet)
    if EnchantConfig then
        local ok, price = Env.call(EnchantConfig.GetRollPrice, pet)
        if ok and type(price) == "number" then
            return price
        end
    end
    return 25000
end

-- Every trait the keep list can hold, rarest first.
local function enchantNames()
    local names = {}
    if EnchantConfig and type(EnchantConfig.Enchants) == "table" then
        for name in pairs(EnchantConfig.Enchants) do
            local ok, filterable = Env.call(EnchantConfig.IsFilterable, name)
            if type(name) == "string" and (not ok or filterable ~= false) then
                names[#names + 1] = name
            end
        end
    end
    local function rank(name)
        local ok, value = Env.call(EnchantConfig.RankOf, name)
        return ok and tonumber(value) or 0
    end
    table.sort(names, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then
            return ra > rb
        end
        return a < b
    end)
    return names
end

-- UI -------------------------------------------------------------------------------------------

local TEAM, CHOSEN = "Equipped team, one by one", "Chosen pet"

local box = tab:AddGroupbox({ Side = "Right", Name = "Auto enchant", IconName = "wand-sparkles" })
box:AddToggle("AutoEnchant", {
    Text = "Auto enchant",
    Default = false,
    Tooltip = "Walks to the Enchant machine, starts the game's own enchant loop on a pet and claims it once it lands a trait you keep. Rolls cost gems.",
})
Ui.automation("AutoEnchant")
box:AddDropdown("EnchantMode", {
    Text = "Pets",
    Values = { TEAM, CHOSEN },
    Default = TEAM,
})
local petIds = {}
box:AddDropdown("EnchantPet", {
    Text = "Chosen pet",
    Values = {},
    Searchable = true,
    Tooltip = "Used when Pets is set to Chosen pet. Strongest first.",
})
box:AddSlider("EnchantSlot", {
    Text = "Slot",
    Default = 1,
    Min = 1,
    Max = 2,
    Rounding = 0,
    Tooltip = "The second slot only exists on pets strong enough to have it.",
})
local initialKeep = {}
do
    local data = Env.data()
    for name in pairs(data and keptSet(data) or {}) do
        initialKeep[#initialKeep + 1] = name
    end
end
box:AddDropdown("EnchantKeep", {
    Text = "Keep these enchants",
    Values = enchantNames(),
    Multi = true,
    Searchable = true,
    Default = initialKeep,
    Tooltip = "The loop stops on the first of these it rolls. Saved to the game, the same list as the machine's Filters.",
})
box:AddToggle("EnchantReplace", {
    Text = "Reroll over a trait not on the list",
    Default = true,
    Tooltip = "A pet whose slot holds a trait you do not keep gets rolled again. Off skips those pets instead.",
})
local panel = Ui.panel(box, 4)

-- Pets for the dropdown, strongest first, refreshed as your inventory changes.
local petSignature
Life.loop("enchant:pets", 5, function()
    local data = Env.data()
    local owned = data and type(data.Pets) == "table" and data.Pets.Owned
    if type(owned) ~= "table" then
        return
    end
    local list = {}
    for id, pet in pairs(owned) do
        if type(pet) == "table" then
            list[#list + 1] = { id = id, pet = pet }
        end
    end
    table.sort(list, function(a, b)
        return (tonumber(a.pet.Power) or 0) > (tonumber(b.pet.Power) or 0)
    end)
    local labels = {}
    table.clear(petIds)
    for index = 1, math.min(#list, 60) do
        local entry = list[index]
        local label = string.format("%s [%s] %s", tostring(entry.pet.Name), tostring(entry.pet.Tier or "Normal"), tostring(entry.pet.Power or "?"))
        while petIds[label] do
            label ..= " "
        end
        petIds[label] = entry.id
        labels[#labels + 1] = label
    end
    local joined = table.concat(labels, "\0")
    if joined ~= petSignature then
        petSignature = joined
        Env.elevate()
        Options.EnchantPet:SetValues(labels)
    end
end)

-- The keep list goes to the server a moment after you stop clicking.
local filtersDirty, filtersChangedAt = false, 0
Options.EnchantKeep:OnChanged(function()
    filtersDirty, filtersChangedAt = true, os.clock()
end)
local function keepList()
    local list = {}
    for name, on in pairs(Options.EnchantKeep.Value or {}) do
        if on then
            list[#list + 1] = name
        end
    end
    table.sort(list)
    return list
end
local function pushFilters()
    filtersDirty = false
    return Env.invoke("EnchantService", "SetFilters", keepList())
end
Life.loop("enchant:filters", 0.5, function()
    if filtersDirty and os.clock() - filtersChangedAt >= 1 then
        pushFilters()
    end
end)

-- Choosing the pet -----------------------------------------------------------------------------

local skipped = {} -- petId -> true when the server will not take it this session

local function slotKey(slot)
    return slot == 2 and "Enchant2" or "Enchant"
end

local function needsWork(pet, slot, kept)
    if type(pet) ~= "table" or slotCount(pet) < slot then
        return false
    end
    local current = pet[slotKey(slot)]
    if current == nil then
        return true
    end
    return not kept[current] and Ui.on("EnchantReplace")
end

-- The next pet to enchant and the slot, or nil plus a reason.
local function target(data)
    local slot = math.clamp(math.floor(tonumber(Options.EnchantSlot.Value) or 1), 1, 2)
    local kept = keptSet(data)
    local owned = type(data.Pets) == "table" and data.Pets.Owned or {}
    if Options.EnchantMode.Value == CHOSEN then
        local id = petIds[Options.EnchantPet.Value or ""]
        local pet = id and owned[id]
        if not pet then
            return nil, "Pick a pet."
        end
        if not needsWork(pet, slot, kept) then
            return nil, string.format("%s already has a kept enchant in slot %d (or no slot %d).", tostring(pet.Name), slot, slot)
        end
        return id, slot
    end
    local team = {}
    for _, id in pairs(type(data.Pets.Equipped) == "table" and data.Pets.Equipped or {}) do
        if owned[id] and not skipped[id] then
            team[#team + 1] = id
        end
    end
    table.sort(team, function(a, b)
        return (tonumber(owned[a].Power) or 0) > (tonumber(owned[b].Power) or 0)
    end)
    for _, id in ipairs(team) do
        if needsWork(owned[id], slot, kept) then
            return id, slot
        end
    end
    return nil, string.format("Every team pet has a kept enchant in slot %d.", slot)
end

-- Moving ---------------------------------------------------------------------------------------

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function findPoint()
    local best, bestDistance
    for _, part in ipairs(Env.CollectionService:GetTagged("InteractionPoint")) do
        if part:IsA("BasePart") and part.Name == POINT and part:IsDescendantOf(workspace) then
            local distance = (part.Position - POINT_FALLBACK).Magnitude
            if not best or distance < bestDistance then
                best, bestDistance = part, distance
            end
        end
    end
    return best
end

local function standAtMachine()
    local hrp = root()
    if not hrp then
        return false
    end
    local point = findPoint()
    if not point then
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(POINT_FALLBACK, 10)
        end)
        Env.elevate()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.CFrame = CFrame.new(POINT_FALLBACK + Vector3.new(0, 6, 0))
        local deadline = os.clock() + 8
        while Life.alive and os.clock() < deadline and not point do
            Life.wait(0.2)
            point = findPoint()
        end
    end
    hrp = root()
    if not point or not hrp then
        return false
    end
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = point.CFrame
    Life.wait(0.35)
    return true
end

-- The loop -------------------------------------------------------------------------------------

local state = { running = nil, rolls = 0, landed = 0, stop = nil, note = "Auto enchant is off." }

Life.spawn("enchant:events", function()
    local remote = Env.remote("EnchantService", "AutoEvent")
    Life.connect(remote.OnClientEvent, function(event)
        if type(event) ~= "table" then
            return
        end
        if event.Kind == "Roll" then
            state.rolls += 1
        elseif event.Kind == "Stop" then
            state.stop = event
        end
    end, "enchant:event")
end)

local function invoke(name, payload)
    local ok, result = Env.invoke("EnchantService", name, payload)
    if not ok then
        return false, "Connection"
    end
    if type(result) == "table" and result.Success then
        return true, result
    end
    return false, type(result) == "table" and result.Reason or "Unknown"
end

-- The confirmation the game sends with AutoStart: the current trait's name when it is a protected
-- (rare) one being rolled over, otherwise nothing.
local function replaceToken(petId, slot)
    local data = Env.data()
    local pet = data and type(data.Pets) == "table" and data.Pets.Owned[petId]
    local current = type(pet) == "table" and pet[slotKey(slot)] or nil
    if current == nil or not EnchantConfig then
        return nil
    end
    local ok, protected = Env.call(EnchantConfig.IsProtected, current)
    return ok and protected == true and current or nil
end

-- One trip: walk to the machine, start the loop on `petId`, walk back. Returns ok, reason.
local function start(petId, slot)
    local settle = os.clock() + 6
    Ui.travelling = "enchant"
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, reason = false, "VisitEnchantMachine"
    local pcallOk, err = pcall(function()
        if not standAtMachine() then
            reason = "VisitEnchantMachine"
            return
        end
        for _ = 1, 3 do
            ok, reason = invoke("AutoStart", { PetId = petId, Slot = slot, Replace = replaceToken(petId, slot) })
            if ok then
                return
            end
            if reason == "ClaimFirst" or reason == "Pending" or reason == "EnchantPending" then
                invoke("Claim")
            elseif reason == "AutoRunning" then
                invoke("AutoStop")
                Life.wait(0.3)
                invoke("Claim")
            elseif reason == "NoFilters" then
                pushFilters()
            elseif reason == "VisitEnchantMachine" then
                standAtMachine()
            else
                return
            end
            Life.wait(0.3)
        end
    end)
    Env.elevate()
    if not pcallOk then
        reason = tostring(err)
    end
    if home and root() then
        root().AssemblyLinearVelocity = Vector3.zero
        root().CFrame = home
    end
    Ui.travelling = false
    return ok, reason
end

local REASONS = {
    InsufficientGems = "Not enough gems for a roll.",
    VisitEnchantMachine = "Could not reach the Enchant machine.",
    ConfirmReplace = "That slot already has a trait (turn on reroll to replace it).",
    InvalidSlot = "That pet does not have this slot.",
    Reserved = "That pet is in a trade.",
    Frozen = "That pet is unavailable.",
    UnknownPet = "That pet is gone.",
    NoFilters = "Pick the enchants to keep first.",
}

Life.spawn("enchant:auto", function()
    while Life.alive do
        if not Ui.on("AutoEnchant") then
            if state.running then
                invoke("AutoStop")
                invoke("Claim")
                state.running = nil
            end
            state.note = "Auto enchant is off."
            Life.wait(0.3)
            continue
        end
        local data = Env.data()
        if not data then
            Life.wait(0.5)
            continue
        end
        -- A loop that has stopped: take the pet back and move on.
        if state.running and state.stop then
            local event = state.stop
            state.stop = nil
            invoke("Claim")
            if event.Reason == "Matched" then
                state.landed += 1
                state.note = string.format("%s got %s.", tostring(event.Pet or "Pet"), tostring(event.Enchant or "a kept enchant"))
            elseif event.Reason == "Gems" then
                state.note = "Out of gems; waiting for more."
            else
                state.note = "Stopped: " .. tostring(event.Reason)
            end
            state.running = nil
        end
        if state.running then
            Life.wait(0.3)
            continue
        end
        if #keepList() == 0 then
            state.note = "Pick the enchants to keep first."
            Life.wait(1)
            continue
        end
        local petId, slot = target(data)
        if not petId then
            state.note = slot
            Life.wait(2)
            continue
        end
        local pet = data.Pets.Owned[petId]
        local gems = tonumber(type(data.Currencies) == "table" and data.Currencies.Gems) or 0
        if gems < rollPrice(pet) then
            state.note = "Not enough gems for a roll."
            Life.wait(3)
            continue
        end
        -- Another trip (craft) or hatch walking owns the character: wait for it.
        if Ui.travelling or Ui.hatchMoving then
            Life.wait(0.3)
            continue
        end
        if filtersDirty then
            pushFilters()
        end
        Ui.status = "Starting auto enchant on " .. tostring(pet.Name)
        local ok, reason = start(petId, slot)
        if ok then
            state.running = petId
            state.stop = nil
            state.failures = 0
            state.note = string.format("Enchanting %s, slot %d.", tostring(pet.Name), slot)
        else
            state.note = REASONS[reason] or ("Could not start: " .. tostring(reason))
            if reason == "ConfirmReplace" or reason == "InvalidSlot" or reason == "Reserved" or reason == "Frozen" or reason == "UnknownPet" then
                skipped[petId] = true
            end
            -- Every attempt is a round trip to the machine: back off instead of bouncing there.
            state.failures = (state.failures or 0) + 1
            Life.wait(math.min(30, 2 ^ state.failures))
        end
        if Ui.status and Ui.status:find("^Starting auto enchant") then
            Ui.status = "Idle"
        end
    end
end)

Life.loop("enchant:panel", 0.5, function()
    local data = Env.data()
    local gems = data and tonumber(type(data.Currencies) == "table" and data.Currencies.Gems) or 0
    local running = state.running and data and data.Pets.Owned[state.running]
    panel.set({
        running and string.format("Running on %s", tostring(running.Name)) or "Not running",
        string.format("Rolls seen: %d, kept enchants landed: %d", state.rolls, state.landed),
        string.format("Gems: %s", tostring(math.floor(gems))),
        state.note,
    })
end)

Life.onCleanup(function()
    if state.running then
        pcall(Env.invoke, "EnchantService", "AutoStop")
    end
end)

return {}
end
__modules["features/hatch"] = function(use)
-- Pets tab: auto hatch, done the way the game's own auto hatch does it, minus the waiting.
--
-- EggService.EggHatchRequested { Egg, Count, Auto, Seq } is answered on EggHatchResult with the
-- same Seq. The server paces hatching itself -- it holds the answer ("Held") until the egg may be
-- opened again -- so the fastest rate that never trips RateLimited is one request in flight and the
-- next sent the moment its answer lands. A timer either wastes time or gets refused.
--
-- The server only hatches an egg you stand next to (Error "TooFar"), so the hub walks you to it:
-- every egg is a model in workspace.Eggs whose pivot is readable even before it streams in.
-- Count follows the game's rule: 8 with the x8 pass or an OctoHatch boost, else 3, else 1, each
-- only if affordable. Auto = true is what the real auto hatch sends, so secret pity keeps building.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local tab = Ui.Tabs.Pets

-- Rules ----------------------------------------------------------------------------------------

-- Egg name -> { price, island, pets = { name = chance% } } from LaunchEggConfig.
local EGGS = {}
local EggPricing, GamepassPerks, BoostFormula
do
    local ok, cfg = Env.call(function()
        return require(RS.Shared.Pets.LaunchEggConfig)
    end)
    if ok and type(cfg) == "table" then
        for name, def in pairs(cfg) do
            -- Test has no stand anywhere in the world; it is what the first version kept picking.
            if type(def) == "table" and name ~= "Test" then
                EGGS[name] = {
                    price = tonumber(def.Price) or 0,
                    island = def.Island,
                    pets = type(def.Pets) == "table" and def.Pets or {},
                }
            end
        end
    end
    local function load(path)
        local found, module = Env.call(function()
            local node = RS
            for _, part in ipairs(path) do
                node = node:FindFirstChild(part)
            end
            return node and require(node)
        end)
        return found and module or nil
    end
    EggPricing = load({ "Shared", "Pets", "EggPricing" })
    GamepassPerks = load({ "Shared", "Monetization", "GamepassPerks" })
    BoostFormula = load({ "Shared", "Items", "BoostFormula" })
end

local SECRET_PITY_SECONDS, SECRET_PITY_MAX = 86400, 4 -- HatchRulesConfig
local STAND_RANGE = 9 -- the client counts you as at an egg within 10 studs

local function unitPrice(data, egg)
    local price = EGGS[egg].price
    if EggPricing then
        local ok, value = Env.call(EggPricing.GetUnitPrice, data, egg, price)
        if ok and type(value) == "number" then
            return value
        end
    end
    return price
end

local function totalPrice(data, egg, count)
    local price = EGGS[egg].price
    if EggPricing then
        local ok, value = Env.call(EggPricing.GetTotal, data, egg, price, count)
        if ok and type(value) == "number" then
            return value
        end
    end
    return price * count
end

local function canOcto(data)
    local function has(module, method, key)
        if not module then
            return false
        end
        local ok, value = Env.call(module[method], data, key)
        return ok and value == true
    end
    return has(GamepassPerks, "Has", "x8Egg") or has(BoostFormula, "HasType", "OctoHatch")
end

-- The game's own pickAutoHatchCount: the biggest batch you have the pass and the coins for.
local function hatchCount(data, egg)
    local coins = tonumber(type(data.Currencies) == "table" and data.Currencies.Coins) or 0
    if canOcto(data) and totalPrice(data, egg, 8) <= coins then
        return 8
    end
    if totalPrice(data, egg, 3) <= coins then
        return 3
    end
    if unitPrice(data, egg) <= coins then
        return 1
    end
    return nil
end

-- workspace.Eggs is streamed: in a fresh server it can be empty until you have been near each egg,
-- so where each one stands is also kept here (read from the map when the hub was written).
local EGG_POSITIONS = {
    Basic = Vector3.new(6, -511, -1833),
    Spotted = Vector3.new(-5, -511, -1822),
    Spiked = Vector3.new(-23, -513, -1707),
    Sky = Vector3.new(-88, -48, -1904),
    Nimbus = Vector3.new(-97, -48, -1891),
    Pumpkin = Vector3.new(-143, 881, -1833),
    Forest = Vector3.new(-297, 1228, 267),
    Mushroom = Vector3.new(-6, 2032, -1925),
    Mycelium = Vector3.new(-21, 2032, -1932),
    Snowman = Vector3.new(-258, 2547, 345),
    Cactus = Vector3.new(-203, 3632, -1863),
    Crystal = Vector3.new(-53, 5438, -1992),
    Geode = Vector3.new(-68, 5438, -1987),
    Void = Vector3.new(-204, 7676, -1885),
}

local function eggModel(egg)
    local folder = workspace:FindFirstChild("Eggs")
    return folder and folder:FindFirstChild(egg)
end

-- Where the egg is: the live model when it has streamed in, else the recorded spot.
local function eggPosition(egg)
    local model = eggModel(egg)
    if model then
        local ok, pivot = pcall(model.GetPivot, model)
        if ok then
            return pivot.Position
        end
    end
    return EGG_POSITIONS[egg]
end

-- Unlocked, on an unlocked island, and standing somewhere in the world.
local function hatchable(data, egg)
    local eggs = type(data.Eggs) == "table" and data.Eggs.Unlocked
    if type(eggs) ~= "table" or eggs[egg] ~= true or not eggPosition(egg) then
        return false
    end
    local island = EGGS[egg].island
    local islands = type(data.Progression) == "table" and data.Progression.UnlockedIslands
    return island == nil or island == "Spawn" or (type(islands) == "table" and islands[island] == true)
end

-- Choosing the egg -----------------------------------------------------------------------------

local BEST, CHOSEN, ISLAND = "Best egg I can afford", "Chosen egg", "Egg on my island"
local UPGRADE_BUFFER = 5 -- move up to a pricier egg only with this many full batches of it in the bank

local current -- the egg being hatched now
local refused = {} -- egg -> os.clock() until which it is skipped (NotEnoughCoins, IslandLocked)

local function eggsByPrice(data)
    local list = {}
    for egg in pairs(EGGS) do
        if hatchable(data, egg) and os.clock() >= (refused[egg] or 0) then
            list[#list + 1] = egg
        end
    end
    table.sort(list, function(a, b)
        return EGGS[a].price > EGGS[b].price
    end)
    return list
end

local function chooseEgg(data)
    local mode = Options.HatchMode.Value
    if mode == CHOSEN then
        local egg = Options.HatchEgg.Value
        return egg and EGGS[egg] and hatchable(data, egg) and egg or nil
    end
    local list = eggsByPrice(data)
    if mode == ISLAND then
        local island = Env.LocalPlayer:GetAttribute("CurrentIsland")
        for _, egg in ipairs(list) do
            if EGGS[egg].island == island and hatchCount(data, egg) then
                return egg
            end
        end
        return nil
    end
    -- Best affordable, with a buffer before moving up so a coin balance hovering at one egg's price
    -- does not fly you back and forth (and split secret pity) every few hatches.
    local coins = tonumber(type(data.Currencies) == "table" and data.Currencies.Coins) or 0
    local stay = current and EGGS[current] and hatchable(data, current) and hatchCount(data, current) ~= nil
    for _, egg in ipairs(list) do
        if stay and egg == current then
            return current
        end
        local count = hatchCount(data, egg)
        if count then
            local better = stay and EGGS[egg].price > EGGS[current].price
            if not better or coins >= totalPrice(data, egg, count) * UPGRADE_BUFFER then
                return egg
            end
        end
    end
    return stay and current or nil
end

-- Moving to the egg ----------------------------------------------------------------------------

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function eggCenter(model)
    local part = model:FindFirstChild("Egg")
    if part and part:IsA("BasePart") then
        return part.Position
    end
    local ok, pivot = pcall(model.GetPivot, model)
    return ok and pivot.Position or nil
end

local function nearEgg(egg)
    local model, hrp = eggModel(egg), root()
    local center = model and eggCenter(model)
    return hrp ~= nil and center ~= nil and (hrp.Position - center).Magnitude <= STAND_RANGE
end

-- Solid ground in a ring around the egg (its pedestal does not collide), facing the egg.
local function standSpot(model, center)
    local ignore = { model }
    for _, player in ipairs(Env.Players:GetPlayers()) do
        if player.Character then
            ignore[#ignore + 1] = player.Character
        end
    end
    for _, name in ipairs({ "GoldPets", "RainbowPets", "Pets", "PlayerPets" }) do
        local folder = workspace:FindFirstChild(name)
        if folder then
            ignore[#ignore + 1] = folder
        end
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignore
    for step = 0, 7 do
        local angle = step * math.pi / 4
        local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 5.5
        local hit = workspace:Raycast(center + offset + Vector3.new(0, 4, 0), Vector3.new(0, -20, 0), params)
        if hit and hit.Instance.CanCollide and hit.Normal.Y > 0.6 then
            local spot = hit.Position + Vector3.new(0, 3, 0)
            if (spot - center).Magnitude <= STAND_RANGE then
                return CFrame.lookAt(spot, Vector3.new(center.X, spot.Y, center.Z))
            end
        end
    end
    return CFrame.new(center + Vector3.new(0, -1, 5))
end

-- Ui.hatchMoving tells auto craft not to start a trip while this one is under way, and a craft trip
-- (Ui.travelling) cuts this one short: two features teleporting at once fight over the character.
local function goToEgg(egg)
    local target, hrp = eggPosition(egg), root()
    if not target or not hrp or Ui.travelling then
        return false
    end
    Ui.hatchMoving = true
    local arrived = false
    pcall(function()
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(target, 10)
        end)
        Env.elevate()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.CFrame = CFrame.new(target + Vector3.new(0, 6, 0))
        -- The model (and its Egg part) stream in once we are here.
        local model
        local deadline = os.clock() + 8
        while Life.alive and not Ui.travelling and os.clock() < deadline do
            model = eggModel(egg)
            if model and model:FindFirstChild("Egg") then
                break
            end
            Life.wait(0.2)
        end
        local center = model and eggCenter(model)
        hrp = root()
        if center and hrp and not Ui.travelling then
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.CFrame = standSpot(model, center)
            Life.wait(0.3)
            arrived = true
        end
    end)
    Env.elevate()
    Ui.hatchMoving = false
    return arrived
end

-- Requests -------------------------------------------------------------------------------------

local seq = 7000000 -- well clear of the game client's own counter
local waiting
Life.spawn("hatch:results", function()
    local remote = Env.remote("EggService", "EggHatchResult")
    Life.connect(remote.OnClientEvent, function(payload)
        if waiting and type(payload) == "table" and (payload.Seq == waiting.seq or (payload.Seq == nil and payload.Egg == waiting.egg)) then
            waiting.result = payload
        end
    end, "hatch:result")
end)

-- Ui.hatchInFlight: the server holds a request until the egg may open again and only then checks
-- distance, so a craft trip must wait for it to land or the held request comes back TooFar.
local function hatch(egg, count)
    seq += 1
    local slot = { seq = seq, egg = egg }
    waiting = slot
    Ui.hatchInFlight = true
    Env.fire("EggService", "EggHatchRequested", { Egg = egg, Count = count, Auto = true, Seq = slot.seq })
    local deadline = os.clock() + 12 -- the client's own give-up time
    while Life.alive and not slot.result and os.clock() < deadline do
        Life.wait(0.03)
    end
    Ui.hatchInFlight = false
    if waiting == slot then
        waiting = nil
    end
    return slot.result
end

-- Auto delete: the game's own per-egg list, filled with every pet at or above a drop chance.
local appliedDelete = {}
local function applyAutoDelete(egg)
    local threshold = tonumber(Options.HatchDeleteAbove.Value) or 0
    if threshold <= 0 or appliedDelete[egg] == threshold then
        return
    end
    local names = {}
    for name, chance in pairs(EGGS[egg].pets) do
        if tonumber(chance) and chance >= threshold then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    Env.fire("EggService", "AutoDeleteRequested", { Egg = egg, Entries = names })
    appliedDelete[egg] = threshold
end

-- UI -------------------------------------------------------------------------------------------

local function shortNumber(n)
    for _, unit in ipairs({ { 1e18, "Qi" }, { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= unit[1] then
            return string.format("%.1f%s", n / unit[1], unit[2])
        end
    end
    return tostring(math.floor(n))
end

local function eggChoices()
    local data = Env.data()
    local names = {}
    for egg in pairs(EGGS) do
        if not data or hatchable(data, egg) then
            names[#names + 1] = egg
        end
    end
    table.sort(names, function(a, b)
        return EGGS[a].price > EGGS[b].price
    end)
    return names
end

local box = tab:AddGroupbox({ Side = "Left", Name = "Auto hatch", IconName = "egg" })
box:AddToggle("AutoHatch", {
    Text = "Auto hatch",
    Default = false,
    Tooltip = "Walks you to the egg and hatches as fast as the server allows: the next hatch goes the instant the last one lands.",
})
Ui.automation("AutoHatch")
box:AddDropdown("HatchMode", {
    Text = "Egg",
    Values = { BEST, CHOSEN, ISLAND },
    Default = BEST,
    Tooltip = "Best egg I can afford moves up as your coins grow and drops down instead of stopping when they run low.",
})
local initialEggs = eggChoices()
box:AddDropdown("HatchEgg", {
    Text = "Chosen egg",
    Values = initialEggs,
    Default = initialEggs[1],
    Searchable = true,
    Tooltip = "Used when Egg is set to Chosen egg. Priciest first.",
})
box:AddToggle("HatchTeleport", {
    Text = "Teleport to the egg",
    Default = true,
    Tooltip = "The server only hatches an egg you stand next to.",
})
box:AddSlider("HatchDeleteAbove", {
    Text = "Auto delete pets above",
    Default = 0,
    Min = 0,
    Max = 50,
    Rounding = 1,
    Suffix = "%",
    Tooltip = "0 keeps your in-game auto delete. Otherwise the egg's auto delete is set to every pet with at least this drop chance, so only rarer hatches reach your storage.",
})

local panelBox = tab:AddGroupbox({ Side = "Left", Name = "Hatching", IconName = "activity" })
local panel = Ui.panel(panelBox, 5)

local signature
Life.loop("hatch:eggs", 5, function()
    local values = eggChoices()
    local joined = table.concat(values, "\0")
    if joined ~= signature then
        signature = joined
        Env.elevate()
        Options.HatchEgg:SetValues(values)
    end
end)

-- The loop -------------------------------------------------------------------------------------

local stats = { eggs = 0, spent = 0, started = nil }
local recent = {} -- os.clock() of each hatched egg in the last minute, for the rate
local note = "Auto hatch is off."
local active = false -- the server believes we are auto hatching

local function stop()
    if active then
        active = false
        pcall(Env.fire, "EggService", "StopOfflineHatch")
    end
end

local function pause(text, seconds)
    note = text
    Life.wait(seconds)
end

Life.spawn("hatch:auto", function()
    local tooFar = 0
    while Life.alive do
        -- A craft trip stands you somewhere else; hatching resumes (and walks back) after it.
        if not Ui.on("AutoHatch") or Ui.travelling then
            stop()
            if not Ui.on("AutoHatch") then
                note = "Auto hatch is off."
                if Ui.status and (Ui.status:find("^Auto hatching") or Ui.status:find("^Walking to the")) then
                    Ui.status = "Idle"
                end
            end
            Life.wait(0.2)
            continue
        end
        local data = Env.data()
        if not data then
            Life.wait(0.5)
            continue
        end
        local egg = chooseEgg(data)
        if not egg then
            pause("No egg you can afford right now. Waiting for coins.", 1)
            continue
        end
        if egg ~= current then
            current, tooFar = egg, 0
        end
        local count = hatchCount(data, egg)
        if not count then
            pause("Not enough coins for the " .. egg .. " egg.", 0.5)
            continue
        end
        if Ui.on("HatchTeleport") and not nearEgg(egg) then
            Ui.status = "Walking to the " .. egg .. " egg"
            if not goToEgg(egg) then
                pause("Could not reach the " .. egg .. " egg.", 2)
                continue
            end
        end
        applyAutoDelete(egg)
        Ui.status = "Auto hatching " .. egg
        local result = hatch(egg, count)
        active = true
        if not result then
            pause("The server did not answer; retrying.", 0.5)
        elseif result.Success then
            tooFar = 0
            local got = tonumber(result.Rolls) or (type(result.Pets) == "table" and #result.Pets > 0 and #result.Pets) or count
            stats.eggs += got
            stats.spent += tonumber(result.Spent) or 0
            stats.started = stats.started or os.clock()
            local now = os.clock()
            for _ = 1, got do
                recent[#recent + 1] = now
            end
            note = string.format("Hatched %s x%d.", egg, got)
        elseif result.Error == "RateLimited" then
            Life.wait(0.4)
        elseif result.Error == "Cancelled" then
            Life.wait(0.1)
        elseif result.Error == "TooFar" then
            tooFar += 1
            if tooFar >= 3 or not Ui.on("HatchTeleport") then
                pause("Too far from the " .. egg .. " egg. Stand next to it.", 2)
            else
                goToEgg(egg)
            end
        elseif result.Error == "StorageFull" then
            pause(string.format("Storage full: this hatch needs %s free slot(s). Auto craft or auto delete frees space.", tostring(result.Needed or count)), 2)
        elseif result.Error == "NotEnoughCoins" then
            refused[egg] = os.clock() + 5
            Life.wait(0.25)
        elseif result.Error == "IslandLocked" then
            refused[egg] = os.clock() + 60
            note = egg .. " is on an island you have not unlocked."
        else
            pause("Hatch refused: " .. tostring(result.Error or result.Reason or "unknown"), 1)
        end
    end
end)

Life.loop("hatch:panel", 0.5, function()
    local data = Env.data()
    if not data then
        return
    end
    local cutoff = os.clock() - 60
    while recent[1] and recent[1] < cutoff do
        table.remove(recent, 1)
    end
    local lines = {}
    if current and EGGS[current] then
        local count = hatchCount(data, current) or 0
        lines[#lines + 1] = string.format("Egg: %s (%s each), %d per hatch", current, shortNumber(unitPrice(data, current)), count)
        local drought = type(data.Eggs) == "table" and type(data.Eggs.SecretDroughtSeconds) == "table"
            and tonumber(data.Eggs.SecretDroughtSeconds[current]) or 0
        local fill = math.clamp(drought / SECRET_PITY_SECONDS, 0, 1)
        lines[#lines + 1] = string.format("Secret pity: %d%% (luck x%.2f)", math.floor(fill * 100), 1 + (SECRET_PITY_MAX - 1) * fill)
    end
    local window = stats.started and math.min(60, os.clock() - stats.started) or 0
    lines[#lines + 1] = string.format("Rate: %d eggs/min, %d this session, %s coins spent",
        window > 1 and math.floor(#recent * 60 / window) or 0, stats.eggs, shortNumber(stats.spent))
    local owned = 0
    for _ in pairs(type(data.Pets) == "table" and type(data.Pets.Owned) == "table" and data.Pets.Owned or {}) do
        owned += 1
    end
    lines[#lines + 1] = string.format("Storage: %d / %s", owned, tostring(type(data.Pets) == "table" and data.Pets.StorageLimit or "?"))
    lines[#lines + 1] = note
    panel.set(lines)
end)

Life.onCleanup(stop)

return {}
end
__modules["features/home"] = function(use)
-- Home tab: the shared welcome box plus your live currencies and progress.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")
local Home = use("shared/home")

local _, statusLabel = Home.build()
local statsBox = Ui.Tabs.Home:AddGroupbox({ Side = "Right", Name = "You", IconName = "user" })
local stats = statsBox:AddLabel("Loading...", true)

local function comma(n)
    local text = string.format("%d", math.floor(tonumber(n) or 0))
    local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

Life.loop("home:stats", 1, function()
    statusLabel:SetText("Doing: " .. tostring(Ui.status or "Idle"))
    local data = Env.data()
    if not data then
        stats:SetText("Waiting for your data to load...")
        return
    end
    local prog = type(data.Progression) == "table" and data.Progression or {}
    local rebirths = type(data.Statistics) == "table" and data.Statistics.Rebirths
    stats:SetText(string.format(
        "Coins: %s\nGems: %s   Tokens: %s\nWorld: %s   Island: %s\nZone: %s%s",
        comma(Env.currency("Coins")),
        comma(Env.currency("Gems")), comma(Env.currency("Tokens")),
        tostring(prog.World or "?"), tostring(prog.Island or "?"),
        tostring(prog.Zone or "?"),
        rebirths and ("\nRebirths: " .. comma(rebirths)) or ""))
end)

return {}
end
__modules["features/mining"] = function(use)
-- Rewards tab: the mine under Crystal Cave (MiningService). A 20 x 20 x 25 block mine per player,
-- fresh every day. Ores fill your bag; selling them gives mining coins, which buy better pickaxes
-- and bags and, in the daily shop, packs of real Coins and Gems. Clearing 25/50/75/100% of the
-- mine pays milestone Coins and Gems once a day (MiningConfig.Milestones).
--
-- Everything goes through the game's own mine so it shows as you would play it:
--   enter   standing in the portal makes the game's MiningController travel in (Enter) and draw
--           the mine;
--   mine    the controller's TouchTapInWorld handler is the game's "tap a block" input: the camera
--           is pointed at the chosen block for that one call and put back, and the game aims,
--           checks reach, sight and pickaxe power, sends Hit and breaks the block on screen;
--   pets    your equipped pets mine blocks near you by themselves (the server's PetMine), which is
--           most of the speed;
--   sell    standing on the Sell pad makes the game sell the bag;
--   shop    Purchase("BuyTool" | "BuyStorage", name) and DailyBuy(id) on their pads;
--   leave   the Exit pad.
-- Without getconnections the hub sends Hit itself, and broken blocks are not removed on screen
-- until the mine is redrawn.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local UserInputService = game:GetService("UserInputService")
local tab = Ui.Tabs.Rewards

local function load(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = RS
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and type(module) == "table" and module or nil
end

local MiningWorld = load("Shared", "Minigames", "Mining", "MiningWorld")
local MiningConfig = load("Shared", "Minigames", "Mining", "MiningConfig")
local DailyShop = load("Shared", "Minigames", "Mining", "DailyShop")

local CRYSTAL_CAVE = Vector3.new(-53, 5445, -1992)
local SKIP_SECONDS = 60
local DAILY_ALL, DAILY_COINS, DAILY_GEMS, DAILY_OFF = "Coins and Gems packs", "Coins packs", "Gems packs", "Off"

local box = tab:AddGroupbox({ Side = "Right", Name = "Mine", IconName = "pickaxe" })
box:AddToggle("AutoMine", {
    Text = "Auto mine",
    Default = false,
    Tooltip = "Goes into the Crystal Cave mine and mines with you and your pets, selling whenever the bag is full. Auto hatch and other trips wait while it runs; turn it off to come back.",
})
Ui.automation("AutoMine", false)
box:AddToggle("MineUpgrades", {
    Text = "Buy pickaxes and bags",
    Default = true,
    Tooltip = "Spends mining coins on the next pickaxe or bag as soon as one is affordable. Better pickaxes break harder ore; the Copper Pickaxe is the only one that breaks Hardened Stone and the rare ores.",
})
box:AddDropdown("MineDaily", {
    Text = "Daily shop",
    Values = { DAILY_ALL, DAILY_COINS, DAILY_GEMS, DAILY_OFF },
    Default = DAILY_ALL,
    Tooltip = "Once every pickaxe and bag is bought, spare mining coins buy the daily shop's packs of real Coins or Gems (the Mining Legend title is never bought).",
})
local label = box:AddLabel("Auto mine is off.", true)

local session = { sold = 0, earned = 0, bought = {}, note = "" }

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function controller()
    local module = RS:FindFirstChild("Controllers") and RS.Controllers:FindFirstChild("Minigames")
    module = module and module:FindFirstChild("MiningController")
    if not module then
        return nil
    end
    local ok, result = Env.call(require, module)
    return ok and type(result) == "table" and result or nil
end

local function mineState()
    local mining = controller()
    if not mining or type(mining.GetState) ~= "function" then
        return nil
    end
    local ok, state = Env.call(mining.GetState, mining)
    return ok and type(state) == "table" and state or nil
end

local function inMine()
    return Env.LocalPlayer:GetAttribute("MiningActive") == true
end

local function teleport(cframe)
    local hrp = root()
    if hrp then
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.CFrame = cframe
    end
end

-- The game's own "tap a block" handler, once the mine's code has loaded.
local tapHandler
local function findTapHandler()
    if tapHandler or type(getconnections) ~= "function" then
        return tapHandler
    end
    local ok, connections = pcall(getconnections, UserInputService.TouchTapInWorld)
    for _, connection in ipairs(ok and type(connections) == "table" and connections or {}) do
        local fine, source = pcall(function()
            return connection.Function and debug.info(connection.Function, "s")
        end)
        if fine and type(source) == "string" and source:find("MiningController") then
            tapHandler = connection.Function
        end
    end
    Env.elevate()
    return tapHandler
end

local function enter()
    if inMine() then
        return true
    end
    pcall(function()
        Env.LocalPlayer:RequestStreamAroundAsync(CRYSTAL_CAVE, 10)
    end)
    Env.elevate()
    teleport(CFrame.new(CRYSTAL_CAVE))
    local portal
    local deadline = os.clock() + 10
    repeat
        Life.wait(0.3)
        portal = MiningWorld and MiningWorld.Portal()
    until portal or not Life.alive or os.clock() > deadline
    if not portal then
        session.note = "Could not find the mine portal on Crystal Cave."
        return false
    end
    teleport(portal.CFrame)
    deadline = os.clock() + 20
    repeat
        Life.wait(0.3)
    until inMine() or not Life.alive or os.clock() > deadline
    Life.wait(1.5) -- the game's fade and the first blocks being drawn
    return inMine()
end

local function onPad(name, until_, seconds)
    local pad = MiningWorld and MiningWorld.Part(name)
    if not pad then
        return false
    end
    teleport(pad.CFrame + Vector3.new(0, 4, 0))
    local deadline = os.clock() + (seconds or 6)
    repeat
        Life.wait(0.3)
    until not until_ or until_() or not Life.alive or os.clock() > deadline
    return true
end

local function ask(name, ...)
    local ok, result = Env.invoke("MiningService", name, ...)
    if ok and type(result) == "table" and not result.Error then
        return result
    end
    return nil, tostring(ok and type(result) == "table" and result.Error or result)
end

-- The next pickaxe or bag above what you use, if you can pay for it now.
local function nextUpgrade(state)
    if not MiningConfig then
        return nil
    end
    local balance = tonumber(state.Balance) or 0
    local best
    for _, kind in ipairs({ "Tool", "Bag" }) do
        local list = kind == "Tool" and MiningConfig.Tools or MiningConfig.Bags
        local current = tonumber(kind == "Tool" and state.Tool or state.Backpack) or 1
        local item = list[current + 1]
        if item and (not best or item.Price < best.price) then
            best = { kind = kind, name = item.Name, price = item.Price, affordable = item.Price <= balance }
        end
    end
    return best
end

-- The dearest daily-shop pack of the chosen kind you can pay for, or nil.
local dailySkip = {} -- id -> day it sold out for you
local function nextDaily(state)
    local pick = Options.MineDaily.Value
    if not DailyShop or pick == DAILY_OFF then
        return nil
    end
    local day = DailyShop.Day(os.time())
    local offers = {}
    local ok, rotating = Env.call(DailyShop.Rotating, day)
    for _, offer in ipairs(ok and type(rotating) == "table" and rotating or {}) do
        offers[#offers + 1] = offer
    end
    for _, offer in ipairs(DailyShop.PermanentOffers()) do
        offers[#offers + 1] = offer
    end
    local balance = tonumber(state.Balance) or 0
    local best
    for _, offer in ipairs(offers) do
        local kindOk = (offer.Kind == "Clicks" and pick ~= DAILY_GEMS) or (offer.Kind == "Gems" and pick ~= DAILY_COINS)
        if kindOk and dailySkip[offer.Id] ~= day and (tonumber(offer.Price) or math.huge) <= balance
            and (not best or offer.Price > best.Price) then
            best = offer
        end
    end
    return best, day
end

local function spend()
    local state = mineState()
    if not state then
        return
    end
    if Ui.on("MineUpgrades") then
        local upgrade = nextUpgrade(state)
        while upgrade and upgrade.affordable and Life.alive do
            onPad("Shop")
            local result, why = ask("Purchase", upgrade.kind == "Tool" and "BuyTool" or "BuyStorage", upgrade.name)
            if not result then
                session.note = string.format("Could not buy the %s: %s.", upgrade.name, why)
                return
            end
            session.bought[#session.bought + 1] = upgrade.name
            session.note = "Bought the " .. upgrade.name .. "."
            Life.wait(0.6)
            state = mineState() or state
            upgrade = nextUpgrade(state)
        end
        if upgrade then
            return -- saving for the next upgrade before anything else
        end
    end
    local offer, day = nextDaily(state)
    while offer and Life.alive do
        onPad("Daily")
        local result, why = ask("DailyBuy", offer.Id)
        if not result then
            dailySkip[offer.Id] = day
            session.note = string.format("Daily shop: %s (%s).", offer.Name, why)
        else
            session.bought[#session.bought + 1] = offer.Name
            session.note = "Daily shop: bought a " .. offer.Name .. "."
        end
        Life.wait(0.6)
        state = mineState() or state
        offer, day = nextDaily(state)
    end
end

local function sellAndSpend()
    local before = mineState()
    local balance = before and tonumber(before.Balance) or 0
    onPad("Sell", function()
        local state = mineState()
        return state and (tonumber(state.Count) or 0) == 0
    end, 8)
    local after = mineState()
    if after and (tonumber(after.Count) or 0) == 0 then
        session.sold += 1
        session.earned += math.max(0, (tonumber(after.Balance) or 0) - balance)
    end
    spend()
end

-- Mining ---------------------------------------------------------------------------------------

local skipped = {} -- key -> skip until (os.clock)

-- Ores at least this valuable are taken before plain rock wherever they are uncovered: Copper (20)
-- and up. Dirt is worth 1, Stone 3, Coal 10; gems 250-650 (BlockStats).
local ORE_VALUE = 20

-- The block to mine: one the game has drawn (drawn blocks are the exposed ones near you) that your
-- pickaxe can break and that has open space above it. The most valuable uncovered ore first, then
-- plain rock top layers first (the mine is Dirt for 3 layers, Stone down to 20, Hardened Stone
-- below), then the nearest.
local function chooseTarget(state, marker)
    local folder = workspace:FindFirstChild("LocalMiningBlocks")
    if not folder or not MiningConfig then
        return nil
    end
    local tool = MiningConfig.Tools[tonumber(state.Tool) or 1]
    local power = tool and tool.Power or 1
    local drawn = {}
    for _, block in ipairs(folder:GetChildren()) do
        if block.Name:match("^%d+:%d+:%d+$") then
            drawn[block.Name] = block
        end
    end
    local hrp = root()
    local here = hrp and hrp.Position or marker.Position
    local now = os.clock()
    local best
    local function better(candidate)
        if not best then
            return true
        end
        local oreA, oreB = candidate.value >= ORE_VALUE, best.value >= ORE_VALUE
        if oreA ~= oreB then
            return oreA
        end
        if oreA and candidate.value ~= best.value then
            return candidate.value > best.value
        end
        if not oreA and candidate.y ~= best.y then
            return candidate.y < best.y
        end
        return candidate.distance < best.distance
    end
    for key, block in pairs(drawn) do
        if (skipped[key] or 0) <= now then
            local x, y, z = key:match("^(%d+):(%d+):(%d+)$")
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            local above = y > 0 and MiningConfig.Key(x, y - 1, z) or nil
            if not (above and drawn[above]) then
                local ok, _, stats = pcall(MiningConfig.Ore, state.Seed, x, y, z)
                if ok and stats and (tonumber(stats.pickaxeRequirement) or 0) <= power then
                    local position = MiningConfig.Position(marker, x, y, z)
                    local candidate = { key = key, x = x, y = y, z = z, position = position, block = block,
                        health = tonumber(stats.health) or 10, value = tonumber(stats.value) or 0,
                        distance = (position - here).Magnitude }
                    if better(candidate) then
                        best = candidate
                    end
                end
            end
        end
    end
    return best, tool
end

local function stillThere(target)
    return target.block.Parent ~= nil and target.block.Name == target.key
end

-- One swing at the target through the game's own input, or the remote when that is out of reach.
local function swing(state, target)
    local handler = findTapHandler()
    if handler then
        local camera = workspace.CurrentCamera
        local hrp = root()
        if not (camera and hrp) then
            return
        end
        local saved = camera.CFrame
        camera.CFrame = CFrame.lookAt(hrp.Position + Vector3.new(0, 1.5, 0), target.position)
        local center = camera.ViewportSize / 2
        pcall(handler, Vector2.new(center.X, center.Y), false)
        camera.CFrame = saved
        Env.elevate()
    else
        Env.invoke("MiningService", "Hit", state.Id, target.x, target.y, target.z)
    end
end

local function mineOne(state, marker)
    local target, tool = chooseTarget(state, marker)
    if not target then
        return false
    end
    local stand = target.position + Vector3.new(0, MiningConfig.BlockSize + 1, 0)
    local hrp = root()
    if hrp and (hrp.Position - stand).Magnitude > 3 then
        teleport(CFrame.new(stand))
        Life.wait(0.2)
    end
    local damage = tool and tool.Damage or 1
    local interval = tool and tool.Interval or 0.45
    local swings = math.ceil(target.health / math.max(damage, 1)) + 4
    for _ = 1, swings do
        if not (Life.alive and Ui.on("AutoMine") and stillThere(target)) then
            break
        end
        local current = mineState()
        if current and (tonumber(current.Count) or 0) >= (tonumber(current.Capacity) or math.huge) then
            return true -- the bag filled up mid-block
        end
        swing(state, target)
        Life.wait(interval + 0.03)
    end
    if stillThere(target) then
        skipped[target.key] = os.clock() + SKIP_SECONDS
    end
    return true
end

local busy = false
local function run()
    busy = true
    Ui.travelling = "mining"
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        Ui.status = "Mining"
        if not enter() then
            session.note = session.note ~= "" and session.note or "Could not get into the mine."
            return
        end
        local idle = 0
        while Life.alive and Ui.on("AutoMine") do
            if not inMine() and not enter() then
                break
            end
            local state = mineState()
            local marker = MiningWorld and MiningWorld.Marker()
            if not (state and marker and state.Seed) then
                Life.wait(0.5)
            elseif (tonumber(state.Count) or 0) >= (tonumber(state.Capacity) or math.huge) then
                sellAndSpend()
            elseif not mineOne(state, marker) then
                -- nothing drawn to mine right here: let the pets work and look again
                idle += 1
                Life.wait(1)
                if idle % 10 == 0 then
                    table.clear(skipped)
                end
            else
                idle = 0
            end
        end
        if inMine() then
            if (tonumber((mineState() or {}).Count) or 0) > 0 then
                sellAndSpend()
            end
            onPad("Exit", function()
                return not inMine()
            end, 12)
        end
    end)
    Env.elevate()
    if not ok then
        Life.errors["mining:run"] = tostring(err)
        session.note = "Mining error: " .. tostring(err)
    end
    Life.wait(1)
    if home then
        teleport(home)
    end
    if Ui.status == "Mining" then
        Ui.status = "Idle"
    end
    Ui.travelling = false
    busy = false
end

local function short(n)
    for _, unit in ipairs({ { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= unit[1] then
            return string.format("%.1f%s", n / unit[1], unit[2])
        end
    end
    return tostring(math.floor(n))
end

Life.loop("mining:auto", 1, function()
    local data = Env.data()
    local mining = data and type(data.Mining) == "table" and data.Mining or {}
    local state = inMine() and mineState() or nil
    local lines = {}
    local tools = MiningConfig and MiningConfig.Tools or {}
    local bags = MiningConfig and MiningConfig.Bags or {}
    local tool = tools[tonumber(mining.Tool) or 1]
    local bag = bags[tonumber(mining.Backpack) or 1]
    lines[1] = string.format("%s, %s. %s mining coins.", tool and tool.Name or "?", bag and bag.Name or "?",
        short(tonumber(mining.Coins) or 0))
    if state then
        local total = tonumber(state.Total) or 10000
        local mined = tonumber(state.Mined) or 0
        lines[#lines + 1] = string.format("Mine %.1f%% cleared (%d / %d), bag %d/%d.", mined / total * 100, mined, total,
            tonumber(state.Count) or 0, tonumber(state.Capacity) or 0)
    end
    if session.sold > 0 then
        lines[#lines + 1] = string.format("%d sales this session for %s mining coins.", session.sold, short(session.earned))
    end
    if session.note ~= "" then
        lines[#lines + 1] = session.note
    end
    if not Ui.on("AutoMine") then
        label:SetText("Off. " .. table.concat(lines, "\n"))
        return
    end
    label:SetText(table.concat(lines, "\n"))
    if not busy and not Ui.travelling and not Ui.hatchMoving and MiningWorld and MiningConfig then
        Life.spawn("mining:run", run)
    end
end)

Life.onCleanup(function()
    if busy then
        Ui.travelling = false
    end
end)

return {}
end
__modules["features/performance"] = function(use)
-- Home tab, Performance: the shared performance mode (see shared/performance) plus Tap Simulator's
-- own quality settings, which is where this game spends its frames: the hatch reveal that plays for
-- every auto hatch, pets following everyone, tap pop-ups and screen shake.
--
-- The game keeps those settings on the server (SettingsService.UpdateSetting { Name, Value },
-- definitions in Shared.Core.SettingsConfig), so the game itself skips the work instead of the hub
-- fighting it. Your own values are read before anything changes and put back when performance mode
-- goes off or the hub unloads.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local group = use("shared/performance").build(Ui.Tabs.Home)

local KEEP = "Keep my setting"
local PET_VALUES = { [KEEP] = nil, ["Hide other players' pets"] = 2, ["Hide all pets"] = 3 }

-- What performance mode sets, besides the pets choice below.
local GAME_SETTINGS = {
    PerformanceMode = 3, -- "Potato"
    HatchAnimation = 3, -- "Off": only drops the slow rare reveal, see "Hide hatching" below
    HideClicks = true,
    HideFlashes = true,
    ScreenShake = false,
    BlobShadows = false,
    HideTitles = true,
}

group:AddToggle("PerfGameSettings", {
    Text = "Use the game's lowest settings",
    Default = true,
    Tooltip = "While performance mode is on: Potato graphics, rare hatch reveal off, tap pop-ups, flashes, screen shake, blob shadows and titles hidden. Your settings come back afterwards.",
})
group:AddToggle("PerfHideHatching", {
    Text = "Hide hatching and crafting",
    Default = true,
    Tooltip = getconnections and "While performance mode is on, eggs you hatch and pets you craft no longer play their animation (the game has no setting for this). Hatching and crafting still happen."
        or "Your executor has no getconnections, so hatching cannot be hidden.",
})
group:AddDropdown("PerfHidePets", {
    Text = "Pets",
    Values = { KEEP, "Hide other players' pets", "Hide all pets" },
    Default = "Hide other players' pets",
    Tooltip = "Pets following players are a large share of what gets drawn and moved each frame.",
})

-- setting name -> the value it had before performance mode changed it. The game keeps settings on
-- the server, so if a session ends without switching performance mode off (a crash, a rejoin) the
-- next one would read "Potato" as your setting. The originals are kept on disk until put back.
local saved = {}
local FOLDER = "NOX/TapSimulator"
local FILE = FOLDER .. "/game-settings.json"
local files = Env.files

local function persist()
    if not (files.writefile and files.isfolder and files.makefolder) then
        return
    end
    pcall(function()
        local path = ""
        for part in FOLDER:gmatch("[^/]+") do
            path = path == "" and part or path .. "/" .. part
            if not files.isfolder(path) then
                files.makefolder(path)
            end
        end
        files.writefile(FILE, Env.HttpService:JSONEncode(saved))
    end)
    Env.elevate()
end

do
    local ok, stored = pcall(function()
        return files.isfile and files.isfile(FILE) and Env.HttpService:JSONDecode(files.readfile(FILE))
    end)
    Env.elevate()
    if ok and type(stored) == "table" then
        for name, value in pairs(stored) do
            if type(name) == "string" and (type(value) == "number" or type(value) == "boolean") then
                saved[name] = value
            end
        end
    end
end

local SettingsConfig
do
    local ok, module = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Core.SettingsConfig)
    end)
    SettingsConfig = ok and type(module) == "table" and module or nil
end
local UserInputService = game:GetService("UserInputService")

-- The value the game is using. A setting you never changed is not stored at all, so its value is
-- the game's default (which differs on PC for some), read the same way the game reads it.
local function current(name)
    local data = Env.data()
    local settings = data and type(data.Settings) == "table" and data.Settings or nil
    if settings and settings[name] ~= nil then
        return settings[name]
    end
    if SettingsConfig then
        local pc = UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled
        local ok, value = Env.call(SettingsConfig.Read, settings, name, pc)
        if ok then
            return value
        end
    end
    return nil
end

-- Several changes in a row get refused now and then (a restore once silently left one behind), so
-- each write is spaced out and retried. task.wait, not Life.wait: this also runs while unloading.
local function write(name, value)
    for attempt = 1, 4 do
        local ok, result = Env.invoke("SettingsService", "UpdateSetting", { Name = name, Value = value })
        if ok and (type(result) ~= "table" or result.Success ~= false) then
            task.wait(0.15)
            return true
        end
        task.wait(0.4 * attempt)
    end
    return false
end

local function wanted()
    local list = {}
    if Ui.on("PerfGameSettings") then
        for name, value in pairs(GAME_SETTINGS) do
            list[name] = value
        end
    end
    local pets = PET_VALUES[Ui.Options.PerfHidePets.Value]
    if pets then
        list.HidePets = pets
    end
    return list
end

local function restore()
    for name, value in pairs(saved) do
        write(name, value)
    end
    table.clear(saved)
    persist()
end

-- Brings the game's settings in line with the toggles: changes what performance mode wants (saving
-- the old value the first time) and puts back anything it no longer wants.
local function apply()
    if not Ui.on("PerfMode") then
        restore()
        return
    end
    local want = wanted()
    local changed = false
    for name, value in pairs(want) do
        local now = current(name)
        if now ~= value then
            if saved[name] == nil and now ~= nil then
                saved[name] = now
                changed = true
            end
            write(name, value)
        end
    end
    for name, value in pairs(saved) do
        if want[name] == nil then
            write(name, value)
            saved[name] = nil
            changed = true
        end
    end
    if changed then
        persist()
    end
end

local pending = false
local function schedule()
    if pending then
        return
    end
    pending = true
    Life.spawn("performance:game-settings", function()
        apply()
        pending = false
    end)
end

-- Hatching and crafting on screen ---------------------------------------------------------------
--
-- The game's Hatch Animation setting only chooses which rarities get the slow reveal: every hatch
-- still plays its egg and pet card (HatchRenderer), and every craft its machine roll. The only way
-- to keep them off the screen is to stop the game's own handlers for those results. Their
-- connections are disabled while this is on and enabled again afterwards. Only functions from the
-- game's ReplicatedStorage scripts are touched, so the hub's own result handlers keep working.

local VISUAL_EVENTS = {
    { "EggService", "EggHatchResult" },
    { "EggService", "ForcedHatchResult" },
    { "EggService", "SecretSkyFireworks" },
    { "EggService", "SecretEggFlash" },
    { "EggService", "SecretCelebration" },
    { "EggService", "ExclusiveEggHatchObserved" },
    { "MachineService", "MachineCraftResult" },
}
local muted = {} -- connection -> true

local function findRemote(service, name)
    local services = Env.ReplicatedStorage:FindFirstChild("RemoteServices")
    local folder = services and services:FindFirstChild(service)
    local events = folder and folder:FindFirstChild("RE")
    return events and events:FindFirstChild(name)
end

local function fromGame(connection)
    local ok, source = pcall(function()
        local fn = connection.Function
        return fn and debug.info(fn, "s")
    end)
    return ok and type(source) == "string" and source:find("^ReplicatedStorage%.") ~= nil
end

local function muteVisuals()
    for _, pair in ipairs(VISUAL_EVENTS) do
        local remote = findRemote(pair[1], pair[2])
        local ok, connections = false, nil
        if remote then
            ok, connections = pcall(getconnections, remote.OnClientEvent)
        end
        for _, connection in ipairs(ok and type(connections) == "table" and connections or {}) do
            if not muted[connection] and fromGame(connection) and pcall(function()
                connection:Disable()
            end) then
                muted[connection] = true
            end
        end
    end
    Env.elevate()
end

local function unmuteVisuals()
    for connection in pairs(muted) do
        pcall(function()
            connection:Enable()
        end)
    end
    table.clear(muted)
    Env.elevate()
end

local function refreshVisuals()
    if type(getconnections) == "function" and Ui.on("PerfMode") and Ui.on("PerfHideHatching") then
        muteVisuals()
    elseif next(muted) ~= nil then
        unmuteVisuals()
    end
end

-- The library keeps one Changed handler per control; shared/performance already owns PerfMode's.
local sharedHandler = Ui.Toggles.PerfMode.Changed
Ui.Toggles.PerfMode:OnChanged(function(...)
    if type(sharedHandler) == "function" then
        sharedHandler(...)
    end
    schedule()
    refreshVisuals()
end)
Ui.Toggles.PerfGameSettings:OnChanged(schedule)
Ui.Options.PerfHidePets:OnChanged(schedule)
Ui.Toggles.PerfHideHatching:OnChanged(refreshVisuals)
-- A handler the game connects later (after a respawn, a menu opening) is caught on the next pass.
Life.loop("performance:visuals", 3, refreshVisuals)
Life.onCleanup(unmuteVisuals)

-- A previous session that never put your settings back: do it now, unless the saved config is
-- about to switch performance mode on (that keeps them, and puts them back when it goes off).
Life.spawn("performance:repair", function()
    Life.wait(3) -- after the config autoload has had its say
    if next(saved) ~= nil and not Ui.on("PerfMode") then
        restore()
    end
end)

Life.onCleanup(restore)

return {}
end
__modules["features/pets"] = function(use)
-- Pets tab (right): keep your strongest pets equipped. The game ranks and swaps them for you with
-- PetActionRequested { Action = "EquipBest" }, so firing it as new pets hatch means the team is
-- always your highest-power four without opening the inventory.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local tab = Ui.Tabs.Pets
local box = tab:AddGroupbox({ Side = "Right", Name = "Auto equip", IconName = "star" })

local function equipBest()
    Env.fire("PetService", "PetActionRequested", { Action = "EquipBest" })
end

box:AddToggle("AutoEquipBest", {
    Text = "Auto equip best pets",
    Default = false,
    Tooltip = "Keeps your highest-power pets equipped. Re-checks as you hatch so new strong pets go on automatically.",
})
Ui.automation("AutoEquipBest", true)
box:AddSlider("EquipEvery", {
    Text = "Re-equip every",
    Default = 5,
    Min = 2,
    Max = 30,
    Rounding = 0,
    Suffix = "s",
})
box:AddButton({
    Text = "Equip best now",
    Func = function()
        equipBest()
        Ui.notify("Tap Simulator", "Equipped your strongest pets.", 3)
    end,
})
local label = box:AddLabel("Auto equip is off.", true)

-- A compact read of what is on the team, so the label reflects the swap.
local function teamSummary()
    local data = Env.data()
    local pets = data and type(data.Pets) == "table" and data.Pets
    if not pets or type(pets.Owned) ~= "table" or type(pets.Equipped) ~= "table" then
        return nil
    end
    local names, best = {}, 0
    for _, petId in pairs(pets.Equipped) do
        local pet = pets.Owned[petId]
        if type(pet) == "table" then
            names[#names + 1] = string.format("%s (%s)", tostring(pet.Name), tostring(pet.Power or "?"))
            best = math.max(best, tonumber(pet.Power) or 0)
        end
    end
    return names, best
end

local lastEquip = 0
Life.loop("pets:equip", 1, function()
    if not Ui.on("AutoEquipBest") then
        return
    end
    local every = math.clamp(tonumber(Ui.Options.EquipEvery.Value) or 5, 2, 30)
    if os.clock() - lastEquip >= every then
        lastEquip = os.clock()
        equipBest()
        Ui.status = "Equipping best pets"
    end
    local names = teamSummary()
    if names then
        label:SetText("Equipped: " .. (table.concat(names, ", ")):sub(1, 140))
    end
end)

return {}
end
__modules["features/pickups"] = function(use)
-- Rewards tab: the things that show up on screen to be clicked. The Lucky Ducky flying across the
-- screen, and the Balloon Party and "Pigs could fly" world events.
--
-- Lucky Ducky (LuckyDuckyService): once you have an hour of playtime, the server sends Spawn { Id,
-- Lifetime, Why } every 20-30 minutes and the duck crosses the screen for ~10 seconds. Claim(Id)
-- rolls x2 coins for 2 min (60%), a pile of coins (27%), x3 coins for 2 min (10%) or 1 in 4
-- hatches Golden for 1 min (3%). The server refuses a claim sooner than 0.3s after the spawn, so
-- the catch waits a human moment, then goes through the game's own LuckyDuckyController:CatchShown
-- (its animation, claim and reward banner); Claim(Id) is sent directly only if no duck was drawn.
--
-- Balloon Party (BalloonPartyService), every 45 minutes for 2 minutes: balloons launch around each
-- player (Launched { Uid, Origin, Rise, Phase, LaunchedAt, Size }) and rise on a path anyone can
-- compute (Shared.Admin.BalloonFlight). Hit(Uid) counts a tap from up to HitRange (150) studs, once
-- per HitCooldown per balloon; Size sets how many taps it takes. The server confirms each tap on
-- Hit (Uid, Taken, UserId), and Popped / Rewarded follow.
--
-- Pigs could fly (PigsCouldFlyService): pigs circle each player on PigFlight paths; one Hit(Uid)
-- from within 120 studs catches one, Caught (Uid, UserId) and Rewarded follow, Retired ends one.
--
-- Both events spawn around you, so nothing here moves the character: it taps what is in range.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local RunService = game:GetService("RunService")
local tab = Ui.Tabs.Rewards
local RS = Env.ReplicatedStorage

local function load(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = RS
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and type(module) == "table" and module or nil
end

local DuckController = load("Controllers", "Game", "LuckyDuckyController")
local WorldEventConfig = load("Shared", "Admin", "WorldEventConfig")
local BalloonFlight = load("Shared", "Admin", "BalloonFlight")
local PigFlight = load("Shared", "Admin", "PigFlight")
local BalloonRules = WorldEventConfig and WorldEventConfig.Balloon or {}
local PigRules = WorldEventConfig and WorldEventConfig.Pig or {}

-- Inside the game's own ranges, so a tap is never judged out of reach on the server's clock.
local BALLOON_RANGE = (tonumber(BalloonRules.HitRange) or 150) - 15
local BALLOON_GAP = (tonumber(BalloonRules.HitCooldown) or 0.1) + 0.06
local PIG_RANGE = (tonumber(PigRules.HitRange) or 120) - 15
local PIG_GAP = 0.6
local TAP_GAP = 0.09 -- between any two taps, about as fast as a quick thumb

local box = tab:AddGroupbox({ Side = "Left", Name = "Pickups", IconName = "sparkles" })
box:AddToggle("AutoDuck", {
    Text = "Catch the Lucky Ducky",
    Default = true,
    Tooltip = "Catches the duck that flies across your screen every 20-30 minutes (after an hour of playtime): x2 or x3 coins for 2 minutes, a pile of coins, or Golden hatches for a minute.",
})
Ui.automation("AutoDuck", true)
box:AddToggle("AutoBalloons", {
    Text = "Pop Balloon Party balloons",
    Default = true,
    Tooltip = "During the Balloon Party event (every 45 minutes, 2 minutes long), taps every balloon within reach until it pops. Balloons give coins and gems.",
})
Ui.automation("AutoBalloons", true)
box:AddToggle("AutoPigs", {
    Text = "Catch flying pigs",
    Default = true,
    Tooltip = "During the \"Pigs could fly\" event, catches every pig within reach for coins and gems.",
})
Ui.automation("AutoPigs", true)
local label = box:AddLabel("Waiting for a duck, balloons or pigs.", true)

local session = { ducks = 0, duckNote = nil, balloons = 0, pigs = 0, coins = 0, gems = 0 }

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function short(n)
    for _, unit in ipairs({ { 1e18, "Qi" }, { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= unit[1] then
            return string.format("%.1f%s", n / unit[1], unit[2])
        end
    end
    return tostring(math.floor(n))
end

local function addReward(reward)
    if type(reward) ~= "table" then
        return
    end
    session.coins += tonumber(reward.Coins) or 0
    session.gems += tonumber(reward.Gems) or 0
end

-- Lucky Ducky ----------------------------------------------------------------------------------

local function catchDuck(payload)
    Life.wait(0.7 + math.random() * 0.8)
    if not Ui.on("AutoDuck") then
        return
    end
    local caught = false
    if DuckController and type(DuckController.CatchShown) == "function" then
        local ok, result = Env.call(DuckController.CatchShown, DuckController)
        caught = ok and result == true
    end
    if caught then
        session.ducks += 1
        session.duckNote = "caught"
        return
    end
    local ok, result = Env.invoke("LuckyDuckyService", "Claim", payload.Id)
    if ok and type(result) == "table" and result.Success == true then
        session.ducks += 1
        session.duckNote = tostring(result.Title or result.Reward or "caught")
        if type(result.Coins) == "number" then
            session.coins += result.Coins
        end
    else
        session.duckNote = "got away: " .. tostring(type(result) == "table" and result.Reason or result)
    end
end

Life.spawn("pickups:duck", function()
    local remote = Env.remote("LuckyDuckyService", "Spawn")
    Life.connect(remote.OnClientEvent, function(payload)
        if Ui.on("AutoDuck") and type(payload) == "table" and payload.Id ~= nil then
            Life.spawn("pickups:duck-catch", catchDuck, payload)
        end
    end)
end)

-- Balloons and pigs ----------------------------------------------------------------------------

local balloons = {} -- uid -> { flight, needed, taken, last }
local pigs = {} -- uid -> { flight, last }
-- uids this hub tapped: Rewarded is only counted for those, whoever else it may reach.
local tappedByMe = {}

local function trackBalloon(flight)
    if type(flight) ~= "table" or type(flight.Uid) ~= "string" or balloons[flight.Uid] then
        return
    end
    if typeof(flight.Origin) ~= "Vector3" or type(flight.Rise) ~= "number" or type(flight.LaunchedAt) ~= "number" then
        return
    end
    local size = type(BalloonRules.Sizes) == "table" and BalloonRules.Sizes[flight.Size]
    balloons[flight.Uid] = {
        flight = flight,
        needed = size and tonumber(size.Hits) or 1,
        taken = 0,
        last = 0,
    }
end

local function trackPig(flight)
    if type(flight) ~= "table" or type(flight.Uid) ~= "string" or pigs[flight.Uid] then
        return
    end
    if typeof(flight.Centre) ~= "Vector3" or typeof(flight.Pass) ~= "Vector3" or type(flight.LaunchedAt) ~= "number" then
        return
    end
    pigs[flight.Uid] = { flight = flight, last = 0 }
end

Life.spawn("pickups:balloon-events", function()
    Life.connect(Env.remote("BalloonPartyService", "Launched").OnClientEvent, trackBalloon)
    Life.connect(Env.remote("BalloonPartyService", "Hit").OnClientEvent, function(uid, taken)
        local balloon = type(uid) == "string" and balloons[uid]
        if balloon and type(taken) == "number" then
            balloon.taken = math.max(balloon.taken, taken)
        end
    end)
    Life.connect(Env.remote("BalloonPartyService", "Popped").OnClientEvent, function(uid)
        if type(uid) == "string" then
            balloons[uid] = nil
        end
    end)
    Life.connect(Env.remote("BalloonPartyService", "Rewarded").OnClientEvent, function(uid, reward)
        if tappedByMe[uid] then
            tappedByMe[uid] = nil
            session.balloons += 1
            addReward(reward)
        end
    end)
    -- A party already running when the hub loads.
    local ok, active = Env.invoke("BalloonPartyService", "GetActive")
    for _, flight in ipairs(ok and type(active) == "table" and active or {}) do
        trackBalloon(flight)
    end
end)

Life.spawn("pickups:pig-events", function()
    Life.connect(Env.remote("PigsCouldFlyService", "Launched").OnClientEvent, trackPig)
    local function gone(uid)
        if type(uid) == "string" then
            pigs[uid] = nil
        end
    end
    Life.connect(Env.remote("PigsCouldFlyService", "Caught").OnClientEvent, gone)
    Life.connect(Env.remote("PigsCouldFlyService", "Retired").OnClientEvent, gone)
    Life.connect(Env.remote("PigsCouldFlyService", "Rewarded").OnClientEvent, function(uid, reward)
        if tappedByMe[uid] then
            tappedByMe[uid] = nil
            session.pigs += 1
            addReward(reward)
        end
    end)
    local ok, active = Env.invoke("PigsCouldFlyService", "GetActive")
    for _, flight in ipairs(ok and type(active) == "table" and active or {}) do
        trackPig(flight)
    end
end)

-- Where a balloon is now, or nil once it has flown off.
local function balloonAt(balloon, now)
    local age = now - balloon.flight.LaunchedAt
    if not BalloonFlight or age >= (BalloonFlight.Lifetime or 25) then
        return nil
    end
    local ok, position = pcall(BalloonFlight.Position, balloon.flight, age)
    return ok and typeof(position) == "Vector3" and position or nil
end

local function pigAt(pig, now)
    local age = now - pig.flight.LaunchedAt
    if not PigFlight or age >= (PigFlight.Lifetime or 40) then
        return nil
    end
    local ok, position = pcall(PigFlight.Position, pig.flight, age)
    return ok and typeof(position) == "Vector3" and position or nil
end

-- The next tap: a pig first (one tap catches it), then the balloon closest to popping, so a
-- tap is never spread thin across a sky full of half-hit balloons.
local function nextTap(here, now, clock)
    if Ui.on("AutoPigs") then
        for uid, pig in pairs(pigs) do
            local at = pigAt(pig, now)
            if not at then
                pigs[uid] = nil
            elseif clock - pig.last >= PIG_GAP and (at - here).Magnitude <= PIG_RANGE then
                return "PigsCouldFlyService", uid, pig
            end
        end
    end
    if Ui.on("AutoBalloons") then
        local best, bestUid, bestLeft
        for uid, balloon in pairs(balloons) do
            local at = balloonAt(balloon, now)
            if not at then
                balloons[uid] = nil
            elseif clock - balloon.last >= BALLOON_GAP and (at - here).Magnitude <= BALLOON_RANGE then
                local left = balloon.needed - balloon.taken
                if left > 0 and (not best or left < bestLeft) then
                    best, bestUid, bestLeft = balloon, uid, left
                end
            end
        end
        if best then
            return "BalloonPartyService", bestUid, best
        end
    end
    return nil
end

Life.spawn("pickups:tap", function()
    while Life.alive do
        local hrp = root()
        local tapped = false
        if hrp and (next(balloons) or next(pigs)) then
            local clock = os.clock()
            local service, uid, target = nextTap(hrp.Position, workspace:GetServerTimeNow(), clock)
            if service then
                target.last = clock
                tappedByMe[uid] = true
                Env.fire(service, "Hit", uid)
                tapped = true
            end
        end
        if tapped then
            Life.wait(TAP_GAP)
        else
            Life.wait(0.15)
        end
    end
end)

Life.loop("pickups:panel", 1, function()
    local live = 0
    for _ in pairs(balloons) do
        live += 1
    end
    local pigsLive = 0
    for _ in pairs(pigs) do
        pigsLive += 1
    end
    local lines = {
        string.format("Ducks caught: %d%s", session.ducks, session.duckNote and (" (last " .. session.duckNote .. ")") or ""),
        string.format("Balloons popped: %d, pigs caught: %d", session.balloons, session.pigs),
    }
    if session.coins > 0 or session.gems > 0 then
        lines[#lines + 1] = string.format("From them: %s coins, %s gems", short(session.coins), short(session.gems))
    end
    if live > 0 or pigsLive > 0 then
        lines[#lines + 1] = string.format("In the sky now: %d balloons, %d pigs", live, pigsLive)
    end
    label:SetText(table.concat(lines, "\n"))
end)

return {}
end
__modules["features/potions"] = function(use)
-- Craft tab (right): the potion machine on Spawn, and drinking what it makes.
--
-- PotionMachineService (Shared.Items.PotionBrewConfig, PotionCraftConfig):
--   Brew(name, slot)  starts a Coins, Luck or Gems Potion I in one of 3 slots. It takes 5 minutes
--                     and costs PotionBrewConfig.GetPrice(rebirths) gems (1 + 5% of your rebirths).
--   ClaimAll()        collects every finished slot.
--   Craft(output)     merges 3 of a Potion I into its Potion II.
-- All three answer { Success, Error } and refuse with "TooFar" unless you stand at the machine, so
-- the machine is a trip like a craft: auto hatch pauses, one visit claims, merges and refills the
-- slots, and you go back where you were.
--
-- BoostService.Use(name) drinks a potion from anywhere. Active boosts of one type add up
-- (Shared.Items.BoostFormula sums every active potion's Multi), so each chosen potion is drunk
-- again as soon as its own timer (Data.ActiveBoosts[name], > 0 while it runs) is out.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local RS = Env.ReplicatedStorage
local tab = Ui.Tabs.Craft

local function load(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = RS
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and type(module) == "table" and module or nil
end

local BrewConfig = load("Shared", "Items", "PotionBrewConfig")
local CraftConfig = load("Shared", "Items", "PotionCraftConfig")
local BoostConfig = load("Shared", "Items", "BoostConfig")

local RECIPES = CraftConfig and CraftConfig.Recipes or {}
local SLOTS = BrewConfig and BrewConfig.SlotCount or 3
local BREWABLE = BrewConfig and BrewConfig.Potions or { "Coins Potion I", "Luck Potion I", "Gems Potion I" }
local MACHINE = { "Map1", "PotionMachine" }
local MACHINE_FALLBACK = Vector3.new(-354, -524, -12047) -- moved in the Oct 16 update

-- Everything drinkable: the six potions first, then the rarer boosts you might hold.
local DRINKABLE, DEFAULT_DRINKS = {}, {}
do
    local definitions = BoostConfig and BoostConfig.Definitions or {}
    local potions, others = {}, {}
    for name, def in pairs(definitions) do
        if type(def) == "table" and (tonumber(def.Duration) or 0) > 0 then
            if name:find("Potion") then
                potions[#potions + 1] = name
            elseif name == "Octo Incubator" or name == "Enchant Overclocker" then
                others[#others + 1] = name
            end
        end
    end
    table.sort(potions)
    table.sort(others)
    for _, name in ipairs(potions) do
        DRINKABLE[#DRINKABLE + 1] = name
        DEFAULT_DRINKS[#DEFAULT_DRINKS + 1] = name
    end
    for _, name in ipairs(others) do
        DRINKABLE[#DRINKABLE + 1] = name
    end
end

local box = tab:AddGroupbox({ Side = "Right", Name = "Potions", IconName = "flask-conical" })
box:AddToggle("AutoBrew", {
    Text = "Auto brew potions",
    Default = false,
    Tooltip = "Keeps the potion machine's 3 slots brewing and collects each potion when it is done (5 minutes each). Each brew costs gems: 1 plus 5% of your rebirths.",
})
Ui.automation("AutoBrew")
box:AddDropdown("BrewPicks", {
    Text = "Brew these",
    Values = BREWABLE,
    Multi = true,
    Default = BREWABLE,
    Tooltip = "Each empty slot gets the chosen potion you have fewest of.",
})
box:AddToggle("AutoCraftPotions", {
    Text = "Auto upgrade potions",
    Default = false,
    Tooltip = "Turns 3 tier I potions into 1 tier II at the potion machine whenever you have enough.",
})
Ui.automation("AutoCraftPotions")
box:AddToggle("AutoDrink", {
    Text = "Auto drink potions",
    Default = false,
    Tooltip = "Drinks each chosen potion again as soon as it runs out, from anywhere. Potions of the same kind add up, so a Coins I and a Coins II both count.",
})
Ui.automation("AutoDrink", true)
box:AddDropdown("DrinkPicks", {
    Text = "Drink these",
    Values = #DRINKABLE > 0 and DRINKABLE or { "Coins Potion I" },
    Multi = true,
    Default = DEFAULT_DRINKS,
    Tooltip = "Octo Incubator (hatch 8 at once) and Enchant Overclocker are here too, off by default.",
})
local label = box:AddLabel("Idle.", true)

local session = { brewed = 0, claimed = 0, merged = 0, drunk = 0 }
local note = ""

local function boosts(data)
    return type(data.Boosts) == "table" and data.Boosts or {}
end

local function slots(data)
    local machine = type(data.PotionMachine) == "table" and data.PotionMachine or {}
    return type(machine.Slots) == "table" and machine.Slots or {}
end

local function brewPrice(data)
    if not BrewConfig then
        return math.huge
    end
    local rebirths = tonumber(type(data.Statistics) == "table" and data.Statistics.Rebirths) or 0
    local ok, price = Env.call(BrewConfig.GetPrice, rebirths)
    return ok and tonumber(price) or math.huge
end

local function gems(data)
    return tonumber(type(data.Currencies) == "table" and data.Currencies.Gems) or 0
end

-- What a visit to the machine would do now: finished slots, empty slots it can fill, merges.
local function machineWork(data)
    local ready, empty = 0, 0
    local now = os.time()
    for slot = 1, SLOTS do
        local entry = slots(data)[tostring(slot)]
        if type(entry) ~= "table" then
            empty += 1
        elseif (tonumber(entry.ReadyAt) or math.huge) <= now then
            ready += 1
        end
    end
    local brew = Ui.on("AutoBrew") and next(Options.BrewPicks.Value or {}) ~= nil
    local work = {
        claim = brew and ready > 0,
        fill = brew and empty > 0 and gems(data) >= brewPrice(data),
        merge = false,
    }
    if Ui.on("AutoCraftPotions") then
        local owned = boosts(data)
        for _, recipe in ipairs(RECIPES) do
            if (tonumber(owned[recipe.Input]) or 0) >= (recipe.Required or 3) then
                work.merge = true
            end
        end
    end
    return work, ready, empty
end

-- The chosen brewable potion you hold the fewest of, counting what is already brewing.
local function nextBrew(data)
    local picks = Options.BrewPicks.Value or {}
    local counts = {}
    for name, count in pairs(boosts(data)) do
        counts[name] = tonumber(count) or 0
    end
    for _, entry in pairs(slots(data)) do
        if type(entry) == "table" and entry.Name then
            counts[entry.Name] = (counts[entry.Name] or 0) + 1
        end
    end
    local best, fewest
    for _, name in ipairs(BREWABLE) do
        if picks[name] and (not best or (counts[name] or 0) < fewest) then
            best, fewest = name, counts[name] or 0
        end
    end
    return best
end

local function root()
    local character = Env.LocalPlayer.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function machinePosition()
    local node = workspace
    for _, name in ipairs(MACHINE) do
        node = node and node:FindFirstChild(name)
    end
    local ok, pivot = false, nil
    if node then
        ok, pivot = pcall(node.GetPivot, node)
    end
    return ok and pivot.Position or MACHINE_FALLBACK
end

local function ask(name, ...)
    local ok, result = Env.invoke("PotionMachineService", name, ...)
    if ok and type(result) == "table" and result.Error == "RateLimited" then
        Life.wait(1)
        ok, result = Env.invoke("PotionMachineService", name, ...)
    end
    if ok and type(result) == "table" and result.Success then
        return result
    end
    return nil, tostring(ok and type(result) == "table" and result.Error or result)
end

local function atMachine()
    local data = Env.data()
    if not data then
        return
    end
    local work, ready = machineWork(data)
    if work.claim then
        local claimed, why = ask("ClaimAll")
        if claimed then
            session.claimed += ready
        else
            note = "Collect refused: " .. why .. "."
        end
        Life.wait(0.4)
    end
    if Ui.on("AutoCraftPotions") then
        for _, recipe in ipairs(RECIPES) do
            while Life.alive and Ui.on("AutoCraftPotions") do
                local current = Env.data()
                if not current or (tonumber(boosts(current)[recipe.Input]) or 0) < (recipe.Required or 3) then
                    break
                end
                local merged, why = ask("Craft", recipe.Output)
                if not merged then
                    note = "Upgrade refused: " .. why .. "."
                    break
                end
                session.merged += 1
                Life.wait(0.3)
            end
        end
    end
    if Ui.on("AutoBrew") then
        for slot = 1, SLOTS do
            local current = Env.data()
            if not current then
                break
            end
            if type(slots(current)[tostring(slot)]) ~= "table" then
                local potion = nextBrew(current)
                if not potion then
                    break
                end
                if gems(current) < brewPrice(current) then
                    note = "Not enough gems to brew."
                    break
                end
                local brewed, why = ask("Brew", potion, slot)
                if not brewed then
                    note = "Brew refused: " .. why .. "."
                    break
                end
                session.brewed += 1
                Life.wait(0.4)
            end
        end
    end
end

local busy = false
local function trip()
    if busy or Ui.hatchMoving or Ui.travelling then
        return
    end
    busy = true
    Ui.travelling = "potions"
    local settle = os.clock() + 6
    while Ui.hatchInFlight and os.clock() < settle do
        Life.wait(0.05)
    end
    local hrp = root()
    local home = hrp and hrp.CFrame
    local ok, err = pcall(function()
        Ui.status = "At the potion machine"
        local target = machinePosition()
        pcall(function()
            Env.LocalPlayer:RequestStreamAroundAsync(target, 10)
        end)
        Env.elevate()
        local here = root()
        if not here then
            return
        end
        here.AssemblyLinearVelocity = Vector3.zero
        here.CFrame = CFrame.new(target + Vector3.new(0, 4, 6))
        Life.wait(0.6)
        atMachine()
    end)
    Env.elevate()
    if not ok then
        Life.errors["potions:trip"] = tostring(err)
        note = "Potion trip error: " .. tostring(err)
    end
    -- The Craft tab's "Return to where I was" covers every machine trip.
    if home and (not Ui.Toggles.CraftReturn or Ui.on("CraftReturn")) then
        local back = root()
        if back then
            back.AssemblyLinearVelocity = Vector3.zero
            back.CFrame = home
        end
    end
    if Ui.status == "At the potion machine" then
        Ui.status = "Idle"
    end
    Ui.travelling = false
    busy = false
end

local nextTrip = 0
Life.loop("potions:machine", 2, function()
    if not (Ui.on("AutoBrew") or Ui.on("AutoCraftPotions")) or busy or os.clock() < nextTrip then
        return
    end
    local data = Env.data()
    if not data then
        return
    end
    local work = machineWork(data)
    if work.claim or work.fill or work.merge then
        nextTrip = os.clock() + 15 -- one visit at a time, and a refused one is not retried at once
        Life.spawn("potions:trip", trip)
    end
end)

-- Drinking --------------------------------------------------------------------------------------

local drinkRefused = {} -- name -> retry after (os.clock)
Life.loop("potions:drink", 2, function()
    if not Ui.on("AutoDrink") then
        return
    end
    local data = Env.data()
    if not data then
        return
    end
    local owned = boosts(data)
    local active = type(data.ActiveBoosts) == "table" and data.ActiveBoosts or {}
    local picks = Options.DrinkPicks.Value or {}
    for _, name in ipairs(DRINKABLE) do
        if picks[name] and (tonumber(owned[name]) or 0) > 0 and not ((tonumber(active[name]) or 0) > 0)
            and (drinkRefused[name] or 0) <= os.clock() then
            local ok, result = Env.invoke("BoostService", "Use", name)
            if ok and type(result) == "table" and result.Success then
                session.drunk += 1
                note = "Drank " .. name .. "."
            else
                drinkRefused[name] = os.clock() + 30
                note = string.format("Could not drink %s: %s.", name,
                    tostring(ok and type(result) == "table" and result.Error or result))
            end
            Life.wait(0.5)
        end
    end
end)

-- Panel -----------------------------------------------------------------------------------------

Life.loop("potions:panel", 1, function()
    local data = Env.data()
    if not data then
        return
    end
    local now = os.time()
    local parts = {}
    for slot = 1, SLOTS do
        local entry = slots(data)[tostring(slot)]
        if type(entry) ~= "table" then
            parts[#parts + 1] = "empty"
        else
            local left = (tonumber(entry.ReadyAt) or now) - now
            local short = tostring(entry.Name or "?"):gsub(" Potion", "")
            parts[#parts + 1] = left > 0 and string.format("%s %d:%02d", short, left // 60, left % 60)
                or (short .. " ready")
        end
    end
    local lines = {
        "Slots: " .. table.concat(parts, ", "),
        string.format("This session: %d brewed, %d collected, %d upgraded, %d drunk", session.brewed,
            session.claimed, session.merged, session.drunk),
    }
    if note ~= "" then
        lines[#lines + 1] = note
    end
    label:SetText(table.concat(lines, "\n"))
end)

Life.onCleanup(function()
    if busy then
        Ui.travelling = false
    end
end)

return {}
end
__modules["features/rewards"] = function(use)
-- Rewards tab: everything the game hands out for free. Offline earnings, finished quests, tap
-- chests and the event spin wheel. Each claim is the game's own remote, fired only when the data
-- says there is something to take, so nothing spams a server that would just reject it.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local tab = Ui.Tabs.Rewards

-- Offline earnings -----------------------------------------------------------------------------

local offlineBox = tab:AddGroupbox({ Side = "Left", Name = "Offline earnings", IconName = "moon" })

local function claimOffline(instant)
    return (Env.invoke("OfflineRewardsService", "Claim", instant == true))
end

offlineBox:AddToggle("AutoClaimOffline", {
    Text = "Claim offline earnings on load",
    Default = true,
    Tooltip = "Claims whatever you banked while away as soon as the hub starts.",
})
offlineBox:AddButton({
    Text = "Claim now",
    Func = function()
        local ok = claimOffline(true)
        Ui.notify("Tap Simulator", ok and "Offline earnings claimed." or "Nothing to claim.", 4)
    end,
})
offlineBox:AddButton({
    Text = "Acknowledge offline hatches",
    Func = function()
        Env.invoke("OfflineRewardsService", "AcknowledgeHatches")
        Ui.notify("Tap Simulator", "Offline hatches acknowledged.", 3)
    end,
})

-- Quests -------------------------------------------------------------------------------------

local questBox = tab:AddGroupbox({ Side = "Left", Name = "Quests", IconName = "scroll-text" })
questBox:AddToggle("AutoClaimQuests", {
    Text = "Auto claim finished quests",
    Default = true,
    Tooltip = "Claims every quest that is complete but unclaimed.",
})
Ui.automation("AutoClaimQuests", true)
local questLabel = questBox:AddLabel("Idle.", true)

local claimedQuests = 0
Life.loop("rewards:quests", 2, function()
    if not Ui.on("AutoClaimQuests") then
        return
    end
    local data = Env.data()
    local quests = data and type(data.Quests) == "table" and data.Quests
    if not quests then
        return
    end
    local pending = 0
    for id, quest in pairs(quests) do
        if type(quest) == "table" and quest.Completed and not quest.Claimed then
            pending += 1
            local ok, res = Env.invoke("QuestService", "ClaimQuest", { Quest = id })
            if ok and (res == nil or type(res) ~= "table" or res.Success ~= false) then
                claimedQuests += 1
            end
            Life.wait(0.3)
        end
    end
    questLabel:SetText(pending > 0
        and string.format("Claimed %d quests this session.", claimedQuests)
        or string.format("No quests ready. %d claimed this session.", claimedQuests))
end)

-- Pet Index rewards ----------------------------------------------------------------------------
--
-- Each egg pays gems once you have found every pet it hatches, again for every pet in Golden,
-- Diamond and Rainbow, and "Secrets" pays when every secret pet is found. The Index screen's Claim
-- button sends PetIndexService.RewardClaimRequested(egg) and the server pays every tier that egg has
-- finished. A refused claim makes the game itself flash "No rewards to claim." with a sound, so this
-- only asks for an egg with a finished, unclaimed tier, and an egg the server turned down is not
-- asked again until you find another of its pets.

local LaunchEggConfig, PetIndexRewardConfig
do
    local ok, eggs = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Pets.LaunchEggConfig)
    end)
    LaunchEggConfig = ok and type(eggs) == "table" and eggs or nil
    local ok2, rewards = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Pets.PetIndexRewardConfig)
    end)
    PetIndexRewardConfig = ok2 and type(rewards) == "table" and rewards or nil
end

-- Reward tiers as PetIndexRewardConfig names them; IndexTiers keys the Rainbow tier "Shiny".
local INDEX_TIERS = { "Normal", "Golden", "Diamond", "Shiny" }

local function petFound(pets, name, tier)
    if tier == "Normal" then
        return type(pets.Index) == "table" and pets.Index[name] == true
    end
    local tiers = type(pets.IndexTiers) == "table" and pets.IndexTiers or {}
    return tiers[name .. "_" .. tier] == true or (tier == "Shiny" and tiers[name .. "_Rainbow"] == true)
end

local function tierClaimed(pets, egg, tier)
    local claimed = type(pets.IndexRewards) == "table" and pets.IndexRewards[egg]
    return type(claimed) == "table" and claimed[tier] == true
end

-- Every egg (plus "Secrets") with a finished tier the server has not paid yet, and how much of its
-- index is found, so a refusal can be remembered until that changes.
local function claimableIndex(pets)
    local list = {}
    if not (LaunchEggConfig and PetIndexRewardConfig) then
        return list
    end
    local secrets, secretsFound = 0, 0
    for egg, def in pairs(LaunchEggConfig) do
        if type(egg) == "string" and type(def) == "table" and type(def.Pets) == "table" then
            local found, ready = 0, false
            local rewards = PetIndexRewardConfig[egg]
            for _, tier in ipairs(INDEX_TIERS) do
                local have, total = 0, 0
                for name in pairs(def.Pets) do
                    total += 1
                    if petFound(pets, name, tier) then
                        have += 1
                    end
                end
                found += have
                if type(rewards) == "table" and type(rewards[tier]) == "number" and total > 0 and have == total
                    and not tierClaimed(pets, egg, tier) then
                    ready = true
                end
            end
            if ready then
                list[#list + 1] = { egg = egg, found = found }
            end
            for name in pairs(type(def.Secrets) == "table" and def.Secrets or {}) do
                secrets += 1
                if petFound(pets, name, "Normal") then
                    secretsFound += 1
                end
            end
        end
    end
    local secretReward = PetIndexRewardConfig.Secrets
    if secrets > 0 and secretsFound == secrets and type(secretReward) == "table"
        and type(secretReward.Complete) == "number" and not tierClaimed(pets, "Secrets", "Complete") then
        list[#list + 1] = { egg = "Secrets", found = secretsFound }
    end
    table.sort(list, function(a, b)
        return a.egg < b.egg
    end)
    return list
end

local indexBox = tab:AddGroupbox({ Side = "Left", Name = "Pet Index", IconName = "book-open" })
indexBox:AddToggle("AutoClaimIndex", {
    Text = "Auto claim index rewards",
    Default = true,
    Tooltip = "Claims the gems for every egg whose index you finish (Normal, Golden, Diamond and Rainbow) and the secret completion reward. Works from anywhere.",
})
Ui.automation("AutoClaimIndex", true)
local indexLabel = indexBox:AddLabel("Idle.", true)

local indexClaimed, indexLast = 0, nil
local indexRefused = {} -- egg -> pets found when the server last refused it
local indexWaiting -- the egg whose answer is pending
Life.spawn("rewards:index-results", function()
    local remote = Env.remote("PetIndexService", "RewardClaimResult")
    Life.connect(remote.OnClientEvent, function(result)
        if not indexWaiting then
            return
        end
        indexWaiting.result = type(result) == "table" and result or { Success = false }
    end)
end)

local function claimIndex(entry)
    local waiting = { egg = entry.egg }
    indexWaiting = waiting
    Env.fire("PetIndexService", "RewardClaimRequested", entry.egg)
    local deadline = os.clock() + 5
    while Life.alive and not waiting.result and os.clock() < deadline do
        Life.wait(0.1)
    end
    indexWaiting = nil
    if waiting.result and waiting.result.Success == true then
        indexClaimed += 1
        indexLast = entry.egg
        indexRefused[entry.egg] = nil
        return true
    end
    indexRefused[entry.egg] = entry.found
    return false
end

local function sweepIndex()
    local data = Env.data()
    local pets = data and type(data.Pets) == "table" and data.Pets
    if not pets then
        return 0
    end
    local claimed = 0
    for _, entry in ipairs(claimableIndex(pets)) do
        if indexRefused[entry.egg] ~= entry.found then
            if claimIndex(entry) then
                claimed += 1
            end
            Life.wait(0.5)
        end
    end
    return claimed
end

indexBox:AddButton({
    Text = "Claim now",
    Func = function()
        Life.spawn("rewards:index-manual", function()
            table.clear(indexRefused)
            local claimed = sweepIndex()
            Ui.notify("Tap Simulator", claimed > 0 and string.format("Claimed %d index rewards.", claimed)
                or "No index rewards to claim.", 4)
        end)
    end,
})

Life.loop("rewards:index", 5, function()
    if not Ui.on("AutoClaimIndex") then
        indexLabel:SetText("Off.")
        return
    end
    if not (LaunchEggConfig and PetIndexRewardConfig) then
        indexLabel:SetText("The game's index config could not be read.")
        return
    end
    sweepIndex()
    indexLabel:SetText(string.format("%d claimed this session%s.", indexClaimed,
        indexLast and (", last: " .. indexLast) or ""))
end)

-- Tap chests ---------------------------------------------------------------------------------

local chestBox = tab:AddGroupbox({ Side = "Right", Name = "Tap chests", IconName = "box" })
chestBox:AddToggle("AutoClaimChests", {
    Text = "Auto claim tap chests",
    Default = true,
    Tooltip = "Claims any tap chest the server shows as ready for you.",
})
Ui.automation("AutoClaimChests", true)
local chestLabel = chestBox:AddLabel("Idle.", true)

local claimedChests = 0
Life.loop("rewards:chests", 3, function()
    if not Ui.on("AutoClaimChests") then
        return
    end
    local data = Env.data()
    local chests = data and type(data.TapChests) == "table" and data.TapChests
    if not chests then
        return
    end
    local any = false
    for id in pairs(chests) do
        any = true
        local ok = Env.invoke("TapChestService", "Claim", id)
        if ok then
            claimedChests += 1
        end
        Life.wait(0.3)
    end
    chestLabel:SetText(any
        and string.format("Tried; %d chests claimed this session.", claimedChests)
        or "No tap chests ready.")
end)

-- Event spin wheel ---------------------------------------------------------------------------

local spinBox = tab:AddGroupbox({ Side = "Right", Name = "Spin wheel", IconName = "disc-3" })
spinBox:AddToggle("AutoSpin", {
    Text = "Auto spin event wheel",
    Default = false,
    Tooltip = "Spins each active event wheel on a timer. The server only gives a spin when one is free.",
})
Ui.automation("AutoSpin", true)
spinBox:AddSlider("SpinEvery", {
    Text = "Spin every",
    Default = 10,
    Min = 3,
    Max = 60,
    Rounding = 0,
    Suffix = "s",
})
local spinLabel = spinBox:AddLabel("Idle.", true)

local lastSpin, spins = 0, 0
Life.loop("rewards:spin", 1, function()
    if not Ui.on("AutoSpin") then
        return
    end
    local every = math.clamp(tonumber(Ui.Options.SpinEvery.Value) or 10, 3, 60)
    if os.clock() - lastSpin < every then
        return
    end
    local data = Env.data()
    local wheels = data and type(data.Spinwheels) == "table" and data.Spinwheels
    if not wheels then
        return
    end
    lastSpin = os.clock()
    local any = false
    for wheel in pairs(wheels) do
        any = true
        local ok = Env.invoke("EventWheelService", "Spin", { WheelType = wheel })
        if ok then
            spins += 1
        end
        Life.wait(0.3)
    end
    spinLabel:SetText(any and string.format("%d spins attempted this session.", spins) or "No event wheel active.")
end)

return {
    afterLoad = function()
        if Ui.on("AutoClaimOffline") then
            Life.spawn("rewards:offline", function()
                Life.wait(1)
                claimOffline(false)
            end)
        end
    end,
}
end
__modules["features/settings"] = function(use)
-- Settings tab (see shared/settings): Tap Simulator configs, and what each missing function changes.

use("core/ui")
local Settings = use("shared/settings")

return Settings.build({
    folder = "TapSimulator",
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
__modules["features/skilltree"] = function(use)
-- Skills tab: buys the whole skill tree for you. Nodes cost gems and gate each other
-- (SubtreeLocked), so this walks every node in the game's config, unlocks the ones you can afford
-- now, and keeps trying -- a node that is SubtreeLocked today opens once its parent is bought.
--
-- SkillTreeService.Unlock { Name } answers { Success, Reason, Price, Missing }. The strong nodes
-- for a tapper are Click Power, Critical, Auto Clicker and Pet Power; auto-unlock just takes them
-- in config order as gems allow.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local tab = Ui.Tabs.Skills
local box = tab:AddGroupbox({ Side = "Left", Name = "Skill tree", IconName = "git-branch" })

-- Every node name in the game's skill tree config (all branches).
local NODES = {}
do
    local ok, cfg = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Progression.SkillTreeConfig)
    end)
    if ok and type(cfg) == "table" then
        local seen = {}
        local function walk(node)
            for _, value in pairs(node) do
                if type(value) == "table" then
                    local name = value.Name
                    if type(name) == "string" and not seen[name] then
                        seen[name] = true
                        NODES[#NODES + 1] = name
                    end
                    walk(value)
                end
            end
        end
        walk(cfg)
    end
end

box:AddToggle("AutoSkillTree", {
    Text = "Auto unlock skill tree",
    Default = false,
    Tooltip = "Buys every skill node you can afford. Nodes cost gems; locked subtrees open as their parent nodes are bought.",
})
Ui.automation("AutoSkillTree", true)
box:AddButton({
    Text = "Unlock all affordable now",
    Func = function()
        Ui.set("AutoSkillTree", true)
        Ui.notify("Tap Simulator", "Unlocking everything you can afford...", 4)
    end,
})
local label = box:AddLabel(string.format("%d skill nodes in the tree.", #NODES), true)

local PACE = 0.3
local unlockedCount = 0

local function isUnlocked(data, node)
    local tree = data and type(data.SkillTree) == "table" and data.SkillTree.Unlocked
    return type(tree) == "table" and tree[node] == true
end

Life.spawn("skills:auto", function()
    while Life.alive do
        if not Ui.on("AutoSkillTree") or #NODES == 0 then
            Life.wait(0.4)
            continue
        end
        local data = Env.data()
        local progressed, blocked, remaining = false, {}, 0
        for _, node in ipairs(NODES) do
            if not (Life.alive and Ui.on("AutoSkillTree")) then
                break
            end
            if not isUnlocked(data, node) then
                remaining += 1
                local ok, res = Env.invoke("SkillTreeService", "Unlock", { Name = node })
                if ok and type(res) == "table" then
                    if res.Success then
                        progressed = true
                        unlockedCount += 1
                        Ui.status = "Unlocking skills"
                        label:SetText(string.format("Unlocked %s (%d this session).", node, unlockedCount))
                        data = Env.data() -- refresh so a freed subtree is seen this pass
                    else
                        local reason = res.Reason or "unavailable"
                        blocked[reason] = (blocked[reason] or 0) + 1
                    end
                end
                Life.wait(PACE)
            end
        end
        if remaining == 0 then
            label:SetText(string.format("Whole skill tree unlocked (%d this session).", unlockedCount))
            Life.wait(5)
        elseif not progressed then
            -- Nothing affordable right now: show why and wait for gems to build up.
            local notes = {}
            for reason, count in pairs(blocked) do
                notes[#notes + 1] = string.format("%s x%d", reason, count)
            end
            table.sort(notes)
            label:SetText(string.format("%d nodes left. Waiting: %s", remaining,
                (table.concat(notes, ", ")):sub(1, 110)))
            Life.wait(3)
        end
    end
end)

return {}
end
__modules["features/tap"] = function(use)
-- Tapping tab: auto tap (the coin engine), the game's own auto clicker, and auto rebirth.
--
-- A tap is TapService.TapRequested { Auto, ClientSequence, Source }: the server credits coins for
-- each one at the player's current tap power, so firing them on a timer is the whole trick. Source
-- names what was pressed ("button" is the tap button, as the game's own client sends it). The
-- server counts at most one tap per GameConfig.ManualTapInterval (0.1s) and drops the rest, so the
-- rate tops out at 10 a second, and the gaps are only ever stretched by the jitter, never shortened
-- below that interval (a real player's taps are never perfectly periodic either).

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local tab = Ui.Tabs.Tapping

-- Auto tap -------------------------------------------------------------------------------------

local MIN_GAP = 0.1
do
    local ok, config = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Core.GameConfig)
    end)
    local interval = ok and type(config) == "table" and tonumber(config.ManualTapInterval)
    if interval and interval > 0 then
        MIN_GAP = interval
    end
end
local MAX_RATE = math.max(1, math.floor(1 / MIN_GAP + 1e-6))

local tapBox = tab:AddGroupbox({ Side = "Left", Name = "Auto tap", IconName = "hand" })
tapBox:AddToggle("AutoTap", {
    Text = "Auto tap",
    Default = false,
    Tooltip = "Fires taps on a timer. Earns coins exactly as tapping does, at your current tap power.",
})
Ui.automation("AutoTap", true)
tapBox:AddSlider("TapRate", {
    Text = "Taps per second",
    Default = MAX_RATE,
    Min = 1,
    Max = MAX_RATE,
    Rounding = 0,
    Suffix = "/s",
    Tooltip = string.format("The server counts at most %d taps a second and throws faster ones away.", MAX_RATE),
})
local tapLabel = tapBox:AddLabel("Auto tap is off.", true)

-- The server only takes a tap whose ClientSequence is above the last one it took from you this
-- session, and drops the rest without a word. A reloaded hub that counted from 0 again was ignored
-- until it caught up with the copy before it, so the count lives in the executor's globals and
-- carries on across reloads. Every accepted tap is answered on TapResult; if a run of taps gets no
-- answer (the game's own taps or another script got ahead), the count jumps forward until they do.
local SEQUENCE_KEY = "__NOXTapSequence"
local STALL_TAPS, STALL_SECONDS = 25, 2
local sequence = tonumber(Env.genv[SEQUENCE_KEY]) or 0
local lastAnswer, unanswered, resyncs = os.clock(), 0, 0

Life.spawn("tap:results", function()
    local results = Env.remote("TapService", "TapResult")
    Life.connect(results.OnClientEvent, function(result)
        if type(result) == "table" and result.ClientSequence ~= nil then
            lastAnswer, unanswered = os.clock(), 0
        end
    end)
end)

Life.spawn("tap:auto", function()
    local remote = Env.remote("TapService", "TapRequested")
    local session = 0
    while Life.alive do
        if Ui.on("AutoTap") then
            if unanswered >= STALL_TAPS and os.clock() - lastAnswer > STALL_SECONDS then
                sequence = math.max(sequence * 2, sequence + 1000000)
                lastAnswer, unanswered = os.clock(), 0
                resyncs += 1
            end
            sequence += 1
            session += 1
            unanswered += 1
            Env.genv[SEQUENCE_KEY] = sequence
            Env.elevate()
            remote:FireServer({ Auto = false, ClientSequence = sequence, Source = "button" })
            -- Tapping runs under everything else; it only names itself when nothing else has.
            if not Ui.status or Ui.status == "Idle" or Ui.status == "Off" then
                Ui.status = "Auto tapping"
            end
            if session % 11 == 0 then
                tapLabel:SetText(string.format("Tapped %d times this session.%s", session,
                    os.clock() - lastAnswer > STALL_SECONDS and "\nThe server is not answering taps; re-syncing."
                        or resyncs > 0 and string.format(" Re-synced %d times.", resyncs) or ""))
            end
            local rate = math.clamp(tonumber(Options.TapRate.Value) or MAX_RATE, 1, MAX_RATE)
            -- Jitter only lengthens a gap: one under the server's interval is a tap thrown away.
            local gap = math.max(1 / rate, MIN_GAP * 1.04)
            Life.wait(gap * (1 + math.random() * 0.12))
        else
            if Ui.status == "Auto tapping" then
                Ui.status = "Idle"
            end
            Life.wait(0.2)
        end
    end
end)

-- Auto clicker (the game's own) -----------------------------------------------------------------

local clickBox = tab:AddGroupbox({ Side = "Left", Name = "Auto clicker", IconName = "mouse-pointer-click" })
clickBox:AddToggle("AutoClicker", {
    Text = "Enable auto clicker",
    Default = false,
    Tooltip = "Turns on the game's built-in auto clicker (needs the auto-clicker unlock or gamepass).",
})
clickBox:AddLabel("Uses the game's own auto clicker. If you do not own it, the server ignores this.", true)

Ui.Toggles.AutoClicker:OnChanged(function(on)
    Env.fire("AutoClickService", "AutoClickRequested", { Enabled = on == true })
end)

-- Auto rebirth ---------------------------------------------------------------------------------
--
-- RebirthRequested { Index } buys 5^(Index-1) rebirths, all at the price for your current rebirth
-- count (Shared.Progression.RebirthConfig), so the biggest pack you can afford is the cheapest per
-- rebirth; any single pack can be pinned instead. The game has GetMaximumOptions(world) buttons (14
-- on the main world) and you have unlocked 1 + Upgrades.RebirthButtons of them (RebirthButtonConfig).
-- Every button is listed, but a locked one is never pressed. With the Auto Rebirth skill the request
-- is flagged Auto, exactly as the game's own auto rebirth sends it, and never more often than its
-- 1.5 seconds.

local function shared(...)
    local path = { ... }
    local ok, module = Env.call(function()
        local node = Env.ReplicatedStorage.Shared
        for _, part in ipairs(path) do
            node = node:FindFirstChild(part)
        end
        return node and require(node)
    end)
    return ok and module or nil
end
local RebirthConfig = shared("Progression", "RebirthConfig")
local RebirthButtonConfig = shared("Progression", "RebirthButtonConfig")
local SkillTreeFormula = shared("Progression", "SkillTreeFormula")

local REBIRTH_GAP = 1.5

local function worldOf(data)
    return data and type(data.Progression) == "table" and data.Progression.World or "Main"
end

local function coinsOf(data)
    return tonumber(type(data.Currencies) == "table" and data.Currencies.Coins) or 0
end

-- How many buttons you have unlocked.
local function buttonCount(data)
    local upgrades = type(data.Upgrades) == "table" and data.Upgrades.RebirthButtons or 0
    if RebirthButtonConfig then
        local ok, count = Env.call(function()
            local world = worldOf(data)
            return RebirthButtonConfig.GetOptionCount(RebirthButtonConfig.GetUnlockedCount(upgrades, world), world)
        end)
        if ok and type(count) == "number" then
            return count
        end
    end
    return 1 + math.clamp(math.floor(tonumber(upgrades) or 0), 0, 13)
end

-- How many buttons the game has on this world, unlocked or not.
local function allButtons(data)
    if RebirthButtonConfig then
        local ok, count = Env.call(RebirthButtonConfig.GetMaximumOptions, worldOf(data))
        if ok and type(count) == "number" then
            return count
        end
    end
    return 14
end

local function packAmount(index)
    if RebirthConfig then
        local ok, amount = Env.call(RebirthConfig.GetAmountFromIndex, index)
        if ok and type(amount) == "number" then
            return amount
        end
    end
    return 5 ^ (index - 1)
end

local function packPrice(data, index)
    if not RebirthConfig then
        return nil
    end
    local rebirths = tonumber(type(data.Statistics) == "table" and data.Statistics.Rebirths) or 0
    local ok, price = Env.call(RebirthConfig.GetPrice, packAmount(index), rebirths)
    return ok and type(price) == "number" and price or nil
end

-- The biggest unlocked pack you can afford now, or nil.
local function bestPack(data)
    local coins = coinsOf(data)
    for index = buttonCount(data), 1, -1 do
        local price = packPrice(data, index)
        if price and price <= coins then
            return index
        end
    end
    return nil
end

local function hasAutoRebirth(data)
    if not SkillTreeFormula then
        return false
    end
    local ok, value = Env.call(SkillTreeFormula.HasAutoRebirth, data)
    return ok and value == true
end

local function short(n)
    for _, unit in ipairs({ { 1e33, "Dc" }, { 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" }, { 1e21, "Sx" }, { 1e18, "Qi" },
        { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= unit[1] then
            return string.format("%.1f%s", n / unit[1], unit[2])
        end
    end
    return tostring(math.floor(n))
end

local BIGGEST = "Biggest I can afford"
local packLabels, packIndex = { BIGGEST }, {}
for index = 1, allButtons(Env.data()) do
    local label = string.format("x%s rebirths (button %d)", short(packAmount(index)), index)
    packLabels[#packLabels + 1] = label
    packIndex[label] = index
end

local rebirthBox = tab:AddGroupbox({ Side = "Right", Name = "Rebirth", IconName = "rotate-ccw" })
rebirthBox:AddToggle("AutoRebirth", {
    Text = "Auto rebirth",
    Default = false,
    Tooltip = "Presses the chosen rebirth pack whenever you can afford it, as often as the game allows.",
})
Ui.automation("AutoRebirth", true)
rebirthBox:AddDropdown("RebirthPack", {
    Text = "Pack",
    Values = packLabels,
    Default = BIGGEST,
    Tooltip = "Every rebirth button in the game. 'Biggest I can afford' is the cheapest per rebirth, since a pack is priced at your current rebirth count. A pinned pack waits until you can afford it; a locked one (more come from the Rebirth Buttons upgrade) is never pressed.",
})
local rebirthLabel = rebirthBox:AddLabel("Auto rebirth is off.", true)

-- The pack to press now, or nil and why not.
local function choosePack(data)
    local pinned = packIndex[Options.RebirthPack.Value or ""]
    if not pinned then
        local index = bestPack(data)
        return index, index == nil and "saving coins for x1" or nil
    end
    local unlocked = buttonCount(data)
    if pinned > unlocked then
        return nil, string.format("button %d is locked (you have %d; the Rebirth Buttons upgrade unlocks more)", pinned, unlocked)
    end
    local price = packPrice(data, pinned)
    if not price then
        return nil, "rebirth prices are unavailable"
    end
    if price > coinsOf(data) then
        return nil, string.format("saving for x%s (%s coins)", short(packAmount(pinned)), short(price))
    end
    return pinned
end

local lastRebirth, rebirthed = -math.huge, 0
local function rebirthNow(data)
    local index, why = choosePack(data)
    if not index then
        return false, why
    end
    lastRebirth = os.clock()
    local payload = hasAutoRebirth(data) and { Auto = true, Index = index } or { Index = index }
    Env.fire("RebirthService", "RebirthRequested", payload)
    rebirthed += packAmount(index)
    return true, index
end

rebirthBox:AddButton({
    Text = "Rebirth now",
    Func = function()
        local data = Env.data()
        if not data then
            return
        end
        local ok, result = rebirthNow(data)
        Ui.notify("Tap Simulator", ok and string.format("Rebirthing x%s (button %d).", short(packAmount(result)), result)
            or ("Not rebirthing: " .. tostring(result) .. "."), 3)
    end,
})

Life.loop("tap:rebirth", 0.25, function()
    local data = Env.data()
    if not data then
        return
    end
    local index, why = choosePack(data)
    local upcoming = index and string.format("x%s for %s coins (button %d of %d)", short(packAmount(index)),
        short(packPrice(data, index) or 0), index, buttonCount(data)) or why
    if not Ui.on("AutoRebirth") then
        rebirthLabel:SetText("Off. Next: " .. tostring(upcoming) .. ".")
        return
    end
    if index and os.clock() - lastRebirth >= REBIRTH_GAP then
        rebirthNow(data)
    end
    rebirthLabel:SetText(string.format("%s this session. Next: %s.", short(rebirthed), tostring(upcoming)))
end)

return {}
end
__modules["features/treats"] = function(use)
-- Pets tab (right): feed treats to the team. Treats (from digging, quests and drops) give pet XP,
-- and a pet's level multiplies its power, so they are worth more on the pets you actually use.
--
-- ItemService.UseOnPet { Item, PetId, Amount } is what the game sends when you drag a treat onto a
-- pet; it answers { Success, Kind, Amount, LevelsGained, Level, ... }. Only items the game marks as
-- pet treats or pet levels (Shared.Items.ItemBehaviorConfig) are offered, one at a time to the
-- lowest-level equipped pet that is below its rarity's cap (Shared.Pets.PetLevelConfig), so the
-- whole team climbs together. Pet levels unlock once the bridge is lowered.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local tab = Ui.Tabs.Pets

local ItemBehaviorConfig, PetLevelConfig
do
    local ok, items = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Items.ItemBehaviorConfig)
    end)
    ItemBehaviorConfig = ok and type(items) == "table" and items or nil
    local ok2, levels = Env.call(function()
        return require(Env.ReplicatedStorage.Shared.Pets.PetLevelConfig)
    end)
    PetLevelConfig = ok2 and type(levels) == "table" and levels or nil
end

local TREAT_KINDS = { PetTreat = true, PetLevels = true }
-- The plain XP treats digging and quests hand out; fruits and shards are rarer and left to you.
local DEFAULT_PICKS = { RegularTreat = true, BagOfTreats = true }
local PACE = 0.35

local treatNames, defaults = {}, {}
for name, behavior in pairs(ItemBehaviorConfig or {}) do
    if type(behavior) == "table" and TREAT_KINDS[behavior.Kind] and behavior.Availability == "Active" then
        treatNames[#treatNames + 1] = name
    end
end
table.sort(treatNames)
for _, name in ipairs(treatNames) do
    if DEFAULT_PICKS[name] then
        defaults[#defaults + 1] = name
    end
end

local box = tab:AddGroupbox({ Side = "Right", Name = "Treats", IconName = "cookie" })
box:AddToggle("AutoTreats", {
    Text = "Auto feed treats",
    Default = false,
    Tooltip = "Feeds the chosen treats to your equipped pets, lowest level first, skipping pets at their level cap.",
})
Ui.automation("AutoTreats", true)
box:AddDropdown("TreatPicks", {
    Text = "Use these",
    Values = #treatNames > 0 and treatNames or { "RegularTreat", "BagOfTreats" },
    Multi = true,
    Default = defaults,
    Tooltip = "Treat and Bag of Treats come from digging. Fruits, Golden Apples and shards are rarer; pick them only if you mean to spend them.",
})
local label = box:AddLabel("Auto feed is off.", true)

local function maxLevel(pet)
    if PetLevelConfig then
        local ok, cap = Env.call(PetLevelConfig.GetMaxLevel, pet.Rarity or "Common")
        if ok and type(cap) == "number" then
            return cap
        end
    end
    return 50
end

-- Equipped pets below their cap, lowest level (then least XP) first.
local function hungryPets(data)
    local pets = type(data.Pets) == "table" and data.Pets
    if not pets or type(pets.Equipped) ~= "table" or type(pets.Owned) ~= "table" then
        return {}
    end
    local list = {}
    for _, id in pairs(pets.Equipped) do
        local pet = pets.Owned[id]
        if type(pet) == "table" and (tonumber(pet.Level) or 1) < maxLevel(pet) then
            list[#list + 1] = { id = id, pet = pet }
        end
    end
    table.sort(list, function(a, b)
        local la, lb = tonumber(a.pet.Level) or 1, tonumber(b.pet.Level) or 1
        if la ~= lb then
            return la < lb
        end
        return (tonumber(a.pet.XP) or 0) < (tonumber(b.pet.XP) or 0)
    end)
    return list
end

local session = { fed = 0, levels = 0, used = {} }
local refused = {} -- item .. "|" .. pet id -> retry after (os.clock)
local note = ""

local function feedOnce(data)
    local owned = type(data.Items) == "table" and type(data.Items.Owned) == "table" and data.Items.Owned or {}
    local picks = Options.TreatPicks.Value or {}
    local pets = hungryPets(data)
    if #pets == 0 then
        return false, "Every equipped pet is at its level cap."
    end
    for _, item in ipairs(treatNames) do
        if picks[item] and (tonumber(owned[item]) or 0) > 0 then
            for _, entry in ipairs(pets) do
                local key = item .. "|" .. entry.id
                if (refused[key] or 0) <= os.clock() then
                    local ok, result = Env.invoke("ItemService", "UseOnPet", { Item = item, PetId = entry.id, Amount = 1 })
                    if ok and type(result) == "table" and result.Success == true then
                        session.fed += 1
                        session.levels += tonumber(result.LevelsGained) or 0
                        session.used[item] = (session.used[item] or 0) + 1
                        note = string.format("Last: %s on %s (level %s).", item, tostring(entry.pet.Name), tostring(result.Level or entry.pet.Level))
                        return true
                    end
                    refused[key] = os.clock() + 60
                    note = string.format("%s on %s refused: %s.", item, tostring(entry.pet.Name),
                        tostring(type(result) == "table" and (result.Reason or result.Error) or result))
                end
            end
        end
    end
    return false, "No chosen treats left."
end

Life.spawn("pets:treats", function()
    while Life.alive do
        local data = Env.data()
        local wait = 1
        if not Ui.on("AutoTreats") then
            label:SetText("Off.")
        elseif not ItemBehaviorConfig then
            label:SetText("The game's item config could not be read.")
        elseif data and PetLevelConfig and type(data.Progression) == "table" and data.Progression.BridgeLowered ~= true then
            label:SetText("Pet levels unlock once the bridge is lowered.")
        elseif data then
            local fed, why = feedOnce(data)
            local parts = {}
            for item, count in pairs(session.used) do
                parts[#parts + 1] = string.format("%d %s", count, item)
            end
            table.sort(parts)
            label:SetText(string.format("%s%d treats fed this session (+%d levels)%s.%s",
                fed and "" or (tostring(why) .. "\n"), session.fed, session.levels,
                #parts > 0 and (": " .. table.concat(parts, ", ")) or "", note ~= "" and ("\n" .. note) or ""))
            wait = fed and PACE or 3
        end
        Life.wait(wait)
    end
end)

return {}
end
__modules["features/upgrades"] = function(use)
-- Upgrades (Tapping tab, right): buys the tap upgrades for you. ClickMultiplier and CriticalChance
-- raise what every tap is worth, so keeping them maxed is the biggest lever after auto tap itself.
--
-- UpgradeService.Purchase { Name } answers { Success, Reason, Current }. The server rate-limits
-- purchases and locks some behind zones (Reason "RateLimited" / "ZoneLocked"), so this paces itself
-- and skips what it cannot buy yet instead of hammering a locked upgrade.

local Env = use("core/env")
local Life = use("shared/life")
local Ui = use("core/ui")

local Options = Ui.Options
local tab = Ui.Tabs.Tapping
local box = tab:AddGroupbox({ Side = "Right", Name = "Upgrades", IconName = "trending-up" })

-- The buyable upgrades, from the game's own config when it is readable.
local ORDER = { "FreeAutoClicker", "ClickMultiplier", "HatchSpeed", "CriticalChance", "AutoClickerSpeed", "Teleport" }
local ok, cfg = Env.call(function()
    return require(Env.ReplicatedStorage.Shared.Progression.UpgradeConfig)
end)
if ok and type(cfg) == "table" and type(cfg.Order) == "table" and #cfg.Order > 0 then
    ORDER = cfg.Order
end

box:AddToggle("AutoUpgrade", {
    Text = "Auto buy upgrades",
    Default = false,
    Tooltip = "Buys the chosen upgrades whenever you can afford one. Skips upgrades locked to a zone you have not reached.",
})
Ui.automation("AutoUpgrade", true)
box:AddDropdown("UpgradePicks", {
    Text = "Buy these",
    Values = ORDER,
    Multi = true,
    Default = ORDER, -- everything by default
    Tooltip = "ClickMultiplier and CriticalChance pay back fastest for a tapper.",
})
local label = box:AddLabel("Auto buy is off.", true)

local PACE = 0.4 -- seconds between purchase attempts (the server rate-limits)
local bought, blocked = 0, {}

Life.spawn("tap:upgrades", function()
    while Life.alive do
        if not Ui.on("AutoUpgrade") then
            Life.wait(0.3)
            continue
        end
        local picks = Options.UpgradePicks.Value or {}
        local progressed = false
        for _, name in ipairs(ORDER) do
            if not (Life.alive and Ui.on("AutoUpgrade")) then
                break
            end
            if picks[name] then
                local ok2, res = Env.invoke("UpgradeService", "Purchase", { Name = name })
                if ok2 and type(res) == "table" then
                    if res.Success then
                        bought += 1
                        progressed = true
                        blocked[name] = nil
                        Ui.status = "Bought " .. name
                        label:SetText(string.format("Bought %s (level %s). %d upgrades this session.",
                            name, tostring(res.Current or "?"), bought))
                    elseif res.Reason == "RateLimited" then
                        Life.wait(0.3)
                    else
                        blocked[name] = res.Reason or "unavailable"
                    end
                end
                Life.wait(PACE)
            end
        end
        if not progressed then
            -- Nothing bought this pass: report why and wait a little longer before trying again.
            local notes = {}
            for name, reason in pairs(blocked) do
                notes[#notes + 1] = name .. ": " .. reason
            end
            table.sort(notes)
            if #notes > 0 then
                label:SetText("Waiting: " .. table.concat(notes, ", "):sub(1, 120))
            end
            Life.wait(2)
        end
    end
end)

return {}
end
__modules["main"] = function(use)
-- Entry point. Core first, then features in tab order, then settings (autoload last).

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Env = use("core/env")

-- Nothing is built until the replica and character are there (see core/ready).
use("core/ready").wait()

-- The whole hub reads the player's Replica through the game's DataController. An executor that
-- cannot require it cannot run the hub, so that is said once here instead of every feature failing.
local canRead, readError = pcall(function()
    return Env.preloadData() ~= nil
end)
Env.elevate()
if not canRead or not Env.data() then
    error("could not read your game data (Replica/DataController): " .. tostring(readError), 0)
end

-- A copy already running is closed first (two hubs fighting over the UI).
local previous = Env.genv.__NOX
if type(previous) == "table" and type(previous.Ui) == "table" and previous.Ui.Library then
    pcall(previous.Ui.Library.Unload, previous.Ui.Library)
    Env.genv.__NOX = nil
    Env.elevate()
end

local Life = use("shared/life")
local Ui = use("core/ui")

local FEATURES = {
    "features/home",
    "features/performance",
    "features/tap",
    "features/upgrades",
    "features/hatch",
    "features/pets",
    "features/treats",
    "features/enchant",
    "features/craft",
    "features/potions",
    "features/skilltree",
    "features/rewards",
    "features/pickups",
    "features/dig",
    "features/defense",
    "features/mining",
}

local function load(name)
    local ok, result = xpcall(use, debug.traceback, name)
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
    Settings.finish()
end

-- After the autoload, so a saved "Claim offline earnings on load: off" is respected.
local Rewards = loaded["features/rewards"]
if Rewards and type(Rewards.afterLoad) == "function" then
    pcall(Rewards.afterLoad)
end

Env.genv.__NOX = {
    Ui = Ui,
    Life = Life,
    Features = loaded,
}
Life.onCleanup(function()
    Env.genv.__NOX = nil
end)

if Env.RuntimeState then
    Env.RuntimeState.onCleanup(function()
        Env.elevate()
        pcall(function()
            Ui.Library:Unload()
        end)
    end)
end

return "NOX loaded"
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
