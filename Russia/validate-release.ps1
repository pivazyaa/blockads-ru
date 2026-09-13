$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$rules = @([IO.File]::ReadAllLines(($root+'\blockAds-RU.module')) | Where-Object {$_ -match '^DOMAIN'})
$failures = New-Object 'System.Collections.Generic.List[string]'
$checks = 0
function Check([bool]$ok, [string]$name) { $script:checks++; if (!$ok) { $script:failures.Add($name) } }
function Blocked([string]$hostName) {
  foreach ($rule in $script:rules) {
    $p=$rule.Split(',')
    if ($hostName -eq $p[1] -or ($p[0] -eq 'DOMAIN-SUFFIX' -and $hostName.EndsWith('.'+$p[1]))) { return $true }
  }
  return $false
}
$keep = @(
  'www.tbank.ru','idmsa.apple.com','buy.itunes.apple.com','setup.icloud.com','gateway.push.apple.com',
  'api-adservices.apple.com','proxy.safebrowsing.apple','safebrowsing.googleapis.com',
  'ocsp.apple.com','gdmf.apple.com','mesu.apple.com','configuration.apple.com',
  'telemost.yandex.ru','passport.yandex.ru','smartcaptcha.yandexcloud.net',
  'api.widgetable.net','api.widgetable.co','api.revenuecat.com','api.vk.com','telegram.org',
  'youtubei.googleapis.com','rr1---sn-test.googlevideo.com','api16-normal-c-useast1a.tiktokv.com',
  'gql.reddit.com','x.com','oauth.reddit.com','gosuslugi.ru','api.sberbank.ru','ads.example.org'
)
$deny = @('banners.mobile.yandex.net','b13.penzainform.ru','iads.unity3d.com','applovin.com','iadsdk.apple.com','alt-ad.mail.ru')
foreach ($hostName in $keep) { Check (!(Blocked $hostName)) ('unblocked '+$hostName) }
foreach ($hostName in $deny) { Check (Blocked $hostName) ('blocked '+$hostName) }
Check (($rules | Sort-Object -Unique).Count -eq $rules.Count) 'unique domain rules'
Check ($rules.Count -lt 3000) 'bounded rule count'
foreach ($rule in $rules) { if ($rule -notmatch '^DOMAIN(?:-SUFFIX)?,[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?,REJECT$') { $failures.Add('invalid domain rule'); break } }
$patternCases = @{
  'Reddit-RU.module'='https://gql.reddit.com/'
  'X-RU.module'='https://x.com/i/api/graphql/test/HomeTimeline?variables=test'
  'TikTok-Web-RU.module'='https://www.tiktok.com/api/recommend/item_list/?count=20'
  'YouTube-RU.module'='https://youtubei.googleapis.com/youtubei/v1/player?alt=proto'
}
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.module') {
  $text = [IO.File]::ReadAllText($file.FullName)
  Check (!($text -match '\[(General|Host|Proxy|Proxy Group)\]')) ($file.Name+' preserves routing and DNS')
  Check (!($text -match '(skip-cert-verify|ca-p12|ca-passphrase|hostname\s*=\s*%APPEND%\s*\*)')) ($file.Name+' no CA or broad MITM')
  Check (!($text -match '(?m)^(DOMAIN-KEYWORD|IP-CIDR)|,(DIRECT|PROXY)(?:,|\r?$)')) ($file.Name+' only ad decisions')
  foreach ($line in $text -split '\r?\n') {
    if ($line -match 'script-path=(\S+)') {
      $url = $Matches[1]
      Check ($url -match '^https://raw\.githubusercontent\.com/pivazyaa/blockads-ru/[a-f0-9]{40}/Russia/(social-json|youtube-player)\.js$') ($file.Name+' pinned script URL')
      Check (Test-Path -LiteralPath (Join-Path $root ([IO.Path]::GetFileName($url)))) ($file.Name+' script exists')
    }
    if ($line -match 'pattern=(.*?), requires-body=') {
      $pattern=$Matches[1]; $regex=New-Object Text.RegularExpressions.Regex($pattern)
      Check (!$regex.IsMatch('https://idmsa.apple.com/')) ($file.Name+' excludes Apple login')
      Check (!$regex.IsMatch('https://www.tbank.ru/')) ($file.Name+' excludes banking')
      if ($file.Name -ne 'YouTube-RU.module' -or $line -match 'RU-YouTube-Player') {
        Check $regex.IsMatch($patternCases[$file.Name]) ($file.Name+' endpoint matches')
      }
    }
  }
}
$report = [ordered]@{checks=$checks;failures=@($failures);domain_rules=$rules.Count;iphone_runtime_tested=$false}
$json=$report | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText(($root+'\release-checks.json'),$json,(New-Object Text.UTF8Encoding($false)))
$json
if ($failures.Count) { exit 1 }
