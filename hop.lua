--[[
    ============================================================================
    AUTO HOP — standalone server hopper
    Server dipilih RANDOM (exclude server saat ini + yang full), bisa prefer
    yang paling sepi. Auto Send Chat dengan rotasi 3 pesan + countdown.

    Auto-execute: pas hop, queueonteleport nge-download script dari URL
    (github raw) terus loadstring - jadi file ini cukup di-upload ke URL itu
    dan semua perubahan langsung ke-sync.

    Config: StealAnEgg/autoHop.json
    ============================================================================
]]

-- single-instance guard: instance lama langsung mati pas versi baru di-run
local MY_RUN = os.clock()
getgenv().__AUTOHOP_ACTIVE = MY_RUN

local Players      = game:GetService("Players")
local HS           = game:GetService("HttpService")
local TS           = game:GetService("TeleportService")
local LocalPlayer  = Players.LocalPlayer
local PLACE        = game.PlaceId

-- URL auto-execute (download ulang script dari sini setelah hop)
local LOADER_URL = "https://raw.githubusercontent.com/JualNasiRendang/loader/refs/heads/main/hop.lua"

-- ============================ config ============================
local CFG_FOLDER = "StealAnEgg"
local CFG_PATH   = CFG_FOLDER .. "/autoHop.json"

local S = {
    autoHop         = true,
    hopWhen         = "Any",          -- "After Steal Count" | "Interval" | "No Match" | "Any"
    hopNoMatchDelay = 60,             -- detik tanpa claim
    hopInterval     = 15,             -- menit
    hopSteals       = 50,             -- jumlah claim
    hopMinPlayers   = 3,              -- target: server isi >= ini (0 = off)
    hopMaxPlayers   = 0,              -- target: server isi <= ini (0 = off)
    hopPreferEmpty  = true,
    autoChat        = false,
    chatText        = "",
    chatText2       = "",
    chatText3       = "",
    chatInterval    = 30,
    -- auto accept friends (via mekanisme notifikasi friend request game)
    autoAcceptFriends = true,
    -- camera lock (offset relatif ke karakter, tersimpan ke config)
    camLock         = false,
    camOffX         = 0,
    camOffY         = 40,
    camOffZ         = 0,
    camFov          = 70,
}

local function saveConfig()
    pcall(function()
        if type(makefolder) == "function" then pcall(makefolder, CFG_FOLDER) end
        if type(writefile) == "function" then writefile(CFG_PATH, HS:JSONEncode(S)) end
    end)
end
local function loadConfig()
    if type(readfile) ~= "function" then return end
    local ok, data = pcall(readfile, CFG_PATH)
    if not (ok and data) then return end
    local ok2, tbl = pcall(function() return HS:JSONDecode(data) end)
    if ok2 and type(tbl) == "table" then for k, v in pairs(tbl) do S[k] = v end end
end
loadConfig()

-- forward-declare biar doHop() di bawah ga manggil global yang belum ada
local armAutoExec

-- ==================== steal tracker (claim counter) ====================
-- PATCH 2026-08: ReplicatedStorage.Library UDAH DIHAPUS (jadi Shared/Data/Client) dan
-- remote pindah ke Packages.Networking. Versi lama require Library.Client.EggCmds di
-- dalam pcall -> gagalnya SENYAP -> claims ga pernah nambah -> mode "After Steal Count"
-- ga pernah kepicu & "No Match" nyala terus. Sekarang: remote baru dulu, lama cadangan.
local claims, lastClaim = 0, os.clock()
local function bumpClaim()
    claims = claims + 1
    lastClaim = os.clock()
