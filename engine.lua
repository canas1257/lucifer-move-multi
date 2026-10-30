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

-- Pelacakan jangkauan fisik terhalang (unreachable path)
local unreachablePathCount = {}

-- Pelacakan percobaan collect tanpa progres (ambigu / server timing)
local collectAttemptCount = {}
local unresolvedCollectObjects = {}

local hasUnreachableItems = false
local hasUnresolvedItems = false
local isTransferCompleted = false

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
        print("[Transfer] Script dihentikan dengan pesan error: " .. error_message)
    elseif not isTransferCompleted then
        print("[Transfer] Script dihentikan sebelum seluruh proses transfer tuntas.")
    else
        print("[Transfer] Script selesai secara normal (seluruh transfer tuntas).")
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

-- Sleep dengan slicing 50ms untuk mendeteksi disconnect yang pulih di tengah jeda
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

-- Helper parsing destinasi fleksibel: mendukung tabel { world = "...", door = "..." }
-- maupun string format "WORLD", "WORLD|DOOR", atau "WORLD:DOOR"
local function parseDestination(dest)
    if type(dest) == "table" then
        return dest.world or "", dest.door or ""
    elseif type(dest) == "string" then
        local w, d = dest:match("^([^|:]+)[|:](.*)$")
        if w then
            return w, d
        else
            return dest, ""
        end
    end
    return tostring(dest or ""), ""
end

-- Helper verifikasi nama world secara case-insensitive
local function isInTargetWorld(dest)
    if not bot:isInWorld() then return false end
    local worldName, _ = parseDestination(dest)
    if not worldName or worldName == "" then return false end
    local upper = worldName:upper()
    return bot:isInWorld(worldName) or bot:isInWorld(upper)
end

-- Hitung floating objects pada tile tertentu di world
local function countFloatingObjectsAtTile(world, tx, ty)
    if not world then return 0 end
    local objs = world:getObjects() or {}
    local count = 0
    for _, obj in ipairs(objs) do
        local ox = math.floor(obj.x / 32)
        local oy = math.floor(obj.y / 32)
        if ox == tx and oy == ty then
            count = count + 1
        end
    end
    return count
end

-- Warp dengan verifikasi arrival
-- Sesuai dokumentasi resmi Lucifer v2.86 (docs/lucifer.md baris 335):
-- | warp(name: string) / warp(name: string, id: string) | Masuk world, dengan door ID opsional. |
local function warpAndVerify(dest, timeoutSec)
    local worldName, doorId = parseDestination(dest)
    local upper = type(worldName) == "string" and worldName:upper() or worldName
    local maxTries = (timeoutSec or 20) * 2

    if not waitOnline(15) then
        print("[Warp] Bot tidak online saat hendak warp ke: " .. tostring(worldName))
        return false
    end

    bot.leave_world_before_warp = false

    -- Sesuai signature resmi Lucifer:
    -- Jika door ID ada & tidak kosong -> 2 argumen: bot:warp(name, id)
    -- Jika door ID tidak ada/kosong   -> 1 argumen: bot:warp(name)
    if doorId and doorId ~= "" then
        bot:warp(upper, doorId)
    else
        bot:warp(upper)
    end

    for _ = 1, maxTries do
        if bot.status ~= BotStatus.online then
            if waitOnline(15) then
                if doorId and doorId ~= "" then
                    bot:warp(upper, doorId)
                else
                    bot:warp(upper)
                end
            end
        end
        if isInTargetWorld(worldName) then
            pacingSleep(800) -- buffer settling tile & object streaming dari server

            -- Jika target memiliki door ID dan bot masih di White Door (ID 6), re-warp ke door ID
            if doorId and doorId ~= "" and isAtWhiteDoor() then
                print(string.format("[Warp] Bot di White Door, re-warp ke door '%s'...", doorId))
                bot:warp(upper, doorId)
                pacingSleep(600)
            end

            return true
        end
        sleep(500)
    end
    return false
end

-- Reconnect & Position Guard komprehensif
local function ensureConnectionAndPosition(dest, targetX, targetY)
    local worldName, doorId = parseDestination(dest)

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
        if doorId and doorId ~= "" then
            print(string.format("[Guard] Bot terdeteksi di White Door (ID 6). Re-warp ke door '%s'...", doorId))
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
        return false, 0, {}, 0, 0, 0
    end

    local world = bot:getWorld()
    if not world then return false, 0, {}, 0, 0, 0 end

    local inv = bot:getInventory()
    if not inv then return false, 0, {}, 0, 0, 0 end

    local objects = world:getObjects()
    if not objects then return false, 0, {}, 0, 0, 0 end

    if bot.status ~= BotStatus.online or not isInTargetWorld(activeWorld) then
        print("[Take] Terdeteksi disconnect saat/setelah getObjects(). Scan dibatalkan untuk diulang.")
        return false, 0, {}, 0, 0, 0
    end

    local totalFloating = 0
    local takeableList = {}
    local capacityDeferredCount = 0
    local unreachablePathCountTotal = 0
    local unresolvedAttemptCountTotal = 0

    for _, obj in ipairs(objects) do
        if isTargetItem[obj.id] then
            totalFloating = totalFloating + 1

            if (unreachablePathCount[obj.oid] or 0) >= 3 then
                unreachablePathCountTotal = unreachablePathCountTotal + 1
            elseif unresolvedCollectObjects[obj.oid] then
                unresolvedAttemptCountTotal = unresolvedAttemptCountTotal + 1
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

    return true, totalFloating, takeableList, capacityDeferredCount, unreachablePathCountTotal, unresolvedAttemptCountTotal
