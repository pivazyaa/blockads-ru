$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$modulePath = Join-Path $root 'blockAds-RU.module'
$configPath = Join-Path $root 'blockads-config.json'
$failures = New-Object 'System.Collections.Generic.List[string]'
$checks = 0
function Check([bool]$ok, [string]$name) {
  $script:checks++
  if (!$ok) { $script:failures.Add($name) }
}
function Blocked([string]$hostName) {
  foreach ($rule in $script:rules) {
    $p = $rule.Split(',')
    if ($hostName -eq $p[1] -or ($p[0] -eq 'DOMAIN-SUFFIX' -and $hostName.EndsWith('.'+$p[1], [StringComparison]::OrdinalIgnoreCase))) { return $true }
  }
  return $false
}
Check (Test-Path -LiteralPath $modulePath) 'main module exists'
Check (Test-Path -LiteralPath $configPath) 'domain-only config exists'
if ((Test-Path -LiteralPath $modulePath) -and (Test-Path -LiteralPath $configPath)) {
  $module = [IO.File]::ReadAllText($modulePath)
  $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
  $rules = @($module -split '\r?\n' | Where-Object { $_ -match '^DOMAIN(?:-SUFFIX)?,[^,]+,REJECT$' })
  Check ($config.version -eq 1 -and $config.module_type -eq 'domain-only' -and $config.mitm_enabled -eq $false) 'config explicitly disables MITM'
  Check ($module.Contains('#!desc='+$config.release+':')) 'module displays configured release'
  Check (([regex]::Matches($module, '(?m)^\[Rule\]\r?$')).Count -eq 1) 'single Rule section'
  Check (([regex]::Matches($module, '(?m)^\[(?:Script|MITM)\]\r?$')).Count -eq 0) 'no Script or MITM sections'
  Check (!($module -match '(?im)\b(?:script-path|requires-body|binary-body-mode|engine\s*=|type\s*=\s*http-response|hostname\s*=)')) 'no response interception directives'
  Check (($rules | Sort-Object -Unique).Count -eq $rules.Count) 'unique domain rules'
  Check ($rules.Count -gt 1000 -and $rules.Count -lt 3000) 'bounded domain rule count'
  foreach ($rule in $rules) { Check ($rule -match '^DOMAIN-SUFFIX,[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?,REJECT$' -and $rule.Split(',')[1] -match '[a-z]') ('valid rule '+$rule) }
  Check (!($module -match '(?m)^(?:DOMAIN-KEYWORD|DOMAIN-WILDCARD|IP-CIDR|IP-CIDR6|GEOIP|RULE-SET|URL-REGEX|PROCESS-NAME|AND|OR|NOT),')) 'no broad routing or IP rules'
  Check (!($module -match '(?im)\b(?:DIRECT|PROXY|REJECT-DROP|REJECT-TINYGIF)\b' -and $module -notmatch '(?m)^DOMAIN-SUFFIX,[^,]+,REJECT$')) 'only domain REJECT decisions'
  $keep = @(
    'www.tbank.ru','idmsa.apple.com','buy.itunes.apple.com','setup.icloud.com','gateway.push.apple.com',
    'api-adservices.apple.com','proxy.safebrowsing.apple','safebrowsing.googleapis.com',
    'ocsp.apple.com','gdmf.apple.com','mesu.apple.com','configuration.apple.com',
    'telemost.yandex.ru','passport.yandex.ru','smartcaptcha.yandexcloud.net',
    'api.widgetable.net','api.widgetable.co','api.revenuecat.com','api.vk.com','telegram.org',
    'youtubei.googleapis.com','rr1---sn-test.googlevideo.com','api16-normal-c-useast1a.tiktokv.com',
    'gql.reddit.com','x.com','oauth.reddit.com','gosuslugi.ru','api.sberbank.ru'
  )
  $deny = @('banners.mobile.yandex.net','b13.penzainform.ru','iads.unity3d.com','applovin.com','doubletag.run')
  foreach ($hostName in $keep) { Check (!(Blocked $hostName)) ('unblocked '+$hostName) }
  foreach ($hostName in $deny) { Check (Blocked $hostName) ('blocked '+$hostName) }
  Check ((Get-ChildItem -LiteralPath $root -Filter '*.js' -File -ErrorAction SilentlyContinue).Count -eq 0) 'no JavaScript files published'
  Check (!(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '^(?:mitm-config|social-json|youtube-player|test-blockads|TikTok-Web|Reddit-RU|YouTube-RU|X-RU)' })) 'no obsolete MITM artifacts published'
}
$report = [ordered]@{
  checks = $checks
  failures = @($failures)
  domain_rules = @($rules).Count
  module_type = 'domain-only'
  mitm_enabled = $false
  scripts = 0
}
$json = $report | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $root 'release-checks.json'), $json, (New-Object Text.UTF8Encoding($false)))
$json
if ($failures.Count) { exit 1 }
