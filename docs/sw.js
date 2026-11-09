/* Service worker aplikasi pengadaan.
   Tujuan: aplikasi bisa dipasang dan tampilannya terbuka cepat. Data tetap dari Supabase, jadi TIDAK disimpan di sini.
   Strategi: untuk berkas milik situs sendiri (halaman, skrip, gambar) coba jaringan dulu supaya versi baru langsung terpakai,
   dan bila tidak ada koneksi pakai salinan terakhir. Panggilan ke Supabase, Google Fonts, ntfy, dan domain lain tidak disentuh.
   Nama cache memuat nomor versi (dari ?v= pada alamat sw.js, diisi portal dari aset/versi.js); versi baru membuang cache lama. */
const VERSI = new URL(self.location).searchParams.get('v') || '0';
const CACHE = 'pengadaan-' + VERSI;
const CANGKANG = ['./', 'offline.html', 'manifest.webmanifest', 'aset/tema.css', 'aset/tema-ringan.css', 'aset/auth.js', 'aset/nama-bagian.js', 'aset/filter.js', 'aset/versi.js',
  'aset/logo-ray.png', 'aset/ikon-192.png', 'seragam/', 'peralatan/', 'administrator/'];

self.addEventListener('install', e => {
  // satu berkas gagal tidak boleh menggagalkan pemasangan
  e.waitUntil(caches.open(CACHE).then(c => Promise.all(CANGKANG.map(u => c.add(new Request(u, { cache: 'reload' })).catch(() => {})))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(n => Promise.all(n.filter(k => k.startsWith('pengadaan-') && k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== self.location.origin || u.pathname.endsWith('/sw.js')) return;
  e.respondWith((async () => {
    const c = await caches.open(CACHE);
    try {
      const baru = await fetch(r);
      if (baru && baru.ok && baru.type === 'basic') c.put(r, baru.clone());
      return baru;
    } catch (galat) {
      const ada = (await c.match(r)) || (await c.match(r, { ignoreSearch: true }));
      if (ada) return ada;
      if (r.mode === 'navigate') return (await c.match('offline.html')) || new Response('Tidak ada koneksi.', { status: 503, headers: { 'content-type': 'text/plain; charset=utf-8' } });
      throw galat;
    }
  })());
});