end

-- ==============================================================================
-- LOGIKA DROP DI STORAGE WORLD (Pemisahan Vertikal & Anti-DC Robust)
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
            local shiftCount = 0
            local maxShifts = settings.MAX_DROP_RETRY or 15

            while shiftCount < maxShifts do
                local localAttempts = 0
                local shouldShiftRight = false

                while localAttempts < 3 do
                    localAttempts = localAttempts + 1

                    -- WAJIB: Setiap percobaan drop harus memverifikasi kedatangan di tile target (pos.x, pos.y)!
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

                    bot:setDirection(false)

                    -- Verifikasi posisi fisik bot: HARUS berada tepat di (pos.x, pos.y)!
                    if not bot:isInTile(pos.x, pos.y) then
                        print(string.format("[Storage Warning] Bot tidak berada di tile (%d, %d). Drop dibatalkan untuk re-path...", pos.x, pos.y))
                    else
                        local preStatus = bot.status
                        bot:fastDrop(itemID, before)
                        local sleepDC = pacingSleep(settings.DROP_DELAY or 400)
                        local postStatus = bot.status
                        local inTileAfter = bot:isInTile(pos.x, pos.y)

                        local wasInterrupted = (preStatus ~= BotStatus.online or sleepDC or postStatus ~= BotStatus.online or not inTileAfter)

                        if wasInterrupted then
                            print("[Storage] Percobaan drop terinterupsi koneksi/posisi. Melakukan pemulihan...")
                            ensureConnectionAndPosition(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                            bot:setDirection(false)
                        end

                        local after = bot:getInventory():findItem(itemID)
                        if after == 0 then
                            dropSuccess = true
                            print(string.format("[Storage] Sukses: Item ID %d (%d unit) telah ter-drop di (%d, %d)", itemID, before, pos.x, pos.y))
                            break
                        elseif after < before then
                            print(string.format("[Storage] Drop sebagian berhasil (%d -> %d). Mencoba sisa di tile yang sama...", before, after))
                            localAttempts = 0
                        else
                            -- after == before: DROP GAGAL!
                            -- Berikan jeda 1.5 detik (1-2 detik sesuai arahan Bos Anas)
                            print(string.format("[Storage] Drop belum berkurang di (%d, %d) (Percobaan %d/3, sisa di tas: %d). Memberi jeda 1.5 detik...", 
                                pos.x, pos.y, localAttempts, after))
                            pacingSleep(1500)

                            -- Setelah jeda, verifikasi ulang koneksi & tas (siapa tahu paket drop baru diproses server)
                            ensureConnectionAndPosition(CONFIG.STORAGE_WORLD, pos.x, pos.y)
                            after = bot:getInventory():findItem(itemID)

                            if after == 0 then
                                dropSuccess = true
                                print(string.format("[Storage] Sukses (terkonfirmasi pasca-jeda): Item ID %d telah ter-drop di (%d, %d)", itemID, pos.x, pos.y))
                                break
                            elseif after < before then
                                print(string.format("[Storage] Drop sebagian berhasil pasca-jeda (%d -> %d). Mencoba sisa...", before, after))
                                localAttempts = 0
                            else
                                -- Cek apakah tile sudah terisi floating objects atau sudah 3x percobaan gagal
                                local activeWorldObj = bot:getWorld()
                                local floatingAtTile = math.max(
                                    countFloatingObjectsAtTile(activeWorldObj, pos.x + 1, pos.y),
                                    countFloatingObjectsAtTile(activeWorldObj, pos.x, pos.y)
                                )

                                -- Jika drop belum berkurang setelah percobaan di tile ini:
                                if localAttempts >= 2 then
                                    print(string.format("[Storage] Tile (%d, %d) belum dapat menerima drop setelah %d percobaan (floating objects: %d). Maju ke kanan mencari lokasi baru...", 
                                        pos.x, pos.y, localAttempts, floatingAtTile))
                                    shouldShiftRight = true
                                    break
                                end
                            end
                        end
                    end
                end

                if dropSuccess then
                    break
                elseif shouldShiftRight then
                    shiftCount = shiftCount + 1
                    pos.x = pos.x + 1
                    print(string.format("[Storage] Maju ke kanan mencari lokasi drop baru untuk Item ID %d: (%d, %d)...", itemID, pos.x, pos.y))
                    shouldShiftRight = false
                    pacingSleep(500)
                else
                    print(string.format("[Storage Warning] Drop Item ID %d di (%d, %d) tidak tuntas. Menghentikan drop demi keamanan.", itemID, pos.x, pos.y))
                    return false
                end
            end

            dropPositions[itemID] = { x = pos.x, y = pos.y }

            if not dropSuccess then
                allItemsDropped = false
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
    local takeWorldName, takeDoorId = parseDestination(currentTakeWorld)

    runtimeState.phase = "TAKE"
    runtimeState.activeWorld = currentTakeWorld

    print(string.format("[Take] Menuju World Take [%d/%d]: %s%s", 
        runtimeState.currentTakeIndex, #takeWorlds, takeWorldName, 
        (takeDoorId ~= "" and ("|" .. takeDoorId) or "")))

    local entered = false
    local enterAttempts = 0
    while not entered and enterAttempts < 5 do
        enterAttempts = enterAttempts + 1
        if warpAndVerify(currentTakeWorld, settings.WARP_TIMEOUT or 20) and ensureConnectionAndPosition(currentTakeWorld) then
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
        unreachablePathCount = {}
        collectAttemptCount = {}
        unresolvedCollectObjects = {}

        local worldClean = false

        while not worldClean do
            local ready, totalFloating, takeableList, capacityDeferredCount, unreachablePathTotal, unresolvedTotal = scanWorldTargetObjects(currentTakeWorld)

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

            elseif #takeableList == 0 and capacityDeferredCount == 0 and (unreachablePathTotal > 0 or unresolvedTotal > 0) then
                -- HANYA TERSISA OBJEK TERHALANG JALUR ATAU PERCOBAAN AMBIGU TANPA PROGRES
                print(string.format("[Warning] World %s selesai dengan catatan: %d objek terhalang jalur (unreachable), %d objek ambigu tanpa progres.", 
                    takeWorldName, unreachablePathTotal, unresolvedTotal))

                if unreachablePathTotal > 0 then hasUnreachableItems = true end
                if unresolvedTotal > 0 then hasUnresolvedItems = true end
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
                    print(string.format("[Take] Tidak ada jalur fisik menuju OID %d di (%d, %d).", targetObj.oid, targetObj.x, targetObj.y))
                    if bot.status == BotStatus.online and isInTargetWorld(currentTakeWorld) then
                        unreachablePathCount[targetObj.oid] = (unreachablePathCount[targetObj.oid] or 0) + 1
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

                        local postCollectDC = (bot.status ~= BotStatus.online or not isInTargetWorld(currentTakeWorld))
                        local wasDC = sleepDC or postCollectDC

                        if wasDC then
                            print("[Take] Terdeteksi gangguan koneksi saat/pasca collect. Menjalankan recovery...")
                            ensureConnectionAndPosition(currentTakeWorld, targetObj.x, targetObj.y)
                        end

                        local afterCount = bot:getInventory():findItem(targetObj.id)

                        if afterCount > beforeCount then
                            -- Sukses mengambil item!
                            collectAttemptCount[targetObj.oid] = nil
                            unreachablePathCount[targetObj.oid] = nil
                        else
                            -- Bot sudah di tile objek tapi barang belum masuk tas:
                            -- Catat percobaan tanpa progres secara terbatas
                            local attempts = (collectAttemptCount[targetObj.oid] or 0) + 1
                            collectAttemptCount[targetObj.oid] = attempts

                            if attempts >= 4 then
                                -- Batas percobaan tercapai! Tandai sebagai unresolved (ambigu), JANGAN blacklist unreachable!
                                print(string.format("[Take Warning] Objek OID %d tidak bertambah di tas setelah %d percobaan. Menandai sebagai belum tuntas (ambigu) agar tidak loop tak terbatas.", targetObj.oid, attempts))
                                unresolvedCollectObjects[targetObj.oid] = true
                            else
                                print(string.format("[Take] Objek OID %d belum masuk tas (Percobaan %d/4). Mengulang pada siklus berikutnya...", targetObj.oid, attempts))
                            end
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

if hasUnreachableItems or hasUnresolvedItems then
    isTransferCompleted = false
    print(string.format("[Finish] PROSES SELESAI DENGAN CATATAN: Terdata %s%s. Seluruh item yang berhasil dijangkau telah dipindahkan ke storage.",
        hasUnreachableItems and "objek terhalang jalur (unreachable) " or "",
        hasUnresolvedItems and "objek belum tuntas terambil (ambigu)" or ""))
else
    isTransferCompleted = true
    print("[Finish] SEMUA ITEM DARI SELURUH TAKE WORLD TELAH BERHASIL DIPINDAHKAN KE STORAGE TANPA SISA! Script selesai.")
end
