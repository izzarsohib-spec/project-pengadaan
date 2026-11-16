-- SEKALI JALAN: memasukkan data lama (sebelum trigger kirim ke toko ada) ke antrean kiriman supaya toko Mas Wahyu sama dengan pengadaan.
-- Syarat: migrasi-kirim-toko.sql, migrasi-kirim-toko-keluar.sql, dan migrasi-kirim-toko-bayar.sql sudah diterapkan, dan toko sudah terpasang.
-- Aman dijalankan ulang: kunci antrean unik, dan baris stok yang sudah masuk antrean dilewati. Kiriman disusun saat dikirim, jadi
-- tagihan lama otomatis membawa status lunas dan tanggal bayarnya. Tagihan batal tidak dikirim.
-- Data lama ini berlabel DEMO (data uji), jadi bila toko perlu dibersihkan lagi hapus lewat Supabase toko (titipan_moves, pengadaan_receipts,
-- pengadaan_issues, pengadaan_invoices) dan kosongkan antrean kirim_toko di pengadaan.

-- 1. tagihan lama
insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
select 'tagihan', t.no_invoice, array[t.id], 'Tagihan ' || t.no_invoice || ' · Rp' || replace(to_char(t.total, 'FM999,999,999,999,999'), ',', '.')
  from public.tagihan t
 where t.status <> 'batal'
 order by t.id
on conflict (kunci) do nothing;

-- 2. barang datang dari vendor toko (pola pengaturan 'toko_vendor', bawaan %wahyu%), dikelompokkan per supplier + dokumen + tanggal
insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
select 'barang_datang', 'BD-' || min(g.id), array_agg(g.id order by g.id),
       g.supplier || ' · ' || sum(g.qty)::int || ' pcs' || coalesce(' · dok ' || nullif(g.no_dokumen, ''), '')
  from public.stok_gerak g
 where g.jenis = 'masuk' and g.sumber is null
   and g.supplier ilike coalesce((select nilai from public.pengaturan where kunci = 'toko_vendor'), '%wahyu%')
   and not exists (select 1 from public.kirim_toko k where g.id = any(k.ref_ids))
 group by g.supplier, g.no_dokumen, g.tanggal
 order by min(g.id)
on conflict (kunci) do nothing;

-- 3. pengiriman ke lokasi (tanpa aksesoris), satu kiriman per pengiriman
insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
select 'barang_keluar', 'BK-' || g.pengiriman_id, array_agg(g.id order by g.id),
       'Pengiriman ' || coalesce(max(g.no_dokumen), '#' || g.pengiriman_id) || ' · ' || sum(g.qty)::int || ' pcs'
  from public.stok_gerak g join public.harga_seragam h on h.no = g.item_no
 where g.jenis = 'keluar' and g.sumber is null and g.pengiriman_id is not null and h.kategori <> 'Aksesoris'
   and not exists (select 1 from public.kirim_toko k where g.id = any(k.ref_ids))
 group by g.pengiriman_id
 order by g.pengiriman_id
on conflict (kunci) do nothing;