end
do
    local RS = game:GetService("ReplicatedStorage")
    local hooked = false
    -- jalur BARU: RE/EggWorld/FieldEggRedeemVerdict (hasil klaim telur)
    pcall(function()
        local net = RS:FindFirstChild("Packages") and RS.Packages:FindFirstChild("Networking")
        local ev = net and net:FindFirstChild("RE/EggWorld/FieldEggRedeemVerdict")
        if ev and ev:IsA("RemoteEvent") then
            ev.OnClientEvent:Connect(function(ok)
                if ok == nil or ok == true or (type(ok) == "table" and ok.Ok ~= false) then bumpClaim() end
            end)
            hooked = true
        end
    end)
    -- jalur LAMA (kalau server rollback)
    if not hooked then
        pcall(function()
            local EggCmds = require(RS.Library.Client.EggCmds)
            EggCmds.AreaEggClaimed:Connect(bumpClaim)
            hooked = true
        end)
    end
    -- CADANGAN TERAKHIR: pantau jumlah telur milik sendiri, naik = ada claim.
    -- Ini yang bikin counter tetep jalan walau nama remote berubah lagi nanti.
    if not hooked then
        task.spawn(function()
            local ES = nil
            pcall(function() ES = require(RS.Client.EggState) end)
            if not (ES and type(ES.ReadOwnedEggs) == "function") then return end
            local function countMine()
                local n = 0
                pcall(function()
                    for _, e in pairs(ES.ReadOwnedEggs() or {}) do
                        if type(e) == "table" and e.OwnerUserId == LocalPlayer.UserId and type(e.Records) == "table" then
                            for _ in pairs(e.Records) do n = n + 1 end
                        end
                    end
                end)
                return n
            end
            local prev = countMine()
            while getgenv().__AUTOHOP_ACTIVE == MY_RUN do
                task.wait(2)
                local cur = countMine()
                if cur > prev then for _ = 1, (cur - prev) do bumpClaim() end end
                prev = cur
            end
        end)
    end
end

