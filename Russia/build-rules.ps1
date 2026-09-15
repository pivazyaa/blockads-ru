$ErrorActionPreference = 'Stop'
$work = $PSScriptRoot
$out = Join-Path $work 'publish'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$definition = [IO.File]::ReadAllText(($work+'\blockads-config.json')) | ConvertFrom-Json
if ($definition.version -ne 1 -or $definition.module_type -ne 'domain-only' -or $definition.mitm_enabled -ne $false) { throw 'Invalid domain-only definition' }
if ($definition.release -notmatch '^\d{4}\.\d{2}\.\d{2}\.\d+$' -or $definition.adguard_ref -notmatch '^[a-f0-9]{40}$') { throw 'Invalid release or source reference' }
$fmz = [pscustomobject]@{ref='3ca7487b4e4b86d9af76e50df72c62eacfbb659e'}
$ag = [pscustomobject]@{ref=$definition.adguard_ref}
$sources = @(
  'BaseFilter/sections/adservers.txt',
  'BaseFilter/sections/adservers_firstparty.txt',
  'MobileFilter/sections/adservers.txt',
  'CyrillicFilters/common-sections/adservers.txt',
  'CyrillicFilters/common-sections/adservers_firstparty.txt',
  'CyrillicFilters/RussianFilter/sections/adservers_firstparty.txt'
)
$exceptions = @(
  'BaseFilter/sections/allowlist.txt',
  'MobileFilter/sections/allowlist_app.txt',
  'MobileFilter/sections/allowlist_web.txt',
  'CyrillicFilters/common-sections/allowlist.txt',
  'CyrillicFilters/RussianFilter/sections/allowlist.txt'
)
function Get-PinnedSource([string]$file, [string]$url) {
  if (!(Test-Path -LiteralPath $file)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file
  }
}
foreach ($source in ($sources+$exceptions)) {
  Get-PinnedSource (Join-Path ($work+'\sources\adguard') $source) ('https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/'+$ag.ref+'/'+$source)
}
Get-PinnedSource ($work+'\upstream\LICENSE') ('https://raw.githubusercontent.com/fmz200/wool_scripts/'+$fmz.ref+'/LICENSE')
$candidates = @{}
$excluded = @{}
$exceptionHosts = New-Object 'System.Collections.Generic.HashSet[string]'
$exceptionAncestors = New-Object 'System.Collections.Generic.HashSet[string]'
$wildcardExceptionHosts = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($source in $exceptions) {
  foreach ($line in [IO.File]::ReadAllLines((Join-Path ($work+'\sources\adguard') $source))) {
    if ($line -match '^@@\|\|([a-z0-9.*-]*\*[a-z0-9.*-]*)\^') {
      [void]$wildcardExceptionHosts.Add($Matches[1])
    } elseif ($line -match '^@@\|\|([a-z0-9.-]+)(\^|/)') {
      $exceptionHost = $Matches[1]
      # A path exception on a parent site does not establish a subdomain-wide dependency.
      if ($Matches[2] -eq '^') { [void]$exceptionHosts.Add($exceptionHost) }
      $labels = $exceptionHost.Split('.')
      for ($i=0; $i -lt $labels.Length-1; $i++) { [void]$exceptionAncestors.Add(($labels[$i..($labels.Length-1)] -join '.')) }
    }
  }
}
foreach ($source in $sources) {
  foreach ($line in [IO.File]::ReadAllLines((Join-Path ($work+'\sources\adguard') $source))) {
    # Preserve semantics: conditional, wildcard, URL, third-party and application rules are not globalized.
    if ($line -match '^\|\|([a-z0-9](?:[a-z0-9.-]*[a-z0-9])?)\^$') {
      $hostName = $Matches[1]
      # Keep DNS names only. Numeric literals are not useful DOMAIN-SUFFIX rules.
      if ($hostName -notmatch '[a-z]') { continue }
      $candidates['DOMAIN-SUFFIX,'+$hostName] = 'AdGuard/'+$source
    }
  }
}
# Mixed service bootstraps, security services and identity/payment endpoints stay outside the blocker.
$protected = @(
  'apple.com','icloud.com','icloud.com.cn','mzstatic.com','cdn-apple.com','safebrowsing.apple',
  'safebrowsing.googleapis.com','safebrowsing.g.applimg.com','gstatic.com','googleapis.com',
  'firebaseio.com','firebaseapp.com','app-measurement.com','revenuecat.com','appsflyer.com',
  'tbank.ru','tinkoff.ru','sberbank.ru','sber.ru','alfabank.ru','vtb.ru','gosuslugi.ru',
  't.me','telegram.org','telegram.me','widgetable.net','widgetable.co',
  'yandex.ru','ya.ru','yandex.net','yandex.com','vk.com','mail.ru','ok.ru',
  'youtube.com','googlevideo.com','tiktok.com','tiktokv.com','tiktokcdn.com',
  'reddit.com','redd.it','x.com','twitter.com','twimg.com'
)
$critical = @(
  'startup.mobile.yandex.net','startup-mobile.ap.yandex-net.ru',
  'redirect.appmetrica.yandex.com','app.adjust.com','click.googleadservices.com',
  'buy.itunes.apple.com','api.storekit.itunes.apple.com','api-adservices.apple.com',
  'idmsa.apple.com','setup.icloud.com','gateway.icloud.com','ocsp.apple.com',
  'gdmf.apple.com','mesu.apple.com','configuration.apple.com','api.push.apple.com',
  'api.widgetable.net','api.widgetable.co','telemost.yandex.ru','telemost.yandex.com',
  'passport.yandex.ru','smartcaptcha.yandexcloud.net','captcha-api.yandex.ru'
)
function Test-Under([string]$child, [string]$parent) {
  return $child -eq $parent -or $child.EndsWith('.'+$parent, [StringComparison]::OrdinalIgnoreCase)
}
function Test-WildcardException([string]$hostName, [bool]$isSuffix, [string]$exceptionHost) {
  $pattern = '(?:^|\.)'+[regex]::Escape($exceptionHost).Replace('\*','.*')+'$'
  if ($hostName -match $pattern) { return $true }
  if (!$isSuffix) { return $false }
  # A suffix block also covers possible descendants matched by the exception.
  # The literal tail keeps i*-tb.isnssdk.com from exempting dm.isnssdk.com.
  $tail = $exceptionHost.Substring($exceptionHost.LastIndexOf('*')+1)
  # Unanchored patterns such as optout*.* do not identify a parent service.
  # Apply those to concrete hosts only, rather than exempting every domain.
  if ($tail.TrimStart('.').Split('.').Length -lt 2) { return $false }
  return $hostName.EndsWith($tail, [StringComparison]::OrdinalIgnoreCase) -or $tail.EndsWith('.'+$hostName, [StringComparison]::OrdinalIgnoreCase)
}
foreach ($key in @($candidates.Keys)) {
  $parts = $key.Split(','); $hostName = $parts[1]; $reason = $null
  if ($protected -contains $hostName -or $hostName -match '(safebrowsing|(^|\.)ocsp\.|(^|\.)crl\.)') { $reason = 'shared-or-security-service' }
  foreach ($hostToKeep in $critical) {
    if ($hostToKeep -eq $hostName -or ($parts[0] -eq 'DOMAIN-SUFFIX' -and (Test-Under $hostToKeep $hostName))) { $reason = 'critical-service'; break }
  }
  # A context exception cannot be represented safely by a global domain REJECT.
  if ($exceptionAncestors.Contains($hostName)) { $reason = 'upstream-context-exception' }
  $labels = $hostName.Split('.')
  for ($i=0; $i -lt $labels.Length-1; $i++) {
    if ($exceptionHosts.Contains(($labels[$i..($labels.Length-1)] -join '.'))) { $reason = 'upstream-context-exception'; break }
  }
  foreach ($exceptionHost in $wildcardExceptionHosts) {
    if (Test-WildcardException $hostName ($parts[0] -eq 'DOMAIN-SUFFIX') $exceptionHost) { $reason = 'upstream-wildcard-context-exception'; break }
  }
  if ($reason) { $excluded[$key] = $reason; $candidates.Remove($key) }
}
$suffixes = New-Object 'System.Collections.Generic.HashSet[string]'
$kept = New-Object 'System.Collections.Generic.List[string]'
foreach ($key in @($candidates.Keys | Sort-Object {$_.Split(',')[1].Length}, {$_})) {
  $p = $key.Split(','); $hostName = $p[1]; $covered = $false
  $labels = $hostName.Split('.')
  for ($i=0; $i -lt $labels.Length-1; $i++) {
    $suffix = ($labels[$i..($labels.Length-1)] -join '.')
    if ($suffixes.Contains($suffix)) { $covered = $true; break }
  }
  if (!$covered) { $kept.Add($key+',REJECT'); if ($p[0] -eq 'DOMAIN-SUFFIX') { [void]$suffixes.Add($hostName) } }
}
$rules = @($kept | Sort-Object)
$header = @'
#!name=BlockAds RU
#!desc=__RELEASE__: быстрый доменный блокировщик рекламы для Shadowrocket. Без MITM, JavaScript и расшифровки HTTPS.
#!author=fmz200, AdGuard contributors; adaptation for pivazyaa
#!homepage=https://github.com/pivazyaa/blockads-ru/tree/main/Russia
#!date=__DATE__
# SPDX-License-Identifier: GPL-3.0-only
# Избирательный форк fmz200 с правилами AdGuard. См. README.md и sources.lock.json.
# Только доменные решения REJECT; маршрутизация и DNS остаются в основном конфиге.
# Сертификат, HTTPS Decryption, Script и MITM для этого модуля не нужны.

