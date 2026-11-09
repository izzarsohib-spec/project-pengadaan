/* Nama tampilan bagian kerja. Di database, Google Form, dan kunci lokasi|bagian nama bagian tetap "KEAMANAN PRIA (SECURITY)"
   (anggaran, karyawan, permintaan, ploting memakai nama itu); di web ditampilkan "KEAMANAN (SECURITY)".
   Dipasang sebagai pembungkus fetch: teks respons Supabase diganti ke nama tampilan, dan teks permintaan ke Supabase dikembalikan ke nama asli,
   sehingga semua halaman dan PDF ikut berubah tanpa mengubah data. Harus dimuat SEBELUM auth.js. Untuk mengganti nama lagi cukup ubah TAMPIL. */
(function () {
  const ASLI = 'KEAMANAN PRIA (SECURITY)', TAMPIL = 'KEAMANAN (SECURITY)';
  const f0 = window.fetch.bind(window);
  const ganti = (s, dari, ke) => s.indexOf(dari) < 0 ? s : s.split(dari).join(ke);
  const keAsli = s => ganti(ganti(s, TAMPIL, ASLI), encodeURIComponent(TAMPIL), encodeURIComponent(ASLI));

  window.fetch = async function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    // hanya API Supabase (REST dan fungsi server); Auth dan Storage tidak disentuh
    if (url.indexOf('.supabase.co/') < 0 || /\/(auth|storage)\/v1\//.test(url)) return f0(input, init);
    if (typeof input === 'string') input = keAsli(input);
    if (init && typeof init.body === 'string') init = Object.assign({}, init, { body: keAsli(init.body) });
    const r = await f0(input, init);
    if (r.status === 204 || r.status === 205 || r.status === 304 || !r.body) return r;
    const tipe = r.headers.get('content-type') || '';
    if (!/json|text/.test(tipe)) return r;
    const t = await r.text();
    return new Response(ganti(t, ASLI, TAMPIL), { status: r.status, statusText: r.statusText, headers: { 'content-type': tipe } });
  };
})();
