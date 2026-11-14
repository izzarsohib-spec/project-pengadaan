# Menerapkan supabase/migrasi-sku-toko.sql (tabel sku_toko, fungsi admin_daftar/simpan/hapus_sku_toko, sku_toko_untuk).
# Aman dijalankan ulang. Dijalankan oleh pemilik proyek; butuh kunci `supabase` di keystore lokal (tidak ada di repo).
#   powershell -ExecutionPolicy Bypass -File alat/pasang-sku-toko.ps1
$ErrorActionPreference = 'Stop'
. "$env:USERPROFILE\keystore\keys.ps1"
$token = key-get supabase -Show
$ref = 'vqcusagijiavaoljfrib'
$sql = Get-Content (Join-Path $PSScriptRoot '..\supabase\migrasi-sku-toko.sql') -Raw -Encoding UTF8
function Kueri($q) {
  $b = [Text.Encoding]::UTF8.GetBytes((@{ query = $q } | ConvertTo-Json))
  Invoke-RestMethod -Method Post -Uri "https://api.supabase.com/v1/projects/$ref/database/query" -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json; charset=utf-8' -Body $b
}
Kueri $sql | Out-Null
Write-Host 'Migrasi SKU toko diterapkan.'
$n = Kueri 'select (select count(*) from public.sku_toko) as dipetakan, (select count(*) from public.harga_seragam) as seragam'
Write-Host ("Pemetaan: " + $n[0].dipetakan + " baris, seragam di daftar harga: " + $n[0].seragam)
