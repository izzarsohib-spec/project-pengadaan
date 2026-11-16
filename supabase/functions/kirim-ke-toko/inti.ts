// Inti pengirim ke toko Mas Wahyu: menyusun kiriman, memetakan SKU, menandatangani, dan menafsirkan balasan.
// Tanpa dependensi Deno/Supabase supaya bisa diuji di Node (lihat inti.test.ts). Kontrak kiriman = penerima di toko
// (adzkia-collection: POST /api/integrations/pengadaan, tanda tangan HMAC-SHA256 hex atas "<timestamp>.<body mentah>").

export interface BarisStok {
  /** SKU toko hasil sku_toko_untuk() di SQL; null = belum dipetakan. */
  sku: string | null;
  item_no: number;
  item_nama: string;
  jenis_ukuran: string;
  ukuran: string;
  qty: number;
  tanggal: string;
  no_dokumen: string | null;
  keterangan: string | null;
}
export interface BarisTagihan { item_nama: string; qty: number; harga: number | string }
export interface Tagihan {
  no_invoice: string;
  tanggal: string;
  jatuh_tempo: string | null;
  total: number | string;
  status: string;
  catatan: string | null;
}
export type Hasil<T> = { ok: true; event: T } | { ok: false; alasan: string };

export const BATAS_RUPIAH = 2_000_000_000;
/** Kode klien titipan di toko (PT Ray Mitra Perkasa); seluruh kiriman pengadaan ini milik klien tersebut. */
export const KLIEN_TOKO = 'RMP';

const label = (b: Pick<BarisStok, 'item_nama' | 'jenis_ukuran' | 'ukuran'>) =>
  b.item_nama + (b.jenis_ukuran && b.jenis_ukuran !== '-' ? ' ' + b.jenis_ukuran + (b.ukuran && b.ukuran !== '-' ? ' ' + b.ukuran : '') : '');

/**
 * Gabungkan baris stok per SKU toko. Semua-atau-tidak-sama-sekali: bila ada baris yang belum punya SKU toko,
 * tidak ada yang dikirim (stok titipan di toko tidak boleh berubah sebagian), dan daftar yang belum dipetakan dikembalikan.
 */
function kumpulkan(baris: BarisStok[], kosong: string): Hasil<{ items: { sku: string; quantity: number }[]; dok: string | null; ket: string | null; tanggal: string }> {
  if (!baris.length) return { ok: false, alasan: kosong };
  const belum = new Set<string>();
  const jumlah = new Map<string, number>();
  for (const b of baris) {
    const sku = b.sku;
    if (!sku) { belum.add(label(b)); continue; }
    jumlah.set(sku, (jumlah.get(sku) ?? 0) + Number(b.qty));
  }
  if (belum.size) return { ok: false, alasan: 'Belum ada SKU toko untuk: ' + [...belum].join(', ') + '. Petakan di Administrator > Seragam > SKU toko.' };
  return {
    ok: true,
    event: {
      items: [...jumlah].map(([sku, quantity]) => ({ sku, quantity })),
      dok: baris.find((b) => b.no_dokumen)?.no_dokumen ?? null,
      ket: baris.find((b) => b.keterangan)?.keterangan ?? null,
      tanggal: baris[0].tanggal,
    },
  };
}

/** Barang datang dari Mas Wahyu -> kiriman `goods_received` (menambah stok titipan klien di toko). */
export function bangunBarangDatang(kunci: string, baris: BarisStok[]): Hasil<Record<string, unknown>> {
  const k = kumpulkan(baris, 'Baris barang masuk tidak ditemukan (sudah dihapus?)');
  if (!k.ok) return k;
  const { items, dok, ket, tanggal } = k.event;
  return {
    ok: true,
    event: {
      type: 'goods_received',
      client: KLIEN_TOKO,
      receipt_no: kunci,
      ...(dok ? { po_number: String(dok).slice(0, 60) } : {}),
      received_date: tanggal,
      ...(ket ? { notes: String(ket).slice(0, 500) } : {}),
      items,
    },
  };
}

