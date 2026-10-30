# Lucifer Move Multi

Skrip kontrol pergerakan multi-bot modular untuk **Nuron's Lucifer (Growtopia)** v2.86.

Dirancang oleh **Salsa** & **Bos Anas** (@canas1257), dengan review teknis oleh **Anna** (@anna).

---

## 🚀 Fitur Utama

1. **Paralel & Non-Blocking (`runThread`)**
   Pergerakan `bot:findPath()` dijalankan secara independen melalui thread per bot sehingga semua bot bergerak serentak tanpa antre.
2. **Busy Lock Guard**
   Setiap bot memiliki status `isBusy` yang dilindungi blok `pcall`. Menghindari penumpukan thread/eksekusi berulang jika pergerakan sebelumnya belum rampung.
3. **World Consistency Guard pada Mode Follow**
   Bot follower memverifikasi apakah berada di world yang sama dengan bot Leader. Dilengkapi fitur `AUTO_WARP` opsional jika terpisah world.
4. **Warp Verification pada Mode Warp & Move**
   Memverifikasi kedatangan bot di world tujuan melalui polling status `bot:isInWorld()` dengan batas timeout, bukan sekadar jeda `sleep()`. Bot yang gagal masuk world tidak akan salah bergerak di world lama.

---

## 🕹️ Mode Pergerakan

| Mode | Nama | Penjelasan |
| :---: | :--- | :--- |
| `1` | **GATHER** | Semua bot bergerak serentak menuju koordinat tile `(x, y)` yang sama. |
| `2` | **FORMATION** | Bot berjejer horizontal membentuk barisan dengan jarak (`SPACING`) dan arah (`DIRECTION`) tertentu. |
| `3` | **FOLLOW** | Seluruh follower membuntuti posisi Leader bot secara realtime. |
| `4` | **WARP_MOVE** | Seluruh bot di-warp serentak ke world target, diverifikasi kedatangannya, lalu kumpul (`GATHER`) atau berbaris (`FORMATION`). |

---

## 📂 Struktur File

- `loader.lua`: Skrip konfigurasi ringan untuk dieksekusi di aplikasi Lucifer. Mengambil `engine.lua` secara realtime dari GitHub Raw.
- `engine.lua`: Core engine multi-bot movement yang memproses pergerakan dan penjagaan thread.

---

## ⚙️ Cara Pakai

1. Buka file `loader.lua`.
2. Sesuaikan tabel `CONFIG` (pilih mode, koordinat target, dsb).
3. Jalankan `loader.lua` di Lucifer bot.
