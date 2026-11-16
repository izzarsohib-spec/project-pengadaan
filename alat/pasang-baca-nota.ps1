# Memasang pembaca nota Chemical (Laporan):
#   1. migrasi database (tabel chemical_nota, kolom bukti transfer + fungsi chemical_nota_daftar / chemical_simpan_nota / chemical_hapus_nota)
#   2. deploy fungsi baca-nota (tanpa verify_jwt; admin diperiksa di dalam fungsi)
#   3. memasang rahasia GEMINI_API_KEY di server bila -Kunci diberikan (atau ada di keystore dengan nama "gemini")
# Jalankan:  powershell -ExecutionPolicy Bypass -File alat\pasang-baca-nota.ps1 [-Kunci <API key>] [-Model gemini-3.6-flash]
param([string]$Kunci = '', [string]$Model = '')
$ErrorActionPreference = 'Stop'
$ref  = 'vqcusagijiavaoljfrib'
$repo = Split-Path -Parent $PSScriptRoot
. "$env:USERPROFILE\keystore\keys.ps1"
$sbp  = key-get supabase -Show
$mgmt = @{ Authorization = "Bearer $sbp" }
$api  = "https://api.supabase.com/v1/projects/$ref"
function Json-Utf8($o) { $b = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 5 -InputObject $o)); return ,$b }   # koma: jaga agar tetap satu array byte

foreach ($berkas in @('migrasi-chemical-nota.sql', 'migrasi-chemical-nota-2.sql')) {
  $sql = [IO.File]::ReadAllText("$repo\supabase\$berkas")
  Invoke-RestMethod -Method Post -Uri "$api/database/query" -Headers $mgmt -ContentType 'application/json; charset=utf-8' -Body (Json-Utf8 @{ query = [string]$sql }) | Out-Null
  Write-Host "migrasi database: $berkas selesai"
}

$slug = 'baca-nota'
$meta = Join-Path $env:TEMP "meta-$slug.json"
[IO.File]::WriteAllText($meta, (@{ entrypoint_path = 'index.ts'; name = $slug; verify_jwt = $false } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
$out = curl.exe -s -w "`nHTTP %{http_code}" -X POST "$api/functions/deploy?slug=$slug" -H "Authorization: Bearer $sbp" -F "metadata=<$meta;type=application/json" -F "file=@$repo\supabase\functions\$slug\index.ts;filename=index.ts"
Remove-Item $meta -Force
Write-Host "$slug -> $(($out -replace "`n", ' ').Substring(0, [Math]::Min(160, $out.Length)))"

if (-not $Kunci) { try { $Kunci = key-get gemini -Show } catch { $Kunci = '' } }
$rahasia = @()
if ($Kunci) { $rahasia += @{ name = 'GEMINI_API_KEY'; value = $Kunci } }
if ($Model) { $rahasia += @{ name = 'GEMINI_MODEL'; value = $Model } }
if ($rahasia.Count) {
  Invoke-RestMethod -Method Post -Uri "$api/secrets" -Headers $mgmt -ContentType 'application/json; charset=utf-8' -Body (Json-Utf8 $rahasia) | Out-Null
  Write-Host ('rahasia terpasang: ' + (($rahasia | ForEach-Object { $_.name }) -join ', '))
} else { Write-Host 'GEMINI_API_KEY belum dipasang (jalankan ulang dengan -Kunci).' }
