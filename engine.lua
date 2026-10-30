-- ==============================================================================
-- ENGINE.LUA - MULTI-ITEM TRANSFER & STORAGE DROP ENGINE (Nuron's Lucifer v2.86)
-- https://github.com/canas1257/lucifer-move-multi
-- Author  : Salsa & Bos Anas
-- ==============================================================================

local CONFIG = ... or _G.CONFIG
if not CONFIG then
    print("[Error] CONFIG tidak ditemukan. Harap jalankan script melalui loader.lua")
    return
end

local bot = getBot()
if not bot then
    print("[Error] Bot context tidak ditemukan. Script harus dijalankan pada bot Lucifer.")
    return
end

-- ==============================================================================
-- INISIALISASI PENGATURAN BOT
-- ==============================================================================
bot.leave_world_before_warp = false  -- Direct subserver warp tanpa menu disconnect
bot.auto_collect = false            -- Matikan auto collect bawaan agar tidak menyedot sampah

local settings = CONFIG.SETTINGS or {}
bot:setInterval(Action.move, settings.MOVE_INTERVAL or 0.20)

-- Lookup cepat item target
local isTargetItem = {}
for _, id in ipairs(CONFIG.ITEMS or {}) do
    isTargetItem[id] = true
end

-- State koordinat drop per item ID di storage world
-- Menyimpan: dropPositions[itemID] = { x = ..., y = ... }
local dropPositions = {}
local storageBaseOrigin = nil

-- Lifecycle handler
function on_stop(error_message)
    if error_message ~= "" then
        print("[Transfer] Script dihentikan dengan pesan: " .. error_message)
    else
        print("[Transfer] Script selesai secara normal.")
    end
end

-- ==============================================================================
-- HELPER FUNCTIONS
-- ==============================================================================

local function waitOnline(timeoutSec)
    for _ = 1, (timeoutSec or 30) do
        if bot.status == BotStatus.online then return true end
        sleep(1000)
    end
    return false
end

local function warpAndVerify(dest, timeoutSec)
    local worldName = type(dest) == "table" and dest.world or dest
    local doorId = type(dest) == "table" and (dest.door or "") or ""
    local upper = type(worldName) == "string" and worldName:upper() or worldName
    local maxTries = (timeoutSec or 20) * 2

    if not waitOnline(10) then
        print("[Warp] Bot tidak online saat hendak warp ke: " .. tostring(worldName))
        return false
    end

    bot.leave_world_before_warp = false
    bot:warp(upper, doorId)

    for _ = 1, maxTries do
        if bot.status ~= BotStatus.online then return false end
        if (bot:isInWorld(worldName) or bot:isInWorld(upper)) and bot:isInWorld() then
            sleep(800) -- buffer settling tile & object streaming
            return true
        end
        sleep(500)
    end
    return false
end

local function countTargetItemsInInventory()
    local inv = bot:getInventory()
    if not inv then return 0 end
    local total = 0
    for _, id in ipairs(CONFIG.ITEMS or {}) do
        total = total + inv:findItem(id)
    end
    return total
end

local function isAllTargetItemsMax()
    local inv = bot:getInventory()
    if not inv then return false end
    for _, id in ipairs(CONFIG.ITEMS or {}) do
        if inv:findItem(id) < 200 then
            return false
        end
    end
    return true
end

-- Mencari objek target di take world yang tasnya belum max 200
local function findNextTakeableObject()
    local world = bot:getWorld()
    if not world then return nil end

    local inv = bot:getInventory()
    if not inv then return nil end

    local objects = world:getObjects()
    if not objects or #objects == 0 then return nil end

    local closestObj = nil
    local shortestDist = 999999

    for _, obj in ipairs(objects) do
        if isTargetItem[obj.id] then
            -- Cek kapasitas tas untuk item ini
            local currentCount = inv:findItem(obj.id)
            if currentCount < 200 then
                local tx = math.floor(obj.x / 32)
                local ty = math.floor(obj.y / 32)
                local dist = math.abs(bot.x - tx) + math.abs(bot.y - ty)

                if dist < shortestDist then
                    shortestDist = dist
                    closestObj = {
                        oid = obj.oid,
                        id = obj.id,
                        x = tx,
                        y = ty,
                    }
                end
            end
        end
    end

    return closestObj
end

-- ==============================================================================
-- LOGIKA DROP DI STORAGE WORLD (Pemisahan Vertikal per Item ID)
-- ==============================================================================

local function executeStorageDrop()
    print("[Storage] Memulai proses drop di Storage World...")

    if not warpAndVerify(CONFIG.STORAGE_WORLD, settings.WARP_TIMEOUT or 20) then
        print("[Error] Gagal masuk ke Storage World!")
        return false
    end

    local world = bot:getWorld()
    if not world then return false end

    -- 1. Tentukan titik awal jika belum pernah tercatat
    if not storageBaseOrigin then
        local curX, curY = bot.x, bot.y
        local spawnTile = world:getTile(curX, curY)

        -- Hindari White Door (ID 6)
        if spawnTile and spawnTile.fg == 6 then
            print("[Storage] Posisi spawn tepat di White Door (ID 6). Menggeser titik awal ke kanan...")
            curX = curX + 1
            bot:findPath(curX, curY)
        end

        storageBaseOrigin = { x = curX, y = curY }
        print(string.format("[Storage] Titik awal drop disetel pada (%d, %d)", curX, curY))
    end

    -- 2. Inisialisasi slot vertikal per item ID jika belum ada
    for idx, itemID in ipairs(CONFIG.ITEMS or {}) do
        if not dropPositions[itemID] then
            -- Item 1 di Y, Item 2 di Y - 1, Item 3 di Y - 2, dst (naik ke atas)
            local assignedY = storageBaseOrigin.y - (idx - 1)
            dropPositions[itemID] = {
                x = storageBaseOrigin.x,
                y = assignedY,
            }
            print(string.format("[Storage] Slot awal untuk Item ID %d: (%d, %d)", itemID, storageBaseOrigin.x, assignedY))
        end
    end

    -- 3. Drop setiap item yang ada di backpack
    for _, itemID in ipairs(CONFIG.ITEMS or {}) do
        local count = bot:getInventory():findItem(itemID)
        if count > 0 then
            local pos = dropPositions[itemID]

            -- Jalan ke koordinat drop item ini
            bot:findPath(pos.x, pos.y)

            -- Hadap ke kanan sesuai instruksi
            bot:setDirection(false)

            -- Eksekusi drop dengan verifikasi kapasitas tile (max 4.000 item / 20 objek)
            local dropSuccess = false
            local retry = 0
            local maxRetry = settings.MAX_DROP_RETRY or 15

            while retry < maxRetry do
                local before = bot:getInventory():findItem(itemID)
                if before == 0 then
                    dropSuccess = true
                    break
                end

                bot:fastDrop(itemID, before)
                sleep(settings.DROP_DELAY or 400)

                local after = bot:getInventory():findItem(itemID)
                if after == 0 then
                    dropSuccess = true
                    print(string.format("[Storage] Sukses drop %d unit Item ID %d di (%d, %d)", before, itemID, pos.x, pos.y))
                    break
                else
                    -- Tile penuh atau gagal drop: maju ke kanan (x + 1)
                    retry = retry + 1
                    pos.x = pos.x + 1
                    print(string.format("[Storage] Tile (%d, %d) penuh/gagal drop ID %d. Geser ke kanan (%d, %d)...", pos.x - 1, pos.y, itemID, pos.x, pos.y))

                    bot:findPath(pos.x, pos.y)
                    bot:setDirection(false)
                end
            end

            -- Update koordinat baru untuk item ini agar trip berikutnya langsung ke sini
            dropPositions[itemID] = { x = pos.x, y = pos.y }

            if not dropSuccess then
                print(string.format("[Warning] Gagal drop seluruh Item ID %d setelah %d kali geser!", itemID, maxRetry))
            end
        end
    end

    print("[Storage] Proses drop selesai.")
    return true
end

-- ==============================================================================
-- MAIN WORKFLOW (MULTI-TAKE WORLDS -> STORAGE)
-- ==============================================================================

local takeWorlds = CONFIG.TAKE_WORLDS or {}
if #takeWorlds == 0 then
    print("[Error] TAKE_WORLDS kosong! Harap masukkan minimal 1 world sumber.")
    return
end

local currentTakeIndex = 1

print(string.format("[Transfer] Memulai transfer multi-item untuk %d item target...", #(CONFIG.ITEMS or {})))

while currentTakeIndex <= #takeWorlds do
    local currentTakeWorld = takeWorlds[currentTakeIndex]
    local takeWorldName = type(currentTakeWorld) == "table" and currentTakeWorld.world or currentTakeWorld

    print(string.format("[Take] Menuju World Take [%d/%d]: %s", currentTakeIndex, #takeWorlds, takeWorldName))

    if not warpAndVerify(currentTakeWorld, settings.WARP_TIMEOUT or 20) then
        print(string.format("[Error] Gagal masuk ke Take World: %s. Lewati ke world berikutnya.", takeWorldName))
        currentTakeIndex = currentTakeIndex + 1
    else
        -- Loop pengambilan barang di world ini
        local worldHasItems = true

        while worldHasItems do
            -- 1. Jika semua item target di tas sudah max 200, saatnya pulang ke storage untuk drop
            if isAllTargetItemsMax() then
                print("[Take] Seluruh jenis item target di backpack sudah mencapai 200. Menuju storage...")
                executeStorageDrop()
                -- Kembali lagi ke take world yang sedang aktif
                warpAndVerify(currentTakeWorld, settings.WARP_TIMEOUT or 20)
            end

            -- 2. Cari objek target berikutnya yang belum max 200 di tas
            local targetObj = findNextTakeableObject()

            if targetObj then
                -- Jalan mendekati objek
                local reached = bot:findPath(targetObj.x, targetObj.y)
                if not reached then
                    -- Coba posisi samping jika tidak bisa pas di tile-nya
                    bot:findPath(targetObj.x - 1, targetObj.y)
                end

                -- Ambil objek
                bot:collectObject(targetObj.oid, 2)
                sleep(200)
            else
                -- Sudah tidak ada lagi floating objek target yang bisa diambil di world ini
                worldHasItems = false
                print(string.format("[Take] Tidak ada lagi floating item target yang dapat diambil di world %s.", takeWorldName))

                -- Jika masih ada barang di tas, drop dulu ke storage
                if countTargetItemsInInventory() > 0 then
                    print("[Take] Membawa sisa barang di backpack ke storage...")
                    executeStorageDrop()
                end

                -- Lanjut ke world take berikutnya
                currentTakeIndex = currentTakeIndex + 1
            end
        end
    end
end

-- ==============================================================================
-- FINAL SWEEP / DROP SISA BACKPACK DI WORLD TERAKHIR
-- ==============================================================================
if countTargetItemsInInventory() > 0 then
    print("[Finish] Seluruh take world selesai. Melakukan drop sisa barang di storage...")
    executeStorageDrop()
end

print("[Finish] SEMUA ITEM DARI SELURUH TAKE WORLD TELAH BERHASIL DIPINDAHKAN KE STORAGE! Script selesai.")
