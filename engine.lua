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

-- Blacklist objek yang gagal di-collect berkali-kali (hanya jika online stabil & gagal valid)
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

-- Sleep dengan slicing 50ms untuk mendeteksi disconnect cepat yang pulih di tengah jeda
local function pacingSleep(ms)
    local interval = 50
    local steps = math.max(1, math.floor(ms / interval))
    local dcDetected = false

    for _ = 1, steps do
        if bot.status ~= BotStatus.online then
            dcDetected = true
        end
        sleep(interval)
        if bot.status ~= BotStatus.online then
            dcDetected = true
        end
    end
    return dcDetected
end

local function isAtWhiteDoor()
    local world = bot:getWorld()
    if not world then return false end
    local tile = world:getTile(bot.x, bot.y)
    return tile ~= nil and tile.fg == 6
end

-- Helper verifikasi nama world secara case-insensitive
local function isInTargetWorld(dest)
    if not bot:isInWorld() then return false end
    local worldName = type(dest) == "table" and dest.world or dest
    if not worldName or worldName == "" then return false end
    local upper = worldName:upper()
    return bot:isInWorld(worldName) or bot:isInWorld(upper)
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
            if waitOnline(15) then
                bot:warp(upper, doorId)
            end
        end
        if isInTargetWorld(worldName) then
            pacingSleep(800) -- buffer settling tile & object streaming dari server
            return true
        end
        sleep(500)
    end
    return false
end

-- Reconnect & Position Guard komprehensif
-- Menjamin bot online, benar-benar berada di world tujuan, dan pulih dari White Door
local function ensureConnectionAndPosition(dest, targetX, targetY)
    local worldName = type(dest) == "table" and dest.world or dest
    local doorId = type(dest) == "table" and (dest.door or "") or ""

    -- 1. Pulihkan koneksi jika bot offline (dibatasi 30 siklus = 5 menit)
    if bot.status ~= BotStatus.online then
        print(string.format("[Guard] Bot terputus/offline (Status: %s). Menunggu auto-reconnect...", tostring(bot.status)))
        local attempts = 0
        while not waitOnline(10) do
            attempts = attempts + 1
            if attempts >= 30 then
                print("[Guard] Timeout: Bot gagal reconnect setelah 5 menit.")
                return false
            end
            sleep(1000)
        end
        print("[Guard] Bot berhasil online kembali!")
        pacingSleep(800)
    end

    -- 2. Pastikan bot benar-benar berada di WORLD TUJUAN (bukan asal in-world di world lama!)
    if not isInTargetWorld(dest) then
        print(string.format("[Guard] Bot belum berada di world tujuan '%s'. Melakukan warp recovery...", worldName))
        local warpOk = warpAndVerify({ world = worldName, door = doorId }, settings.WARP_TIMEOUT or 20)
        if not warpOk or not isInTargetWorld(dest) then
            print(string.format("[Guard Error] Gagal mencapai world tujuan: %s", worldName))
            return false
        end
    end

    -- 3. Pemulihan dari White Door (ID 6)
    if isAtWhiteDoor() then
        print(string.format("[Guard] Bot terdeteksi di White Door (ID 6). Re-warp ke door '%s'...", doorId))
        if doorId ~= "" then
            bot:warp(worldName, doorId)
            pacingSleep(800)
        end

        -- Berjalan kembali ke posisi target kerja jika ditentukan
        if targetX and targetY then
            local world = bot:getWorld()
            if world and world:isValidTile(targetX, targetY) then
                print(string.format("[Guard] Kembali dari White Door ke posisi target (%d, %d)...", targetX, targetY))
                bot:findPath(targetX, targetY)
                pacingSleep(400)
            end
        end
    end

    return bot.status == BotStatus.online and isInTargetWorld(dest)
end

