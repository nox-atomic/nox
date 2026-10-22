if not game:IsLoaded() then
    game.Loaded:Wait()
end

local BASE = 'https://raw.githubusercontent.com/nox-atomic/nox/main/games/'

local games = {
    [828376264] = '158926407.lua',
    [998753178] = '268491735.lua',
    [PLACEID] = '315806492.lua',
    [PLACEID] = '395718624.lua',
    [PLACEID] = '407193826.lua',
    [PLACEID] = '482719635.lua',
    [PLACEID] = '519837264.lua',
    [PLACEID] = '573820194.lua',
    [PLACEID] = '627403819.lua',
    [PLACEID] = '682941573.lua',
    [PLACEID] = '694218573.lua',
    [PLACEID] = '731906482.lua',
    [PLACEID] = '742581936.lua',
    [PLACEID] = '804627391.lua',
    [PLACEID] = '827405193.lua',
    [PLACEID] = '863205719.lua',
    [PLACEID] = '916382745.lua',
}

local file = games[game.PlaceId] or games[game.CreatorId]

if file then
    task.wait(math.random())
    pcall(function()
        loadstring(game:HttpGet(BASE .. file))()
    end)
end
