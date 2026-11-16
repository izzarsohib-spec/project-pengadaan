-- Chemical: hapus periode dari halaman (khusus admin login). Aman dijalankan ulang.
--
-- Menghapus satu periode ikut menghapus PERMANEN semua yang menempel padanya (ON DELETE CASCADE): kiriman form korlap, baris permintaan,
-- pencocokan lokasi, biaya operasional, dan pengajuan ke pimpinan (termasuk catatan persetujuannya).
-- Pengaman: periode yang sudah melewati tahap rekap (DIAJUKAN, DISETUJUI, dst.) hanya bisa dihapus bila pemanggil mengirim
-- konfirmasi 'MM/YYYY' (mis. '12/2026'); pemeriksaan dilakukan di sini, bukan hanya di halaman.
-- Penghapusan periode dan pengajuan dicatat di Log perubahan (siapa, kapan, isi sebelum dihapus).

-- Pratinjau: apa saja yang ikut terhapus, ditampilkan pada dialog konfirmasi.
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
    'pengajuan', (select count(*) from public.chemical_pengajuan where periode_id = p.id));
end $f$;

create or replace function public.chemical_hapus_periode(p_periode bigint, p_konfirmasi text default null) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare p public.chemical_periode; kode text; isi jsonb;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into p from public.chemical_periode where id = p_periode for update;
  if not found then raise exception 'periode tidak ditemukan'; end if;
  kode := lpad(p.bulan::text, 2, '0') || '/' || p.tahun;
  if p.status not in ('FORM', 'REKAP') and coalesce(btrim(p_konfirmasi), '') <> kode then
    raise exception 'periode % sudah melewati tahap rekap (%): ketik % untuk mengonfirmasi penghapusan', kode, p.status, kode;
  end if;
  isi := public.chemical_isi_periode(p.id);
  delete from public.chemical_periode where id = p.id;
  return isi;
end $f$;

revoke all on function public.chemical_isi_periode(bigint) from public, anon;
grant execute on function public.chemical_isi_periode(bigint) to authenticated;
revoke all on function public.chemical_hapus_periode(bigint, text) from public, anon;
grant execute on function public.chemical_hapus_periode(bigint, text) to authenticated;

-- Log penghapusan (hanya DELETE; perubahan biasa tidak dicatat agar log tidak ramai).
drop trigger if exists log_hapus on public.chemical_periode;
create trigger log_hapus after delete on public.chemical_periode for each row execute function public._catat_log();
drop trigger if exists log_hapus on public.chemical_pengajuan;
create trigger log_hapus after delete on public.chemical_pengajuan for each row execute function public._catat_log();
