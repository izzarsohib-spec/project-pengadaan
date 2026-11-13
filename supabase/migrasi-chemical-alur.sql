-- Chemical tahap A: status periode, pencocokan per lokasi, biaya operasional, dan pengajuan anggaran ke pimpinan.
-- Alur status periode (maju satu arah): FORM -> REKAP -> DIAJUKAN -> DISETUJUI -> BELANJA -> PLOTING -> PENGIRIMAN -> DILAPORKAN.
-- Tahap A memakai FORM sampai DISETUJUI; sisanya dipakai tahap B-D.
-- Persetujuan: Pak Yasir dan Pak Ferry, masing-masing lewat tautan bertoken (tanpa login). Ditolak salah satu = ditolak; disetujui keduanya = disetujui.

update public.chemical_periode set status = 'FORM' where status = 'DRAFT';
alter table public.chemical_periode alter column status set default 'FORM';
alter table public.chemical_periode drop constraint if exists chemical_periode_status_cek;
alter table public.chemical_periode add constraint chemical_periode_status_cek
  check (status in ('FORM','REKAP','DIAJUKAN','DISETUJUI','BELANJA','PLOTING','PENGIRIMAN','DILAPORKAN'));

create table if not exists public.chemical_pencocokan (
  periode_id bigint not null references public.chemical_periode(id) on delete cascade,
  lokasi_id bigint not null references public.chemical_lokasi(id),
  cocok boolean not null default false,
  lewat_rab boolean not null default false,        -- permintaan melebihi RAB dan diajukan sebagai pengecualian
  catatan text,
  diubah timestamptz not null default now(),
  primary key (periode_id, lokasi_id));

create table if not exists public.chemical_biaya (
  id bigint generated always as identity primary key,
  periode_id bigint not null references public.chemical_periode(id) on delete cascade,
  kategori text not null,
  estimasi numeric not null default 0 check (estimasi >= 0),
  aktual numeric check (aktual is null or aktual >= 0),   -- diisi di tahap pengeluaran
  metode text not null default 'proporsional' check (metode in ('proporsional','rata','langsung')),
  lokasi_id bigint references public.chemical_lokasi(id),  -- dipakai bila metode = langsung
  catatan text,
  dibuat timestamptz not null default now());
create index if not exists chemical_biaya_periode_idx on public.chemical_biaya (periode_id);

create table if not exists public.chemical_pengajuan (
  id bigint generated always as identity primary key,
  periode_id bigint not null references public.chemical_periode(id) on delete cascade,
  ke int not null default 1,
  dibuat timestamptz not null default now(),
  catatan text,
  rincian jsonb not null,                           -- salinan angka saat diajukan (toko, operasional, lokasi)
  total numeric not null,
  status text not null default 'MENUNGGU' check (status in ('MENUNGGU','DISETUJUI','DITOLAK','DITARIK')),
  token_yasir text not null default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  token_ferry text not null default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  status_yasir text not null default 'MENUNGGU' check (status_yasir in ('MENUNGGU','SETUJU','TOLAK')),
  status_ferry text not null default 'MENUNGGU' check (status_ferry in ('MENUNGGU','SETUJU','TOLAK')),
  waktu_yasir timestamptz, waktu_ferry timestamptz, alasan_yasir text, alasan_ferry text,
  unique (periode_id, ke), unique (token_yasir), unique (token_ferry));

alter table public.chemical_pencocokan enable row level security;  revoke all on public.chemical_pencocokan from anon, authenticated;
alter table public.chemical_biaya enable row level security;       revoke all on public.chemical_biaya from anon, authenticated;
alter table public.chemical_pengajuan enable row level security;   revoke all on public.chemical_pengajuan from anon, authenticated;

