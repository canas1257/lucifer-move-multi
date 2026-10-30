# Lucifer Move Multi (Multi-Item Transfer & Storage Drop)

Skrip otomatisasi untuk **Nuron's Lucifer (Growtopia)** v2.86 untuk memindahkan banyak jenis item sekaligus dari beberapa World Sumber (Take Worlds) ke World Penyimpanan (Storage World), dengan sistem drop terpisah secara vertikal per item ID dan auto-shift koordinat jika tile penuh.

Dirancang oleh **Salsa** & **Bos Anas** (@canas1257), dengan review teknis oleh **Anna** (@anna).

---

## 🚀 Fitur Utama

1. **Multi-Item Scanning & Filtering**
   - Mendukung pemindahan banyak jenis item sekaligus (`CONFIG.ITEMS = { id1, id2, id3, ... }`).
   - Menyaring floating objects di world secara otomatis berdasarkan ID target.
   - Pengecekan tas per item: jika salah satu item sudah mencapai 200 di tas, bot akan sementara skip item tersebut dan tetap mengambil item target lainnya sampai semua penuh atau world bersih.

2. **Pemisahan Drop Vertikal di Storage**
   - Titik awal drop dimulai dari posisi bot tiba di Storage World (`world|id`), dengan proteksi otomatis menghindari White Door (ID 6).
   - Item 1 di-drop di lantai dasar `(X, Y)`.
   - Item 2 di-drop di atasnya `(X, Y - 1)`.
   - Item 3 di-drop di atasnya lagi `(X, Y - 2)`, dst.
   - Bot otomatis **menghadap ke kanan** sebelum melakukan drop.

3. **Auto-Shift Tile Penuh (Max 4.000 Item / 20 Objek)**
   - Jika tile drop sudah mencapai batas maksimum (gagal drop), bot otomatis maju 1 tile ke kanan (`X + 1`), drop ulang, dan memperbarui koordinat drop untuk item tersebut.
   - Pada trip storage berikutnya, bot langsung menggunakan koordinat baru yang sudah tercatat.

4. **Multi-World Take Support**
   - Bot menyapu world take pertama sampai bersih.
   - Jika barang target di world tersebut sudah habis, bot otomatis lanjut ke world take berikutnya.
   - Di akhir seluruh rotasi, bot melakukan drop sisa barang di backpack ke storage lalu selesai.

---

## 📂 Struktur File

- `loader.lua`: Skrip ringan untuk dieksekusi di bot Lucifer. Berisi tabel `CONFIG` dan mengunduh `engine.lua` secara realtime dari GitHub Raw.
- `engine.lua`: Core engine transfer & drop yang di-host di GitHub Raw.

---

## ⚙️ Cara Pakai

1. Buka `loader.lua`.
2. Masukkan ID item yang ingin dipindahkan pada `ITEMS`:
   ```lua
   ITEMS = { 4584, 4585 }
   ```
3. Tentukan daftar `TAKE_WORLDS` dan `STORAGE_WORLD`:
   ```lua
   TAKE_WORLDS = {
       { world = "TAKE1", door = "" },
       { world = "TAKE2", door = "" },
   },
   STORAGE_WORLD = { world = "STORE1", door = "" },
   ```
4. Jalankan `loader.lua` di bot Lucifer.
