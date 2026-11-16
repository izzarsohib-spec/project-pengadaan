-- Chemical: kelola barang (item), harga, dan toko beli dari halaman Administrator (Chemical > Barang dan Toko). Aman dijalankan ulang. Khusus admin login.
--
--   chemical_barang_daftar()   : semua barang beserta nama toko dan pemakaian (jumlah baris permintaan dan periode).
--   chemical_toko_daftar()     : semua toko beserta jumlah barangnya.
--   chemical_simpan_item(...)  : tambah (p_id null) atau ubah; tanda tangan lama dipertahankan. Menolak toko tak dikenal dan nama kembar
--                                dalam satu toko (tanpa membedakan huruf besar-kecil), dan memeriksa panjang isian.
--   chemical_hapus_item(p_id)  : hanya untuk barang yang belum pernah dipakai pada permintaan; yang sudah dipakai ditolak dengan pesan jelas
--                                (gunakan nonaktifkan agar riwayat tetap utuh).
--   chemical_simpan_toko(...)  : tambah atau ubah toko; menolak nama kembar.
--   chemical_hapus_toko(p_id)  : hanya untuk toko yang tidak punya barang.
-- Perubahan harga, toko beli, tambah, dan hapus tercatat di Log perubahan (siapa, kapan, nilai sebelum dan sesudah).
-- Catatan: rekap periode menghitung dari harga barang saat ini, jadi mengubah harga memengaruhi angka rekap yang belum diajukan;
-- rincian pengajuan yang sudah dibuat tersimpan sebagai salinan dan tidak ikut berubah.

create or replace function public.chemical_barang_daftar() returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return coalesce((select jsonb_agg(to_jsonb(i) || jsonb_build_object('toko', t.nama, 'toko_aktif', t.aktif,
      'permintaan', (select count(*) from public.chemical_permintaan m where m.item_id = i.id),
      'periode', (select count(distinct m.periode_id) from public.chemical_permintaan m where m.item_id = i.id)) order by t.nama, i.nama)
    from public.chemical_item i join public.chemical_toko t on t.id = i.toko_id), '[]'::jsonb);
end $f$;

create or replace function public.chemical_toko_daftar() returns jsonb
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return coalesce((select jsonb_agg(to_jsonb(t) || jsonb_build_object(
      'barang', (select count(*) from public.chemical_item i where i.toko_id = t.id),
      'barang_aktif', (select count(*) from public.chemical_item i where i.toko_id = t.id and i.aktif)) order by t.nama) from public.chemical_toko t), '[]'::jsonb);
end $f$;

create or replace function public.chemical_simpan_item(p_id bigint, p_toko bigint, p_nama text, p_satuan text, p_beli numeric, p_jual numeric, p_aktif boolean, p_tinjau boolean, p_catatan text) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint; nm text := btrim(coalesce(p_nama, '')); st text := btrim(coalesce(p_satuan, '')); tk text;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if nm = '' or st = '' then raise exception 'nama dan satuan wajib diisi'; end if;
  if length(nm) > 200 then raise exception 'nama barang maksimal 200 karakter'; end if;
  if length(st) > 30 then raise exception 'satuan maksimal 30 karakter'; end if;
  select nama into tk from public.chemical_toko where id = p_toko;
  if tk is null then raise exception 'toko beli wajib dipilih'; end if;
  if p_beli is null or p_beli < 0 or (p_jual is not null and p_jual < 0) then raise exception 'harga tidak valid'; end if;
  if exists (select 1 from public.chemical_item where toko_id = p_toko and lower(nama) = lower(nm) and id is distinct from p_id) then
    raise exception 'barang "%" sudah ada di %', nm, tk;
  end if;
  if p_id is null then
    insert into public.chemical_item (toko_id, nama, satuan, harga_beli, harga_jual, aktif, perlu_ditinjau, catatan)
      values (p_toko, nm, st, p_beli, p_jual, coalesce(p_aktif, true), coalesce(p_tinjau, false), nullif(btrim(p_catatan), '')) returning id into v;
  else
    update public.chemical_item set toko_id = p_toko, nama = nm, satuan = st, harga_beli = p_beli, harga_jual = p_jual,
      aktif = coalesce(p_aktif, true), perlu_ditinjau = coalesce(p_tinjau, false), catatan = nullif(btrim(p_catatan), '') where id = p_id returning id into v;
    if v is null then raise exception 'barang tidak ditemukan'; end if;
  end if;
  return v;
