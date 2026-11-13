-- Chemical form korlap, penyesuaian 2: barang di luar daftar (teks bebas, tanpa harga sampai admin menetapkan) dan catatan per pesanan.
-- Baris bebas disimpan di chemical_permintaan dengan item_id kosong + nama_bebas/satuan_bebas; admin melihatnya bertanda 'bebas'.

alter table public.chemical_kiriman add column if not exists catatan text;

alter table public.chemical_permintaan alter column item_id drop not null;
alter table public.chemical_permintaan add column if not exists nama_bebas text;
alter table public.chemical_permintaan add column if not exists satuan_bebas text;
alter table public.chemical_permintaan drop constraint if exists chemical_permintaan_item_atau_bebas;
alter table public.chemical_permintaan add constraint chemical_permintaan_item_atau_bebas
  check ((item_id is not null and nama_bebas is null) or (item_id is null and nama_bebas is not null and satuan_bebas is not null));

-- fungsi kirim lama (tanpa catatan) diganti
drop function if exists public.form_chemical_kirim(text, bigint, text, text, jsonb);

-- p_baris = [{"item_id":1,"qty":2}, {"nama":"Barang lain","satuan":"Pcs","qty":3}]; p_catatan = catatan untuk seluruh pesanan (opsional)
create or replace function public.form_chemical_kirim(p_token text, p_lokasi bigint, p_pengirim text, p_email text, p_catatan text, p_baris jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare p public.chemical_periode; kid bigint; n int := 0; nb int := 0; b jsonb; q numeric; iid bigint; nm text; st text;
  em text := lower(btrim(coalesce(p_email, '')));
begin
  select * into p from public.chemical_periode where token = p_token;
  if not found then raise exception 'tautan tidak valid'; end if;
  if not p.form_dibuka then raise exception 'form periode ini sudah ditutup'; end if;
  if not exists (select 1 from public.chemical_lokasi where id = p_lokasi and aktif) then raise exception 'lokasi tidak dikenal'; end if;
  if coalesce(btrim(p_pengirim), '') = '' then raise exception 'nama pengirim wajib diisi'; end if;
  if em !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'email pengirim tidak valid'; end if;
  if length(coalesce(p_catatan, '')) > 500 then raise exception 'catatan terlalu panjang (maksimal 500 karakter)'; end if;
  if jsonb_typeof(p_baris) <> 'array' or jsonb_array_length(p_baris) = 0 then raise exception 'belum ada barang yang dipilih'; end if;
  if jsonb_array_length(p_baris) > 500 then raise exception 'terlalu banyak baris'; end if;

  -- satu lokasi dan satu email hanya boleh mengirim sekali per periode (indeks unik menjaga juga bila dua kiriman datang bersamaan)
  if exists (select 1 from public.chemical_kiriman where periode_id = p.id and lokasi_id = p_lokasi) then raise exception 'lokasi ini sudah mengisi form periode ini'; end if;
  if exists (select 1 from public.chemical_kiriman where periode_id = p.id and lower(email) = em) then raise exception 'email ini sudah dipakai mengisi form periode ini'; end if;

  insert into public.chemical_kiriman (periode_id, lokasi_id, pengirim, email, catatan) values (p.id, p_lokasi, btrim(p_pengirim), em, nullif(btrim(p_catatan), '')) returning id into kid;
  for b in select * from jsonb_array_elements(p_baris) loop
    q := (b->>'qty')::numeric;
    if q is null or q <= 0 or q > 100000 then continue; end if;
    if b->>'item_id' is not null then
      iid := (b->>'item_id')::bigint;
      if not exists (select 1 from public.chemical_item i where i.id = iid and i.aktif) then raise exception 'barang tidak dikenal: %', iid; end if;
      insert into public.chemical_permintaan (kiriman_id, periode_id, lokasi_id, item_id, qty) values (kid, p.id, p_lokasi, iid, q)
        on conflict (kiriman_id, item_id) do update set qty = excluded.qty;
    else
      nm := btrim(coalesce(b->>'nama', '')); st := btrim(coalesce(b->>'satuan', ''));
      if nm = '' or st = '' then continue; end if;
      if length(nm) > 120 or length(st) > 30 then raise exception 'nama atau satuan barang lain terlalu panjang'; end if;
      nb := nb + 1; if nb > 20 then raise exception 'barang lain maksimal 20 baris'; end if;
      insert into public.chemical_permintaan (kiriman_id, periode_id, lokasi_id, item_id, qty, nama_bebas, satuan_bebas) values (kid, p.id, p_lokasi, null, q, nm, st);
    end if;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'jumlah barang tidak valid'; end if;
  return jsonb_build_object('ok', true, 'jumlah_barang', n, 'barang_lain', nb);
end $f$;
revoke all on function public.form_chemical_kirim(text, bigint, text, text, text, jsonb) from public;
grant execute on function public.form_chemical_kirim(text, bigint, text, text, text, jsonb) to anon, authenticated;

-- daftar admin: barang bebas ikut tampil (bebas = true, tanpa harga) dan catatan pesanan disertakan
drop function if exists public.chemical_permintaan_daftar(bigint);
create or replace function public.chemical_permintaan_daftar(p_periode bigint) returns table(kiriman_id bigint, pengirim text, email text, catatan_kiriman text, lokasi_id bigint, lokasi text, item_id bigint, bebas boolean, toko text, barang text, satuan text, qty numeric, harga_beli numeric, harga_jual numeric, dikirim timestamptz)
 language plpgsql stable security definer set search_path to 'public' as $f$
begin
  if not public._adalah_admin() then raise exception 'login admin diperlukan'; end if;
  return query
    select k.id, k.pengirim, k.email, k.catatan, m.lokasi_id, l.nama, m.item_id, m.item_id is null, t.nama, coalesce(i.nama, m.nama_bebas), coalesce(i.satuan, m.satuan_bebas), m.qty, i.harga_beli, i.harga_jual, k.dikirim
    from public.chemical_permintaan m
    join public.chemical_kiriman k on k.id = m.kiriman_id
    join public.chemical_lokasi l on l.id = m.lokasi_id
    left join public.chemical_item i on i.id = m.item_id
    left join public.chemical_toko t on t.id = i.toko_id
    where m.periode_id = p_periode order by l.nama, k.dikirim, (m.item_id is null), t.nama, coalesce(i.nama, m.nama_bebas);
end $f$;
revoke all on function public.chemical_permintaan_daftar(bigint) from public, anon;
grant execute on function public.chemical_permintaan_daftar(bigint) to authenticated;