[Rule]
'@
$header = $header.Replace('__RELEASE__', $definition.release).Replace('__DATE__', $definition.release.Substring(0,10).Replace('.','-'))
$combined = $header+"`n"+($rules -join "`n")+"`n"
[IO.File]::WriteAllText(($out+'\blockAds-RU.module'), $combined, $utf8)
$obsolete = @('Reddit-RU.module','TikTok-Web-RU.module','YouTube-RU.module','X-RU.module','social-json.js','youtube-player.js','test-blockads.js','test-results.json','tiktok-evidence.json','mitm-config.json')
foreach ($name in $obsolete) {
  $old = Join-Path $out $name
  if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
}
$lock = [ordered]@{
  generated_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); fmz200_ref = $fmz.ref; adguard_ref = $ag.ref
  rule_count = $rules.Count; bytes = (Get-Item ($out+'\blockAds-RU.module')).Length
  source_files = $sources; exception_files = $exceptions
  excluded_rules = $excluded; runtime_remote_rule_lists = @()
  wildcard_exception_hosts = @($wildcardExceptionHosts | Sort-Object)
  config_file = 'blockads-config.json'; release = $definition.release; module_type = 'domain-only'; mitm_enabled = $false
  script_entries = 0; mitm_hostnames = @()
}
$hashes = @{}
foreach ($source in ($sources+$exceptions)) {
  $hashes['AdGuard/'+$source] = (Get-FileHash -LiteralPath (Join-Path ($work+'\sources\adguard') $source) -Algorithm SHA256).Hash.ToLowerInvariant()
}
$hashes['BlockAds/blockads-config.json'] = (Get-FileHash -LiteralPath ($work+'\blockads-config.json') -Algorithm SHA256).Hash.ToLowerInvariant()
$lock['source_sha256'] = $hashes
[IO.File]::WriteAllText(($out+'\sources.lock.json'), ($lock | ConvertTo-Json -Depth 6)+"`n", $utf8)
Copy-Item -LiteralPath ($work+'\upstream\LICENSE') -Destination ($out+'\LICENSE') -Force
Copy-Item -LiteralPath ($work+'\blockads-config.json') -Destination ($out+'\blockads-config.json') -Force
Copy-Item -LiteralPath ($work+'\build-rules.ps1') -Destination ($out+'\build-rules.ps1') -Force
[ordered]@{rules=$rules.Count;bytes=$lock.bytes;excluded=$excluded.Count;mitm_enabled=$false;sha256=(Get-FileHash ($out+'\blockAds-RU.module') -Algorithm SHA256).Hash} | ConvertTo-Json -Compress
