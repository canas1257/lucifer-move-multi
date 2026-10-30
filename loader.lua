-- ==============================================================================
-- LOADER.LUA - MULTI-BOT MOVE CONTROLLER (Nuron's Lucifer v2.86)
-- https://github.com/canas1257/lucifer-move-multi
-- ==============================================================================

local CONFIG = {
    -- Target bot: "ALL" untuk semua bot yang ada di client,
    -- atau list nama spesifik: { "BOT1", "BOT2" }
    TARGET_BOTS = "ALL",

    -- Mode Gerakan:
    -- 1 = "GATHER"       (Semua bot kumpul di 1 tile target)
    -- 2 = "FORMATION"    (Bot berjejer horizontal membentuk barisan rapi)
    -- 3 = "FOLLOW"       (Semua follower mengikuti posisi leader secara realtime)
    -- 4 = "WARP_MOVE"    (Warp serentak ke world target, lalu kumpul atau formasi)
    MODE = 1,

    -- Koordinat Target (Tile) untuk Mode 1, 2, dan 4
    TARGET = {
        x = 50,
        y = 23,
    },

    -- Opsi untuk Mode 2: FORMATION
    FORMATION = {
        SPACING = 1,          -- Jarak antar-bot (dalam tile)
        DIRECTION = "RIGHT",  -- "RIGHT" (+x) atau "LEFT" (-x)
    },

    -- Opsi untuk Mode 3: FOLLOW
    FOLLOW = {
        LEADER_NAME = "",     -- Nama bot leader (kosongkan "" untuk memakai bot index 1)
        AUTO_WARP = true,     -- Jika follower beda world dengan leader, auto-warp ke world leader
        INTERVAL = 1000,      -- Interval polling pergerakan (ms)
        MIN_DISTANCE = 2,     -- Jarak minimal sebelum follower melangkah (tile Manhattan distance)
    },

    -- Opsi untuk Mode 4: WARP_MOVE
    WARP = {
        WORLD = "WORLD_TARGET",
        DOOR_ID = "",
        TIMEOUT = 15,         -- Batas timeout verifikasi kedatangan di world (detik)
        SUB_MODE = "GATHER",  -- "GATHER" (kumpul di 1 titik) atau "FORMATION" (berjejer)
    },

    -- Pengaturan Pergerakan & Sistem
    SETTINGS = {
        MOVE_INTERVAL = 0.20, -- Interval delay move (detik)
        USE_THREAD = true,    -- true = gerak serentak (runThread), false = antri bergantian
        TIMEOUT = 10,         -- Batas timeout pathfinding (detik)
    }
}

-- ==============================================================================
-- RAW ENGINE FETCHER (GitHub Raw)
-- ==============================================================================
local ENGINE_URL = "https://raw.githubusercontent.com/canas1257/lucifer-move-multi/main/engine.lua"

local function fetchAndRun()
    local client = HttpClient.new()
    client.url = ENGINE_URL
    client:setMethod(Method.get)
    client.timeout = 10
    client.headers = {
        ["User-Agent"] = "Lucifer"
    }

    local res = client:request()
    if res.error ~= 0 or res.status ~= 200 then
        print(string.format("[Error] Gagal mengunduh engine.lua (HTTP %d, Error: %s)", res.status, res:getError()))
        return
    end

    local loader = loadstring or load
    local chunk, err = loader(res.body, "engine.lua")
    if not chunk then
        print("[Error] Gagal parse engine.lua: " .. tostring(err))
        return
    end

    _G.CONFIG = CONFIG
    chunk(CONFIG)
end

fetchAndRun()
