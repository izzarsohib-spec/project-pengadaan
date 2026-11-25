/* Filter cabang / PIC lapangan yang dipakai bersama oleh portal, Seragam, Peralatan, dan Administrator.
   Pilihan disimpan di localStorage (satu pilihan untuk semua halaman, termasuk yang dibuka di dalam portal) dan diumumkan lewat
   peristiwa 'saring-ubah' di window. Tiap halaman menyaring datanya sendiri dengan Saring.boleh(namaLokasi) lalu menggambar ulang.
   Peta penugasan berasal dari fungsi publik daftar_penugasan_publik (hanya nama cabang, nama PIC, dan pasangan lokasinya). */
(function () {
  const URL_ = 'https://vqcusagijiavaoljfrib.supabase.co';
  // Anon key memang publik; hak aksesnya dibatasi di Supabase.
  const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZxY3VzYWdpamlhdmFvbGpmcmliIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0OTIzOTksImV4cCI6MjEwODA2ODM5OX0.VeslVR4UHv26LCMbkO7KP0k96r8lg7-NNLjY30iMyFk';
  const KUNCI = 'filter.lokasi', TANPA = '__tanpa';
  let peta = new Map(), petaB = new Map(), cab = [], pic = [], dimuat = false;

  // Tombol Filter PIC sudah dihapus: tidak ada lagi penyaringan lokasi; pilihan lama di browser dibuang. Saring.boleh selalu true.
  try { localStorage.removeItem(KUNCI); } catch (e) {}
  const baca = () => ({ cabang: '', pic: '' });
  const tulis = () => {};
  const umumkan = () => window.dispatchEvent(new Event('saring-ubah'));
  window.addEventListener('storage', e => { if (e.key === KUNCI) umumkan(); });

  const siap = (async () => {
    try {
      const r = await fetch(URL_ + '/rest/v1/rpc/daftar_penugasan_publik', { method: 'POST', headers: { apikey: ANON, Authorization: 'Bearer ' + ANON, 'Content-Type': 'application/json' }, body: '{}' });
      const j = await r.json(); if (!r.ok) throw new Error('HTTP ' + r.status);
      cab = j.cabang || []; pic = j.pic || []; petaB = new Map(); peta = new Map(); for (const x of j.lokasi || []) { if (x.b) petaB.set(x.l + '|' + x.b, x); else peta.set(x.l, x); } for (const x of j.lokasi || []) if (x.b && !peta.has(x.l)) peta.set(x.l, x); // tanpa bagian: baris seluruh lokasi, atau bagian pertama bila belum ada dimuat = true;
    } catch (e) { dimuat = false; }
  })();

  // area yang dipilih beserta sub-areanya (id sebagai teks)
  const turunan = id => { const x = String(id); return new Set([x, ...cab.filter(c => String(c.induk) === x).map(c => String(c.id))]); };
  const aktif = () => { const f = baca(); return dimuat && !!(f.cabang || f.pic); };
  function boleh(nama) {
    if (!aktif()) return true;
    const f = baca(), x = peta.get(String(nama == null ? '' : nama).toUpperCase());
    const area = f.cabang ? turunan(f.cabang) : null;
    if (f.pic === TANPA) return (!x || !x.p) && (!area || (!!x && area.has(String(x.c))));
    if (f.pic) return !!x && String(x.p) === String(f.pic);
    return !!x && !!area && area.has(String(x.c));
  }
  function set(o) {
    const f = Object.assign(baca(), o);
    if (f.pic && f.pic !== TANPA && f.cabang && !pic.some(p => String(p.id) === String(f.pic) && turunan(f.cabang).has(String(p.cabang_id)))) f.pic = '';
    tulis(f); umumkan();
  }
  const jumlah = () => [...peta.keys()].filter(boleh).length;
  function label() {
    const f = baca(); if (!aktif()) return 'Semua lokasi';
    const c = cab.find(x => String(x.id) === String(f.cabang)), p = pic.find(x => String(x.id) === String(f.pic));
    return f.pic === TANPA ? 'Belum ada PIC' + (c ? ' · ' + c.nama : '') : p ? 'PIC ' + p.nama : c ? (c.induk ? 'Area ' + (cab.find(x => String(x.id) === String(c.induk)) || {}).nama + ' · ' : 'Area ') + c.nama : 'Semua lokasi';
  }

  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // PIC yang memegang suatu lokasi ({id, nama}) atau null bila belum ada
  const cari = (nama, bagian) => { const n = String(nama == null ? '' : nama).toUpperCase(); return (bagian && petaB.get(n + '|' + String(bagian).toUpperCase())) || peta.get(n); };
  const picDari = (nama, bagian) => { const x = cari(nama, bagian); return x && x.p ? pic.find(p => String(p.id) === String(x.p)) || null : null; };

  // area (cabang / sub-area) tempat suatu lokasi, atau null
  const areaDari = (nama, bagian) => { const x = cari(nama, bagian); return x && x.c ? cab.find(c => String(c.id) === String(x.c)) || null : null; };

  window.Saring = { siap, boleh, aktif, set, get: baca, label, jumlah, picDari, areaDari, areaUtama: () => cab.filter(c => !c.induk), picSemua: () => pic.map(p => { const c = cab.find(x => String(x.id) === String(p.cabang_id)); return { id: p.id, nama: p.nama, area: c ? String(c.induk || c.id) : '' }; }), TANPA };

})();
