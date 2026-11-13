-- Chemical tahap 2: lokasi dengan anggaran dan kebijakan, periode bulanan, dan form korlap.
-- Alur: admin membuka periode -> satu tautan per periode disebar ke korlap -> korlap memilih lokasinya, memilih barang katalog,
-- dan mengirim -> masuk ke halaman Permintaan. Korlap tidak login dan TIDAK melihat harga maupun anggaran.
-- Satu kiriman saja per lokasi per periode, dan satu email hanya boleh mengirim sekali per periode (dijaga indeks unik di database).
-- Bila korlap salah isi, admin membuka kembali lokasinya (hapus kiriman) lalu korlap mengisi ulang.
-- Data lokasi dan anggaran TIDAK ada di berkas ini (rahasia perusahaan); diisi lewat skrip data di luar repo.

create table if not exists public.chemical_lokasi (
  id bigint generated always as identity primary key,
  nama text not null unique,
  rab_bulan numeric,                                   -- anggaran chemical per bulan; null bila tanpa batas
  mode_anggaran text not null default 'ketat' check (mode_anggaran in ('ketat','persetujuan','tanpa_batas')),
                                                       -- ketat = tidak boleh lewat; persetujuan = boleh lewat dengan persetujuan pimpinan
  pinjam_seragam boolean not null default false,       -- boleh memakai anggaran seragam bila anggaran chemical kurang
  kebijakan text,                                      -- catatan kebijakan lokasi (bebas)
  aktif boolean not null default true);

create table if not exists public.chemical_periode (
  id bigint generated always as identity primary key,
  bulan int not null check (bulan between 1 and 12),
  tahun int not null,
  status text not null default 'DRAFT',                -- mengikuti STATUS di docs/chemical/index.html
  form_dibuka boolean not null default false,          -- true = korlap boleh mengirim
  token text not null unique default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  dibuat timestamptz not null default now(),
  unique (bulan, tahun));

create table if not exists public.chemical_kiriman (
  id bigint generated always as identity primary key,
  periode_id bigint not null references public.chemical_periode(id) on delete cascade,
  lokasi_id bigint not null references public.chemical_lokasi(id),
  pengirim text not null,
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  dikirim timestamptz not null default now(),
  unique (periode_id, lokasi_id));                     -- satu lokasi, satu kiriman per periode
create unique index if not exists chemical_kiriman_email_idx on public.chemical_kiriman (periode_id, lower(email));  -- satu email, satu kiriman per periode

create table if not exists public.chemical_permintaan (
  id bigint generated always as identity primary key,
  kiriman_id bigint not null references public.chemical_kiriman(id) on delete cascade,
  periode_id bigint not null references public.chemical_periode(id) on delete cascade,
  lokasi_id bigint not null references public.chemical_lokasi(id),
  item_id bigint not null references public.chemical_item(id),
  qty numeric not null check (qty > 0),
  catatan text,
  unique (kiriman_id, item_id));
create index if not exists chemical_permintaan_periode_idx on public.chemical_permintaan (periode_id, lokasi_id);

alter table public.chemical_lokasi enable row level security;      revoke all on public.chemical_lokasi from anon, authenticated;
alter table public.chemical_periode enable row level security;     revoke all on public.chemical_periode from anon, authenticated;
alter table public.chemical_kiriman enable row level security;     revoke all on public.chemical_kiriman from anon, authenticated;
alter table public.chemical_permintaan enable row level security;  revoke all on public.chemical_permintaan from anon, authenticated;

-- ===== ADMIN (login admin) =====

create or replace function public.chemical_master() returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return jsonb_build_object(
    'toko', coalesce((select jsonb_agg(to_jsonb(t) order by t.nama) from public.chemical_toko t), '[]'::jsonb),
    'barang', coalesce((select jsonb_agg(to_jsonb(i) || jsonb_build_object('toko', o.nama) order by o.nama, i.nama) from public.chemical_item i join public.chemical_toko o on o.id = i.toko_id), '[]'::jsonb),
    'lokasi', coalesce((select jsonb_agg(to_jsonb(l) order by l.nama) from public.chemical_lokasi l), '[]'::jsonb),
    'periode', coalesce((select jsonb_agg(to_jsonb(p) order by p.tahun, p.bulan) from public.chemical_periode p), '[]'::jsonb));
end $f$;