-- ===== periode: buka/tutup form dengan aturan status =====
create or replace function public.chemical_atur_periode(p_bulan int, p_tahun int, p_dibuka boolean) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare r public.chemical_periode;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into r from public.chemical_periode where bulan = p_bulan and tahun = p_tahun;
  if not found then
    insert into public.chemical_periode (bulan, tahun, form_dibuka, status) values (p_bulan, p_tahun, p_dibuka, case when p_dibuka then 'FORM' else 'REKAP' end) returning * into r;
  else
    if r.status not in ('FORM','REKAP') then raise exception 'periode sudah melewati tahap rekap; form tidak bisa dibuka atau ditutup lagi'; end if;
    update public.chemical_periode set form_dibuka = p_dibuka, status = case when p_dibuka then 'FORM' else 'REKAP' end where id = r.id returning * into r;
  end if;
  return jsonb_build_object('id', r.id, 'bulan', r.bulan, 'tahun', r.tahun, 'status', r.status, 'form_dibuka', r.form_dibuka, 'token', r.token);
end $f$;

-- ===== rekap =====
create or replace function public.chemical_rekap_data(p_periode bigint) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare p public.chemical_periode;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into p from public.chemical_periode where id = p_periode;
  if not found then raise exception 'periode tidak ditemukan'; end if;
  return jsonb_build_object(
    'periode', jsonb_build_object('id', p.id, 'bulan', p.bulan, 'tahun', p.tahun, 'status', p.status, 'form_dibuka', p.form_dibuka, 'token', p.token),
    'lokasi', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'nama', l.nama, 'rab_bulan', l.rab_bulan, 'mode', l.mode_anggaran, 'pinjam_seragam', l.pinjam_seragam, 'kebijakan', l.kebijakan, 'aktif', l.aktif,
        'kiriman', (select jsonb_build_object('id', k.id, 'pengirim', k.pengirim, 'email', k.email, 'dikirim', k.dikirim, 'catatan', k.catatan) from public.chemical_kiriman k where k.periode_id = p.id and k.lokasi_id = l.id),
        'cocok', coalesce(c.cocok, false), 'lewat_rab', coalesce(c.lewat_rab, false), 'catatan_cocok', c.catatan) order by l.nama)
      from public.chemical_lokasi l left join public.chemical_pencocokan c on c.periode_id = p.id and c.lokasi_id = l.id
      where l.aktif or exists (select 1 from public.chemical_kiriman k where k.periode_id = p.id and k.lokasi_id = l.id)), '[]'::jsonb),
    'baris', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'lokasi_id', m.lokasi_id, 'item_id', m.item_id, 'bebas', m.item_id is null, 'nama', coalesce(i.nama, m.nama_bebas), 'satuan', coalesce(i.satuan, m.satuan_bebas),
        'qty', m.qty, 'toko_id', i.toko_id, 'toko', t.nama, 'harga_beli', i.harga_beli, 'harga_jual', i.harga_jual) order by coalesce(i.nama, m.nama_bebas))
      from public.chemical_permintaan m left join public.chemical_item i on i.id = m.item_id left join public.chemical_toko t on t.id = i.toko_id where m.periode_id = p.id), '[]'::jsonb));
end $f$;

create or replace function public._chemical_status_ok(p_periode bigint) returns void
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not exists (select 1 from public.chemical_periode where id = p_periode and status in ('FORM','REKAP')) then raise exception 'periode sudah diajukan; data tidak bisa diubah (tarik pengajuan dulu)'; end if;
end $f$;
revoke all on function public._chemical_status_ok(bigint) from public, anon, authenticated;

create or replace function public.chemical_ubah_qty(p_permintaan bigint, p_qty numeric) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare m public.chemical_permintaan;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into m from public.chemical_permintaan where id = p_permintaan;
  if not found then raise exception 'baris tidak ditemukan'; end if;
  perform public._chemical_status_ok(m.periode_id);
  if p_qty is null or p_qty < 0 or p_qty > 100000 then raise exception 'jumlah tidak valid'; end if;
  if p_qty = 0 then delete from public.chemical_permintaan where id = p_permintaan; else update public.chemical_permintaan set qty = p_qty where id = p_permintaan; end if;
  update public.chemical_pencocokan set cocok = false, diubah = now() where periode_id = m.periode_id and lokasi_id = m.lokasi_id;
end $f$;

