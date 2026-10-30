-- ==============================================================================
-- ENGINE.LUA - MULTI-BOT MOVE CORE ENGINE (Nuron's Lucifer v2.86)
-- https://github.com/canas1257/lucifer-move-multi
-- Author  : Salsa & Bos Anas
-- Partner : Anna (@anna)
-- ==============================================================================

local CONFIG = ... or _G.CONFIG
if not CONFIG then
    print("[Error] CONFIG tidak ditemukan. Harap jalankan script melalui loader.lua")
    return
end

-- State tracking untuk mencegah penumpukan thread per bot
local isBusy = {}

-- Lifecycle handler
function on_stop(error_message)
    if error_message ~= "" then
        print("[Multi-Move] Script berhenti dengan pesan: " .. error_message)
    else
        print("[Multi-Move] Script selesai secara normal.")
    end
end

-- ==============================================================================
-- UTILITY & VALIDATION HELPERS
-- ==============================================================================

local function getTargetBotsList()
    local all = getBots()
    if type(CONFIG.TARGET_BOTS) == "string" and CONFIG.TARGET_BOTS:upper() == "ALL" then
        return all
    end

    local selected = {}
    local lookup = {}
    if type(CONFIG.TARGET_BOTS) == "table" then
        for _, name in ipairs(CONFIG.TARGET_BOTS) do
            lookup[name:upper()] = true
        end
    end

    for _, bot in ipairs(all) do
        if lookup[bot.name:upper()] then
            table.insert(selected, bot)
        end
    end
    return selected
end

local function verifyWorldArrival(bot, targetWorld, timeoutSec)
    local upper = type(targetWorld) == "string" and targetWorld:upper() or targetWorld
    local maxTries = (timeoutSec or 15) * 2

    for _ = 1, maxTries do
        if bot.status ~= BotStatus.online then return false end
        if (bot:isInWorld(targetWorld) or bot:isInWorld(upper)) and bot:isInWorld() then
            sleep(500) -- buffer settling tile streaming
            return true
        end
        sleep(500)
    end
    return false
end

-- ==============================================================================
-- WORKER GERAKAN (SAFE WITH BUSY LOCK)
-- ==============================================================================

local function moveSingleBot(bot, tx, ty)
    if not bot or bot.status ~= BotStatus.online then return end
    if not bot:isInWorld() then return end

    -- Mencegah penumpukan thread (busy guard)
    if isBusy[bot.name] then
        return
    end
    isBusy[bot.name] = true

    local ok, err = pcall(function()
        local world = bot:getWorld()
        if not world or not world:isValidTile(tx, ty) then
            print(string.format("[%s] Koordinat target (%d, %d) di luar batas valid!", bot.name, tx, ty))
            return
        end

        -- Cek jika sudah berada di posisi target
        if bot.x == tx and bot.y == ty then
            return
        end

        -- Atur pacing interval move
        bot:setInterval(Action.move, (CONFIG.SETTINGS and CONFIG.SETTINGS.MOVE_INTERVAL) or 0.20)

        -- Blocking pathfinding
        local reached = bot:findPath(tx, ty)
        if reached and bot:isInTile(tx, ty) then
            print(string.format("[%s] Berhasil sampai di (%d, %d)", bot.name, tx, ty))
        else
            print(string.format("[%s] Jalur terhalang atau gagal sampai di (%d, %d)", bot.name, tx, ty))
        end
    end)

    -- Pastikan lock busy SELALU dilepas meski terjadi error
    isBusy[bot.name] = false

    if not ok then
        print(string.format("[%s] Error pada proses pergerakan: %s", bot.name, tostring(err)))
    end
end

-- ==============================================================================
-- DISPATCHER PERGERAKAN
-- ==============================================================================

local function dispatchMovement(bot, tx, ty)
    if CONFIG.SETTINGS and CONFIG.SETTINGS.USE_THREAD then
        runThread(moveSingleBot, bot, tx, ty)
    else
        moveSingleBot(bot, tx, ty)
    end
end

-- ==============================================================================
-- MAIN LOGIC
-- ==============================================================================

local bots = getTargetBotsList()
if #bots == 0 then
    print("[Error] Tidak ditemukan bot yang sesuai target konfigurasi!")
    return
end

print(string.format("[Multi-Move] Memproses %d bot aktif (Mode: %s)...", #bots, tostring(CONFIG.MODE)))

-- ------------------------------------------------------------------------------
-- MODE 4: WARP BARENG LALU GERAK (VERIFIKASI KEDATANGAN)
-- ------------------------------------------------------------------------------
if CONFIG.MODE == 4 then
    local targetWorld = CONFIG.WARP.WORLD:upper()
    local door = CONFIG.WARP.DOOR_ID or ""
    local timeout = CONFIG.WARP.TIMEOUT or 15
    local subMode = (CONFIG.WARP.SUB_MODE or "GATHER"):upper()

    print(string.format("[Multi-Warp] Mengirim request warp %d bot ke %s|%s...", #bots, targetWorld, door))

    -- Trigger direct subserver warp ke seluruh bot
    for _, bot in ipairs(bots) do
        if bot.status == BotStatus.online then
            bot.leave_world_before_warp = false
            bot:warp(targetWorld, door)
        end
    end

    -- Verifikasi setiap bot benar-benar tiba di world tujuan
    local arrivedBots = {}
    for _, bot in ipairs(bots) do
        if verifyWorldArrival(bot, targetWorld, timeout) then
            table.insert(arrivedBots, bot)
            print(string.format("[%s] Berhasil masuk ke world %s", bot.name, targetWorld))
        else
            print(string.format("[%s] [Gagal Warp] Tidak berhasil tiba di %s dalam %d detik. Dilewati.", bot.name, targetWorld, timeout))
        end
    end

    if #arrivedBots == 0 then
        print("[Error] Tidak ada bot yang berhasil masuk ke world tujuan. Eksekusi dibatalkan.")
        return
    end

    -- Posisikan bot yang berhasil masuk sesuai sub_mode (GATHER atau FORMATION)
    local startX = CONFIG.TARGET.x
    local startY = CONFIG.TARGET.y
    local spacing = (CONFIG.FORMATION and CONFIG.FORMATION.SPACING) or 1
    local isRight = not CONFIG.FORMATION or (CONFIG.FORMATION.DIRECTION or "RIGHT"):upper() == "RIGHT"

    for index, bot in ipairs(arrivedBots) do
        local targetX = startX
        local targetY = startY

        if subMode == "FORMATION" then
            local offset = (index - 1) * spacing
            targetX = isRight and (startX + offset) or (startX - offset)
        end

        dispatchMovement(bot, targetX, targetY)
    end
    print(string.format("[Multi-Warp] Perintah pergerakan (%s) dikirim ke %d bot yang sudah tiba.", subMode, #arrivedBots))

-- ------------------------------------------------------------------------------
-- MODE 1 & 2: GATHER (1 TITIK) ATAU FORMATION (BERJEJER)
-- ------------------------------------------------------------------------------
elseif CONFIG.MODE == 1 or CONFIG.MODE == 2 then
    local startX = CONFIG.TARGET.x
    local startY = CONFIG.TARGET.y
    local spacing = (CONFIG.FORMATION and CONFIG.FORMATION.SPACING) or 1
    local isRight = not CONFIG.FORMATION or (CONFIG.FORMATION.DIRECTION or "RIGHT"):upper() == "RIGHT"

    for index, bot in ipairs(bots) do
        if bot.status == BotStatus.online and bot:isInWorld() then
            local targetX = startX
            local targetY = startY

            if CONFIG.MODE == 2 then
                local offset = (index - 1) * spacing
                targetX = isRight and (startX + offset) or (startX - offset)
            end

            dispatchMovement(bot, targetX, targetY)
        else
            print(string.format("[%s] Dilewati karena offline atau belum berada di world.", bot.name))
        end
    end
    print("[Multi-Move] Perintah pergerakan selesai dikirim.")

-- ------------------------------------------------------------------------------
-- MODE 3: FOLLOW LEADER (DENGAN WORLD CHECK & BUSY LOCK)
-- ------------------------------------------------------------------------------
elseif CONFIG.MODE == 3 then
    local leaderName = (CONFIG.FOLLOW and CONFIG.FOLLOW.LEADER_NAME) or ""
    local leader = nil

    if leaderName ~= "" then
        leader = getBot(leaderName)
    else
        leader = bots[1]
    end

    if not leader then
        print("[Error] Leader bot tidak ditemukan!")
        return
    end

    print(string.format("[Follow Mode] Mengikuti leader: %s. Loop berjalan realtime...", leader.name))

    while true do
        if leader.status == BotStatus.online and leader:isInWorld() then
            local leaderWorldObj = leader:getWorld()
            local leaderWorld = leaderWorldObj and leaderWorldObj.name or ""
            local lx, ly = leader.x, leader.y

            if leaderWorld ~= "" then
                for _, follower in ipairs(bots) do
                    if follower.name ~= leader.name and follower.status == BotStatus.online then
                        -- 1. Verifikasi apakah follower ada di world yang sama dengan leader
                        if not follower:isInWorld(leaderWorld) then
                            if CONFIG.FOLLOW and CONFIG.FOLLOW.AUTO_WARP then
                                if not isBusy[follower.name] then
                                    print(string.format("[%s] World berbeda dari leader (%s). Auto-warp...", follower.name, leaderWorld))
                                    follower.leave_world_before_warp = false
                                    follower:warp(leaderWorld)
                                end
                            end
                            -- Lewati pergerakan koordinat jika belum satu world!
                        else
                            -- 2. Follower di world yang sama: cek jarak Manhattan
                            local dist = math.abs(follower.x - lx) + math.abs(follower.y - ly)
                            local minDist = (CONFIG.FOLLOW and CONFIG.FOLLOW.MIN_DISTANCE) or 2

                            if dist >= minDist then
                                dispatchMovement(follower, lx, ly)
                            end
                        end
                    end
                end
            end
        end
        sleep((CONFIG.FOLLOW and CONFIG.FOLLOW.INTERVAL) or 1000)
    end
end