end $f$;

create or replace function public.chemical_hapus_item(p_id bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare i public.chemical_item; n int;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into i from public.chemical_item where id = p_id;
  if not found then raise exception 'barang tidak ditemukan'; end if;
  select count(*) into n from public.chemical_permintaan where item_id = p_id;
  if n > 0 then raise exception 'barang "%" sudah dipakai pada % baris permintaan sehingga tidak bisa dihapus; nonaktifkan saja agar riwayat tetap utuh', i.nama, n; end if;
  delete from public.chemical_item where id = p_id;
end $f$;

create or replace function public.chemical_simpan_toko(p_id bigint, p_nama text, p_aktif boolean, p_catatan text) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare v bigint; nm text := btrim(coalesce(p_nama, ''));
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  if nm = '' then raise exception 'nama toko wajib diisi'; end if;
  if length(nm) > 100 then raise exception 'nama toko maksimal 100 karakter'; end if;
  if exists (select 1 from public.chemical_toko where lower(nama) = lower(nm) and id is distinct from p_id) then raise exception 'toko "%" sudah ada', nm; end if;
  if p_id is null then insert into public.chemical_toko (nama, aktif, catatan) values (nm, coalesce(p_aktif, true), nullif(btrim(p_catatan), '')) returning id into v;
  else update public.chemical_toko set nama = nm, aktif = coalesce(p_aktif, true), catatan = nullif(btrim(p_catatan), '') where id = p_id returning id into v;
       if v is null then raise exception 'toko tidak ditemukan'; end if; end if;
  return v;
end $f$;

create or replace function public.chemical_hapus_toko(p_id bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
declare t public.chemical_toko; n int;
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  select * into t from public.chemical_toko where id = p_id;
  if not found then raise exception 'toko tidak ditemukan'; end if;
  select count(*) into n from public.chemical_item where toko_id = p_id;
  if n > 0 then raise exception 'toko "%" masih punya % barang sehingga tidak bisa dihapus; pindahkan atau hapus barangnya dulu, atau nonaktifkan tokonya', t.nama, n; end if;
  delete from public.chemical_toko where id = p_id;
end $f$;

revoke all on function public.chemical_barang_daftar() from public, anon;                      grant execute on function public.chemical_barang_daftar() to authenticated;
revoke all on function public.chemical_toko_daftar() from public, anon;                        grant execute on function public.chemical_toko_daftar() to authenticated;
revoke all on function public.chemical_simpan_item(bigint, bigint, text, text, numeric, numeric, boolean, boolean, text) from public, anon;
grant execute on function public.chemical_simpan_item(bigint, bigint, text, text, numeric, numeric, boolean, boolean, text) to authenticated;
revoke all on function public.chemical_hapus_item(bigint) from public, anon;                   grant execute on function public.chemical_hapus_item(bigint) to authenticated;
revoke all on function public.chemical_simpan_toko(bigint, text, boolean, text) from public, anon;  grant execute on function public.chemical_simpan_toko(bigint, text, boolean, text) to authenticated;
revoke all on function public.chemical_hapus_toko(bigint) from public, anon;                   grant execute on function public.chemical_hapus_toko(bigint) to authenticated;

-- Catatan perubahan barang dan toko (termasuk perubahan harga) untuk Log perubahan.
drop trigger if exists log_perubahan on public.chemical_item;
create trigger log_perubahan after insert or update or delete on public.chemical_item for each row execute function public._catat_log();
drop trigger if exists log_perubahan on public.chemical_toko;
create trigger log_perubahan after insert or update or delete on public.chemical_toko for each row execute function public._catat_log();
