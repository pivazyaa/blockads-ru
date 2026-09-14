$ErrorActionPreference = 'Stop'
$work = $PSScriptRoot
$out = Join-Path $work 'publish'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$mitmDefinition = [IO.File]::ReadAllText(($work+'\mitm-config.json')) | ConvertFrom-Json
if ($mitmDefinition.version -ne 1 -or $mitmDefinition.script_ref -notmatch '^[a-f0-9]{40}$') { throw 'Invalid MITM definition or script reference' }
if ($mitmDefinition.release -notmatch '^\d{4}\.\d{2}\.\d{2}\.\d+$') { throw 'Invalid release identifier' }
$fmz = [pscustomobject]@{ref='3ca7487b4e4b86d9af76e50df72c62eacfbb659e'}
$ag = [pscustomobject]@{ref='ebd6f4bc46f816cf75a41c9764dd35bed4a65b00'}
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
Get-PinnedSource ($work+'\upstream\Shadowrocket\module\blockAds.srmodule') ('https://raw.githubusercontent.com/fmz200/wool_scripts/'+$fmz.ref+'/Shadowrocket/module/blockAds.srmodule')
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
      $candidates['DOMAIN-SUFFIX,'+$hostName] = 'AdGuard/'+$source
    }
  }
}
$reviewedFmz = @(
  'adcolony.com','adroll.com','chartboost.com','criteo.com','criteo.net',
  'inmobi.com','inmobi.net','inmobicdn.net','mopub.com','openx.net',
  'pubmatic.com','rubiconproject.com','smartadserver.com','applvn.com',
  'applovin.com','ads-twitter.com','st.yandexadexchange.net','ads.yandex.com',
  'doubleclick.net','googleadservices.com','googlesyndication.com',
  'iadsdk.apple.com','iad.apple.com'
)
foreach ($line in [IO.File]::ReadAllLines(($work+'\upstream\Shadowrocket\module\blockAds.srmodule'))) {
  if ($line -match '^(DOMAIN(?:-SUFFIX)?),([^,]+),REJECT$' -and $reviewedFmz -contains $Matches[2]) {
    $candidates[$Matches[1]+','+$Matches[2]] = 'fmz200/Shadowrocket/module/blockAds.srmodule'
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
  foreach ($compatibleRoot in $mitmDefinition.passthrough_roots) {
    if ((Test-Under $hostName $compatibleRoot) -or ($parts[0] -eq 'DOMAIN-SUFFIX' -and (Test-Under $compatibleRoot $hostName))) { $reason = 'X-iPhone-compatibility'; break }
  }
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
$scriptLines = New-Object 'System.Collections.Generic.List[string]'
$scriptNames = New-Object 'System.Collections.Generic.HashSet[string]'
$mitmHosts = New-Object 'System.Collections.Generic.HashSet[string]'
$legacyLines = @{}
$legacyHosts = @{}
foreach ($entry in $mitmDefinition.scripts) {
  if ($entry.id -notmatch '^RU-[A-Za-z0-9-]+$' -or !$scriptNames.Add($entry.id)) { throw 'Invalid or duplicate script name' }
  if ($entry.file -notin @('social-json.js','youtube-player.js') -or $entry.module -notin @('Reddit-RU.module','TikTok-Web-RU.module','YouTube-RU.module')) { throw 'Unexpected script or module path' }
  if ($entry.pattern.Contains(',') -or $entry.pattern.Contains("`n")) { throw 'Unsafe script pattern delimiter' }
  if ($entry.max_size -notin @(1048576,2097152)) { throw 'Unexpected body limit' }
  $binary = if ($entry.binary) { ', binary-body-mode=true' } else { '' }
  $line = $entry.id+' = type=http-response, pattern='+$entry.pattern+', requires-body=true'+$binary+', max-size='+$entry.max_size+', timeout=5, engine=jsc, script-path=https://raw.githubusercontent.com/pivazyaa/blockads-ru/'+$mitmDefinition.script_ref+'/Russia/'+$entry.file
  $scriptLines.Add($line)
  if (!$legacyLines.ContainsKey($entry.module)) {
    $legacyLines[$entry.module] = New-Object 'System.Collections.Generic.List[string]'
    $legacyHosts[$entry.module] = New-Object 'System.Collections.Generic.HashSet[string]'
  }
  $legacyLines[$entry.module].Add($line)
  foreach ($hostName in $entry.hosts) {
    if ($hostName -notmatch '^[a-z0-9.-]+$') { throw 'Unexpected MITM hostname' }
    foreach ($compatibleRoot in $mitmDefinition.passthrough_roots) {
      if (Test-Under $hostName $compatibleRoot) { throw 'X compatibility host must not be decrypted' }
    }
    [void]$mitmHosts.Add($hostName)
    [void]$legacyHosts[$entry.module].Add($hostName)
  }
}
if ($scriptLines.Count -ne 4 -or $mitmHosts.Count -ne 11) { throw 'Incomplete combined MITM configuration' }
$header = @'
#!name=BlockAds RU
#!desc=__RELEASE__: точнее обработка Reddit, ограничен расход памяти YouTube, учтены исключения AdGuard. MITM встроен; X работает без перехвата. Для HTTPS нужен собственный доверенный сертификат.
#!author=fmz200, AdGuard contributors; adaptation for pivazyaa
#!homepage=https://github.com/pivazyaa/blockads-ru/tree/main/Russia
#!date=__DATE__
# SPDX-License-Identifier: GPL-3.0-only
# Избирательный форк fmz200 с правилами AdGuard. См. README.md и sources.lock.json.
# Не импортируйте исходный blockAds одновременно с этой версией.
# Все поддерживаемые обработчики включены ниже. Отдельные модули не добавлять.
# X/Twitter, t.co и twimg не расшифровываются и не блокируются этой версией.
# Скрипты загружаются автоматически по закреплённым ссылкам. CA создаётся на самом iPhone.

[Rule]
'@
$header = $header.Replace('__RELEASE__', $mitmDefinition.release).Replace('__DATE__', $mitmDefinition.release.Substring(0,10).Replace('.','-'))
$combined = $header+"`n"+($rules -join "`n")+"`n`n[Script]`n"+($scriptLines -join "`n")+"`n`n[MITM]`n"
$combined += 'hostname = %APPEND% '+(@($mitmHosts | Sort-Object) -join ', ')+"`n"
[IO.File]::WriteAllText(($out+'\blockAds-RU.module'), $combined, $utf8)
foreach ($name in $legacyLines.Keys) {
  $legacy = '#!name=BlockAds RU - '+$name.Replace('-RU.module','').Replace('.module','')+"`n"
  $legacy += '#!desc=Совместимая отдельная версия. При использовании единого BlockAds RU отключите этот модуль.'+"`n"
  $legacy += '#!homepage=https://github.com/pivazyaa/blockads-ru/tree/main/Russia'+"`n# SPDX-License-Identifier: GPL-3.0-only`n[Script]`n"
  $legacy += ($legacyLines[$name] -join "`n")+"`n[MITM]`n"+'hostname = %APPEND% '+(@($legacyHosts[$name] | Sort-Object) -join ', ')+"`n"
  [IO.File]::WriteAllText((Join-Path $out $name), $legacy, $utf8)
}
$xCompatibility = @'
#!name=BlockAds RU - X
#!desc=Перехват X отключён после сбоя загрузки постов на iPhone. Этот старый модуль можно удалить; основной BlockAds RU содержит остальные обработчики.
#!homepage=https://github.com/pivazyaa/blockads-ru/tree/main/Russia
# SPDX-License-Identifier: GPL-3.0-only
# Compatibility placeholder: no X scripts, MITM hosts or domain rejections.
[Rule]
'@
[IO.File]::WriteAllText(($out+'\X-RU.module'), $xCompatibility+"`n", $utf8)
$lock = [ordered]@{
  generated_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); fmz200_ref = $fmz.ref; adguard_ref = $ag.ref
  rule_count = $rules.Count; bytes = (Get-Item ($out+'\blockAds-RU.module')).Length
  source_files = $sources; exception_files = $exceptions; fmz_reviewed_domains = $reviewedFmz
  excluded_rules = $excluded; runtime_remote_rule_lists = @()
  wildcard_exception_hosts = @($wildcardExceptionHosts | Sort-Object)
  mitm_definition_file = 'mitm-config.json'; script_ref = $mitmDefinition.script_ref; release = $mitmDefinition.release
  compatibility_passthrough_roots = $mitmDefinition.passthrough_roots
  script_entries = $scriptLines.Count; mitm_hostnames = @($mitmHosts | Sort-Object)
}
$hashes = @{}
foreach ($source in ($sources+$exceptions)) {
  $hashes['AdGuard/'+$source] = (Get-FileHash -LiteralPath (Join-Path ($work+'\sources\adguard') $source) -Algorithm SHA256).Hash.ToLowerInvariant()
}
$hashes['fmz200/Shadowrocket/module/blockAds.srmodule'] = (Get-FileHash -LiteralPath ($work+'\upstream\Shadowrocket\module\blockAds.srmodule') -Algorithm SHA256).Hash.ToLowerInvariant()
$hashes['BlockAds/mitm-config.json'] = (Get-FileHash -LiteralPath ($work+'\mitm-config.json') -Algorithm SHA256).Hash.ToLowerInvariant()
$lock['source_sha256'] = $hashes
[IO.File]::WriteAllText(($out+'\sources.lock.json'), ($lock | ConvertTo-Json -Depth 6)+"`n", $utf8)
Copy-Item -LiteralPath ($work+'\upstream\LICENSE') -Destination ($out+'\LICENSE') -Force
Copy-Item -LiteralPath ($work+'\mitm-config.json') -Destination ($out+'\mitm-config.json') -Force
Copy-Item -LiteralPath ($work+'\build-rules.ps1') -Destination ($out+'\build-rules.ps1') -Force
[ordered]@{rules=$rules.Count;bytes=$lock.bytes;excluded=$excluded.Count;sha256=(Get-FileHash ($out+'\blockAds-RU.module') -Algorithm SHA256).Hash} | ConvertTo-Json -Compress
