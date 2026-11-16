// Pembaca nota: foto nota (belanja atau operasional) dibaca Gemini lalu dikembalikan sebagai isian form. Khusus admin login.
//  POST {foto: "data:image/jpeg;base64,...", jenis: "belanja"|"operasional"}
//   -> {foto_url, hasil: {toko, tanggal, no_nota, total, kategori, rincian:[{nama, qty, satuan, harga, subtotal}], keyakinan, catatan_baca}, model}
// Foto disimpan di Storage (folder acak "nota-..."); yang disimpan ke database baru terjadi setelah admin memeriksa dan menekan Simpan.
// Rahasia: GEMINI_API_KEY (wajib), GEMINI_MODEL (opsional). verify_jwt dimatikan; admin diperiksa di sini.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'content-type, authorization, apikey, x-client-info' };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json', ...CORS } });
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const MODEL = Deno.env.get('GEMINI_MODEL') || 'gemini-3.6-flash';
const acak = () => crypto.randomUUID().replaceAll('-', '') + crypto.randomUUID().replaceAll('-', '');

async function adalahAdmin(req: Request): Promise<boolean> {
  const t = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!t) return false;
  const { data, error } = await db.auth.getUser(t);
  if (error || !data?.user) return false;
  const { data: a } = await db.from('admin_pengguna').select('user_id').eq('user_id', data.user.id).eq('aktif', true).maybeSingle();
  return !!a;
}

const SKEMA = {
  type: 'OBJECT',
  properties: {
    toko: { type: 'STRING', nullable: true, description: 'Nama toko/penjual/pihak yang menerbitkan nota' },
    tanggal: { type: 'STRING', nullable: true, description: 'Tanggal nota format YYYY-MM-DD' },
    no_nota: { type: 'STRING', nullable: true, description: 'Nomor nota/faktur/struk' },
    total: { type: 'NUMBER', nullable: true, description: 'Total yang harus dibayar, rupiah, tanpa pemisah ribuan' },
    kategori: { type: 'STRING', nullable: true, description: 'Untuk nota operasional: jenis biaya singkat, mis. Bensin, Tol, Parkir, Makan, Ongkir' },
    rincian: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          nama: { type: 'STRING' }, qty: { type: 'NUMBER', nullable: true }, satuan: { type: 'STRING', nullable: true },
          harga: { type: 'NUMBER', nullable: true, description: 'Harga per satuan, rupiah' }, subtotal: { type: 'NUMBER', nullable: true, description: 'Jumlah harga baris, rupiah' },
        },
        required: ['nama'],
      },
    },
    keyakinan: { type: 'STRING', enum: ['tinggi', 'sedang', 'rendah'], description: 'Seberapa yakin hasil bacaan ini benar' },
    catatan_baca: { type: 'STRING', nullable: true, description: 'Bagian yang buram, terpotong, atau diragukan; kosong bila semua jelas' },
  },
  required: ['rincian', 'keyakinan'],
};

