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

-- State koordinat drop per item ID di storage world (persistent antar trip & DC)
local dropPositions = {}
local storageBaseOrigin = nil

-- Blacklist objek yang gagal di-collect berkali-kali (hanya jika online & gagal valid)
local failedCollectCount = {}
local hasUnreachableItems = false

-- Runtime state tracking untuk pemulihan disconnect
local runtimeState = {
    phase = "INIT",         -- "TAKE", "STORAGE_DROP", "FINISHED"
    currentTakeIndex = 1,
    activeWorld = nil,      -- tabel { world = "...", door = "..." }
    targetX = nil,
    targetY = nil,
}

-- Lifecycle handler
function on_stop(error_message)
    if error_message ~= "" then
        print("[Transfer] Script dihentikan dengan pesan: " .. error_message)
    else
        print("[Transfer] Script selesai secara normal.")
    end
end

-- ==============================================================================
-- HELPER FUNCTIONS & RECONNECT GUARD
-- ==============================================================================

local function waitOnline(timeoutSec)
    for _ = 1, (timeoutSec or 30) do
        if bot.status == BotStatus.online then return true end
        sleep(1000)
    end
    return false
end

local function isAtWhiteDoor()
    local world = bot:getWorld()
    if not world then return false end
    local tile = world:getTile(bot.x, bot.y)
    return tile ~= nil and tile.fg == 6
end

-- Warp dengan verifikasi arrival
local function warpAndVerify(dest, timeoutSec)
    local worldName = type(dest) == "table" and dest.world or dest
    local doorId = type(dest) == "table" and (dest.door or "") or ""
    local upper = type(worldName) == "string" and worldName:upper() or worldName
    local maxTries = (timeoutSec or 20) * 2

    if not waitOnline(15) then
        print("[Warp] Bot tidak online saat hendak warp ke: " .. tostring(worldName))
        return false
    end

    bot.leave_world_before_warp = false
    bot:warp(upper, doorId)

    for _ = 1, maxTries do
        if bot.status ~= BotStatus.online then
            -- Disconnect saat proses warp, tunggu online kembali
            if waitOnline(15) then
                bot:warp(upper, doorId)
            end
        end
        if (bot:isInWorld(worldName) or bot:isInWorld(upper)) and bot:isInWorld() then
            sleep(800) -- buffer settling tile & object streaming dari server
            return true
        end
        sleep(500)
    end
    return false
end

-- Reconnect & Position Guard komprehensif
-- Menjaga bot online, memastikan di world tujuan, dan pulih dari White Door ke (targetX, targetY)
local function ensureConnectionAndPosition(dest, targetX, targetY)
    local worldName = type(dest) == "table" and dest.world or dest
    local doorId = type(dest) == "table" and (dest.door or "") or ""
    local upper = type(worldName) == "string" and worldName:upper() or worldName

    -- 1. Pulihkan koneksi jika bot offline (dibatasi 30 siklus = 5 menit)
    if bot.status ~= BotStatus.online then
        print(string.format("[Guard] Bot terputus/offline (Status: %s). Menunggu auto-reconnect...", tostring(bot.status)))
        local attempts = 0
        while not waitOnline(10) do
            attempts = attempts + 1
            if attempts >= 30 then
                print("[Guard] Timeout: Bot gagal reconnect setelah 5 menit. Menghentikan guard.")
                return false
            end
            sleep(1000)
        end
        print("[Guard] Bot berhasil online kembali!")
        sleep(800)
    end

    -- 2. Pastikan bot berada di world tujuan
    if not bot:isInWorld() or (not bot:isInWorld(worldName) and not bot:isInWorld(upper)) then
        print(string.format("[Guard] Bot belum di world '%s'. Melakukan warp recovery...", worldName))
        warpAndVerify({ world = worldName, door = doorId }, settings.WARP_TIMEOUT or 20)
    end

    -- 3. Pemulihan dari White Door (ID 6)
    if isAtWhiteDoor() then
        print(string.format("[Guard] Bot terdeteksi di White Door (ID 6). Re-warp ke door '%s'...", doorId))
        if doorId ~= "" then
            bot:warp(worldName, doorId)
            sleep(800)
        end

        -- Berjalan kembali ke posisi target kerja jika ditentukan
        if targetX and targetY then
            local world = bot:getWorld()
            if world and world:isValidTile(targetX, targetY) then
                print(string.format("[Guard] Kembali dari White Door ke posisi target (%d, %d)...", targetX, targetY))
                bot:findPath(targetX, targetY)
                sleep(400)
            end
        end
    end

    return bot.status == BotStatus.online and bot:isInWorld()
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