create or replace function public.chemical_simpan_lokasi(p_id bigint, p_nama text, p_rab_bulan numeric, p_mode text, p_pinjam boolean, p_kebijakan text, p_aktif boolean) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if coalesce(btrim(p_nama), '') = '' then raise exception 'nama lokasi wajib diisi'; end if;
  if p_mode <> 'tanpa_batas' and p_rab_bulan is null then raise exception 'anggaran per bulan wajib diisi (kecuali mode tanpa batas)'; end if;
  if p_id is null then
    insert into public.chemical_lokasi (nama, rab_bulan, mode_anggaran, pinjam_seragam, kebijakan, aktif)
      values (btrim(p_nama), case when p_mode = 'tanpa_batas' then null else p_rab_bulan end, p_mode, coalesce(p_pinjam, false), nullif(btrim(p_kebijakan), ''), coalesce(p_aktif, true)) returning id into v;
  else
    update public.chemical_lokasi set nama = btrim(p_nama), rab_bulan = case when p_mode = 'tanpa_batas' then null else p_rab_bulan end, mode_anggaran = p_mode,
      pinjam_seragam = coalesce(p_pinjam, false), kebijakan = nullif(btrim(p_kebijakan), ''), aktif = coalesce(p_aktif, true) where id = p_id returning id into v;
    if v is null then raise exception 'lokasi tidak ditemukan'; end if;
  end if;
  return v;
end $f$;

