// Uji inti pengirim ke toko. Jalankan: node --test supabase/functions/kirim-ke-toko/inti.test.ts   (Node 22.18+ / 24)
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import { bangunBarangDatang, bangunBarangKeluar, bangunTagihan, tafsirBalasan, tandatangani, type BarisStok } from './inti.ts';

const stok = (o: Partial<BarisStok> = {}): BarisStok => ({ sku: 'SRG-001', item_no: 1, item_nama: 'SERAGAM PDL', jenis_ukuran: 'baju', ukuran: 'L', qty: 5, tanggal: '2026-11-14', no_dokumen: 'SJ-77', keterangan: null, ...o });

test('barang datang: jumlah digabung per SKU, urutan SKU mengikuti kemunculan', () => {
  const h = bangunBarangDatang('BD-9', [stok(), stok({ ukuran: 'XL', qty: 3 }), stok({ sku: 'SPT-001', item_no: 2, item_nama: 'SEPATU PDH', jenis_ukuran: 'sepatu', ukuran: '42', qty: 2 })]);
  assert.ok(h.ok);
  assert.deepEqual(h.event, { type: 'goods_received', client: 'RMP', receipt_no: 'BD-9', po_number: 'SJ-77', received_date: '2026-11-14', items: [{ sku: 'SRG-001', quantity: 8 }, { sku: 'SPT-001', quantity: 2 }] });
});

test('barang keluar: jadi goods_issued untuk klien, jumlah digabung per SKU, nomor surat jalan sebagai po_number', () => {
  const h = bangunBarangKeluar('BK-5', [stok({ no_dokumen: 'SJ/2026/10/0001' }), stok({ ukuran: 'XL', qty: 3 }), stok({ sku: 'SRG-002', item_no: 1, jenis_ukuran: 'celana', ukuran: '32', qty: 4 })]);
  assert.ok(h.ok);
  assert.deepEqual(h.event, { type: 'goods_issued', client: 'RMP', issue_no: 'BK-5', po_number: 'SJ/2026/10/0001', issued_date: '2026-11-14', items: [{ sku: 'SRG-001', quantity: 8 }, { sku: 'SRG-002', quantity: 4 }] });
});

test('barang keluar: ada yang belum dipetakan -> seluruh pengiriman tertahan; baris kosong ditolak', () => {
  const h = bangunBarangKeluar('BK-6', [stok(), stok({ sku: null, item_nama: 'SEPATU PDH', jenis_ukuran: 'sepatu', ukuran: '42' })]);
  assert.equal(h.ok, false);
  assert.match((h as { alasan: string }).alasan, /SEPATU PDH sepatu 42/);
  assert.equal(bangunBarangKeluar('BK-7', []).ok, false);
});

test('barang datang: ada yang belum dipetakan -> tidak ada yang dikirim, daftar disebut', () => {
  const h = bangunBarangDatang('BD-9', [stok(), stok({ sku: null, item_no: 3, item_nama: 'TOPI', jenis_ukuran: '-', ukuran: '-' })]);
  assert.equal(h.ok, false);
  assert.match((h as { alasan: string }).alasan, /TOPI/);
  assert.doesNotMatch((h as { alasan: string }).alasan, /SERAGAM PDL/);
  const l = bangunBarangDatang('BD-9', [stok({ sku: null, ukuran: 'XXL' })]);
  assert.match((l as { alasan: string }).alasan, /SERAGAM PDL baju XXL/);
});

test('barang datang: baris kosong ditolak; keterangan dan dokumen opsional', () => {
  assert.equal(bangunBarangDatang('BD-1', []).ok, false);
  const h = bangunBarangDatang('BD-2', [stok({ no_dokumen: null, keterangan: 'sebagian' })]);
  assert.ok(h.ok);
  assert.equal('po_number' in h.event, false);
  assert.equal((h.event as { notes: string }).notes, 'sebagian');
});

