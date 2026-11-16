-- Chemical: kelola lokasi dan RAB dari halaman Administrator (Chemical > Lokasi & RAB). Aman dijalankan ulang. Khusus admin login.
--
--   chemical_lokasi_daftar()                  : semua lokasi beserta pemakaiannya (jumlah periode, permintaan, kiriman, pencocokan, biaya).
--   chemical_simpan_lokasi(...)               : tambah (p_id null) atau ubah. Tanda tangan lama dipertahankan; ditambah pemeriksaan nama kembar
--                                               (tanpa membedakan huruf besar-kecil) dan RAB tidak boleh minus.
--   chemical_hapus_lokasi(p_id)               : hanya untuk lokasi yang belum pernah dipakai; yang sudah dipakai ditolak dengan pesan jelas
--                                               (gunakan Nonaktifkan agar riwayat periode tetap utuh).
-- Semua perubahan (tambah, ubah RAB, hapus) tercatat di Log perubahan.

create or replace function public.chemical_lokasi_daftar() returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object(
      'periode', (select count(distinct x.periode_id) from (select periode_id from public.chemical_kiriman where lokasi_id = l.id union select periode_id from public.chemical_permintaan where lokasi_id = l.id) x),
      'kiriman', (select count(*) from public.chemical_kiriman where lokasi_id = l.id),
      'permintaan', (select count(*) from public.chemical_permintaan where lokasi_id = l.id),
      'pencocokan', (select count(*) from public.chemical_pencocokan where lokasi_id = l.id),
      'biaya', (select count(*) from public.chemical_biaya where lokasi_id = l.id)) order by l.nama) from public.chemical_lokasi l), '[]'::jsonb);
end $f$;

create or replace function public.chemical_simpan_lokasi(p_id bigint, p_nama text, p_rab_bulan numeric, p_mode text, p_pinjam boolean, p_kebijakan text, p_aktif boolean) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint; nm text := btrim(coalesce(p_nama, ''));
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if nm = '' then raise exception 'nama lokasi wajib diisi'; end if;
  if length(nm) > 150 then raise exception 'nama lokasi maksimal 150 karakter'; end if;
  if p_mode is null or p_mode not in ('ketat', 'persetujuan', 'tanpa_batas') then raise exception 'mode anggaran tidak dikenal'; end if;
  if p_mode <> 'tanpa_batas' and p_rab_bulan is null then raise exception 'anggaran (RAB) per bulan wajib diisi, kecuali mode tanpa batas'; end if;
  if p_rab_bulan is not null and p_rab_bulan < 0 then raise exception 'RAB per bulan tidak boleh minus'; end if;
  if exists (select 1 from public.chemical_lokasi where lower(nama) = lower(nm) and id is distinct from p_id) then raise exception 'lokasi "%" sudah ada', nm; end if;
  if p_id is null then
    insert into public.chemical_lokasi (nama, rab_bulan, mode_anggaran, pinjam_seragam, kebijakan, aktif)
      values (nm, case when p_mode = 'tanpa_batas' then null else p_rab_bulan end, p_mode, coalesce(p_pinjam, false), nullif(btrim(p_kebijakan), ''), coalesce(p_aktif, true)) returning id into v;
  else
    update public.chemical_lokasi set nama = nm, rab_bulan = case when p_mode = 'tanpa_batas' then null else p_rab_bulan end, mode_anggaran = p_mode,
      pinjam_seragam = coalesce(p_pinjam, false), kebijakan = nullif(btrim(p_kebijakan), ''), aktif = coalesce(p_aktif, true) where id = p_id returning id into v;
    if v is null then raise exception 'lokasi tidak ditemukan'; end if;
  end if;
  return v;
end $f$;

create or replace function public.chemical_hapus_lokasi(p_id bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare l public.chemical_lokasi; n_kir int; n_per int; n_cok int; n_bia int;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into l from public.chemical_lokasi where id = p_id;
  if not found then raise exception 'lokasi tidak ditemukan'; end if;
  select count(*) into n_kir from public.chemical_kiriman where lokasi_id = p_id;
  select count(*) into n_per from public.chemical_permintaan where lokasi_id = p_id;
  select count(*) into n_cok from public.chemical_pencocokan where lokasi_id = p_id;
  select count(*) into n_bia from public.chemical_biaya where lokasi_id = p_id;
  if n_kir + n_per + n_cok + n_bia > 0 then
    raise exception 'lokasi "%" sudah dipakai pada periode chemical (% kiriman, % permintaan, % pencocokan, % biaya) sehingga tidak bisa dihapus; nonaktifkan saja agar riwayat tetap utuh', l.nama, n_kir, n_per, n_cok, n_bia;
  end if;
  delete from public.chemical_lokasi where id = p_id;
end $f$;

revoke all on function public.chemical_lokasi_daftar() from public, anon;
grant execute on function public.chemical_lokasi_daftar() to authenticated;
revoke all on function public.chemical_simpan_lokasi(bigint, text, numeric, text, boolean, text, boolean) from public, anon;
grant execute on function public.chemical_simpan_lokasi(bigint, text, numeric, text, boolean, text, boolean) to authenticated;
revoke all on function public.chemical_hapus_lokasi(bigint) from public, anon;
grant execute on function public.chemical_hapus_lokasi(bigint) to authenticated;

-- Catatan perubahan lokasi (tambah, ubah RAB atau mode, hapus) untuk Log perubahan.
drop trigger if exists log_perubahan on public.chemical_lokasi;
create trigger log_perubahan after insert or update or delete on public.chemical_lokasi for each row execute function public._catat_log();
