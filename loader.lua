-- ==============================================================================
-- LOADER.LUA - MULTI-ITEM TRANSFER & STORAGE DROP (Nuron's Lucifer v2.86)
-- https://github.com/canas1257/lucifer-move-multi
-- Author  : Salsa & Bos Anas
-- ==============================================================================

local CONFIG = {
    -- Daftar ID item yang ingin dipindahkan dari take world ke storage
    -- Contoh: { 1, 2, 3, 4 } atau { 4584, 4585 }
    ITEMS = { 4584, 4585 },

    -- Daftar world sumber pengambilan barang (Take Worlds)
    -- Format: { world = "NAMA_WORLD", door = "DOOR_ID" } atau string "NAMA_WORLD"
    TAKE_WORLDS = {
        { world = "WORLD_TAKE1", door = "" },
        -- { world = "WORLD_TAKE2", door = "" },
    },

    -- World tujuan penyimpanan (Storage World)
    STORAGE_WORLD = { world = "WORLD_STORE", door = "" },

    -- Pengaturan Pergerakan & Drop
    SETTINGS = {
        MOVE_INTERVAL = 0.20,   -- Pacing delay jalan bot (detik)
        DROP_DELAY = 400,       -- Delay konfirmasi drop antar item (ms)
        MAX_DROP_RETRY = 15,    -- Maksimal geser ke kanan jika tile penuh (x + 1)
        WARP_TIMEOUT = 20,      -- Batas tunggu masuk world (detik)
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
