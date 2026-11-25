-- Chemical form korlap: email superadmin boleh mengisi form periode yang sama untuk banyak lokasi.
-- Email biasa tetap satu kiriman per periode; satu lokasi tetap satu kiriman per periode untuk semua email.
create table if not exists public.chemical_email_super (email text primary key check (email = lower(email)));
alter table public.chemical_email_super enable row level security; revoke all on public.chemical_email_super from anon, authenticated;
insert into public.chemical_email_super (email) values ('izzarsohib@gmail.com') on conflict do nothing;

alter table public.chemical_kiriman add column if not exists super boolean not null default false;
drop index if exists public.chemical_kiriman_email_idx;
create unique index chemical_kiriman_email_idx on public.chemical_kiriman (periode_id, lower(email)) where not super;

-- p_baris = [{"item_id":1,"qty":2}, {"nama":"Barang lain","satuan":"Pcs","qty":3}]; p_catatan = catatan untuk seluruh pesanan (opsional)
create or replace function public.form_chemical_kirim(p_token text, p_lokasi bigint, p_pengirim text, p_email text, p_catatan text, p_baris jsonb) returns jsonb
 language plpgsql security definer set search_path to 'public' as $f$
declare p public.chemical_periode; kid bigint; n int := 0; nb int := 0; b jsonb; q numeric; iid bigint; nm text; st text;
  em text := lower(btrim(coalesce(p_email, ''))); sup boolean;
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

  sup := exists (select 1 from public.chemical_email_super where lower(email) = em);
  -- satu lokasi dan satu email hanya boleh mengirim sekali per periode (indeks unik menjaga juga bila dua kiriman datang bersamaan)
  if exists (select 1 from public.chemical_kiriman where periode_id = p.id and lokasi_id = p_lokasi) then raise exception 'lokasi ini sudah mengisi form periode ini'; end if;
  if not sup and exists (select 1 from public.chemical_kiriman where periode_id = p.id and lower(email) = em) then raise exception 'email ini sudah dipakai mengisi form periode ini'; end if;

  insert into public.chemical_kiriman (periode_id, lokasi_id, pengirim, email, catatan, super) values (p.id, p_lokasi, btrim(p_pengirim), em, nullif(btrim(p_catatan), ''), sup) returning id into kid;
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
