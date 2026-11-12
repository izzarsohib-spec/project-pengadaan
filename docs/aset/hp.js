/* Pelengkap tampilan ponsel (<= 760px) untuk modul: melipat kartu panjang yang jarang dibaca di ponsel.
   Memakai mekanisme lipat bawaan halaman (kelas .lipat dan .tutup); pengguna tetap bisa membukanya dengan mengetuk judulnya. */
(function () {
  if (!window.matchMedia || !window.matchMedia('(max-width: 760px)').matches) return;
  const LIPAT = ['#pantau > .pcard.lipat']; // progres pengisian per PIC (13 PIC memanjangkan halaman Monitoring sampai ribuan piksel)
  function lipat() {
    LIPAT.forEach(function (s) {
      document.querySelectorAll(s).forEach(function (e) {
        if (e.dataset.hpLipat) return; e.dataset.hpLipat = '1';
        e.classList.add('tutup'); const h = e.querySelector('.lipat-h'); if (h) h.setAttribute('aria-expanded', 'false');
      });
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', lipat); else lipat();
})();
