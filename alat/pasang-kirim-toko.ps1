# Memasang pengirim ke toko Mas Wahyu (integrasi toko): barang datang menambah stok toko, tagihan tampil di Administrator toko.
#   1. migrasi database: migrasi-sku-toko.sql lalu migrasi-kirim-toko.sql (keduanya aman dijalankan ulang)
#   2. deploy fungsi kirim-ke-toko (index.ts + inti.ts, tanpa verify_jwt: pg_cron tidak membawa JWT; dijaga X-Token atau admin login)
#   3. rahasia fungsi: KIRIM_TOKO_TOKEN (acak, untuk pg_cron), TOKO_WEBHOOK_URL dan TOKO_WEBHOOK_SECRET (bila diberikan)
#   4. jadwal pg_cron "kirim-ke-toko" tiap menit (memanggil fungsi dengan X-Token)
# Dijalankan oleh pemilik proyek dari terminal Claude Code:  ! powershell -ExecutionPolicy Bypass -File alat/pasang-kirim-toko.ps1
# Parameter (semua opsional; tanpa -TokoUrl, kiriman ditahan dengan status "Tertahan" sampai toko diatur):
#   -TokoUrl https://alamat-toko/api/integrations/pengadaan   alamat penerima di server toko
#   -BuatRahasia                                              buat rahasia bersama baru; disimpan di Documents\toko-rahasia.txt (BUKAN di repo)
#                                                             dan harus diisi ke PENGADAAN_WEBHOOK_SECRET di server toko
#   -Rahasia <teks>                                           pakai rahasia yang sudah ada (min. 32 karakter), bila toko sudah punya
param([string]$TokoUrl = '', [switch]$BuatRahasia, [string]$Rahasia = '')
$ErrorActionPreference = 'Stop'
$ref  = 'vqcusagijiavaoljfrib'
$repo = Split-Path $PSScriptRoot -Parent
. "$env:USERPROFILE\keystore\keys.ps1"
$sbp  = key-get supabase -Show
$mgmt = @{ Authorization = "Bearer $sbp" }
$api  = "https://api.supabase.com/v1/projects/$ref"
function Acak($n) { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $n | ForEach-Object { [char]$_ }) }
function Kueri($q) {
  $b = ConvertTo-Json -Compress -InputObject @{ query = [string]$q }
  Invoke-RestMethod -Method Post -Uri "$api/database/query" -Headers $mgmt -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($b))
}

# 1. migrasi
foreach ($berkas in @('migrasi-sku-toko.sql', 'migrasi-kirim-toko.sql')) {
  Kueri ([IO.File]::ReadAllText("$repo\supabase\$berkas")) | Out-Null
  Write-Host "migrasi database: $berkas selesai"
}

# 2. deploy fungsi
$slug = 'kirim-ke-toko'
$meta = Join-Path $env:TEMP "meta-$slug.json"
[IO.File]::WriteAllText($meta, (@{ entrypoint_path = 'index.ts'; name = $slug; verify_jwt = $false } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
$dir = "$repo\supabase\functions\$slug"
$out = curl.exe -s -w "`nHTTP %{http_code}" -X POST "$api/functions/deploy?slug=$slug" -H "Authorization: Bearer $sbp" -F "metadata=<$meta;type=application/json" -F "file=@$dir\index.ts;filename=index.ts" -F "file=@$dir\inti.ts;filename=inti.ts"
Remove-Item $meta -Force
Write-Host "$slug -> $($out -replace "`n", ' ')"

# 3. rahasia
$token = Acak 48
$rahasia = @(@{ name = 'KIRIM_TOKO_TOKEN'; value = $token })
if ($BuatRahasia -and -not $Rahasia) {
  $Rahasia = Acak 48
  $catat = "$env:USERPROFILE\Documents\toko-rahasia.txt"
  Set-Content -Path $catat -Value $Rahasia -Encoding UTF8
  Write-Host "Rahasia bersama baru tersimpan di $catat (bukan di repo). Isi nilai yang sama ke PENGADAAN_WEBHOOK_SECRET di server toko."
}
if ($Rahasia -and $Rahasia.Length -lt 32) { throw 'Rahasia minimal 32 karakter.' }
if ($Rahasia) { $rahasia += @{ name = 'TOKO_WEBHOOK_SECRET'; value = $Rahasia } }
if ($TokoUrl) { $rahasia += @{ name = 'TOKO_WEBHOOK_URL'; value = $TokoUrl } }
Invoke-RestMethod -Method Post -Uri "$api/secrets" -Headers $mgmt -ContentType 'application/json' -Body (ConvertTo-Json -Compress -InputObject $rahasia) | Out-Null
Write-Host ('rahasia diatur: ' + (($rahasia | ForEach-Object { $_.name }) -join ', '))

# 4. jadwal tiap menit
$cron = @"
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
select cron.unschedule('kirim-ke-toko') where exists (select 1 from cron.job where jobname = 'kirim-ke-toko');
select cron.schedule('kirim-ke-toko', '* * * * *', `$c`$
  select net.http_post(url := 'https://$ref.supabase.co/functions/v1/kirim-ke-toko',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Token', '$token'),
    body := '{"aksi":"proses"}'::jsonb) `$c`$);
"@
Kueri $cron | Out-Null
Write-Host 'jadwal pg_cron kirim-ke-toko (tiap menit) dipasang'

$n = Kueri "select (select count(*) from public.kirim_toko) as antrean, (select count(*) from public.sku_toko) as pemetaan"
Write-Host ("Antrean kiriman: " + $n[0].antrean + ", pemetaan SKU: " + $n[0].pemetaan)
if (-not $TokoUrl) { Write-Host 'Catatan: TOKO_WEBHOOK_URL belum diisi, kiriman akan berstatus Tertahan. Jalankan ulang dengan -TokoUrl bila toko sudah di-hosting.' }
