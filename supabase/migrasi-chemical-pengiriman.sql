-- Chemical: monitoring pengiriman. Satu tautan bertoken per lokasi per periode; kurir/PIC mengisi form (centang barang, foto, penerima)
-- dan halaman Chemical > Pengiriman menampilkan lokasi mana yang sudah/belum dikirim beserta fotonya. Aman dijalankan ulang.
--
--   chemical_pengiriman_daftar(p_periode) : admin login; menyiapkan baris+token untuk tiap lokasi yang sudah mengirim permintaan, lalu mengembalikan status semuanya.
--   chemical_pengiriman_info(p_token)     : hanya untuk fungsi Edge kirim-chemical (service role); data form kurir TANPA harga.
-- Penyimpanan hasil form (dan foto ke Storage) dilakukan fungsi Edge kirim-chemical.

create table if not exists public.chemical_pengiriman (
  id bigint generated always as identity primary key,
  periode_id bigint not null references public.chemical_periode(id) on delete cascade,
  lokasi_id bigint not null references public.chemical_lokasi(id),
  token text not null unique default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''),
  dibuat timestamptz not null default now(),
  terkirim timestamptz,                                  -- terisi saat kurir mengirim form; null = belum dikirim
  penerima text, jabatan text,
  kondisi text check (kondisi in ('sesuai', 'kurang', 'rusak')),
  catatan text,
  barang jsonb not null default '[]'::jsonb,             -- salinan saat form dikirim: [{nama, satuan, qty, diantar}]
  foto_urls jsonb not null default '[]'::jsonb,
  unique (periode_id, lokasi_id));
alter table public.chemical_pengiriman enable row level security;
revoke all on public.chemical_pengiriman from anon, authenticated;

-- barang yang harus diantar ke satu lokasi pada satu periode (item katalog atau barang bebas), tanpa harga
create or replace function public._chemical_barang_kirim(p_periode bigint, p_lokasi bigint) returns jsonb
 language sql stable security definer set search_path to 'public' as $f$
  select coalesce(jsonb_agg(jsonb_build_object('nama', coalesce(i.nama, m.nama_bebas), 'satuan', coalesce(i.satuan, m.satuan_bebas), 'qty', m.qty) order by coalesce(i.nama, m.nama_bebas)), '[]'::jsonb)
  from public.chemical_permintaan m left join public.chemical_item i on i.id = m.item_id
  where m.periode_id = p_periode and m.lokasi_id = p_lokasi $f$;
revoke all on function public._chemical_barang_kirim(bigint, bigint) from public, anon, authenticated;

create or replace function public.chemical_pengiriman_daftar(p_periode bigint) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if not exists (select 1 from public.chemical_periode where id = p_periode) then raise exception 'periode tidak ditemukan'; end if;
  insert into public.chemical_pengiriman (periode_id, lokasi_id)
    select p_periode, k.lokasi_id from public.chemical_kiriman k where k.periode_id = p_periode
    on conflict (periode_id, lokasi_id) do nothing;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', g.id, 'lokasi_id', g.lokasi_id, 'lokasi', l.nama, 'token', g.token,
      'jenis', jsonb_array_length(public._chemical_barang_kirim(p_periode, g.lokasi_id)),
      'unit', coalesce((select sum((b ->> 'qty')::numeric) from jsonb_array_elements(public._chemical_barang_kirim(p_periode, g.lokasi_id)) b), 0),
      'terkirim', g.terkirim, 'penerima', g.penerima, 'jabatan', g.jabatan, 'kondisi', g.kondisi, 'catatan', g.catatan,
      'barang', case when g.terkirim is null then null else g.barang end, 'foto', g.foto_urls) order by l.nama)
    from public.chemical_pengiriman g join public.chemical_lokasi l on l.id = g.lokasi_id where g.periode_id = p_periode), '[]'::jsonb);
end $f$;
revoke all on function public.chemical_pengiriman_daftar(bigint) from public, anon;
grant execute on function public.chemical_pengiriman_daftar(bigint) to authenticated;

-- dipakai fungsi Edge (service role) untuk menampilkan form kurir dan memvalidasi kiriman
create or replace function public.chemical_pengiriman_info(p_token text) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare g public.chemical_pengiriman; p public.chemical_periode; l public.chemical_lokasi;
begin
  select * into g from public.chemical_pengiriman where token = p_token;
  if not found then raise exception 'tautan tidak dikenali'; end if;
  select * into p from public.chemical_periode where id = g.periode_id;
  select * into l from public.chemical_lokasi where id = g.lokasi_id;
  return jsonb_build_object('id', g.id, 'lokasi', l.nama, 'bulan', p.bulan, 'tahun', p.tahun, 'status', p.status,
    'barang', public._chemical_barang_kirim(g.periode_id, g.lokasi_id),
    'sudah', case when g.terkirim is null then null else jsonb_build_object('penerima', g.penerima, 'terkirim', g.terkirim) end);
end $f$;
revoke all on function public.chemical_pengiriman_info(text) from public, anon, authenticated;
grant execute on function public.chemical_pengiriman_info(text) to service_role;