create or replace function public.chemical_hapus_lokasi(p_id bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if exists (select 1 from public.chemical_kiriman where lokasi_id = p_id) then raise exception 'lokasi sudah punya kiriman; nonaktifkan saja'; end if;
  delete from public.chemical_lokasi where id = p_id;
end $f$;

create or replace function public.chemical_simpan_toko(p_id bigint, p_nama text, p_aktif boolean, p_catatan text) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if coalesce(btrim(p_nama), '') = '' then raise exception 'nama toko wajib diisi'; end if;
  if p_id is null then insert into public.chemical_toko (nama, aktif, catatan) values (btrim(p_nama), coalesce(p_aktif, true), nullif(btrim(p_catatan), '')) returning id into v;
  else update public.chemical_toko set nama = btrim(p_nama), aktif = coalesce(p_aktif, true), catatan = nullif(btrim(p_catatan), '') where id = p_id returning id into v;
       if v is null then raise exception 'toko tidak ditemukan'; end if; end if;
  return v;
end $f$;

create or replace function public.chemical_simpan_item(p_id bigint, p_toko bigint, p_nama text, p_satuan text, p_beli numeric, p_jual numeric, p_aktif boolean, p_tinjau boolean, p_catatan text) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if coalesce(btrim(p_nama), '') = '' or coalesce(btrim(p_satuan), '') = '' then raise exception 'nama dan satuan wajib diisi'; end if;
  if p_beli is null or p_beli < 0 or (p_jual is not null and p_jual < 0) then raise exception 'harga tidak valid'; end if;
  if p_id is null then
    insert into public.chemical_item (toko_id, nama, satuan, harga_beli, harga_jual, aktif, perlu_ditinjau, catatan)
      values (p_toko, btrim(p_nama), btrim(p_satuan), p_beli, p_jual, coalesce(p_aktif, true), coalesce(p_tinjau, false), nullif(btrim(p_catatan), '')) returning id into v;
  else
    update public.chemical_item set toko_id = p_toko, nama = btrim(p_nama), satuan = btrim(p_satuan), harga_beli = p_beli, harga_jual = p_jual,
      aktif = coalesce(p_aktif, true), perlu_ditinjau = coalesce(p_tinjau, false), catatan = nullif(btrim(p_catatan), '') where id = p_id returning id into v;
    if v is null then raise exception 'barang tidak ditemukan'; end if;
  end if;
  return v;
end $f$;

create or replace function public.chemical_hapus_item(p_id bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if exists (select 1 from public.chemical_permintaan where item_id = p_id) then raise exception 'barang sudah dipakai di permintaan; nonaktifkan saja'; end if;
  delete from public.chemical_item where id = p_id;
end $f$;

-- buka atau tutup form sebuah periode (periode dibuat bila belum ada); mengembalikan token tautan
create or replace function public.chemical_atur_periode(p_bulan int, p_tahun int, p_dibuka boolean) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare r public.chemical_periode;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  insert into public.chemical_periode (bulan, tahun, form_dibuka) values (p_bulan, p_tahun, p_dibuka)
    on conflict (bulan, tahun) do update set form_dibuka = excluded.form_dibuka returning * into r;
  return jsonb_build_object('id', r.id, 'bulan', r.bulan, 'tahun', r.tahun, 'status', r.status, 'form_dibuka', r.form_dibuka, 'token', r.token);
end $f$;

-- buat ulang token tautan (tautan lama langsung mati); kiriman yang sudah masuk tidak terpengaruh
create or replace function public.chemical_ganti_token(p_periode bigint) returns text
 language plpgsql security definer set search_path to 'public' as $f$
declare tk text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  update public.chemical_periode set token = tk where id = p_periode;
  if not found then raise exception 'periode tidak ditemukan'; end if;
  return tk;
end $f$;

-- status pengisian per lokasi untuk satu periode (siapa sudah kirim, siapa belum)
create or replace function public.chemical_status_periode(p_periode bigint) returns table(kiriman_id bigint, lokasi_id bigint, lokasi text, sudah_kirim boolean, jumlah_barang int, dikirim timestamptz, pengirim text, email text)
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return query
    select k.id, l.id, l.nama, k.id is not null,
      (select count(*)::int from public.chemical_permintaan m where m.kiriman_id = k.id),
      k.dikirim, k.pengirim, k.email
    from public.chemical_lokasi l
    left join public.chemical_kiriman k on k.lokasi_id = l.id and k.periode_id = p_periode
    where l.aktif order by l.nama;
end $f$;

-- seluruh permintaan satu periode lengkap dengan harga
create or replace function public.chemical_permintaan_daftar(p_periode bigint) returns table(kiriman_id bigint, pengirim text, email text, lokasi_id bigint, lokasi text, item_id bigint, toko text, barang text, satuan text, qty numeric, harga_beli numeric, harga_jual numeric, catatan text, dikirim timestamptz)
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return query
    select k.id, k.pengirim, k.email, m.lokasi_id, l.nama, m.item_id, t.nama, i.nama, i.satuan, m.qty, i.harga_beli, i.harga_jual, m.catatan, k.dikirim
    from public.chemical_permintaan m
    join public.chemical_kiriman k on k.id = m.kiriman_id
    join public.chemical_lokasi l on l.id = m.lokasi_id
    join public.chemical_item i on i.id = m.item_id
    join public.chemical_toko t on t.id = i.toko_id
    where m.periode_id = p_periode order by l.nama, k.dikirim, t.nama, i.nama;
end $f$;

-- buka kembali sebuah lokasi: kirimannya dihapus supaya korlap bisa mengisi ulang (hanya selama periode belum diajukan)
create or replace function public.chemical_buka_kembali(p_kiriman bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  delete from public.chemical_kiriman where id = p_kiriman;
  if not found then raise exception 'kiriman tidak ditemukan'; end if;
end $f$;

-- ===== PUBLIK (korlap, tanpa login; hanya lewat token periode) =====

-- isi form: periode, daftar lokasi aktif (nama saja), dan katalog TANPA harga
create or replace function public.form_chemical_ambil(p_token text) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare p public.chemical_periode;
begin
  select * into p from public.chemical_periode where token = p_token;
  if not found then raise exception 'tautan tidak valid'; end if;
  return jsonb_build_object(
    'bulan', p.bulan, 'tahun', p.tahun, 'dibuka', p.form_dibuka,
    'lokasi', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'nama', l.nama,
                          'sudah', exists (select 1 from public.chemical_kiriman k where k.periode_id = p.id and k.lokasi_id = l.id)) order by l.nama)
                        from public.chemical_lokasi l where l.aktif), '[]'::jsonb),
    'barang', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'toko', o.nama, 'nama', i.nama, 'satuan', i.satuan) order by o.nama, i.nama)
                        from public.chemical_item i join public.chemical_toko o on o.id = i.toko_id where i.aktif and o.aktif), '[]'::jsonb));
end $f$;

