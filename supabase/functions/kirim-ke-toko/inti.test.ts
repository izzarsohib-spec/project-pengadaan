// Uji inti pengirim ke toko. Jalankan: node --test supabase/functions/kirim-ke-toko/inti.test.ts   (Node 22.18+ / 24)
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import { bangunBarangDatang, bangunTagihan, tafsirBalasan, tandatangani, type BarisStok } from './inti.ts';

const stok = (o: Partial<BarisStok> = {}): BarisStok => ({ sku: 'SRG-001', item_no: 1, item_nama: 'SERAGAM PDL', jenis_ukuran: 'baju', ukuran: 'L', qty: 5, tanggal: '2026-11-14', no_dokumen: 'SJ-77', keterangan: null, ...o });

test('barang datang: jumlah digabung per SKU, urutan SKU mengikuti kemunculan', () => {
  const h = bangunBarangDatang('BD-9', [stok(), stok({ ukuran: 'XL', qty: 3 }), stok({ sku: 'SPT-001', item_no: 2, item_nama: 'SEPATU PDH', jenis_ukuran: 'sepatu', ukuran: '42', qty: 2 })]);
  assert.ok(h.ok);
  assert.deepEqual(h.event, { type: 'goods_received', receipt_no: 'BD-9', po_number: 'SJ-77', received_date: '2026-11-14', items: [{ sku: 'SRG-001', quantity: 8 }, { sku: 'SPT-001', quantity: 2 }] });
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
  assert.deepEqual(h.event, { type: 'invoice', invoice_number: 'INV-1', issued_date: '2026-11-10', due_date: null, total_amount: 5000000, status: 'MENDATANG', notes: 'PO-530', items: [{ description: 'SERAGAM PDL', quantity: 20, unit_price: 195000 }] });
  const b = bangunTagihan({ ...t, jatuh_tempo: '2026-12-01', status: 'batal' }, [], true);
  assert.ok(b.ok);
  assert.equal((b.event as { status: string }).status, 'DIBATALKAN');
  assert.equal((b.event as { due_date: string }).due_date, '2026-12-01');
  const s = bangunTagihan({ ...t, status: 'batal' }, [], false);
  assert.equal((s as { event: { status: string } }).event.status, 'DIBATALKAN');
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
