-- Kiriman ke toko Mas Wahyu, tambahan: PEMBAYARAN tagihan. Saat tagihan dibayar di pengadaan (catat_bayar), statusnya ikut jadi
-- LUNAS di halaman Titipan Seragam toko lengkap dengan tanggal bayar terakhir; pembayaran sebagian tetap "belum dibayar"
-- dengan catatan jumlah yang sudah dibayar. Syarat: migrasi-kirim-toko.sql dan migrasi-kirim-toko-keluar.sql sudah diterapkan.
-- Aman dijalankan ulang. Toko HARUS sudah menerima status LUNAS (versi toko 9775a51 atau lebih baru).
--
-- kunci antrean = no_invoice || '#bayar-' || jumlah terbayar (satu per perubahan jumlah). Kiriman disusun dari keadaan tagihan SAAT
-- DIKIRIM, jadi kiriman dasar maupun kiriman pembayaran selalu membawa status terbaru.

create or replace function public._antre_toko_tagihan() returns trigger
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if tg_op = 'INSERT' then
    insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
      values ('tagihan', new.no_invoice, array[new.id], 'Tagihan ' || new.no_invoice || ' · Rp' || replace(to_char(new.total, 'FM999,999,999,999,999'), ',', '.')) on conflict (kunci) do nothing;
  elsif new.status = 'batal' and old.status is distinct from 'batal' then
    insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
      values ('tagihan', new.no_invoice || '#batal', array[new.id], 'Pembatalan tagihan ' || new.no_invoice) on conflict (kunci) do nothing;
  elsif new.status in ('lunas', 'sebagian') and new.terbayar is distinct from old.terbayar then
    insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
      values ('tagihan', new.no_invoice || '#bayar-' || new.terbayar, array[new.id],
              'Pembayaran tagihan ' || new.no_invoice || ' · Rp' || replace(to_char(new.terbayar, 'FM999,999,999,999,999'), ',', '.') || case when new.status = 'lunas' then ' (lunas)' else ' (sebagian)' end)
      on conflict (kunci) do nothing;
  end if;
  return null;
end $f$;
revoke all on function public._antre_toko_tagihan() from public, anon, authenticated;
drop trigger if exists antre_toko_tagihan on public.tagihan;
create trigger antre_toko_tagihan after insert or update of status, terbayar on public.tagihan for each row execute function public._antre_toko_tagihan();

-- Bahan penyusun kiriman: tagihan kini membawa jumlah terbayar dan tanggal pembayaran terakhir.
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
    'tagihan', (select jsonb_build_object('no_invoice', t.no_invoice, 'tanggal', t.tanggal, 'jatuh_tempo', t.jatuh_tempo, 'total', t.total, 'status', t.status, 'catatan', t.catatan,
                       'terbayar', t.terbayar, 'tgl_bayar', (select max(b.tanggal) from public.tagihan_bayar b where b.tagihan_id = t.id))
                  from public.tagihan t where t.id = k.ref_ids[1]),
    'items', coalesce((select jsonb_agg(jsonb_build_object('item_nama', i.item_nama, 'qty', i.qty, 'harga', i.harga) order by i.id)
                         from public.tagihan_item i where i.tagihan_id = k.ref_ids[1]), '[]'::jsonb));
end $f$;
revoke all on function public.kirim_toko_data(bigint) from public, anon, authenticated;
grant execute on function public.kirim_toko_data(bigint) to service_role;
