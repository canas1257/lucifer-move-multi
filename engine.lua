-- ==============================================================================
-- ENGINE.LUA - MULTI-ITEM TRANSFER & STORAGE DROP ENGINE (Nuron's Lucifer v2.86)
-- https://github.com/canas1257/lucifer-move-multi
-- Author  : Salsa & Bos Anas
-- Partner : Anna (@anna)
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
bot.auto_collect = false            -- Matikan auto collect bawaan agar tidak menyedot sampah liar

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

-- Blacklist objek yang gagal di-collect berkali-kali untuk mencegah infinite loop
local failedCollectCount = {}

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
            sleep(800) -- buffer settling tile & object streaming dari server
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

-- Memindai seluruh objek target di world:
-- Return: totalFloating (jumlah semua target di lantai), takeableList (hanya yang tasnya muat & belum blacklist)
local function scanWorldTargetObjects()
    local world = bot:getWorld()
    if not world then return 0, {} end

    local inv = bot:getInventory()
    if not inv then return 0, {} end

    local objects = world:getObjects()
    if not objects or #objects == 0 then return 0, {} end

    local totalFloating = 0
    local takeableList = {}

    for _, obj in ipairs(objects) do
        if isTargetItem[obj.id] then
            totalFloating = totalFloating + 1

            -- Cek apakah objek belum di-blacklist (gagal collect < 3 kali)
            local failCount = failedCollectCount[obj.oid] or 0
            if failCount < 3 then
                -- Cek apakah tas masih bisa menampung item ini (< 200)
                if inv:findItem(obj.id) < 200 then
                    local tx = math.floor(obj.x / 32)
                    local ty = math.floor(obj.y / 32)
                    local dist = math.abs(bot.x - tx) + math.abs(bot.y - ty)
                    table.insert(takeableList, {
                        oid = obj.oid,
                        id = obj.id,
                        x = tx,
                        y = ty,
                        dist = dist
                    })
                end
            end
        end
    end

    -- Urutkan berdasarkan jarak terdekat dari bot
    table.sort(takeableList, function(a, b)
        return a.dist < b.dist
    end)

    return totalFloating, takeableList
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
    local allItemsDropped = true

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
                allItemsDropped = false
                print(string.format("[Critical] Gagal drop seluruh Item ID %d setelah %d kali geser! Sisa di tas: %d", 
                    itemID, maxRetry, bot:getInventory():findItem(itemID)))
            end
        end
    end

    return allItemsDropped
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
        -- Reset blacklist gagal collect untuk world ini
        failedCollectCount = {}

        local worldClean = false

        while not worldClean do
            -- 1. Pindai status barang di world
            local totalFloating, takeableList = scanWorldTargetObjects()

            if totalFloating == 0 then
                -- Tidak ada lagi floating item target sama sekali di world ini -> WORLD BENAR-BENAR BERSIH!
                print(string.format("[Take] World %s sudah BERSIH dari seluruh item target.", takeWorldName))
                worldClean = true

                -- Jika masih ada barang di tas, bawa ke storage
                if countTargetItemsInInventory() > 0 then
                    print("[Take] Membawa sisa barang dari world ini ke storage...")
                    local dropOk = executeStorageDrop()
                    if not dropOk then
                        print("[Critical Error] Drop di storage gagal tuntas! Script dihentikan demi keamanan.")
                        return
                    end
                end

                -- Pindah ke world berikutnya
                currentTakeIndex = currentTakeIndex + 1
                break

            elseif #takeableList == 0 then
                -- Ada floating target di world, tapi tas bot tidak bisa menampungnya (karena semua jenis item yang ada di lantai sudah 200 di tas)
                print(string.format("[Take] Tas penuh untuk seluruh item target yang ada di lantai (%d objek tersisa). Drop ke storage lalu kembali lagi...", totalFloating))

                local dropOk = executeStorageDrop()
                if not dropOk then
                    print("[Critical Error] Drop di storage gagal tuntas! Script dihentikan demi keamanan.")
                    return
                end

                -- WAJIB kembali ke world take yang sama untuk menyapu sisa floating items!
                print(string.format("[Take] Kembali ke world take: %s...", takeWorldName))
                local returned = warpAndVerify(currentTakeWorld, settings.WARP_TIMEOUT or 20)
                if not returned then
                    print(string.format("[Error] Gagal warp kembali ke %s! Mencoba sekali lagi...", takeWorldName))
                    returned = warpAndVerify(currentTakeWorld, settings.WARP_TIMEOUT or 20)
                    if not returned then
                        print(string.format("[Critical Error] Tidak dapat kembali ke world take %s. Script berhenti.", takeWorldName))
                        return
                    end
                end

            else
                -- Masih ada objek yang bisa diambil di tas
                local targetObj = takeableList[1]
                local reached = bot:findPath(targetObj.x, targetObj.y)
                if not reached then
                    bot:findPath(targetObj.x - 1, targetObj.y)
                end

                local beforeCount = bot:getInventory():findItem(targetObj.id)
                bot:collectObject(targetObj.oid, 2)
                sleep(200)

                local afterCount = bot:getInventory():findItem(targetObj.id)
                if afterCount == beforeCount then
                    -- Objek gagal diambil (mungkin terhalang atau unreachable)
                    failedCollectCount[targetObj.oid] = (failedCollectCount[targetObj.oid] or 0) + 1
                end

                -- Jika seluruh jenis item target di tas sudah max 200, segera bawa ke storage
                if isAllTargetItemsMax() then
                    print("[Take] Seluruh slot item target di tas sudah max 200. Menuju storage...")
                    local dropOk = executeStorageDrop()
                    if not dropOk then
                        print("[Critical Error] Drop di storage gagal tuntas! Script dihentikan demi keamanan.")
                        return
                    end

                    -- Kembali ke world take yang sama
                    print(string.format("[Take] Kembali ke world take: %s...", takeWorldName))
                    local returned = warpAndVerify(currentTakeWorld, settings.WARP_TIMEOUT or 20)
                    if not returned then
                        print(string.format("[Critical Error] Gagal kembali ke world take %s. Script berhenti.", takeWorldName))
                        return
                    end
                end
            end
        end
    end
end

-- ==============================================================================
-- FINAL INTEGRITY VERIFICATION
-- ==============================================================================
local leftover = countTargetItemsInInventory()
if leftover > 0 then
    print(string.format("[Finish] Melakukan drop akhir sisa %d barang di storage...", leftover))
    local finalDropOk = executeStorageDrop()
    if not finalDropOk or countTargetItemsInInventory() > 0 then
        print(string.format("[Warning] Masih ada %d item tersisa di tas setelah drop akhir! Script dihentikan tanpa konfirmasi sukses.", countTargetItemsInInventory()))
        return
    end
end

print("[Finish] SEMUA ITEM DARI SELURUH TAKE WORLD TELAH BERHASIL DIPINDAHKAN KE STORAGE TANPA SISA! Script selesai.")
