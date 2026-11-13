-- Modul CHEMICAL (pengadaan bahan kimia dan perlengkapan kebersihan), terpisah dari seragam dan peralatan.
-- Tahap 1: katalog toko dan barang. Lokasi, anggaran, dan permintaan menyusul.
-- Satu barang boleh ada di beberapa toko dengan harga berbeda, jadi barang menempel pada toko (unik per toko + nama).
-- Semua tabel tertutup untuk anon (RLS aktif, hak dicabut); akses nanti lewat fungsi security definer seperti modul lain.
-- Data harga TIDAK ada di berkas ini (rahasia perusahaan); diisi lewat skrip data terpisah di luar repo.

create table if not exists public.chemical_toko (
  id bigint generated always as identity primary key,
  nama text not null unique,
  aktif boolean not null default true,
  catatan text);

create table if not exists public.chemical_item (
  id bigint generated always as identity primary key,
  toko_id bigint not null references public.chemical_toko(id),
  nama text not null,
  satuan text not null,
  harga_beli numeric not null default 0,
  harga_jual numeric,                              -- null = belum ditetapkan
  aktif boolean not null default true,
  perlu_ditinjau boolean not null default false,   -- harga jual menyimpang dari pola atau nama mirip item lain
  catatan text,
  unique (toko_id, nama));
create index if not exists chemical_item_toko_idx on public.chemical_item (toko_id);

alter table public.chemical_toko enable row level security;   revoke all on public.chemical_toko from anon, authenticated;
alter table public.chemical_item enable row level security;   revoke all on public.chemical_item from anon, authenticated;