const PROMPT = (jenis: string) => `Kamu membaca foto nota/struk/faktur berbahasa Indonesia untuk pencatatan pengeluaran ${jenis === 'operasional' ? 'operasional (bensin, tol, parkir, makan, ongkos kirim, dll.)' : 'belanja barang chemical dan perlengkapan kebersihan'}.
Aturan:
- Salin HANYA yang benar-benar tertulis. Bila sebuah isian tidak terbaca atau tidak ada, isi null. JANGAN menebak atau mengarang angka.
- Semua uang dalam rupiah sebagai angka bulat tanpa titik/koma pemisah (Rp 1.250.000 menjadi 1250000).
- Tanggal ditulis YYYY-MM-DD. Format nota Indonesia umumnya hari/bulan/tahun (03/11/2026 berarti 3 November 2026). Bila tahun hanya 2 digit, anggap 20xx.
- total = jumlah akhir yang dibayar (setelah diskon/pajak bila ada), bukan subtotal sebagian.
- rincian: satu baris per barang di nota, urut seperti di nota. Untuk nota tanpa rincian (mis. struk bensin atau tol), isi satu baris saja atau kosongkan.
- keyakinan "rendah" bila foto buram, tulisan tangan sulit dibaca, atau ada angka yang meragukan; jelaskan di catatan_baca.`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Metode tidak didukung' }, 405);
  if (!(await adalahAdmin(req))) return json({ error: 'login admin diperlukan' }, 401);
  const kunci = Deno.env.get('GEMINI_API_KEY');
  if (!kunci) return json({ error: 'GEMINI_API_KEY belum dipasang di server' }, 500);

  let body: any; try { body = await req.json(); } catch { return json({ error: 'Data tidak terbaca' }, 400); }
  const jenis = body?.jenis === 'operasional' ? 'operasional' : 'belanja';
  const m = /^data:image\/jpeg;base64,([A-Za-z0-9+/=]+)$/.exec(String(body?.foto ?? ''));
  if (!m) return json({ error: 'Foto tidak valid (harus JPEG)' }, 400);
  let bytes: Uint8Array;
  try { const bin = atob(m[1]); if (bin.length < 500 || bin.length > 4_000_000) return json({ error: 'Ukuran foto tidak wajar (maksimal sekitar 4 MB)' }, 400); bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0)); }
  catch { return json({ error: 'Foto tidak terbaca' }, 400); }

  // 1) simpan foto
  const folder = `nota-${acak().slice(0, 32)}`, nama = 'nota.jpg';
  const { error: eUp } = await db.storage.from('lampiran-surat').upload(`${folder}/${nama}`, bytes, { contentType: 'image/jpeg', upsert: false });
  if (eUp) return json({ error: 'Gagal menyimpan foto: ' + eUp.message }, 500);
  const foto_url = `${Deno.env.get('SUPABASE_URL')}/storage/v1/object/public/lampiran-surat/${folder}/${nama}`;

  // 2) baca dengan Gemini
  let r: Response;
  try {
    r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`, {
      method: 'POST', headers: { 'x-goog-api-key': kunci, 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(90_000),
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text: PROMPT(jenis) }, { inline_data: { mime_type: 'image/jpeg', data: m[1] } }] }],
        generationConfig: { responseMimeType: 'application/json', responseSchema: SKEMA, temperature: 0 },
      }),
    });
  } catch (e) { return json({ error: 'Gemini tidak terjangkau: ' + (e as Error).message, foto_url }, 502); }
  const mentah = await r.text();
  if (!r.ok) {
    const pesan = r.status === 429 ? 'Kuota Gemini sedang habis. Tunggu sebentar atau isi nota secara manual.' : r.status === 400 || r.status === 403 ? 'Gemini menolak permintaan (' + r.status + '): ' + mentah.slice(0, 200) : 'Gemini gagal (' + r.status + ')';
    return json({ error: pesan, foto_url }, 502);
  }
  let hasil: any;
  try {
    const teks = JSON.parse(mentah)?.candidates?.[0]?.content?.parts?.map((p: any) => p.text ?? '').join('') ?? '';
    hasil = JSON.parse(teks);
  } catch { return json({ error: 'Jawaban Gemini tidak bisa dibaca. Isi manual atau coba foto ulang.', foto_url }, 502); }

  // 3) rapikan: hanya tipe yang diharapkan
  const angka = (v: unknown) => (typeof v === 'number' && isFinite(v) && v >= 0 ? v : null);
  const teks = (v: unknown, n: number) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, n) : null);
  const tgl = typeof hasil?.tanggal === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(hasil.tanggal) ? hasil.tanggal : null;
  const bersih = {
    toko: teks(hasil?.toko, 150), tanggal: tgl, no_nota: teks(hasil?.no_nota, 60), total: angka(hasil?.total), kategori: teks(hasil?.kategori, 60),
    rincian: (Array.isArray(hasil?.rincian) ? hasil.rincian : []).slice(0, 150).map((b: any) => ({ nama: teks(b?.nama, 160) ?? '', qty: angka(b?.qty), satuan: teks(b?.satuan, 30), harga: angka(b?.harga), subtotal: angka(b?.subtotal) })).filter((b: any) => b.nama),
    keyakinan: ['tinggi', 'sedang', 'rendah'].includes(hasil?.keyakinan) ? hasil.keyakinan : 'rendah', catatan_baca: teks(hasil?.catatan_baca, 400),
  };
  return json({ foto_url, hasil: bersih, model: MODEL });
});
