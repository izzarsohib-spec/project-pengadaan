-- Chemical pengiriman, tahap 2: SATU tautan per periode untuk semua lokasi (bukan lagi satu tautan per lokasi).
-- Orang lapangan membuka tautan, memilih lokasinya, mengisi nama pengirim, centang barang, foto, dan penerima. Aman dijalankan ulang.
--   chemical_periode.token_kirim                 : token tautan form pengiriman (terpisah dari token form permintaan korlap)
--   chemical_pengiriman.pengirim                 : nama orang lapangan yang mengantar
--   chemical_pengiriman_daftar(p_periode)        : admin; {token, lokasi:[...]} status semua lokasi
--   chemical_pengiriman_tautan_baru(p_periode)   : admin; buat ulang token (tautan lama langsung mati)
--   chemical_pengiriman_info(p_token)            : hanya fungsi Edge kirim-chemical; lokasi + barang tiap lokasi TANPA harga

alter table public.chemical_periode add column if not exists token_kirim text;
update public.chemical_periode set token_kirim = replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '') where token_kirim is null;
alter table public.chemical_periode alter column token_kirim set default replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
alter table public.chemical_periode alter column token_kirim set not null;
create unique index if not exists chemical_periode_token_kirim_idx on public.chemical_periode (token_kirim);

alter table public.chemical_pengiriman add column if not exists pengirim text;
alter table public.chemical_pengiriman drop column if exists token;   -- tidak dipakai lagi (tabel masih kosong saat diubah)

create or replace function public.chemical_pengiriman_daftar(p_periode bigint) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare p public.chemical_periode;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into p from public.chemical_periode where id = p_periode;
  if not found then raise exception 'periode tidak ditemukan'; end if;
  insert into public.chemical_pengiriman (periode_id, lokasi_id)
    select p_periode, k.lokasi_id from public.chemical_kiriman k where k.periode_id = p_periode
    on conflict (periode_id, lokasi_id) do nothing;
  return jsonb_build_object('token', p.token_kirim, 'lokasi', coalesce((select jsonb_agg(jsonb_build_object(
      'id', g.id, 'lokasi_id', g.lokasi_id, 'lokasi', l.nama,
      'jenis', jsonb_array_length(public._chemical_barang_kirim(p_periode, g.lokasi_id)),
      'unit', coalesce((select sum((b ->> 'qty')::numeric) from jsonb_array_elements(public._chemical_barang_kirim(p_periode, g.lokasi_id)) b), 0),
      'terkirim', g.terkirim, 'pengirim', g.pengirim, 'penerima', g.penerima, 'jabatan', g.jabatan, 'kondisi', g.kondisi, 'catatan', g.catatan,
      'barang', case when g.terkirim is null then null else g.barang end, 'foto', g.foto_urls) order by l.nama)
    from public.chemical_pengiriman g join public.chemical_lokasi l on l.id = g.lokasi_id where g.periode_id = p_periode), '[]'::jsonb));
end $f$;
revoke all on function public.chemical_pengiriman_daftar(bigint) from public, anon;
grant execute on function public.chemical_pengiriman_daftar(bigint) to authenticated;

create or replace function public.chemical_pengiriman_tautan_baru(p_periode bigint) returns text
 language plpgsql security definer set search_path to 'public' as $f$
declare t text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  update public.chemical_periode set token_kirim = t where id = p_periode;
  if not found then raise exception 'periode tidak ditemukan'; end if;
  return t;
end $f$;
revoke all on function public.chemical_pengiriman_tautan_baru(bigint) from public, anon;
grant execute on function public.chemical_pengiriman_tautan_baru(bigint) to authenticated;

drop function if exists public.chemical_pengiriman_info(text);
create or replace function public.chemical_pengiriman_info(p_token text) returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
declare p public.chemical_periode;
begin
  select * into p from public.chemical_periode where token_kirim = p_token;
  if not found then raise exception 'tautan tidak dikenali'; end if;
  return jsonb_build_object('periode_id', p.id, 'bulan', p.bulan, 'tahun', p.tahun, 'status', p.status,
    'lokasi', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'nama', l.nama,
        'sudah', exists (select 1 from public.chemical_pengiriman g where g.periode_id = p.id and g.lokasi_id = l.id and g.terkirim is not null),
        'barang', public._chemical_barang_kirim(p.id, l.id)) order by l.nama)
      from public.chemical_lokasi l where exists (select 1 from public.chemical_kiriman k where k.periode_id = p.id and k.lokasi_id = l.id)), '[]'::jsonb));
end $f$;
revoke all on function public.chemical_pengiriman_info(text) from public, anon, authenticated;
grant execute on function public.chemical_pengiriman_info(text) to service_role;
