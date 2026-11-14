# alat/

## cek-tata-letak.mjs

Pemeriksa tata letak otomatis untuk web administrasi pengadaan (halaman modul Seragam). Membuka tiap halaman di Chrome, lalu melaporkan masalah tampilan. Butuh **Node 22+** dan **Google Chrome**; tidak perlu instal paket apa pun.

```
node alat/cek-tata-letak.mjs                                   # situs langsung, semua halaman, layar 1500x1000
node alat/cek-tata-letak.mjs --halaman datang,kurang,retur     # sebagian halaman
node alat/cek-tata-letak.mjs --lebar 1366 --tinggi 768         # ukuran layar lain
node alat/cek-tata-letak.mjs --url http://localhost:8000/seragam/   # versi lokal
node alat/cek-tata-letak.mjs --keluar alat/hasil --json alat/hasil/laporan.json   # simpan tangkapan layar dan laporan
node alat/cek-tata-letak.mjs --halaman ploting --editor --tinggi 1300 --keluar alat/hasil   # buka form ploting (10 karyawan palsu, login palsu, penulisan ke server diblokir)
```

Tingkat temuan:
- **KRITIS**: kontrol keluar dari kartunya, isi terpotong (overflow tersembunyi), error JavaScript. Kode keluar 1 bila ada.
- **PERINGATAN**: tabel yang harus digeser ke samping, teks dropdown terpotong.
- **INFO**: halaman bergulir melebihi layar, kartu `.k3` dengan ruang kosong besar atau sudut atau latar tidak sama dengan acuan (16px, putih), huruf kecil dari 10,5px.

Acuan gaya: halaman **Monitoring pengisian** (kartu putih polos di atas latar halaman: sudut 16px, padding 20px 22px, garis tipis #DCE3EC, bayangan halus, judul 15px). Susunan kolom Barang datang dan kawan-kawan tetap tutorial di kiri. Jalankan sebelum push setelah mengubah halaman mana pun; temuan INFO "ruang kosong" pada kartu yang memang kosong (belum ada data) bisa diabaikan.

## pasang-konfirmasi-vendor.ps1

Memasang fitur konfirmasi Mas Wahyu lewat ntfy (rekap pesanan dan surat kekurangan) di Supabase. Dijalankan **oleh pemilik proyek** dari PowerShell (membutuhkan kunci `supabase` di keystore lokal; kunci tidak ada di repo):

```
powershell -ExecutionPolicy Bypass -File alat/pasang-konfirmasi-vendor.ps1 -TanpaTopik
```

Yang dilakukan:
1. Menerapkan migrasi database `supabase/migrasi-konfirmasi-vendor.sql` dan `supabase/migrasi-kekurangan-surat.sql`.
2. Men-deploy fungsi `supabase/functions/konfirmasi-vendor` (tanpa verify_jwt, karena tombol ntfy tidak bisa mengirim JWT; keamanan lewat token acak per pengiriman).
3. Mengunggah tanda tangan vendor `Documents	td-wahyu.png` ke bucket privat `tanda-tangan/wahyu.png` (tidak ada di repo).
4. Tanpa `-TanpaTopik`: membuat rahasia `NTFY_TOPIC_WAHYU` (topik ntfy vendor) dan menyimpannya di `Documents
tfy-wahyu-topik.txt`.

Skrip pemasangan lain (`pasang-*.ps1` untuk rekap, TTD, penambahan item) masih ada di `Documents` pemilik proyek.

## pasang-riwayat-ploting.ps1

Menerapkan `supabase/migrasi-riwayat-ploting.sql` (tabel `ploting_riwayat`, trigger, fungsi `daftar_riwayat_ploting`) untuk kartu Riwayat ploting. Dijalankan **oleh pemilik proyek** (butuh kunci `supabase` di keystore lokal):

```
powershell -ExecutionPolicy Bypass -File alat/pasang-riwayat-ploting.ps1
```

## pasang-sku-toko.ps1 dan pasang-kirim-toko.ps1

Integrasi ke toko Mas Wahyu. `pasang-sku-toko.ps1` hanya menerapkan `supabase/migrasi-sku-toko.sql` (tab Administrator SKU toko). `pasang-kirim-toko.ps1` memasang semuanya: kedua migrasi, fungsi Edge `kirim-ke-toko`, rahasia, dan jadwal pg_cron tiap menit. Dijalankan **oleh pemilik proyek** (butuh kunci `supabase` di keystore). Aman dijalankan ulang.

```
powershell -ExecutionPolicy Bypass -File alat/pasang-kirim-toko.ps1 -BuatRahasia -TokoUrl https://alamat-toko/api/integrations/pengadaan
```

- Tanpa `-TokoUrl`, kiriman berstatus **Tertahan** sampai toko diatur (berguna untuk menguji pengisian data dulu).
- `-BuatRahasia` membuat rahasia bersama dan menyimpannya di `Documents\toko-rahasia.txt` (bukan di repo); nilai yang sama harus diisi ke `PENGADAAN_WEBHOOK_SECRET` di server toko. Atau pakai `-Rahasia <teks>` bila toko sudah punya.
- Uji inti pengirim: `node --test supabase/functions/kirim-ke-toko/inti.test.ts` (Node 22.18+).
