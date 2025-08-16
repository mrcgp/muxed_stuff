:: === bulbys_muxed_loader.cmd (one-file) ===
@echo off
setlocal EnableExtensions
title bulbys_muxed_loader - Pi muxed report helper (one-file)

echo ============================================================
echo  bulbys_muxed_loader - Pi muxed report helper (one-file)
echo  Created by bulby_bot - %date% %time%
echo ============================================================

:: Temp PS path
set "TMPPS=%TEMP%\bulbys_mux_scan_%RANDOM%.ps1"

:: Find the line number of the PS marker
for /f "tokens=1 delims=:" %%N in ('findstr /n /b /c:"<#PS#>" "%~f0"') do set "PSLINE=%%N"

if not defined PSLINE (
  echo ERROR: PS block marker not found. Aborting.
  pause & exit /b 2
)

:: Extract everything AFTER the marker to the temp .ps1
(for /f "skip=%PSLINE% delims=" %%L in ('findstr /n "^" "%~f0"') do (
  set "line=%%L"
  setlocal enabledelayedexpansion
  echo(!line:*:=!
  endlocal
)) > "%TMPPS%"

:: Run it
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%"
set "RC=%ERRORLEVEL%"

:: Clean up
del "%TMPPS%" >nul 2>&1

echo.
echo Done. Exit code: %RC%
pause
exit /b %RC%

<#PS#>
# MIT License
# Copyright (c) 2025 bulby_bot
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to do so, subject to the following
# conditions: The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software. THE SOFTWARE IS
# PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

# ================== bulbys_mux_scan (embedded) ==================
# Created by bulby_bot on (auto): 
$created_info = "Created by bulby_bot on " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K')

Write-Host "============================================================"
Write-Host " bulbys_mux_scan — recover muxed recipients you sent to"
Write-Host " $created_info"
Write-Host "============================================================"

# -------- Params (prompt for account) --------
$Account = Read-Host "Account (G...)"
if ([string]::IsNullOrWhiteSpace($Account)) {
  Write-Warning "No account provided. Exiting."
  exit 1
}
$Account = $Account.Trim()
$SinceDays = 3650
$MaxPages  = 2000

# -------- Config --------
$HORIZON  = 'https://api.mainnet.minepi.com'
$TIMEOUT  = 15
$SINCE_TS = (Get-Date).AddDays(-1 * [Math]::Abs([double]$SinceDays))

# Output CSV name
$safe = ($Account -replace '[^A-Z0-9]','')
if ($safe.Length -gt 12) { $safe = $safe.Substring(0,12) }
$OutCsv = "bulbys_mux_report_" + $safe + ".csv"

# -------- Known exchanges --------
$KnownBaseToExchange = @{
  'GDFNWH6Z' = 'Bitget'
  'GALYJFJ5' = 'OKX'
  # add more as you verify them
}

# Exact muxed -> exchange and resolver (optional CSV)
$script:mxExchangeMap = @{}   # muxed_address -> exchange
$script:muxResolver   = @{}   # "base|muxed_id" -> muxed_address
$MuxMapPath = Join-Path (Get-Location) "muxed_canonical_enriched.csv"
if (Test-Path $MuxMapPath) {
  try {
    $rows = Import-Csv $MuxMapPath
    foreach($r in $rows){
      if ($r.muxed_address -and $r.base_account -and $r.muxed_id) {
        $key = $r.base_account + "|" + $r.muxed_id
        $script:muxResolver[$key] = $r.muxed_address
      }
      if ($r.muxed_address -and $r.exchange) {
        $script:mxExchangeMap[$r.muxed_address] = $r.exchange
      }
    }
    $count = ($rows | Measure-Object).Count
    Write-Host ("Loaded enrichment from " + $MuxMapPath + " (" + $count + " rows).")
  } catch {
    Write-Warning ("Failed to load " + $MuxMapPath + ": " + $_.Exception.Message)
  }
} else {
  try {
    "base_account,muxed_id,muxed_address,exchange" | Out-File -Encoding utf8 $MuxMapPath
    Write-Host ("Created empty seed file: " + $MuxMapPath + " (optional).")
  } catch {
    Write-Warning ("Could not create seed file " + $MuxMapPath + ": " + $_.Exception.Message)
  }
}

function Get-ExchangeLabel {
  param([string]$BaseTo, [string]$ToMuxed)
  if ($script:mxExchangeMap -and $ToMuxed -and $script:mxExchangeMap.ContainsKey($ToMuxed)) {
    return $script:mxExchangeMap[$ToMuxed]
  }
  if ($BaseTo) {
    foreach($k in $KnownBaseToExchange.Keys){
      if ($BaseTo.StartsWith($k)) { return $KnownBaseToExchange[$k] }
    }
  }
  return 'Unknown'
}

# HTTP helper
function Get-Json { param([string]$Url)
  try { Invoke-RestMethod -Uri $Url -TimeoutSec $TIMEOUT -Method Get -ErrorAction Stop }
  catch { Write-Warning ("HTTP error " + $Url + ": " + $_.Exception.Message); $null }
}

# Memo cache
$memoCache = @{}
function Get-TxMemo { param([string]$TxHash)
  if ($memoCache.ContainsKey($TxHash)) { return $memoCache[$TxHash] }
  $t = Get-Json ($HORIZON + "/transactions/" + $TxHash)
  if ($t) { $memoCache[$TxHash] = @{ memo_type=$t.memo_type; memo=$t.memo } }
  else     { $memoCache[$TxHash] = @{ memo_type=$null; memo=$null } }
  return $memoCache[$TxHash]
}

# Output header
"source_account,timestamp,tx_hash,from,to,to_muxed,amount,asset_code,exchange" | Out-File -Encoding utf8 $OutCsv

# Scan
$pages = 0; $seen = 0; $hits = 0
$url = $HORIZON + "/accounts/" + $Account + "/payments?limit=200&order=desc&include_failed=false"

Write-Host ""
Write-Host ("Scanning account: " + $Account)
Write-Host ("Lookback: " + ([Math]::Round([Math]::Abs($SinceDays),2)) + " days (from " + $SINCE_TS.ToString("u") + ")")
Write-Host ("Writing report to: " + $OutCsv)
Write-Host ""

while ($url -and $pages -lt $MaxPages) {
  Write-Progress -Activity "Scanning payments…" -Status ("Page " + $pages) -PercentComplete ([int]([double]$pages / [double][Math]::Max(1,$MaxPages) * 100.0))
  $resp = Get-Json $url
  if (-not $resp) { break }
  $records = $resp._embedded.records
  if (-not $records -or $records.Count -eq 0) { break }

  foreach($op in $records){
    if ($op.type -ne "payment") { continue }
    if ($op.from -ne $Account) { continue }
    $seen++

    $created = Get-Date $op.created_at
    if ($created -lt $SINCE_TS) { continue }

    $mux = $op.to_muxed
    if (-not $mux) {
      $m = Get-TxMemo $op.transaction_hash
      if ($m.memo_type -eq "id" -and $op.to) {
        $k = $op.to + "|" + $m.memo
        if ($script:muxResolver.ContainsKey($k)) { $mux = $script:muxResolver[$k] }
      }
    }
    if (-not $mux) { continue }

    $code = ""
    if ($op.asset_type -eq "native") { $code = "PI" }
    elseif ($op.asset_code) { $code = $op.asset_code }

    $ex = Get-ExchangeLabel -BaseTo $op.to -ToMuxed $mux

    $line = $Account + "," + $op.created_at + "," + $op.transaction_hash + "," +
            $op.from + "," + $op.to + "," + $mux + "," + $op.amount + "," + $code + "," + $ex
    Add-Content -Encoding utf8 -LiteralPath $OutCsv -Value $line
    $hits++
  }

  $pages++
  $url = $resp._links.next.href
}

Write-Progress -Activity "Scanning payments…" -Completed -Status "Done"
Write-Host ""
Write-Host "bulbys_mux_scan complete."
Write-Host ("Account: " + $Account)
Write-Host $created_info
Write-Host ("Pages scanned: " + $pages + "  payments seen: " + $seen + "  muxed hits: " + $hits)
Write-Host ("Report: " + $OutCsv)

# Tiny preview table
try {
  Import-Csv $OutCsv |
    Select-Object -First 8 timestamp,to,to_muxed,amount,asset_code,exchange |
    Format-Table -Auto
} catch { }

Write-Host ""
[void](Read-Host "Press Enter to exit")
# ================== /end embedded PS ==================