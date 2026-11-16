# Memasang monitoring pengiriman Chemical:
#   1. migrasi database (tabel chemical_pengiriman + fungsi chemical_pengiriman_daftar / chemical_pengiriman_info)
#   2. deploy fungsi kirim-chemical (tanpa verify_jwt: kurir tidak login; keamanan lewat token acak per lokasi)
# Jalankan:  powershell -ExecutionPolicy Bypass -File alat\pasang-kirim-chemical.ps1
$ErrorActionPreference = 'Stop'
$ref  = 'vqcusagijiavaoljfrib'
$repo = Split-Path -Parent $PSScriptRoot
. "$env:USERPROFILE\keystore\keys.ps1"
$sbp  = key-get supabase -Show
$mgmt = @{ Authorization = "Bearer $sbp" }
$api  = "https://api.supabase.com/v1/projects/$ref"

$sql  = [IO.File]::ReadAllText("$repo\supabase\migrasi-chemical-pengiriman.sql")
$body = ConvertTo-Json -Compress -InputObject @{ query = [string]$sql }
Invoke-RestMethod -Method Post -Uri "$api/database/query" -Headers $mgmt -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
Write-Host 'migrasi database selesai'

$slug = 'kirim-chemical'
$meta = Join-Path $env:TEMP "meta-$slug.json"
[IO.File]::WriteAllText($meta, (@{ entrypoint_path = 'index.ts'; name = $slug; verify_jwt = $false } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
$out = curl.exe -s -w "`nHTTP %{http_code}" -X POST "$api/functions/deploy?slug=$slug" -H "Authorization: Bearer $sbp" -F "metadata=<$meta;type=application/json" -F "file=@$repo\supabase\functions\$slug\index.ts;filename=index.ts"
Remove-Item $meta -Force
Write-Host "$slug -> $($out -replace "`n", ' ')"
