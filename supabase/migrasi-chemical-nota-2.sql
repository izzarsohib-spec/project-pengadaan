-- Chemical > Laporan, tahap 2: tiap nota boleh dilampiri foto BUKTI TRANSFER selain foto nota. Aman dijalankan ulang.
-- chemical_nota.bukti_url                : alamat foto bukti transfer (diunggah lewat fungsi Edge baca-nota dengan baca:false)
-- chemical_simpan_nota(... p_bukti_url)  : parameter baru (bawaan null, jadi halaman lama yang belum memuat ulang tetap bisa menyimpan);
--                                          saat mengubah nota, bukti/foto lama dipertahankan bila parameter kosong.

alter table public.chemical_nota add column if not exists bukti_url text;

drop function if exists public.chemical_simpan_nota(bigint, bigint, text, text, date, text, numeric, text, text, jsonb, text, jsonb);
create or replace function public.chemical_simpan_nota(p_id bigint, p_periode bigint, p_jenis text, p_toko text, p_tanggal date, p_no_nota text, p_total numeric,
    p_kategori text, p_catatan text, p_rincian jsonb, p_foto_url text, p_baca jsonb, p_bukti_url text default null) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint; tk text := btrim(coalesce(p_toko, '')); rin jsonb := coalesce(p_rincian, '[]'::jsonb);
  pola constant text := '^https://[a-z0-9.-]+\.supabase\.co/storage/v1/object/public/lampiran-surat/nota-[a-z0-9]+/[a-z0-9.-]+$';
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if p_jenis is null or p_jenis not in ('belanja', 'operasional') then raise exception 'jenis nota harus belanja atau operasional'; end if;
  if tk = '' then raise exception 'nama toko wajib diisi'; end if;
  if length(tk) > 150 then raise exception 'nama toko maksimal 150 karakter'; end if;
  if p_tanggal is null then raise exception 'tanggal nota wajib diisi'; end if;
  if p_tanggal < date '2020-01-01' or p_tanggal > current_date + 1 then raise exception 'tanggal nota tidak masuk akal (%)', p_tanggal; end if;
  if p_total is null or p_total < 0 then raise exception 'total nota wajib diisi dan tidak boleh minus'; end if;
  if jsonb_typeof(rin) <> 'array' or jsonb_array_length(rin) > 150 then raise exception 'rincian nota tidak valid (maksimal 150 baris)'; end if;
  if p_foto_url is not null and p_foto_url !~ pola then raise exception 'alamat foto nota tidak valid'; end if;
  if p_bukti_url is not null and p_bukti_url !~ pola then raise exception 'alamat foto bukti transfer tidak valid'; end if;
  if not exists (select 1 from public.chemical_periode where id = p_periode) then raise exception 'periode tidak ditemukan'; end if;
  if p_id is null then
    insert into public.chemical_nota (periode_id, jenis, toko, tanggal, no_nota, total, kategori, catatan, rincian, foto_url, bukti_url, baca_ai)
      values (p_periode, p_jenis, tk, p_tanggal, nullif(btrim(p_no_nota), ''), p_total, nullif(btrim(p_kategori), ''), nullif(btrim(p_catatan), ''), rin, p_foto_url, p_bukti_url, p_baca) returning id into v;
  else
    update public.chemical_nota set jenis = p_jenis, toko = tk, tanggal = p_tanggal, no_nota = nullif(btrim(p_no_nota), ''), total = p_total,
      kategori = nullif(btrim(p_kategori), ''), catatan = nullif(btrim(p_catatan), ''), rincian = rin,
      foto_url = coalesce(p_foto_url, foto_url), bukti_url = coalesce(p_bukti_url, bukti_url)
      where id = p_id and periode_id = p_periode returning id into v;
    if v is null then raise exception 'nota tidak ditemukan'; end if;
  end if;
  return v;
end $f$;
revoke all on function public.chemical_simpan_nota(bigint, bigint, text, text, date, text, numeric, text, text, jsonb, text, jsonb, text) from public, anon;
grant execute on function public.chemical_simpan_nota(bigint, bigint, text, text, date, text, numeric, text, text, jsonb, text, jsonb, text) to authenticated;
