-- Kiriman ke toko Mas Wahyu, tambahan: BARANG KELUAR (pengiriman ke lokasi) mengurangi stok titipan klien di halaman Titipan Seragam toko.
-- Syarat: migrasi-kirim-toko.sql sudah diterapkan. Aman dijalankan ulang. Pengirimnya tetap fungsi Edge `kirim-ke-toko`.
--
-- Yang ditangkap trigger: baris stok_gerak jenis 'keluar' yang `sumber`-nya kosong (= pengiriman; retur dan opname bertanda sendiri) dan
-- bersumber dari pengiriman (pengiriman_id terisi). Aksesoris tidak dikirim karena dibeli online, bukan titipan Mas Wahyu (seragam dan sepatu).
-- catat_pengiriman memasukkan seluruh baris satu pengiriman dalam SATU pernyataan insert, jadi satu pengiriman = satu kiriman,
-- issue_no = 'BK-<pengiriman_id>'. Baris keluar lama (sebelum trigger ini ada) tidak ikut terkirim.

alter table public.kirim_toko drop constraint if exists kirim_toko_jenis_check;
alter table public.kirim_toko add constraint kirim_toko_jenis_check check (jenis in ('barang_datang', 'barang_keluar', 'tagihan'));

create or replace function public._antre_toko_keluar() returns trigger
 language plpgsql security definer set search_path to 'public' as $f$
declare r record;
begin
  for r in
    select g.pengiriman_id, array_agg(g.id order by g.id) as ids, sum(g.qty)::int as qty, max(g.no_dokumen) as no_dokumen
      from baru g join public.harga_seragam h on h.no = g.item_no
     where g.jenis = 'keluar' and g.sumber is null and g.pengiriman_id is not null and h.kategori <> 'Aksesoris'
     group by g.pengiriman_id
  loop
    insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
      values ('barang_keluar', 'BK-' || r.pengiriman_id, r.ids, 'Pengiriman ' || coalesce(r.no_dokumen, '#' || r.pengiriman_id) || ' · ' || r.qty || ' pcs')
      on conflict (kunci) do nothing;
  end loop;
  return null;
end $f$;
revoke all on function public._antre_toko_keluar() from public, anon, authenticated;
drop trigger if exists antre_toko_keluar on public.stok_gerak;
create trigger antre_toko_keluar after insert on public.stok_gerak referencing new table as baru for each statement execute function public._antre_toko_keluar();

-- Bahan penyusun kiriman: barang datang dan barang keluar sama-sama baris stok beserta SKU toko-nya (null bila belum dipetakan).
create or replace function public.kirim_toko_data(p_id bigint) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare k public.kirim_toko%rowtype;
begin
  select * into k from public.kirim_toko where id = p_id;
  if not found then return null; end if;
  if k.jenis in ('barang_datang', 'barang_keluar') then
    return jsonb_build_object('jenis', k.jenis, 'kunci', k.kunci, 'baris', coalesce((
      select jsonb_agg(jsonb_build_object('item_no', g.item_no, 'item_nama', g.item_nama, 'jenis_ukuran', g.jenis_ukuran, 'ukuran', g.ukuran, 'qty', g.qty,
               'tanggal', g.tanggal, 'no_dokumen', g.no_dokumen, 'keterangan', g.keterangan, 'sku', public.sku_toko_untuk(g.item_no, g.jenis_ukuran, g.ukuran)) order by g.id)
        from public.stok_gerak g where g.id = any(k.ref_ids)), '[]'::jsonb));
  end if;
  return jsonb_build_object('jenis', k.jenis, 'kunci', k.kunci,
    'tagihan', (select jsonb_build_object('no_invoice', t.no_invoice, 'tanggal', t.tanggal, 'jatuh_tempo', t.jatuh_tempo, 'total', t.total, 'status', t.status, 'catatan', t.catatan)
                  from public.tagihan t where t.id = k.ref_ids[1]),
    'items', coalesce((select jsonb_agg(jsonb_build_object('item_nama', i.item_nama, 'qty', i.qty, 'harga', i.harga) order by i.id)
                         from public.tagihan_item i where i.tagihan_id = k.ref_ids[1]), '[]'::jsonb));
end $f$;
revoke all on function public.kirim_toko_data(bigint) from public, anon, authenticated;
grant execute on function public.kirim_toko_data(bigint) to service_role;