-- petakan barang lain ke barang katalog (jumlah digabung bila barang itu sudah dipesan di kiriman yang sama)
create or replace function public.chemical_petakan_bebas(p_permintaan bigint, p_item bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare m public.chemical_permintaan; ada bigint;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into m from public.chemical_permintaan where id = p_permintaan and item_id is null;
  if not found then raise exception 'baris barang lain tidak ditemukan'; end if;
  perform public._chemical_status_ok(m.periode_id);
  if not exists (select 1 from public.chemical_item where id = p_item and aktif) then raise exception 'barang katalog tidak ditemukan'; end if;
  select id into ada from public.chemical_permintaan where kiriman_id = m.kiriman_id and item_id = p_item;
  if ada is not null then update public.chemical_permintaan set qty = qty + m.qty where id = ada; delete from public.chemical_permintaan where id = m.id;
  else update public.chemical_permintaan set item_id = p_item, nama_bebas = null, satuan_bebas = null where id = m.id; end if;
  update public.chemical_pencocokan set cocok = false, diubah = now() where periode_id = m.periode_id and lokasi_id = m.lokasi_id;
end $f$;

-- jadikan barang lain sebagai barang katalog baru (nama dan satuan dari isian korlap) lalu petakan
create or replace function public.chemical_buat_item_dari_bebas(p_permintaan bigint, p_toko bigint, p_beli numeric, p_jual numeric) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare m public.chemical_permintaan; iid bigint;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into m from public.chemical_permintaan where id = p_permintaan and item_id is null;
  if not found then raise exception 'baris barang lain tidak ditemukan'; end if;
  if p_beli is null or p_beli < 0 or p_jual is null or p_jual < 0 then raise exception 'harga beli dan jual wajib diisi'; end if;
  select id into iid from public.chemical_item where toko_id = p_toko and lower(nama) = lower(m.nama_bebas);
  if iid is null then
    insert into public.chemical_item (toko_id, nama, satuan, harga_beli, harga_jual, perlu_ditinjau, catatan)
      values (p_toko, m.nama_bebas, m.satuan_bebas, p_beli, p_jual, true, 'dibuat dari barang lain korlap') returning id into iid;
  end if;
  perform public.chemical_petakan_bebas(p_permintaan, iid);
  return iid;
end $f$;

-- tandai lokasi cocok (atau batalkan); aturan menurut mode anggaran lokasi
create or replace function public.chemical_cocokkan(p_periode bigint, p_lokasi bigint, p_cocok boolean, p_lewat boolean, p_catatan text) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare l public.chemical_lokasi; jual numeric;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  perform public._chemical_status_ok(p_periode);
  select * into l from public.chemical_lokasi where id = p_lokasi;
  if not found then raise exception 'lokasi tidak ditemukan'; end if;
  if p_cocok then
    if not exists (select 1 from public.chemical_kiriman where periode_id = p_periode and lokasi_id = p_lokasi) then raise exception 'lokasi ini belum mengirim permintaan'; end if;
    if exists (select 1 from public.chemical_permintaan where periode_id = p_periode and lokasi_id = p_lokasi and item_id is null) then raise exception 'masih ada barang lain yang belum diberi harga atau dipetakan'; end if;
    select coalesce(sum(m.qty * i.harga_jual), 0) into jual from public.chemical_permintaan m join public.chemical_item i on i.id = m.item_id where m.periode_id = p_periode and m.lokasi_id = p_lokasi;
    if jual > 0 and exists (select 1 from public.chemical_permintaan m join public.chemical_item i on i.id = m.item_id where m.periode_id = p_periode and m.lokasi_id = p_lokasi and i.harga_jual is null) then raise exception 'ada barang tanpa harga jual'; end if;
    if l.mode_anggaran <> 'tanpa_batas' and l.rab_bulan is not null and jual > l.rab_bulan then
      if l.mode_anggaran = 'ketat' then raise exception 'melebihi RAB dan lokasi ini berkebijakan ketat; kurangi jumlah dulu'; end if;
      if not coalesce(p_lewat, false) then raise exception 'melebihi RAB; centang "ajukan sebagai pengecualian" untuk melanjutkan'; end if;
    end if;
  end if;
  insert into public.chemical_pencocokan (periode_id, lokasi_id, cocok, lewat_rab, catatan, diubah)
    values (p_periode, p_lokasi, coalesce(p_cocok, false), coalesce(p_lewat, false) and coalesce(p_cocok, false), nullif(btrim(p_catatan), ''), now())
    on conflict (periode_id, lokasi_id) do update set cocok = excluded.cocok, lewat_rab = excluded.lewat_rab, catatan = excluded.catatan, diubah = now();
  return jsonb_build_object('ok', true);
end $f$;

-- ===== biaya operasional (estimasi di tahap ini; aktual di tahap pengeluaran) =====
create or replace function public.chemical_daftar_biaya(p_periode bigint) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return coalesce((select jsonb_agg(to_jsonb(b) order by b.id) from public.chemical_biaya b where b.periode_id = p_periode), '[]'::jsonb);
end $f$;

create or replace function public.chemical_simpan_biaya(p_id bigint, p_periode bigint, p_kategori text, p_estimasi numeric, p_aktual numeric, p_metode text, p_lokasi bigint) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if coalesce(btrim(p_kategori), '') = '' then raise exception 'kategori biaya wajib diisi'; end if;
  if coalesce(p_estimasi, 0) < 0 or coalesce(p_aktual, 0) < 0 then raise exception 'angka tidak boleh negatif'; end if;
  if p_metode = 'langsung' and p_lokasi is null then raise exception 'metode langsung perlu lokasi tujuan'; end if;
  if p_id is null then
    perform public._chemical_status_ok(p_periode);
    insert into public.chemical_biaya (periode_id, kategori, estimasi, aktual, metode, lokasi_id) values (p_periode, btrim(p_kategori), coalesce(p_estimasi, 0), p_aktual, coalesce(p_metode, 'proporsional'), case when p_metode = 'langsung' then p_lokasi end) returning id into v;
  else
    update public.chemical_biaya set kategori = btrim(p_kategori), estimasi = coalesce(p_estimasi, 0), aktual = p_aktual, metode = coalesce(p_metode, 'proporsional'), lokasi_id = case when p_metode = 'langsung' then p_lokasi end where id = p_id returning id into v;
    if v is null then raise exception 'biaya tidak ditemukan'; end if;
  end if;
  return v;
end $f$;

create or replace function public.chemical_hapus_biaya(p_id bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare pid bigint;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select periode_id into pid from public.chemical_biaya where id = p_id;
  if pid is null then return; end if;
  perform public._chemical_status_ok(pid);
  delete from public.chemical_biaya where id = p_id;
end $f$;

-- ===== pengajuan =====
-- angka pengajuan dihitung dari data saat ini: belanja per toko (harga beli), operasional (estimasi), dan ringkasan tiap lokasi
create or replace function public._chemical_rincian(p_periode bigint) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare toko jsonb; ops jsonb; lok jsonb; beli numeric; opst numeric;
begin
  select coalesce(jsonb_agg(jsonb_build_object('toko', t.nama, 'total', s.total) order by t.nama), '[]'::jsonb), coalesce(sum(s.total), 0) into toko, beli
    from (select i.toko_id, sum(m.qty * i.harga_beli) total from public.chemical_permintaan m join public.chemical_item i on i.id = m.item_id where m.periode_id = p_periode group by i.toko_id) s join public.chemical_toko t on t.id = s.toko_id;
  select coalesce(jsonb_agg(jsonb_build_object('kategori', b.kategori, 'estimasi', b.estimasi) order by b.id), '[]'::jsonb), coalesce(sum(b.estimasi), 0) into ops, opst from public.chemical_biaya b where b.periode_id = p_periode;
  select coalesce(jsonb_agg(jsonb_build_object('lokasi', l.nama, 'jual', coalesce(x.jual, 0), 'beli', coalesce(x.beli, 0), 'rab', l.rab_bulan, 'mode', l.mode_anggaran, 'lewat_rab', coalesce(c.lewat_rab, false), 'cocok', coalesce(c.cocok, false), 'catatan', c.catatan) order by l.nama), '[]'::jsonb) into lok
    from public.chemical_lokasi l
    join (select m.lokasi_id, sum(m.qty * i.harga_jual) jual, sum(m.qty * i.harga_beli) beli from public.chemical_permintaan m join public.chemical_item i on i.id = m.item_id where m.periode_id = p_periode group by m.lokasi_id) x on x.lokasi_id = l.id
    left join public.chemical_pencocokan c on c.periode_id = p_periode and c.lokasi_id = l.id;
  return jsonb_build_object('toko', toko, 'beli', beli, 'ops', ops, 'ops_total', opst, 'total', beli + opst, 'lokasi', lok);
end $f$;
revoke all on function public._chemical_rincian(bigint) from public, anon, authenticated;

-- pengajuan terakhir periode ini (dengan tautan pimpinan, hanya untuk admin) + angka terkini
create or replace function public.chemical_pengajuan_info(p_periode bigint) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare g public.chemical_pengajuan; masalah jsonb := '[]'::jsonb; per public.chemical_periode;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into per from public.chemical_periode where id = p_periode;
  if not found then raise exception 'periode tidak ditemukan'; end if;
  select * into g from public.chemical_pengajuan where periode_id = p_periode order by ke desc limit 1;
  if not exists (select 1 from public.chemical_kiriman where periode_id = p_periode) then masalah := masalah || to_jsonb('Belum ada permintaan dari korlap.'::text); end if;
  if per.form_dibuka then masalah := masalah || to_jsonb('Form masih dibuka; tutup form di halaman Periode dulu.'::text); end if;
  if exists (select 1 from public.chemical_permintaan where periode_id = p_periode and item_id is null) then masalah := masalah || to_jsonb('Masih ada barang lain yang belum diberi harga atau dipetakan.'::text); end if;
  if exists (select 1 from public.chemical_kiriman k left join public.chemical_pencocokan c on c.periode_id = k.periode_id and c.lokasi_id = k.lokasi_id where k.periode_id = p_periode and coalesce(c.cocok, false) = false) then masalah := masalah || to_jsonb('Masih ada lokasi yang belum ditandai cocok.'::text); end if;
  return jsonb_build_object('periode_status', per.status, 'rincian', public._chemical_rincian(p_periode), 'masalah', masalah,
    'pengajuan', case when g.id is null then null else jsonb_build_object('id', g.id, 'ke', g.ke, 'dibuat', g.dibuat, 'catatan', g.catatan, 'total', g.total, 'status', g.status, 'rincian', g.rincian,
      'token_yasir', g.token_yasir, 'token_ferry', g.token_ferry, 'status_yasir', g.status_yasir, 'status_ferry', g.status_ferry, 'waktu_yasir', g.waktu_yasir, 'waktu_ferry', g.waktu_ferry, 'alasan_yasir', g.alasan_yasir, 'alasan_ferry', g.alasan_ferry) end);
end $f$;

create or replace function public.chemical_ajukan(p_periode bigint, p_catatan text) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare per public.chemical_periode; r jsonb; g public.chemical_pengajuan; ke int;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into per from public.chemical_periode where id = p_periode for update;
  if not found then raise exception 'periode tidak ditemukan'; end if;
  if per.status <> 'REKAP' or per.form_dibuka then raise exception 'pengajuan hanya bisa dibuat setelah form ditutup dan sebelum diajukan'; end if;
  if not exists (select 1 from public.chemical_kiriman where periode_id = p_periode) then raise exception 'belum ada permintaan'; end if;
  if exists (select 1 from public.chemical_permintaan where periode_id = p_periode and item_id is null) then raise exception 'masih ada barang lain tanpa harga'; end if;
  if exists (select 1 from public.chemical_kiriman k left join public.chemical_pencocokan c on c.periode_id = k.periode_id and c.lokasi_id = k.lokasi_id where k.periode_id = p_periode and coalesce(c.cocok, false) = false) then raise exception 'masih ada lokasi yang belum cocok'; end if;
  r := public._chemical_rincian(p_periode);
  select coalesce(max(pg.ke), 0) + 1 into ke from public.chemical_pengajuan pg where pg.periode_id = p_periode;
  insert into public.chemical_pengajuan (periode_id, ke, catatan, rincian, total) values (p_periode, ke, nullif(btrim(p_catatan), ''), r, (r->>'total')::numeric) returning * into g;
  update public.chemical_periode set status = 'DIAJUKAN' where id = p_periode;
  return jsonb_build_object('id', g.id, 'ke', g.ke, 'token_yasir', g.token_yasir, 'token_ferry', g.token_ferry, 'total', g.total);
end $f$;

create or replace function public.chemical_tarik(p_pengajuan bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare g public.chemical_pengajuan;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into g from public.chemical_pengajuan where id = p_pengajuan for update;
  if not found then raise exception 'pengajuan tidak ditemukan'; end if;
  if g.status <> 'MENUNGGU' then raise exception 'hanya pengajuan yang masih menunggu yang bisa ditarik'; end if;
  update public.chemical_pengajuan set status = 'DITARIK' where id = g.id;
  update public.chemical_periode set status = 'REKAP' where id = g.periode_id and status = 'DIAJUKAN';
end $f$;

-- ===== PUBLIK untuk pimpinan (tanpa login; hanya lewat token) =====
create or replace function public.chemical_pengajuan_publik(p_token text) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare g public.chemical_pengajuan; per public.chemical_periode; siapa text;
begin
  select * into g from public.chemical_pengajuan where token_yasir = p_token or token_ferry = p_token;
  if not found then raise exception 'tautan tidak valid'; end if;
  siapa := case when g.token_yasir = p_token then 'yasir' else 'ferry' end;
  select * into per from public.chemical_periode where id = g.periode_id;
  return jsonb_build_object('pimpinan', siapa, 'bulan', per.bulan, 'tahun', per.tahun, 'ke', g.ke, 'dibuat', g.dibuat, 'catatan', g.catatan, 'total', g.total, 'rincian', g.rincian, 'status', g.status,
    'status_saya', case when siapa = 'yasir' then g.status_yasir else g.status_ferry end,
    'alasan_saya', case when siapa = 'yasir' then g.alasan_yasir else g.alasan_ferry end,
    'status_lain', case when siapa = 'yasir' then g.status_ferry else g.status_yasir end);
end $f$;

create or replace function public.chemical_putuskan(p_token text, p_aksi text, p_alasan text) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare g public.chemical_pengajuan; siapa text; baru text;
begin
  select * into g from public.chemical_pengajuan where token_yasir = p_token or token_ferry = p_token for update;
  if not found then raise exception 'tautan tidak valid'; end if;
  siapa := case when g.token_yasir = p_token then 'yasir' else 'ferry' end;
  if g.status <> 'MENUNGGU' then raise exception 'pengajuan ini sudah %', lower(g.status); end if;
  if (siapa = 'yasir' and g.status_yasir <> 'MENUNGGU') or (siapa = 'ferry' and g.status_ferry <> 'MENUNGGU') then raise exception 'Anda sudah memberi keputusan'; end if;
  if p_aksi not in ('setuju','tolak') then raise exception 'aksi tidak dikenal'; end if;
  if p_aksi = 'tolak' and length(btrim(coalesce(p_alasan, ''))) < 3 then raise exception 'alasan penolakan wajib diisi'; end if;
  baru := case when p_aksi = 'setuju' then 'SETUJU' else 'TOLAK' end;
  if siapa = 'yasir' then update public.chemical_pengajuan set status_yasir = baru, waktu_yasir = now(), alasan_yasir = nullif(btrim(p_alasan), '') where id = g.id;
  else update public.chemical_pengajuan set status_ferry = baru, waktu_ferry = now(), alasan_ferry = nullif(btrim(p_alasan), '') where id = g.id; end if;
  select * into g from public.chemical_pengajuan where id = g.id;
  if g.status_yasir = 'TOLAK' or g.status_ferry = 'TOLAK' then
    update public.chemical_pengajuan set status = 'DITOLAK' where id = g.id;
    update public.chemical_periode set status = 'REKAP' where id = g.periode_id and status = 'DIAJUKAN';
  elsif g.status_yasir = 'SETUJU' and g.status_ferry = 'SETUJU' then
    update public.chemical_pengajuan set status = 'DISETUJUI' where id = g.id;
    update public.chemical_periode set status = 'DISETUJUI' where id = g.periode_id and status = 'DIAJUKAN';
  end if;
  return jsonb_build_object('ok', true, 'status', (select status from public.chemical_pengajuan where id = g.id));
end $f$;

-- buka kembali lokasi (hapus kiriman) hanya selama periode belum diajukan; pencocokan lokasi itu dibatalkan
create or replace function public.chemical_buka_kembali(p_kiriman bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare k public.chemical_kiriman;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into k from public.chemical_kiriman where id = p_kiriman;
  if not found then raise exception 'kiriman tidak ditemukan'; end if;
  perform public._chemical_status_ok(k.periode_id);
  delete from public.chemical_kiriman where id = p_kiriman;
  delete from public.chemical_pencocokan where periode_id = k.periode_id and lokasi_id = k.lokasi_id;
end $f$;

-- ===== hak eksekusi =====
revoke all on function public.chemical_atur_periode(int, int, boolean) from public, anon;                grant execute on function public.chemical_atur_periode(int, int, boolean) to authenticated;
revoke all on function public.chemical_rekap_data(bigint) from public, anon;                              grant execute on function public.chemical_rekap_data(bigint) to authenticated;
revoke all on function public.chemical_ubah_qty(bigint, numeric) from public, anon;                       grant execute on function public.chemical_ubah_qty(bigint, numeric) to authenticated;
revoke all on function public.chemical_petakan_bebas(bigint, bigint) from public, anon;                   grant execute on function public.chemical_petakan_bebas(bigint, bigint) to authenticated;
revoke all on function public.chemical_buat_item_dari_bebas(bigint, bigint, numeric, numeric) from public, anon; grant execute on function public.chemical_buat_item_dari_bebas(bigint, bigint, numeric, numeric) to authenticated;
revoke all on function public.chemical_cocokkan(bigint, bigint, boolean, boolean, text) from public, anon; grant execute on function public.chemical_cocokkan(bigint, bigint, boolean, boolean, text) to authenticated;
revoke all on function public.chemical_daftar_biaya(bigint) from public, anon;                            grant execute on function public.chemical_daftar_biaya(bigint) to authenticated;
revoke all on function public.chemical_simpan_biaya(bigint, bigint, text, numeric, numeric, text, bigint) from public, anon; grant execute on function public.chemical_simpan_biaya(bigint, bigint, text, numeric, numeric, text, bigint) to authenticated;
revoke all on function public.chemical_hapus_biaya(bigint) from public, anon;                             grant execute on function public.chemical_hapus_biaya(bigint) to authenticated;
revoke all on function public.chemical_pengajuan_info(bigint) from public, anon;                          grant execute on function public.chemical_pengajuan_info(bigint) to authenticated;
revoke all on function public.chemical_ajukan(bigint, text) from public, anon;                            grant execute on function public.chemical_ajukan(bigint, text) to authenticated;
revoke all on function public.chemical_tarik(bigint) from public, anon;                                   grant execute on function public.chemical_tarik(bigint) to authenticated;
revoke all on function public.chemical_pengajuan_publik(text) from public;                                grant execute on function public.chemical_pengajuan_publik(text) to anon, authenticated;
revoke all on function public.chemical_putuskan(text, text, text) from public;                            grant execute on function public.chemical_putuskan(text, text, text) to anon, authenticated;
revoke all on function public.chemical_buka_kembali(bigint) from public, anon;                            grant execute on function public.chemical_buka_kembali(bigint) to authenticated;
