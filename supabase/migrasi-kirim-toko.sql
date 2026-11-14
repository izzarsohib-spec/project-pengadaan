-- Antrean kiriman ke toko Mas Wahyu (integrasi toko): barang datang dari Mas Wahyu menambah stok toko, tagihan tampil di Administrator toko.
-- Syarat: migrasi-sku-toko.sql sudah diterapkan (sku_toko_untuk). Pengirimnya fungsi Edge `kirim-ke-toko`.
--
-- Yang ditangkap trigger (tanpa mengubah fungsi yang sudah ada):
--   * stok_gerak: baris jenis 'masuk' yang `sumber`-nya kosong (= Barang datang dari supplier; retur dan opname bertanda sendiri)
--     dengan supplier yang cocok pola vendor toko. Pola ada di pengaturan 'toko_vendor' (default '%wahyu%', cocok dengan vendor "Wahyu Ardianto").
--     Satu pernyataan insert (satu kali simpan Barang datang) = satu kiriman, receipt_no = 'BD-<id terkecil>'.
--   * tagihan: tagihan baru, dan tagihan yang berubah jadi 'batal'. kunci = no_invoice (batal: no_invoice || '#batal').
-- Status antrean: menunggu (baru), terkirim, tertahan (belum bisa: SKU belum dipetakan / toko belum diatur / SKU belum ada di toko), gagal (toko tidak terjangkau atau menolak).
-- Tabel dan fungsi kirim_toko_* hanya untuk service role (fungsi Edge); browser memakai admin_daftar_kirim_toko (login admin).

create table if not exists public.kirim_toko (
  id bigint generated always as identity primary key,
  dibuat timestamptz not null default now(),
  jenis text not null check (jenis in ('barang_datang', 'tagihan')),
  kunci text not null unique,
  ref_ids bigint[] not null,
  ringkasan text,
  status text not null default 'menunggu' check (status in ('menunggu', 'terkirim', 'tertahan', 'gagal')),
  percobaan int not null default 0,
  galat text,
  terakhir_coba timestamptz,
  terkirim_pada timestamptz
);
create index if not exists kirim_toko_status_idx on public.kirim_toko (status, id);
alter table public.kirim_toko enable row level security;
revoke all on public.kirim_toko from anon, authenticated;

-- ---------- penangkap: barang datang ----------
create or replace function public._antre_toko_barang() returns trigger
 language plpgsql security definer set search_path to 'public' as $f$
declare pola text := coalesce((select nilai from public.pengaturan where kunci = 'toko_vendor'), '%wahyu%'); r record;
begin
  for r in
    select min(id) as awal, array_agg(id order by id) as ids, sum(qty)::int as qty, supplier, no_dokumen
      from baru where jenis = 'masuk' and sumber is null and supplier ilike pola
     group by supplier, no_dokumen, tanggal
  loop
    insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
      values ('barang_datang', 'BD-' || r.awal, r.ids, r.supplier || ' · ' || r.qty || ' pcs' || coalesce(' · dok ' || nullif(r.no_dokumen, ''), ''))
      on conflict (kunci) do nothing;
  end loop;
  return null;
end $f$;
revoke all on function public._antre_toko_barang() from public, anon, authenticated;
drop trigger if exists antre_toko_barang on public.stok_gerak;
create trigger antre_toko_barang after insert on public.stok_gerak referencing new table as baru for each statement execute function public._antre_toko_barang();

-- ---------- penangkap: tagihan ----------
create or replace function public._antre_toko_tagihan() returns trigger
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if tg_op = 'INSERT' then
    insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
      values ('tagihan', new.no_invoice, array[new.id], 'Tagihan ' || new.no_invoice || ' · Rp' || replace(to_char(new.total, 'FM999,999,999,999,999'), ',', '.')) on conflict (kunci) do nothing;
  elsif new.status = 'batal' and old.status is distinct from 'batal' then
    insert into public.kirim_toko (jenis, kunci, ref_ids, ringkasan)
      values ('tagihan', new.no_invoice || '#batal', array[new.id], 'Pembatalan tagihan ' || new.no_invoice) on conflict (kunci) do nothing;
  end if;
  return null;
end $f$;
revoke all on function public._antre_toko_tagihan() from public, anon, authenticated;
drop trigger if exists antre_toko_tagihan on public.tagihan;
create trigger antre_toko_tagihan after insert or update of status on public.tagihan for each row execute function public._antre_toko_tagihan();

-- ---------- untuk fungsi Edge (service role) ----------
-- Baris antrean yang boleh diproses. Otomatis: jeda 5 menit antar percobaan dan maksimal 60 percobaan; manual (admin): semua yang belum terkirim.
create or replace function public.kirim_toko_ambil(p_manual boolean, p_id bigint default null, p_maks int default 25)
 returns setof public.kirim_toko language sql stable security definer set search_path to 'public' as $f$
  select * from public.kirim_toko k
   where k.status <> 'terkirim' and (p_id is null or k.id = p_id)
     and (p_manual or (k.percobaan < 60 and (k.terakhir_coba is null or k.terakhir_coba < now() - interval '5 minutes')))
   order by k.id limit greatest(1, least(coalesce(p_maks, 25), 100)) $f$;

-- Bahan penyusun kiriman: barang datang = baris stok beserta SKU toko-nya (null bila belum dipetakan); tagihan = kepala dan rincian.
create or replace function public.kirim_toko_data(p_id bigint) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare k public.kirim_toko%rowtype;
begin
  select * into k from public.kirim_toko where id = p_id;
  if not found then return null; end if;
  if k.jenis = 'barang_datang' then
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

-- Catat hasil satu percobaan. p_dicoba = benar-benar menghubungi toko; p_reset = dipicu manual (hitungan percobaan mulai dari nol).
create or replace function public.kirim_toko_catat(p_id bigint, p_status text, p_galat text, p_dicoba boolean, p_reset boolean) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if p_status not in ('terkirim', 'tertahan', 'gagal') then raise exception 'status tidak dikenal'; end if;
  update public.kirim_toko set status = p_status, galat = left(p_galat, 400), terakhir_coba = now(),
         percobaan = (case when p_reset then 0 else percobaan end) + (case when p_dicoba then 1 else 0 end),
         terkirim_pada = case when p_status = 'terkirim' then now() else terkirim_pada end
   where id = p_id;
end $f$;

do $$ declare f text; begin
  foreach f in array array['kirim_toko_ambil(boolean,bigint,int)', 'kirim_toko_data(bigint)', 'kirim_toko_catat(bigint,text,text,boolean,boolean)', 'sku_toko_untuk(int,text,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- ---------- untuk halaman Administrator (login admin) ----------
create or replace function public.admin_daftar_kirim_toko(kode text, p_batas int default 200)
 returns table(id bigint, dibuat timestamptz, jenis text, kunci text, ringkasan text, status text, percobaan int, galat text, terakhir_coba timestamptz, terkirim_pada timestamptz)
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  perform public._wajib_kode(kode);
  return query select k.id, k.dibuat, k.jenis, k.kunci, k.ringkasan, k.status, k.percobaan, k.galat, k.terakhir_coba, k.terkirim_pada
    from public.kirim_toko k order by k.id desc limit greatest(1, least(coalesce(p_batas, 200), 500));
end $f$;
revoke all on function public.admin_daftar_kirim_toko(text, int) from public; grant execute on function public.admin_daftar_kirim_toko(text, int) to anon, authenticated;