test('tagihan: pemetaan field, jatuh tempo kosong tetap null, status batal', () => {
  const t = { no_invoice: 'INV-1', tanggal: '2026-11-10T00:00:00Z', jatuh_tempo: null, total: '5000000', status: 'belum', catatan: 'PO-530' };
  const h = bangunTagihan(t, [{ item_nama: 'SERAGAM PDL', qty: 20, harga: '195000' }], false);
  assert.ok(h.ok);
  assert.deepEqual(h.event, { type: 'invoice', client: 'RMP', invoice_number: 'INV-1', issued_date: '2026-11-10', due_date: null, total_amount: 5000000, status: 'MENDATANG', notes: 'PO-530', items: [{ description: 'SERAGAM PDL', quantity: 20, unit_price: 195000 }] });
  const b = bangunTagihan({ ...t, jatuh_tempo: '2026-12-01', status: 'batal' }, [], true);
  assert.ok(b.ok);
  assert.equal((b.event as { status: string }).status, 'DIBATALKAN');
  assert.equal((b.event as { due_date: string }).due_date, '2026-12-01');
  const s = bangunTagihan({ ...t, status: 'batal' }, [], false);
  assert.equal((s as { event: { status: string } }).event.status, 'DIBATALKAN');
});

test('tagihan: lunas di pengadaan -> LUNAS dengan tanggal bayar; sebagian tetap MENDATANG dengan catatan jumlah', () => {
  const t = { no_invoice: 'INV-3', tanggal: '2026-11-10', jatuh_tempo: '2026-11-24', total: 2180000, status: 'lunas', catatan: null, terbayar: 2180000, tgl_bayar: '2026-11-16' };
  const l = bangunTagihan(t, [], false);
  assert.ok(l.ok);
  assert.equal((l.event as { status: string }).status, 'LUNAS');
  assert.equal((l.event as { paid_date: string }).paid_date, '2026-11-16');
  assert.equal('notes' in l.event, false);
  const s = bangunTagihan({ ...t, status: 'sebagian', terbayar: 1090000, tgl_bayar: '2026-11-16', catatan: 'DEMO' }, [], false);
  assert.ok(s.ok);
  assert.equal((s.event as { status: string }).status, 'MENDATANG');
  assert.equal('paid_date' in s.event, false);
  assert.match((s.event as { notes: string }).notes, /^DEMO · Dibayar sebagian Rp1\.090\.000 dari Rp2\.180\.000$/);
  // lunas tanpa tanggal bayar (data lama): tetap LUNAS, toko memakai waktu terima
  const n = bangunTagihan({ ...t, tgl_bayar: null }, [], false);
  assert.equal((n as { event: { status: string } }).event.status, 'LUNAS');
  assert.equal('paid_date' in (n as { event: object }).event, false);
  // batal mengalahkan lunas
  assert.equal((bangunTagihan(t, [], true) as { event: { status: string } }).event.status, 'DIBATALKAN');
});

test('tagihan: melewati batas rupiah toko ditolak dengan alasan', () => {
  const t = { no_invoice: 'INV-2', tanggal: '2026-11-10', jatuh_tempo: null, total: 3_000_000_000, status: 'belum', catatan: null };
  const h = bangunTagihan(t, [], false);
  assert.equal(h.ok, false);
  assert.match((h as { alasan: string }).alasan, /batas/);
  assert.equal(bangunTagihan({ ...t, total: 100 }, [{ item_nama: 'X', qty: 0, harga: 1 }], false).ok, false);
});

test('tanda tangan sama persis dengan verifikasi toko (HMAC-SHA256 hex atas "ts.body")', async () => {
  const sig = await tandatangani('rahasia-uji-minimal-32-karakter-xxxx', '1800000000', '{"a":1}');
  assert.equal(sig, createHmac('sha256', 'rahasia-uji-minimal-32-karakter-xxxx').update('1800000000.{"a":1}').digest('hex'));
});

test('tafsir balasan toko', () => {
  assert.deepEqual(tafsirBalasan(200, { data: { duplicate: false } }), { status: 'terkirim', galat: null });
  assert.match(tafsirBalasan(200, { data: { duplicate: true } }).galat!, /sudah pernah/);
  const sku = tafsirBalasan(422, { code: 'SKU_NOT_FOUND', message: 'SKU belum ada di toko, stok tidak diubah: X-1' });
  assert.equal(sku.status, 'tertahan');
  assert.match(sku.galat!, /X-1/);
  assert.equal(tafsirBalasan(401, {}).status, 'gagal');
  assert.match(tafsirBalasan(503, {}).galat!, /belum dikonfigurasi/);
  assert.match(tafsirBalasan(400, { message: 'Input tidak valid', errors: { items: 'x' } }).galat!, /Input tidak valid/);
  assert.match(tafsirBalasan(500, {}).galat!, /HTTP 500/);
});
