// Form pengiriman Chemical untuk orang lapangan. SATU tautan bertoken per periode (chemical_periode.token_kirim), tanpa login; lokasi dipilih di dalam form.
//  GET  ?t=<token>  -> lokasi beserta barang yang harus diantar (tanpa harga) dan status sudah/belum
//  POST {t, lokasi_id, pengirim, penerima, jabatan, kondisi, catatan, diantar:[true/false per barang], foto:[dataURL jpeg...]} -> simpan; lokasi menjadi "Terkirim"
// Foto (JPEG) disimpan di Storage publik (folder acak). Tiap lokasi hanya bisa dilaporkan sekali; admin diberi tahu lewat ntfy.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Allow-Headers': 'content-type' };
const balas = (obj: unknown, status = 200) => new Response(JSON.stringify(obj), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const acak = () => crypto.randomUUID().replaceAll('-', '') + crypto.randomUUID().replaceAll('-', '');
const kodekan = (s: string) => '=?UTF-8?B?' + btoa(String.fromCharCode(...new TextEncoder().encode(s))) + '?=';
const teksBersih = (v: unknown, maks: number) => String(v ?? '').replace(/[\u0000-\u001f]+/g, ' ').trim().slice(0, maks);

function dariDataUrl(s: unknown, maksByte: number): Uint8Array | null {
  const t = String(s ?? ''), awal = 'data:image/jpeg;base64,';
  if (!t.startsWith(awal)) return null;
  try {
    const bin = atob(t.slice(awal.length)); if (bin.length > maksByte || bin.length < 50) return null;
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch { return null; }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let body: any = null;
  if (req.method === 'POST') { try { body = await req.json(); } catch { return balas({ error: 'Data tidak terbaca' }, 400); } }
  else if (req.method !== 'GET') return balas({ error: 'Metode tidak didukung' }, 405);
  const t = String(body?.t ?? new URL(req.url).searchParams.get('t') ?? '');
  if (t.length < 32) return balas({ error: 'Tautan tidak valid' }, 400);

  const { data: info, error: eInfo } = await db.rpc('chemical_pengiriman_info', { p_token: t });
  if (eInfo || !info) return balas({ error: 'Tautan tidak dikenali' }, 403);
  if (req.method === 'GET') return balas(info);

  // ---- POST ----
  if (!['DISETUJUI', 'BELANJA', 'PLOTING', 'PENGIRIMAN', 'DILAPORKAN'].includes(info.status)) return balas({ error: 'Pengiriman periode ini belum dibuka' }, 403);
  const lok = (info.lokasi ?? []).find((l: any) => l.id === Number(body.lokasi_id));
  if (!lok) return balas({ error: 'Pilih lokasi' }, 400);
  if (lok.sudah) return balas({ error: 'Pengiriman lokasi ini sudah dilaporkan' }, 409);
  const pengirim = teksBersih(body.pengirim, 120);
  if (!pengirim) return balas({ error: 'Nama pengirim wajib diisi' }, 400);
  const penerima = teksBersih(body.penerima, 120), jabatan = teksBersih(body.jabatan, 80), catatan = teksBersih(body.catatan, 500);
  if (!penerima) return balas({ error: 'Nama penerima wajib diisi' }, 400);
  const barang: { nama: string; satuan: string; qty: number }[] = lok.barang ?? [];
  const diantar: unknown[] = Array.isArray(body.diantar) ? body.diantar : [];
  if (diantar.length !== barang.length) return balas({ error: 'Daftar barang tidak cocok, muat ulang halaman' }, 400);
  const hasilBarang = barang.map((b, i) => ({ ...b, diantar: diantar[i] === true }));
  const kurang = hasilBarang.filter((b) => !b.diantar).length;
  const kondisi = ['sesuai', 'kurang', 'rusak'].includes(body.kondisi) ? String(body.kondisi) : '';
  if (!kondisi) return balas({ error: 'Pilih kondisi barang' }, 400);
  if (kondisi === 'sesuai' && kurang) return balas({ error: 'Ada barang yang belum dicentang; pilih kondisi "Ada yang kurang"' }, 400);
  if (kondisi !== 'sesuai' && !catatan) return balas({ error: 'Jelaskan barang yang kurang atau rusak pada catatan' }, 400);
  const fotoIn: unknown[] = Array.isArray(body.foto) ? body.foto.slice(0, 8) : [];
  const foto = fotoIn.map((f) => dariDataUrl(f, 1_800_000)).filter((x): x is Uint8Array => !!x);
  if (!foto.length) return balas({ error: 'Lampirkan minimal satu foto' }, 400);
  if (foto.length !== fotoIn.length) return balas({ error: 'Ada foto yang tidak valid atau terlalu besar' }, 400);

  const folder = `chem-kirim-${lok.id}-${acak().slice(0, 24)}`, url = (n: string) => `${Deno.env.get('SUPABASE_URL')}/storage/v1/object/public/lampiran-surat/${folder}/${n}`;
  try {
    for (let i = 0; i < foto.length; i++) { const { error } = await db.storage.from('lampiran-surat').upload(`${folder}/foto-${i + 1}.jpg`, foto[i], { contentType: 'image/jpeg', upsert: false }); if (error) throw new Error('Gagal menyimpan foto: ' + error.message); }
  } catch (e) { return balas({ error: String((e as Error).message) }, 500); }
  await db.from('chemical_pengiriman').upsert({ periode_id: info.periode_id, lokasi_id: lok.id }, { onConflict: 'periode_id,lokasi_id', ignoreDuplicates: true });
  // is('terkirim', null): bila dua kiriman datang bersamaan, hanya satu yang menang
  const { data: upd, error: eUpd } = await db.from('chemical_pengiriman').update({ terkirim: new Date().toISOString(), pengirim, penerima, jabatan: jabatan || null, kondisi, catatan: catatan || null, barang: hasilBarang, foto_urls: foto.map((_, i) => url(`foto-${i + 1}.jpg`)) })
    .eq('periode_id', info.periode_id).eq('lokasi_id', lok.id).is('terkirim', null).select('id');
  if (eUpd) return balas({ error: 'Gagal menyimpan pengiriman' }, 500);
  if (!upd?.length) return balas({ error: 'Pengiriman lokasi ini sudah dilaporkan' }, 409);

  const topik = Deno.env.get('NTFY_TOPIC_ADMIN');
  if (topik) {
    try { await fetch(`https://ntfy.sh/${topik}`, { method: 'POST', headers: { Title: kodekan(`Chemical terkirim: ${lok.nama}`.slice(0, 120)), Priority: kondisi === 'sesuai' ? '3' : '4', Tags: 'package' },
      body: `Pengirim: ${pengirim}\nPenerima: ${penerima}${jabatan ? ' (' + jabatan + ')' : ''}\nKondisi: ${kondisi}${kurang ? ` · ${kurang} barang belum diantar` : ''}\n${foto.length} foto. Lihat di Chemical > Pengiriman.` }); } catch { /* abaikan */ }
  }
  return balas({ ok: true, foto: foto.length });
});
