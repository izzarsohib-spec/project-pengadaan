-- Chemical > Laporan: pencatatan nota pengeluaran (belanja dan operasional), dengan foto nota yang dibaca otomatis (fungsi Edge baca-nota,
-- memakai Gemini) lalu dikoreksi dan disimpan oleh admin. Aman dijalankan ulang. Khusus admin login.
--
--   chemical_nota_daftar(p_periode)   : semua nota satu periode (terbaru dulu).
--   chemical_simpan_nota(...)         : tambah (p_id null) atau ubah. Foto hanya boleh berasal dari unggahan baca-nota (alamat dicek).
--   chemical_hapus_nota(p_id)         : hapus satu nota (fotonya tidak ikut dihapus dari penyimpanan).
-- chemical_isi_periode ikut menghitung nota supaya dialog hapus periode jujur tentang apa yang terhapus.

create table if not exists public.chemical_nota (
  id bigint generated always as identity primary key,
  periode_id bigint not null references public.chemical_periode(id) on delete cascade,
  jenis text not null check (jenis in ('belanja', 'operasional')),
  toko text not null,                                       -- nama toko / pihak yang ditagih
  tanggal date not null,
  no_nota text,
  total numeric not null check (total >= 0),
  kategori text,                                            -- untuk operasional: jenis biaya (bensin, tol, parkir, ...)
  catatan text,
  rincian jsonb not null default '[]'::jsonb,               -- [{nama, qty, satuan, harga, subtotal}]; boleh kosong
  foto_url text,
  baca_ai jsonb,                                            -- hasil mentah pembacaan AI, disimpan untuk pemeriksaan ulang
  dibuat timestamptz not null default now());
create index if not exists chemical_nota_periode_idx on public.chemical_nota (periode_id, tanggal);
alter table public.chemical_nota enable row level security;
revoke all on public.chemical_nota from anon, authenticated;

create or replace function public.chemical_nota_daftar(p_periode bigint) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return coalesce((select jsonb_agg(to_jsonb(n) - 'baca_ai' order by n.tanggal desc, n.id desc) from public.chemical_nota n where n.periode_id = p_periode), '[]'::jsonb);
end $f$;

create or replace function public.chemical_simpan_nota(p_id bigint, p_periode bigint, p_jenis text, p_toko text, p_tanggal date, p_no_nota text, p_total numeric,
    p_kategori text, p_catatan text, p_rincian jsonb, p_foto_url text, p_baca jsonb) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint; tk text := btrim(coalesce(p_toko, '')); rin jsonb := coalesce(p_rincian, '[]'::jsonb);
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if p_jenis is null or p_jenis not in ('belanja', 'operasional') then raise exception 'jenis nota harus belanja atau operasional'; end if;
  if tk = '' then raise exception 'nama toko wajib diisi'; end if;
  if length(tk) > 150 then raise exception 'nama toko maksimal 150 karakter'; end if;
  if p_tanggal is null then raise exception 'tanggal nota wajib diisi'; end if;
  if p_tanggal < date '2020-01-01' or p_tanggal > current_date + 1 then raise exception 'tanggal nota tidak masuk akal (%)', p_tanggal; end if;
  if p_total is null or p_total < 0 then raise exception 'total nota wajib diisi dan tidak boleh minus'; end if;
  if jsonb_typeof(rin) <> 'array' or jsonb_array_length(rin) > 150 then raise exception 'rincian nota tidak valid (maksimal 150 baris)'; end if;
  if p_foto_url is not null and p_foto_url !~ '^https://[a-z0-9.-]+\.supabase\.co/storage/v1/object/public/lampiran-surat/nota-[a-z0-9]+/[a-z0-9.-]+$' then raise exception 'alamat foto nota tidak valid'; end if;
  if not exists (select 1 from public.chemical_periode where id = p_periode) then raise exception 'periode tidak ditemukan'; end if;
  if p_id is null then
    insert into public.chemical_nota (periode_id, jenis, toko, tanggal, no_nota, total, kategori, catatan, rincian, foto_url, baca_ai)
      values (p_periode, p_jenis, tk, p_tanggal, nullif(btrim(p_no_nota), ''), p_total, nullif(btrim(p_kategori), ''), nullif(btrim(p_catatan), ''), rin, p_foto_url, p_baca) returning id into v;
  else
    update public.chemical_nota set jenis = p_jenis, toko = tk, tanggal = p_tanggal, no_nota = nullif(btrim(p_no_nota), ''), total = p_total,
      kategori = nullif(btrim(p_kategori), ''), catatan = nullif(btrim(p_catatan), ''), rincian = rin, foto_url = coalesce(p_foto_url, foto_url)
      where id = p_id and periode_id = p_periode returning id into v;
    if v is null then raise exception 'nota tidak ditemukan'; end if;
  end if;
  return v;
end $f$;

create or replace function public.chemical_hapus_nota(p_id bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  delete from public.chemical_nota where id = p_id;
  if not found then raise exception 'nota tidak ditemukan'; end if;
end $f$;

revoke all on function public.chemical_nota_daftar(bigint) from public, anon;
grant execute on function public.chemical_nota_daftar(bigint) to authenticated;
revoke all on function public.chemical_simpan_nota(bigint, bigint, text, text, date, text, numeric, text, text, jsonb, text, jsonb) from public, anon;
grant execute on function public.chemical_simpan_nota(bigint, bigint, text, text, date, text, numeric, text, text, jsonb, text, jsonb) to authenticated;
revoke all on function public.chemical_hapus_nota(bigint) from public, anon;
grant execute on function public.chemical_hapus_nota(bigint) to authenticated;

-- dialog hapus periode: tambahkan hitungan nota
create or replace function public.chemical_isi_periode(p_periode bigint) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare p public.chemical_periode;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into p from public.chemical_periode where id = p_periode;
  if not found then raise exception 'periode tidak ditemukan'; end if;
  return jsonb_build_object('id', p.id, 'bulan', p.bulan, 'tahun', p.tahun, 'status', p.status,
    'kiriman', (select count(*) from public.chemical_kiriman where periode_id = p.id),
    'permintaan', (select count(*) from public.chemical_permintaan where periode_id = p.id),
    'pencocokan', (select count(*) from public.chemical_pencocokan where periode_id = p.id),
    'biaya', (select count(*) from public.chemical_biaya where periode_id = p.id),
    'pengajuan', (select count(*) from public.chemical_pengajuan where periode_id = p.id),
    'nota', (select count(*) from public.chemical_nota where periode_id = p.id),
    'pengiriman', (select count(*) from public.chemical_pengiriman where periode_id = p.id));
end $f$;