-- kirim: p_baris = [{"item_id":1,"qty":2,"catatan":"..."}]
create or replace function public.form_chemical_kirim(p_token text, p_lokasi bigint, p_pengirim text, p_email text, p_baris jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare p public.chemical_periode; kid bigint; n int := 0; b jsonb; q numeric; iid bigint; em text := lower(btrim(coalesce(p_email, '')));
begin
  select * into p from public.chemical_periode where token = p_token;
  if not found then raise exception 'tautan tidak valid'; end if;
  if not p.form_dibuka then raise exception 'form periode ini sudah ditutup'; end if;
  if not exists (select 1 from public.chemical_lokasi where id = p_lokasi and aktif) then raise exception 'lokasi tidak dikenal'; end if;
  if coalesce(btrim(p_pengirim), '') = '' then raise exception 'nama pengirim wajib diisi'; end if;
  if em !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'email pengirim tidak valid'; end if;
  if jsonb_typeof(p_baris) <> 'array' or jsonb_array_length(p_baris) = 0 then raise exception 'belum ada barang yang dipilih'; end if;
  if jsonb_array_length(p_baris) > 500 then raise exception 'terlalu banyak baris'; end if;

  -- satu lokasi dan satu email hanya boleh mengirim sekali per periode (indeks unik menjaga juga bila dua kiriman datang bersamaan)
  if exists (select 1 from public.chemical_kiriman where periode_id = p.id and lokasi_id = p_lokasi) then raise exception 'lokasi ini sudah mengisi form periode ini'; end if;
  if exists (select 1 from public.chemical_kiriman where periode_id = p.id and lower(email) = em) then raise exception 'email ini sudah dipakai mengisi form periode ini'; end if;

  insert into public.chemical_kiriman (periode_id, lokasi_id, pengirim, email) values (p.id, p_lokasi, btrim(p_pengirim), em) returning id into kid;
  for b in select * from jsonb_array_elements(p_baris) loop
    iid := (b->>'item_id')::bigint;  q := (b->>'qty')::numeric;
    if q is null or q <= 0 or q > 100000 then continue; end if;
    if not exists (select 1 from public.chemical_item i where i.id = iid and i.aktif) then raise exception 'barang tidak dikenal: %', iid; end if;
    insert into public.chemical_permintaan (kiriman_id, periode_id, lokasi_id, item_id, qty, catatan)
      values (kid, p.id, p_lokasi, iid, q, nullif(btrim(b->>'catatan'), ''))
      on conflict (kiriman_id, item_id) do update set qty = excluded.qty, catatan = excluded.catatan;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'jumlah barang tidak valid'; end if;
  return jsonb_build_object('ok', true, 'jumlah_barang', n);
end $f$;

-- hak eksekusi: admin hanya untuk yang login; fungsi form untuk siapa saja
revoke all on function public.chemical_master() from public, anon;                                                                     grant execute on function public.chemical_master() to authenticated;
revoke all on function public.chemical_simpan_lokasi(bigint, text, numeric, text, boolean, text, boolean) from public, anon;            grant execute on function public.chemical_simpan_lokasi(bigint, text, numeric, text, boolean, text, boolean) to authenticated;
revoke all on function public.chemical_hapus_lokasi(bigint) from public, anon;                                                          grant execute on function public.chemical_hapus_lokasi(bigint) to authenticated;
revoke all on function public.chemical_simpan_toko(bigint, text, boolean, text) from public, anon;                                      grant execute on function public.chemical_simpan_toko(bigint, text, boolean, text) to authenticated;
revoke all on function public.chemical_simpan_item(bigint, bigint, text, text, numeric, numeric, boolean, boolean, text) from public, anon; grant execute on function public.chemical_simpan_item(bigint, bigint, text, text, numeric, numeric, boolean, boolean, text) to authenticated;
revoke all on function public.chemical_hapus_item(bigint) from public, anon;                                                            grant execute on function public.chemical_hapus_item(bigint) to authenticated;
revoke all on function public.chemical_atur_periode(int, int, boolean) from public, anon;                                               grant execute on function public.chemical_atur_periode(int, int, boolean) to authenticated;
revoke all on function public.chemical_ganti_token(bigint) from public, anon;                                                           grant execute on function public.chemical_ganti_token(bigint) to authenticated;
revoke all on function public.chemical_status_periode(bigint) from public, anon;                                                        grant execute on function public.chemical_status_periode(bigint) to authenticated;
revoke all on function public.chemical_permintaan_daftar(bigint) from public, anon;                                                     grant execute on function public.chemical_permintaan_daftar(bigint) to authenticated;
revoke all on function public.chemical_buka_kembali(bigint) from public, anon;                                                          grant execute on function public.chemical_buka_kembali(bigint) to authenticated;
revoke all on function public.form_chemical_ambil(text) from public;                                                                    grant execute on function public.form_chemical_ambil(text) to anon, authenticated;
revoke all on function public.form_chemical_kirim(text, bigint, text, text, jsonb) from public;                                         grant execute on function public.form_chemical_kirim(text, bigint, text, text, jsonb) to anon, authenticated;
