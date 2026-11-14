// Pengirim ke toko Mas Wahyu: barang datang (menambah stok toko) dan tagihan (tampil di halaman Administrator toko).
// Antrean = tabel kirim_toko, diisi trigger database saat Barang datang dari Mas Wahyu dicatat atau tagihan dibuat/dibatalkan.
// Semua akses data lewat fungsi SQL (kirim_toko_ambil, kirim_toko_data, kirim_toko_catat) supaya logikanya teruji di database.
//   POST {aksi:'proses'}            : kirim yang menunggu / tertahan / gagal (jeda 5 menit antar percobaan, maks 60). Dipanggil pg_cron tiap menit (header X-Token).
//   POST {aksi:'ulang'}             : kirim ulang semua yang belum terkirim sekarang juga (admin login).
//   POST {aksi:'ulang', id: 12}     : kirim ulang satu baris antrean (admin login).
// verify_jwt dimatikan karena pg_cron tidak membawa JWT pengguna; keamanan: X-Token = KIRIM_TOKO_TOKEN, atau admin login (diperiksa di sini).
// Rahasia: TOKO_WEBHOOK_URL (alamat penerima di toko, mis. https://toko.example/api/integrations/pengadaan), TOKO_WEBHOOK_SECRET
// (sama dengan PENGADAAN_WEBHOOK_SECRET di server toko, min. 32 karakter), KIRIM_TOKO_TOKEN (untuk pg_cron).
// Aman dari kiriman ganda: toko menolak penerimaan dengan receipt_no yang sama dan menimpa tagihan per nomor, jadi dua pemanggilan bersamaan tidak menambah stok dua kali.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { bangunBarangDatang, bangunTagihan, tafsirBalasan, tandatangani, type StatusAntrean } from './inti.ts';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'content-type, authorization, apikey, x-client-info, x-token' };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json', ...CORS } });
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

async function adalahAdmin(req: Request): Promise<boolean> {
  const t = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!t) return false;
  const { data, error } = await db.auth.getUser(t);
  if (error || !data?.user) return false;
  const { data: a } = await db.from('admin_pengguna').select('user_id').eq('user_id', data.user.id).eq('aktif', true).maybeSingle();
  return !!a;
}

type Konfigurasi = { url: string; secret: string };
function bacaKonfigurasi(): Konfigurasi | null {
  const url = (Deno.env.get('TOKO_WEBHOOK_URL') ?? '').trim();
  const secret = Deno.env.get('TOKO_WEBHOOK_SECRET') ?? '';
  return /^https?:\/\//.test(url) && secret.length >= 32 ? { url, secret } : null;
}

async function bangunEvent(id: number) {
  const { data, error } = await db.rpc('kirim_toko_data', { p_id: id });
  if (error) throw new Error(error.message);
  if (!data) return { ok: false as const, alasan: 'Data kiriman tidak ditemukan' };
  if (data.jenis === 'barang_datang') return bangunBarangDatang(data.kunci, data.baris);
  if (!data.tagihan) return { ok: false as const, alasan: 'Tagihan tidak ditemukan (sudah dihapus?)' };
  return bangunTagihan(data.tagihan, data.items ?? [], String(data.kunci).endsWith('#batal'));
}

/** Proses satu baris antrean, lalu catat hasilnya. */
async function proses(id: number, konf: Konfigurasi | null, manual: boolean): Promise<StatusAntrean> {
  let hasil: { status: StatusAntrean; galat: string | null };
  let dicoba = false;
  try {
    const b = await bangunEvent(id);
    if (!b.ok) hasil = { status: 'tertahan', galat: b.alasan };
    else if (!konf) hasil = { status: 'tertahan', galat: 'Toko belum dikonfigurasi: TOKO_WEBHOOK_URL dan TOKO_WEBHOOK_SECRET belum diisi' };
    else {
      const body = JSON.stringify(b.event);
      const ts = String(Math.floor(Date.now() / 1000));
      const sig = await tandatangani(konf.secret, ts, body);
      dicoba = true;
      try {
        const res = await fetch(konf.url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'x-pengadaan-timestamp': ts, 'x-pengadaan-signature': sig },
          body,
          signal: AbortSignal.timeout(15000),
        });
        hasil = tafsirBalasan(res.status, await res.json().catch(() => ({})));
      } catch (e) {
        hasil = { status: 'gagal', galat: 'Tidak dapat menghubungi toko: ' + String((e as Error).message ?? e).slice(0, 200) };
      }
    }
  } catch (e) {
    hasil = { status: 'gagal', galat: String((e as Error).message ?? e).slice(0, 300) };
  }
  await db.rpc('kirim_toko_catat', { p_id: id, p_status: hasil.status, p_galat: hasil.galat, p_dicoba: dicoba, p_reset: manual });
  return hasil.status;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Gunakan POST' }, 405);
  const token = Deno.env.get('KIRIM_TOKO_TOKEN') ?? '';
  const dariCron = !!token && req.headers.get('x-token') === token;
  if (!dariCron && !(await adalahAdmin(req))) return json({ error: 'Tidak diizinkan' }, 401);

  const b = await req.json().catch(() => ({}));
  const manual = b?.aksi === 'ulang';
  const { data: daftar, error } = await db.rpc('kirim_toko_ambil', { p_manual: manual, p_id: manual && b?.id ? Number(b.id) : null });
  if (error) return json({ error: error.message }, 500);

  const konf = bacaKonfigurasi();
  const hitung: Record<StatusAntrean, number> = { terkirim: 0, tertahan: 0, gagal: 0 };
  for (const r of (daftar ?? []) as { id: number }[]) hitung[await proses(r.id, konf, manual)]++;
  return json({ ok: true, diproses: (daftar ?? []).length, ...hitung, dikonfigurasi: !!konf });
});