-- Helper verifikasi perjalanan sampai di tile yang dituju secara pasti
local function walkToTileSafely(destWorld, targetX, targetY)
    for attempt = 1, 4 do
        if not ensureConnectionAndPosition(destWorld, targetX, targetY) then
            return false
        end

        if bot:isInTile(targetX, targetY) then
            return true
        end

        local pathOk = bot:findPath(targetX, targetY)
        if pathOk and bot:isInTile(targetX, targetY) and bot.status == BotStatus.online then
            return true
        end

        pacingSleep(300)
    end
    return bot.status == BotStatus.online and isInTargetWorld(destWorld) and bot:isInTile(targetX, targetY)
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
local function scanWorldTargetObjects(activeWorld)
    if not ensureConnectionAndPosition(activeWorld) then
        return false, 0, {}, 0, 0
    end

    local world = bot:getWorld()
    if not world then return false, 0, {}, 0, 0 end

    local inv = bot:getInventory()
    if not inv then return false, 0, {}, 0, 0 end

    local objects = world:getObjects()
    if not objects then return false, 0, {}, 0, 0 end

    -- Verifikasi ulang status bot SETELAH pemanggilan getObjects()
    if bot.status ~= BotStatus.online or not isInTargetWorld(activeWorld) then
        print("[Take] Terdeteksi disconnect saat/setelah getObjects(). Scan dibatalkan untuk diulang.")
        return false, 0, {}, 0, 0
    end

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
        print("[Critical Error] Gagal memverifikasi kedatangan di Storage World! Drop dibatalkan demi keamanan.")
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
        local count = bot:getInventory():findItem(itemID)
        if count > 0 then
            local pos = dropPositions[itemID]
            runtimeState.targetX = pos.x
            runtimeState.targetY = pos.y

            local dropSuccess = false
            local retry = 0
            local maxRetry = settings.MAX_DROP_RETRY or 15
            local consecutiveRejections = 0

            while retry < maxRetry do
                -- Wajib verifikasi bot online, di storage world, dan SAMPAI DI TILE (pos.x, pos.y)
                local arrived = walkToTileSafely(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                if not arrived then
                    print(string.format("[Storage Error] Gagal mencapai koordinat drop (%d, %d)! Drop ditangguhkan.", pos.x, pos.y))
                    return false
                end

                local before = bot:getInventory():findItem(itemID)
                if before == 0 then
                    dropSuccess = true
                    break
                end

                -- Hadap kanan sebelum drop
                bot:setDirection(false)

                -- Verifikasi ketat tepat sebelum memanggil fastDrop:
                -- Bot HARUS online dan berada tepat di tile drop!
                if bot.status ~= BotStatus.online or not isInTargetWorld(CONFIG.STORAGE_WORLD) or not bot:isInTile(pos.x, pos.y) then
                    print("[Storage] Kondisi koneksi/posisi belum valid sesaat sebelum drop. Mengulang perjalanan...")
                    ensureConnectionAndPosition(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                else
                    local preStatus = bot.status
                    bot:fastDrop(itemID, before)
                    local sleepDC = pacingSleep(settings.DROP_DELAY or 400)
                    local postStatus = bot.status
                    local inTileAfter = bot:isInTile(pos.x, pos.y)

                    local wasInterruptedByDC = (preStatus ~= BotStatus.online or sleepDC or postStatus ~= BotStatus.online or not isInTargetWorld(CONFIG.STORAGE_WORLD) or not inTileAfter)

                    if wasInterruptedByDC then
                        print("[Storage] Gangguan koneksi terdeteksi saat/pasca fastDrop. Menjalankan recovery...")
                        ensureConnectionAndPosition(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                        bot:setDirection(false)
                    end

                    -- BACA ULANG BACKPACK SETELAH PULIH
                    local after = bot:getInventory():findItem(itemID)

                    if after == 0 then
                        -- Drop sukses (termasuk jika diterima server sebelum DC terdeteksi)!
                        dropSuccess = true
                        print(string.format("[Storage] Sukses: Item ID %d (%d unit) telah ter-drop di (%d, %d)", itemID, before, pos.x, pos.y))
                        break
                    elseif after < before then
                        -- Sebagian unit item ter-drop
                        print(string.format("[Storage] Drop sebagian berhasil (%d -> %d). Mencoba sisa di tile yang sama...", before, after))
                        consecutiveRejections = 0
                    else
                        -- after == before
                        if wasInterruptedByDC then
                            -- Gagal karena koneksi putus (bukan karena kapasitas tile) -> jangan geser slot!
                            print(string.format("[Storage] Drop terinterupsi DC (bukan tile penuh). Mencoba ulang di (%d, %d)...", pos.x, pos.y))
                        else
                            consecutiveRejections = consecutiveRejections + 1
                            if consecutiveRejections >= 2 then
                                -- Terkonfirmasi 2x ditolak saat online stabil di tile yang sama -> TILE PENUH
                                retry = retry + 1
                                pos.x = pos.x + 1
                                consecutiveRejections = 0
                                print(string.format("[Storage] Tile (%d, %d) penuh/gagal drop ID %d. Geser ke kanan (%d, %d)...", pos.x - 1, pos.y, itemID, pos.x, pos.y))

                                walkToTileSafely(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                                bot:setDirection(false)
                            else
                                print(string.format("[Storage] Percobaan drop belum berkurang di (%d, %d). Mengulang konfirmasi sebelum geser...", pos.x, pos.y))
                            end
                        end
                    end
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
            pacingSleep(1000)
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
            local ready, totalFloating, takeableList, capacityDeferredCount, blockedCount = scanWorldTargetObjects(currentTakeWorld)

            if not ready then
                print("[Take] Menunggu world settled / recovery koneksi...")
                pacingSleep(1000)
            elseif totalFloating == 0 then
                -- WORLD BENAR-BENAR BERSIH!
                print(string.format("[Take] World %s sudah BERSIH dari seluruh item target.", takeWorldName))
                worldClean = true

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
                -- HANYA TERSISA OBJEK TERBLOKIR / BLACKLIST
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

                ensureConnectionAndPosition(currentTakeWorld, targetObj.x, targetObj.y)

                -- 1. Jalankan pathfinding mendekati objek
                local reached = bot:findPath(targetObj.x, targetObj.y)
                if not reached then
                    reached = bot:findPath(targetObj.x - 1, targetObj.y)
                end
                if not reached then
                    reached = bot:findPath(targetObj.x + 1, targetObj.y)
                end

                -- 2. Jika jalur fisik terhalang (tidak bisa dicapai sama sekali)
                if not reached then
                    print(string.format("[Take] Tidak ada jalur jangkauan menuju OID %d di (%d, %d).", targetObj.oid, targetObj.x, targetObj.y))
                    -- Hanya kegagalan jangkauan fisik terverifikasi yang boleh menaikkan hitungan unreachable
                    if bot.status == BotStatus.online and isInTargetWorld(currentTakeWorld) then
                        failedCollectCount[targetObj.oid] = (failedCollectCount[targetObj.oid] or 0) + 1
                    end
                else
                    -- 3. Bot berhasil mendekati objek. Verifikasi koneksi sebelum collect!
                    if bot.status ~= BotStatus.online or not isInTargetWorld(currentTakeWorld) then
                        print("[Take] Terdeteksi gangguan koneksi sebelum collect. Menjalankan recovery & re-scan...")
                        ensureConnectionAndPosition(currentTakeWorld)
                    else
                        local beforeCount = bot:getInventory():findItem(targetObj.id)

                        bot:collectObject(targetObj.oid, 2)
                        local sleepDC = pacingSleep(200)

                        -- Verifikasi koneksi pasca collect
                        local postCollectDC = (bot.status ~= BotStatus.online or not isInTargetWorld(currentTakeWorld))
                        local wasDC = sleepDC or postCollectDC

                        if wasDC then
                            print("[Take] Terdeteksi gangguan koneksi saat/pasca collect. Menjalankan recovery...")
                            ensureConnectionAndPosition(currentTakeWorld, targetObj.x, targetObj.y)
                        end

                        local afterCount = bot:getInventory():findItem(targetObj.id)

                        if afterCount > beforeCount then
                            -- Sukses mengambil item
                            failedCollectCount[targetObj.oid] = nil
                        else
                            -- Jika barang belum terambil tetapi bot berhasil sampai di tile objek:
                            -- Ini situasi ambigu (timing/lag/DC), JANGAN anggap sebagai kegagalan jangkauan!
                            print(string.format("[Take] Objek OID %d belum terambil ke tas di (%d, %d). Mengulang scan pada siklus berikutnya...", targetObj.oid, targetObj.x, targetObj.y))
                        end
                    end
                end

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