-- Memindai seluruh objek target di world dengan proteksi disconnect:
-- Return:
-- 1. isReady: boolean (false jika world belum settled/bot disconnect)
-- 2. totalFloating: jumlah seluruh objek target di lantai
-- 3. takeableList: list objek yang tasnya muat (< 200) & belum blacklist
-- 4. capacityDeferredCount: jumlah objek yang belum blacklist tapi tasnya sudah penuh (>= 200)
-- 5. blockedCount: jumlah objek yang sudah blacklist (gagal collect >= 3x)
local function scanWorldTargetObjects(activeWorld)
    -- Pastikan bot online & in world sebelum scan
    if not ensureConnectionAndPosition(activeWorld) then
        return false, 0, {}, 0, 0
    end

    local world = bot:getWorld()
    if not world then return false, 0, {}, 0, 0 end

    local inv = bot:getInventory()
    if not inv then return false, 0, {}, 0, 0 end

    local objects = world:getObjects()
    if not objects then return false, 0, {}, 0, 0 end

    local totalFloating = 0
    local takeableList = {}
    local capacityDeferredCount = 0
    local blockedCount = 0

    for _, obj in ipairs(objects) do
        if isTargetItem[obj.id] then
            totalFloating = totalFloating + 1

            local failCount = failedCollectCount[obj.oid] or 0
            if failCount >= 3 then
                blockedCount = blockedCount + 1
            else
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
                else
                    capacityDeferredCount = capacityDeferredCount + 1
                end
            end
        end
    end

    table.sort(takeableList, function(a, b)
        return a.dist < b.dist
    end)

    return true, totalFloating, takeableList, capacityDeferredCount, blockedCount
end

-- ==============================================================================
-- LOGIKA DROP DI STORAGE WORLD (Pemisahan Vertikal per Item ID & Anti-DC)
-- ==============================================================================