/** Pengiriman ke lokasi (surat jalan) -> kiriman `goods_issued` (mengurangi stok titipan klien di toko). */
export function bangunBarangKeluar(kunci: string, baris: BarisStok[]): Hasil<Record<string, unknown>> {
  const k = kumpulkan(baris, 'Baris barang keluar tidak ditemukan (sudah dihapus?)');
  if (!k.ok) return k;
  const { items, dok, ket, tanggal } = k.event;
  return {
    ok: true,
    event: {
      type: 'goods_issued',
      client: KLIEN_TOKO,
      issue_no: kunci,
      ...(dok ? { po_number: String(dok).slice(0, 60) } : {}),
      issued_date: tanggal,
      ...(ket ? { notes: String(ket).slice(0, 500) } : {}),
      items,
    },
  };
}

/** Tagihan (invoice dari Mas Wahyu kepada kita) -> kiriman `invoice`. `batal` mengirim status DIBATALKAN. */
export function bangunTagihan(t: Tagihan, items: BarisTagihan[], batal: boolean): Hasil<Record<string, unknown>> {
  const total = Number(t.total);
  if (!Number.isFinite(total) || total < 0 || total > BATAS_RUPIAH) return { ok: false, alasan: `Total tagihan ${t.total} di luar batas toko (maks Rp2 miliar)` };
  const baris = items.map((i) => ({ description: String(i.item_nama).slice(0, 200), quantity: Number(i.qty), unit_price: Number(i.harga) }));
  if (baris.some((i) => !Number.isInteger(i.quantity) || i.quantity < 1 || !Number.isFinite(i.unit_price) || i.unit_price < 0 || i.unit_price > BATAS_RUPIAH)) {
    return { ok: false, alasan: 'Ada baris tagihan dengan jumlah atau harga di luar batas toko' };
  }
  return {
    ok: true,
    event: {
      type: 'invoice',
      client: KLIEN_TOKO,
      invoice_number: t.no_invoice,
      issued_date: String(t.tanggal).slice(0, 10),
      due_date: t.jatuh_tempo ? String(t.jatuh_tempo).slice(0, 10) : null,
      total_amount: Math.round(total),
      status: batal || t.status === 'batal' ? 'DIBATALKAN' : 'MENDATANG',
      ...(t.catatan ? { notes: String(t.catatan).slice(0, 500) } : {}),
      items: baris,
    },
  };
}

/** Tanda tangan = hex HMAC-SHA256 dari "<timestamp>.<body mentah>" (sama dengan verifikasi di toko). */
export async function tandatangani(secret: string, timestamp: string, body: string): Promise<string> {
  const enc = new TextEncoder();
  const kunci = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', kunci, enc.encode(timestamp + '.' + body)));
  return Array.from(sig).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export type StatusAntrean = 'terkirim' | 'tertahan' | 'gagal';
/** Tafsir balasan toko. 422 SKU_NOT_FOUND = SKU sudah dipetakan di sini tetapi belum ada di toko: tertahan sampai salah satu sisi diperbaiki. */
export function tafsirBalasan(status: number, json: any): { status: StatusAntrean; galat: string | null } {
  const pesan = String(json?.message ?? '').slice(0, 300);
  if (status >= 200 && status < 300) return { status: 'terkirim', galat: json?.data?.duplicate ? 'Toko sudah pernah menerima kiriman ini (tidak dihitung dua kali)' : null };
  if (status === 422 && json?.code === 'SKU_NOT_FOUND') return { status: 'tertahan', galat: pesan || 'SKU belum ada di toko' };
  if (status === 401) return { status: 'gagal', galat: 'Ditolak toko: tanda tangan tidak cocok. Periksa TOKO_WEBHOOK_SECRET dan PENGADAAN_WEBHOOK_SECRET.' };
  if (status === 503) return { status: 'gagal', galat: 'Toko belum dikonfigurasi menerima kiriman (rahasia belum diisi di sisi toko)' };
  if (status === 400) return { status: 'gagal', galat: 'Data ditolak toko: ' + (pesan || 'tidak valid') + (json?.errors ? ' ' + JSON.stringify(json.errors).slice(0, 200) : '') };
  return { status: 'gagal', galat: `Toko membalas HTTP ${status}${pesan ? ': ' + pesan : ''}` };
}