-- ==================== server list ====================
local lastFetch, lastList = 0, nil
local function fetchServers()
    -- cache 15 detik: API Roblox rate-limit kalo di-spam (429) - jangan
    -- hammer tiap 5 detik, pake hasil yang barusan
    local now = os.clock()
    if lastList and (now - lastFetch) < 15 then
        return lastList
    end
    local function httpGet(url)
        local res
        local function try(fn)
            local ok, r = pcall(fn)
            if ok and type(r) == "string" and #r > 0 then
                -- VALIDASI: respons harus JSON dengan .data yang ISI (>0 entry).
                -- Proxy Volt suka balikin error {"errors":[{"code":0}]} ATAU
                -- respons yang data-nya dikosongin - dua-duanya ditolak biar
                -- fallback ke method berikutnya.
                local ok2, d = pcall(function() return HS:JSONDecode(r) end)
                if ok2 and type(d) == "table" and type(d.data) == "table" and #d.data > 0 then
                    res = r
                    return true
                end
            end
            return false
        end
        -- request/http_request DULU (terbukti dapet data asli dari client),
        -- baru game:HttpGet, terakhir GetAsync
        pcall(function() try(function() return (request or http_request or (http and http.request))({ Url = url, Method = "GET" }).Body end) end)
        if not res then pcall(function() try(function() return game:HttpGet(url) end) end) end
        if not res then pcall(function() try(function() return game:GetService("HttpService"):GetAsync(url) end) end) end
        return res
    end
    local list = {}
    -- sortOrder=Asc: dari paling sepi. Server 0-2 player di halaman awal
    -- ke-skip sama filter min (3), jadi di-paginasi jauh (maks 10 halaman)
    -- sampe ketemu yang isinya >= min. Server penuh (7/7) tetep ditolak.
    local cursor = ""
    local pages = 0
    local sample = nil
    for _ = 1, 10 do -- maks 10 halaman (1000 server)
        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s"):format(
            PLACE, cursor ~= "" and ("&cursor=" .. HS:UrlEncode(cursor)) or "")
        local body
        for attempt = 1, 3 do
            body = httpGet(url)
            if body then break end
            task.wait(3 * attempt) -- backoff buat 429 rate-limit
        end
        if not body then break end
        local ok2, data = pcall(function() return HS:JSONDecode(body) end)
        if not ok2 or type(data) ~= "table" or type(data.data) ~= "table" then break end
        pages = pages + 1
        if #data.data > 0 and not sample then sample = data.data[1] end
        for _, s in ipairs(data.data) do
            if s.id and s.id ~= game.JobId and type(s.playing) == "number" and s.playing < (s.maxPlayers or 999) then
                -- filter rentang player (0 = off). Contoh min=3 max=4 =
                -- cari server yang isinya 3-4 player.
                local okMin = (S.hopMinPlayers or 0) <= 0 or s.playing >= (S.hopMinPlayers or 0)
                local okMax = (S.hopMaxPlayers or 0) <= 0 or s.playing <= (S.hopMaxPlayers or 0)
                if okMin and okMax then
                    list[#list + 1] = s
                end
            end
        end
        if #list >= 30 then break end -- udah cukup buat dipilih acak
        if type(data.nextPageCursor) == "string" and data.nextPageCursor ~= "" then
            cursor = data.nextPageCursor
        else
            break
        end
    end
    print(("[AutoHop] scan: %d halaman | %d server ditemukan"):format(pages, #list))
    if #list == 0 and sample then
        -- debug: halaman kebaca tapi ga ada yang lolos filter - kemungkinan
        -- struktur datanya beda, dump entry pertama buat dianalisa
        print("[AutoHop] sample entry: " .. HS:JSONEncode(sample))
    end
    if pages == 0 then
        -- debug: tampilin isi respons API biar keliatan error-nya apa
        -- (429 rate-limit / place invalid / dll)
        local lastBody
        pcall(function()
            lastBody = httpGet(("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100"):format(PLACE))
        end)
        if lastBody then
            print("[AutoHop] API response: " .. tostring(lastBody):sub(1, 200))
        else
            print("[AutoHop] API response: (semua method HTTP gagal)")
        end
    end
    lastFetch, lastList = os.clock(), list
    return list
end

-- ==================== hop ====================
local hopping = false
local function doHop()
    if hopping then return false end
    hopping = true
    armAutoExec() -- re-inject diri sendiri di server baru via URL
    local cands = fetchServers()
    if #cands == 0 then
        -- ga ada server yang masuk rentang player: jangan matchmake (bisa
        -- balik ke server yang sama). Refresh cache biar retry berikutnya
        -- fetch ulang beneran, loop cek lagi 5 detik kemudian.
        hopping = false
        lastFetch = 0
        return false
    end
    -- Prefer empty: ambil tier paling sepi (min player +1) terus shuffle biar
    -- ga nyangkut di job mati yang sama terus. Kalo off: shuffle semua kandidat.
    if S.hopPreferEmpty then
        table.sort(cands, function(a, b) return a.playing < b.playing end)
        local minP = cands[1].playing
        local tier = {}
        for _, s in ipairs(cands) do if s.playing <= minP + 1 then tier[#tier + 1] = s end end
        cands = tier
    end
    for i = #cands, 2, -1 do local j = math.random(i); cands[i], cands[j] = cands[j], cands[i] end
    -- Coba kandidat satu-satu; TeleportInitFailed (server stale/penuh) -> next.
    local idx, conn = 0, nil
    local function tryNext()
        idx = idx + 1
        local s = cands[idx]
        if not s then
            if conn then conn:Disconnect() end
            -- kandidat abis semua: jangan matchmake (bisa balik ke server
            -- yang sama). Refresh cache biar scan berikutnya dapet server
            -- fresh (list API sering isinya job mati/stale).
            hopping = false
            lastFetch = 0
            return
        end
        pcall(function() TS:TeleportToPlaceInstance(PLACE, s.id, LocalPlayer) end)
    end
    conn = TS.TeleportInitFailed:Connect(function(plr)
        if plr == LocalPlayer then tryNext() end
    end)
    tryNext()
    -- SAFETY: kalau teleport gagal SENYAP (ga fire TeleportInitFailed), dulu `hopping`
    -- nyangkut true selamanya -> auto-hop mati total sampai rejoin. Sekarang auto-lepas.
    task.delay(25, function()
        if hopping then
            hopping = false
            lastFetch = 0
            if conn then pcall(function() conn:Disconnect() end) end
            print("[AutoHop] hop timeout - dilepas, coba lagi nanti")
        end
    end)
    return true
end

-- ==================== kondisi hop ====================
local hopStart, hopBaseClaims = os.clock(), claims
local function hopReady()
    local m = S.hopWhen
    if m == "After Steal Count" then
        return (claims - hopBaseClaims) >= (S.hopSteals or 50)
    elseif m == "Interval" then
        return (os.clock() - hopStart) >= (S.hopInterval or 15) * 60
    elseif m == "No Match" then
        return (os.clock() - lastClaim) >= (S.hopNoMatchDelay or 60)
    else -- Any
        return (claims - hopBaseClaims) >= (S.hopSteals or 50)
            or (os.clock() - hopStart) >= (S.hopInterval or 15) * 60
    end
end
local function resetBaselines()
    hopStart, hopBaseClaims = os.clock(), claims
end

-- ==================== auto-execute (URL) ====================
local function loaderSrc()
    return ([[
if getgenv().__AUTOHOP_RUN then return end
getgenv().__AUTOHOP_RUN = true
task.spawn(function()
    pcall(function() if not game:IsLoaded() then game.Loaded:Wait() end end)
    task.wait(2)
    local src
    for i = 1, 4 do
        local ok, res = pcall(game.HttpGet, game, %q)
        if ok and type(res) == "string" and #res > 0 then src = res break end
        task.wait(2)
    end
    if src then pcall(function() loadstring(src)() end) end
end)
]]):format(LOADER_URL)
end
-- (di-forward-declare di atas biar doHop bisa manggil tanpa gantung ke global)
function armAutoExec()
    if type(queueonteleport) == "function" then pcall(queueonteleport, loaderSrc()) end
end

-- ==================== auto send chat ====================
local chatCountLbl
local function sendChat(text)
    pcall(function()
        local tcs = game:GetService("TextChatService")
        local ch = nil
        -- channel general bisa di Folder "TextChannels" ATAU di property
        -- TextChannels - cek dua-duanya (di game ini channel-nya beda struktur)
        for _, f in ipairs(tcs:GetChildren()) do
            if f.Name == "TextChannels" and f:IsA("Folder") then
                ch = f:FindFirstChild("RBXGeneral") or f:FindFirstChild("General")
                if not ch then
                    for _, c in ipairs(f:GetChildren()) do
                        if c:IsA("TextChannel") and c.Name ~= "GameSystem" then ch = c break end
                    end
                end
                if ch then break end
            end
        end
        if not ch then
            pcall(function() ch = tcs.TextChannels and tcs.TextChannels:FindFirstChild("RBXGeneral") end)
        end
        if ch and ch.SendAsync then
            ch:SendAsync(text)
        else
            pcall(function() game:GetService("Players"):Chat(text) end)
        end
    end)
end
task.spawn(function()
    local lastSent = 0
    local chatIdx = 0
    while getgenv().__AUTOHOP_ACTIVE == MY_RUN do
        -- cek tiap 1 detik biar langsung kirim pas toggle dinyalain.
        -- ROTASI 3 pesan biar ga ke-sensor spam (pesan kosong dilewatin).
        if S.autoChat and (os.clock() - lastSent) >= math.max(5, S.chatInterval or 30) then
            local msgs = {}
            for _, t in ipairs({ S.chatText, S.chatText2, S.chatText3 }) do
                if tostring(t or "") ~= "" then msgs[#msgs + 1] = t end
            end
            if #msgs > 0 then
                lastSent = os.clock()
                chatIdx = chatIdx % #msgs + 1
                sendChat(msgs[chatIdx])
            end
        end
        -- countdown label
        if chatCountLbl then
            if S.autoChat then
                local hasMsg = false
                for _, t in ipairs({ S.chatText, S.chatText2, S.chatText3 }) do
                    if tostring(t or "") ~= "" then hasMsg = true break end
                end
                if not hasMsg then
                    chatCountLbl.Text = "chat on - isi pesan dulu!"
                else
                    local remain = math.max(0, math.ceil(math.max(5, S.chatInterval or 30) - (os.clock() - lastSent)))
                    chatCountLbl.Text = "next chat in " .. remain .. "s"
                end
            else
                chatCountLbl.Text = "chat off"
            end
        end
        task.wait(1)
    end
end)

-- ==================== auto accept friends ====================
-- Game ini punya mekanisme friend request sendiri: server fire event
-- FRIEND_REQUEST (Gifting) ke client + tombol accept-nya jalanin
-- CoreCall("SetCore", "PromptSendFriendRequest", player). Jadi kita
-- langsung auto-accept tiap kali ada yang add.
-- PATCH 2026-08: path lama (Library.Client.Network / Library.Functions.CoreCall) UDAH
-- DIHAPUS -> blok ini diem-diem mati. Sekarang: cari remote friend-request di namespace
-- baru (Packages.Networking), fallback ke path lama.
do
    local RS = game:GetService("ReplicatedStorage")
    local function acceptFrom(player)
        if not (S.autoAcceptFriends and player and typeof(player) == "Instance" and player:IsA("Player")) then return end
        local done = pcall(function()
            local CoreCall = require(RS.Shared.Functions.CoreCall)
            CoreCall("SetCore", "PromptSendFriendRequest", player)
        end)
        if not done then
            pcall(function() game:GetService("StarterGui"):SetCore("PromptSendFriendRequest", player) end)
        end
        print("[AutoHop] friend request accepted: " .. tostring(player.Name))
    end
    local ok = pcall(function()
        local net = RS:FindFirstChild("Packages") and RS.Packages:FindFirstChild("Networking")
        if not net then error("no net") end
        local found = false
        for _, c in ipairs(net:GetChildren()) do
            local n = tostring(c.Name)
            if c:IsA("RemoteEvent") and (n:find("Friend") or n:find("FRIEND")) then
                c.OnClientEvent:Connect(function(p) acceptFrom(p) end)
                found = true
            end
        end
        if not found then error("no friend remote") end
    end)
    if not ok then
        pcall(function()
            local Network = require(RS.Library.Client.Network)
            Network.Fired(Network.NET_MAP.Gifting.FRIEND_REQUEST):Connect(acceptFrom)
        end)
    end
end

-- ==================== camera lock ====================
-- Offset relatif ke karakter (tersimpan di config) - kamera ngikutin
-- karakter tapi sudut/jarak/zoom terkunci. Angka-angkanya ke-set lewat
-- UI (slider live) atau tombol "Capture Current POV".
local RunService = game:GetService("RunService")
local cam = game.Workspace.CurrentCamera
RunService.RenderStepped:Connect(function()
    if not S.camLock then return end
    local chr = LocalPlayer.Character
    local r = chr and chr:FindFirstChild("HumanoidRootPart")
    if not (r and cam) then return end
    cam.CameraType = Enum.CameraType.Custom
    cam.FieldOfView = S.camFov or 70
    local off = Vector3.new(S.camOffX or 0, S.camOffY or 0, S.camOffZ or 0)
    cam.CFrame = CFrame.lookAt(r.Position + off, r.Position + Vector3.new(0, 2, 0))
end)

-- ==================== main loop ====================
task.spawn(function()
    while getgenv().__AUTOHOP_ACTIVE == MY_RUN do
        if S.autoHop and hopReady() then
            local started = doHop()
            if started then
                resetBaselines()
                task.wait(10) -- biar teleport keburu proses
            end
            -- kalo hop di-skip, loop bakal cek lagi 5 detik kemudian
        end
        task.wait(5)
    end
end)

-- Simple custom UI template (draggable window, title, 2 buttons, close button)
-- Edit the values in the SETTINGS section to change how it looks.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer

-- ===== SETTINGS (change these) =====
lo