local function executeStorageDrop()
    runtimeState.phase = "STORAGE_DROP"
    runtimeState.activeWorld = CONFIG.STORAGE_WORLD

    print("[Storage] Memulai proses drop di Storage World...")

    if not ensureConnectionAndPosition(CONFIG.STORAGE_WORLD) then
        print("[Error] Gagal masuk dan memverifikasi Storage World!")
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
        -- Pastikan bot online & di storage world sebelum memproses item ini
        local pos = dropPositions[itemID]
        runtimeState.targetX = pos.x
        runtimeState.targetY = pos.y

        ensureConnectionAndPosition(CONFIG.STORAGE_WORLD, pos.x, pos.y)

        -- Baca ulang backpack secara realtime
        local count = bot:getInventory():findItem(itemID)
        if count > 0 then
            bot:findPath(pos.x, pos.y)
            bot:setDirection(false)

            local dropSuccess = false
            local retry = 0
            local maxRetry = settings.MAX_DROP_RETRY or 15

            while retry < maxRetry do
                -- Cek kondisi sebelum drop
                ensureConnectionAndPosition(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                local before = bot:getInventory():findItem(itemID)
                if before == 0 then
                    dropSuccess = true
                    break
                end

                bot:setDirection(false)
                bot:fastDrop(itemID, before)
                sleep(settings.DROP_DELAY or 400)

                -- Deteksi disconnect saat atau sesudah fastDrop
                if bot.status ~= BotStatus.online or not bot:isInWorld() then
                    print("[Storage] Disconnect terdeteksi pasca-drop. Menjalankan recovery & verifikasi tas...")
                    ensureConnectionAndPosition(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                    bot:setDirection(false)
                end

                -- BACA ULANG BACKPACK SETELAH PEMULIHAN
                local after = bot:getInventory():findItem(itemID)

                if after == 0 then
                    -- Drop sukses (termasuk jika diterima server sebelum disconnect!)
                    dropSuccess = true
                    print(string.format("[Storage] Sukses: Item ID %d (%d unit) telah ter-drop di (%d, %d)", itemID, before, pos.x, pos.y))
                    break
                elseif after < before then
                    -- Drop sebagian berhasil (misal sisa kapasitas tile hanya muat separuh)
                    print(string.format("[Storage] Drop sebagian berhasil (%d -> %d). Mencoba sisa di tile ini...", before, after))
                else
                    -- after == before: Tile benar-benar penuh, geser 1 tile ke kanan
                    retry = retry + 1
                    pos.x = pos.x + 1
                    print(string.format("[Storage] Tile (%d, %d) penuh/gagal drop ID %d. Geser ke kanan (%d, %d)...", pos.x - 1, pos.y, itemID, pos.x, pos.y))

                    ensureConnectionAndPosition(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                    bot:findPath(pos.x, pos.y)
                    bot:setDirection(false)
                end
            end

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
-- MAIN WORKFLOW (MULTI-TAKE WORLDS -> STORAGE DENGAN PERLINDUNGAN DC PENUH)
-- ==============================================================================

local takeWorlds = CONFIG.TAKE_WORLDS or {}
if #takeWorlds == 0 then
    print("[Error] TAKE_WORLDS kosong! Harap masukkan minimal 1 world sumber.")
    return
end

runtimeState.currentTakeIndex = 1

print(string.format("[Transfer] Memulai transfer multi-item untuk %d item target...", #(CONFIG.ITEMS or {})))

while runtimeState.currentTakeIndex <= #takeWorlds do
    local currentTakeWorld = takeWorlds[runtimeState.currentTakeIndex]
    local takeWorldName = type(currentTakeWorld) == "table" and currentTakeWorld.world or currentTakeWorld

    runtimeState.phase = "TAKE"
    runtimeState.activeWorld = currentTakeWorld

    print(string.format("[Take] Menuju World Take [%d/%d]: %s", runtimeState.currentTakeIndex, #takeWorlds, takeWorldName))

    local entered = false
    local enterAttempts = 0
    while not entered and enterAttempts < 5 do
        enterAttempts = enterAttempts + 1
        if ensureConnectionAndPosition(currentTakeWorld) then
            entered = true
        else
            print(string.format("[Warning] Percobaan masuk ke %s belum berhasil (%d/5). Mencoba lagi...", takeWorldName, enterAttempts))
            sleep(1000)
        end
    end

    if not entered then
        print(string.format("[Critical Error] Tidak dapat mengakses Take World %s setelah 5 percobaan. Dilewati.", takeWorldName))
        hasUnreachableItems = true
        runtimeState.currentTakeIndex = runtimeState.currentTakeIndex + 1
    else
        failedCollectCount = {}
        local worldClean = false

        while not worldClean do
            -- 1. Pindai status barang di world (aman terhadap DC)
            local ready, totalFloating, takeableList, capacityDeferredCount, blockedCount = scanWorldTargetObjects(currentTakeWorld)

            if not ready then
                -- World belum settled atau terjadi DC saat scan, ulangi scan setelah recovery
                print("[Take] Menunggu world settled / recovery koneksi...")
                sleep(1000)
            elseif totalFloating == 0 then
                -- WORLD BENAR-BENAR BERSIH!
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

                runtimeState.currentTakeIndex = runtimeState.currentTakeIndex + 1
                break

            elseif #takeableList == 0 and capacityDeferredCount == 0 and blockedCount > 0 then
                -- HANYA TERSISA OBJEK TERBLOKIR / BLACKLIST!
                print(string.format("[Warning] World %s masih memiliki %d objek target terblokir/unreachable (gagal collect >= 3x). Melewati objek ini.", takeWorldName, blockedCount))
                hasUnreachableItems = true
                worldClean = true

                if countTargetItemsInInventory() > 0 then
                    print("[Take] Membawa sisa barang yang terkumpul dari world ini ke storage...")
                    local dropOk = executeStorageDrop()
                    if not dropOk then
                        print("[Critical Error] Drop di storage gagal tuntas! Script dihentikan demi keamanan.")
                        return
                    end
                end

                runtimeState.currentTakeIndex = runtimeState.currentTakeIndex + 1
                break

            elseif #takeableList == 0 and capacityDeferredCount > 0 then
                -- Tas penuh untuk item di lantai -> drop ke storage lalu kembali
                print(string.format("[Take] Tas penuh untuk seluruh item target yang ada di lantai (%d objek tertunda karena kapasitas). Drop ke storage lalu kembali lagi...", capacityDeferredCount))

                local dropOk = executeStorageDrop()
                if not dropOk then
                    print("[Critical Error] Drop di storage gagal tuntas! Script dihentikan demi keamanan.")
                    return
                end

                -- Kembali ke world take yang sama
                runtimeState.phase = "TAKE"
                runtimeState.activeWorld = currentTakeWorld
                print(string.format("[Take] Kembali ke world take: %s...", takeWorldName))

                local returned = ensureConnectionAndPosition(currentTakeWorld)
                if not returned then
                    print(string.format("[Critical Error] Tidak dapat kembali ke world take %s. Script berhenti.", takeWorldName))
                    return
                end

            else
                -- Ambil objek dari takeableList
                local targetObj = takeableList[1]
                runtimeState.targetX = targetObj.x
                runtimeState.targetY = targetObj.y

                -- Proteksi posisi & koneksi sebelum jalan
                ensureConnectionAndPosition(currentTakeWorld, targetObj.x, targetObj.y)

                local reached = bot:findPath(targetObj.x, targetObj.y)
                if not reached then
                    bot:findPath(targetObj.x - 1, targetObj.y)
                end

                local beforeCount = bot:getInventory():findItem(targetObj.id)

                -- Eksekusi collect
                bot:collectObject(targetObj.oid, 2)
                sleep(200)

                -- Cek apakah terjadi DC saat collect
                if bot.status ~= BotStatus.online or not bot:isInWorld() then
                    print("[Take] Terdeteksi disconnect saat collect! Melakukan recovery...")
                    ensureConnectionAndPosition(currentTakeWorld, targetObj.x, targetObj.y)
                end

                -- BACA ULANG BACKPACK SETELAH PULIH
                local afterCount = bot:getInventory():findItem(targetObj.id)

                if afterCount == beforeCount then
                    -- Hanya tambahkan blacklist jika bot benar-benar online & gagal mengambil
                    if bot.status == BotStatus.online and bot:isInWorld() then
                        failedCollectCount[targetObj.oid] = (failedCollectCount[targetObj.oid] or 0) + 1
                    end
                else
                    -- Sukses ambil (meskipun tadi sempat DC sesaat)!
                    failedCollectCount[targetObj.oid] = nil
                end

                -- Jika seluruh jenis item target di tas sudah max 200, segera bawa ke storage
                if isAllTargetItemsMax() then
                    print("[Take] Seluruh slot item target di tas sudah max 200. Menuju storage...")
                    local dropOk = executeStorageDrop()
                    if not dropOk then
                        print("[Critical Error] Drop di storage gagal tuntas! Script dihentikan demi keamanan.")
                        return
                    end

                    runtimeState.phase = "TAKE"
                    runtimeState.activeWorld = currentTakeWorld
                    print(string.format("[Take] Kembali ke world take: %s...", takeWorldName))

                    local returned = ensureConnectionAndPosition(currentTakeWorld)
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

if hasUnreachableItems then
    print("[Finish] SEMUA WORLD SELESAI DIPROSES DENGAN CATATAN: Ada objek unreachable/terblokir di world take yang dilewati. Barang yang dapat dijangkau berhasil dipindahkan ke storage.")
else
    print("[Finish] SEMUA ITEM DARI SELURUH TAKE WORLD TELAH BERHASIL DIPINDAHKAN KE STORAGE TANPA SISA! Script selesai.")
end
