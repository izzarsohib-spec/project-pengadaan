-- Pemetaan barang pengadaan -> SKU toko Mas Wahyu. Dipakai pengirim barang datang dan tagihan ke toko (integrasi toko):
-- kiriman memakai SKU toko, bukan nama barang, jadi tiap barang (dan ukurannya bila stok toko per ukuran) perlu dipetakan sekali.
--
-- Satu baris = satu pemetaan. Pencarian memilih yang paling khusus:
--   1. barang + jenis ukuran + ukuran persis (mis. SERAGAM PDL, baju, XL)
--   2. barang + jenis ukuran, semua ukuran   (mis. SERAGAM PDL, baju, *)
--   3. barang saja, semua jenis dan ukuran   (jenis '*' dan ukuran '*')
-- jenis_ukuran sama dengan stok_gerak.jenis_ukuran ('baju','celana','sepatu','-'); '*' = semua.
-- Semua akses lewat fungsi security definer; tabel tertutup untuk anon. Membaca dan menulis butuh login admin.

create table if not exists public.sku_toko (
  id bigint generated always as identity primary key,
  item_no int not null,
  jenis_ukuran text not null default '*' check (jenis_ukuran in ('*', 'baju', 'celana', 'sepatu', '-')),
  ukuran text not null default '*',
  sku text not null check (length(trim(sku)) between 1 and 50),
  diperbarui timestamptz not null default now(),
  check (jenis_ukuran <> '*' or ukuran = '*')
);
create unique index if not exists sku_toko_kunci on public.sku_toko (item_no, jenis_ukuran, upper(ukuran));
alter table public.sku_toko enable row level security;
revoke all on public.sku_toko from anon, authenticated;

-- Seragam yang dihapus dari daftar harga tidak meninggalkan pemetaan yatim.
create or replace function public._sku_toko_bersih() returns trigger
 language plpgsql security definer set search_path to 'public' as $f$
begin
  delete from public.sku_toko where item_no = old.no;
  return old;
end $f$;
revoke all on function public._sku_toko_bersih() from public, anon, authenticated;
drop trigger if exists sku_toko_bersih on public.harga_seragam;
create trigger sku_toko_bersih after delete on public.harga_seragam for each row execute function public._sku_toko_bersih();

-- Perubahan pemetaan ikut tercatat di Log perubahan.
drop trigger if exists log_perubahan on public.sku_toko;
create trigger log_perubahan after insert or update or delete on public.sku_toko for each row execute function public._catat_log();

-- Daftar untuk tab Administrator: semua pemetaan, ditambah satu baris kosong untuk tiap seragam yang belum punya pemetaan sama sekali.
create or replace function public.admin_daftar_sku_toko(kode text)
 returns table(id bigint, item_no int, kategori text, nama text, komponen text, jenis_ukuran text, ukuran text, sku text)
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  perform public._wajib_kode(kode);
  return query
    select x.id, x.item_no, x.kategori, x.nama, x.komponen, x.jenis_ukuran, x.ukuran, x.sku from (
      select s.id, s.item_no, h.kategori, h.nama, h.komponen, s.jenis_ukuran, s.ukuran, s.sku
        from public.sku_toko s join public.harga_seragam h on h.no = s.item_no
      union all
      select null::bigint, h.no, h.kategori, h.nama, h.komponen, '*'::text, '*'::text, null::text
        from public.harga_seragam h where not exists (select 1 from public.sku_toko s where s.item_no = h.no)
    ) x order by x.item_no, (x.jenis_ukuran <> '*'), x.jenis_ukuran, upper(x.ukuran);
end $f$;
revoke all on function public.admin_daftar_sku_toko(text) from public; grant execute on function public.admin_daftar_sku_toko(text) to anon, authenticated;

-- p_id kosong = tambah. Ukuran kosong = semua ukuran; jenis '*' berarti semua jenis (ukuran harus kosong).
create or replace function public.admin_simpan_sku_toko(kode text, p_id bigint, p_item int, p_jenis text, p_ukuran text, p_sku text) returns bigint
 language plpgsql security definer set search_path to 'public' as $f$
declare
  j text := coalesce(nullif(trim(p_jenis), ''), '*');
  u text := coalesce(nullif(trim(p_ukuran), ''), '*');
  s text := trim(coalesce(p_sku, ''));
  rid bigint;
begin
  perform public._wajib_kode(kode);
  if s = '' then raise exception 'SKU toko wajib diisi'; end if;
  if length(s) > 50 then raise exception 'SKU toko maksimal 50 karakter'; end if;
  if j not in ('*', 'baju', 'celana', 'sepatu', '-') then raise exception 'jenis ukuran tidak dikenal'; end if;
  if j = '*' and u <> '*' then raise exception 'pilih jenis ukuran (baju, celana, atau sepatu) bila ukuran diisi'; end if;
  if not exists (select 1 from public.harga_seragam h where h.no = p_item) then raise exception 'seragam tidak ditemukan'; end if;
  if exists (select 1 from public.sku_toko t where t.item_no = p_item and t.jenis_ukuran = j and upper(t.ukuran) = upper(u) and t.id is distinct from p_id) then
    raise exception 'pemetaan untuk seragam, jenis ukuran, dan ukuran itu sudah ada';
  end if;
  if p_id is null then
    insert into public.sku_toko (item_no, jenis_ukuran, ukuran, sku) values (p_item, j, u, s) returning id into rid;
  else
    update public.sku_toko set item_no = p_item, jenis_ukuran = j, ukuran = u, sku = s, diperbarui = now() where id = p_id returning id into rid;
    if rid is null then raise exception 'pemetaan tidak ditemukan'; end if;
  end if;
  return rid;
end $f$;
revoke all on function public.admin_simpan_sku_toko(text, bigint, int, text, text, text) from public; grant execute on function public.admin_simpan_sku_toko(text, bigint, int, text, text, text) to anon, authenticated;

create or replace function public.admin_hapus_sku_toko(kode text, p_id bigint) returns void
 language plpgsql security definer set search_path to 'public' as $f$
begin
  perform public._wajib_kode(kode);
  delete from public.sku_toko where id = p_id;
  if not found then raise exception 'pemetaan tidak ditemukan'; end if;
end $f$;
revoke all on function public.admin_hapus_sku_toko(text, bigint) from public; grant execute on function public.admin_hapus_sku_toko(text, bigint) to anon, authenticated;

-- Dipakai fungsi pengirim ke toko (service role), bukan dari browser: SKU toko untuk satu baris barang, atau null bila belum dipetakan.
create or replace function public.sku_toko_untuk(p_item int, p_jenis text, p_ukuran text) returns text
 language sql stable security definer set search_path to 'public' as $f$
  select t.sku from public.sku_toko t
   where t.item_no = p_item
     and (t.jenis_ukuran = '*' or (t.jenis_ukuran = coalesce(p_jenis, '-') and (t.ukuran = '*' or upper(t.ukuran) = upper(coalesce(p_ukuran, '-')))))
   order by (t.jenis_ukuran = '*'), (t.ukuran = '*') limit 1 $f$;
revoke all on function public.sku_toko_untuk(int, text, text) from public, anon, authenticated;
