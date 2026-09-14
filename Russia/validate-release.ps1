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
  'gql.reddit.com','x.com','oauth.reddit.com','gosuslugi.ru','api.sberbank.ru','ads.example.org',
  'api.x.com','twitter.com','api.twitter.com','abs.twimg.com','pbs.twimg.com','video.twimg.com','t.co',
  'syndication.twitter.com','urls.api.twitter.com','ads-bidder-api.twitter.com','ads-twitter.com'
)
$deny = @('banners.mobile.yandex.net','b13.penzainform.ru','iads.unity3d.com','applovin.com','iadsdk.apple.com','alt-ad.mail.ru')
foreach ($hostName in $keep) { Check (!(Blocked $hostName)) ('unblocked '+$hostName) }
foreach ($hostName in $deny) { Check (Blocked $hostName) ('blocked '+$hostName) }
Check (($rules | Sort-Object -Unique).Count -eq $rules.Count) 'unique domain rules'
Check ($rules.Count -lt 3000) 'bounded rule count'
foreach ($rule in $rules) { if ($rule -notmatch '^DOMAIN(?:-SUFFIX)?,[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?,REJECT$') { $failures.Add('invalid domain rule'); break } }
$patternCases = @{
  'RU-Reddit'='https://gql.reddit.com/'
  'RU-TikTok-Web'='https://www.tiktok.com/api/recommend/item_list/?count=20'
  'RU-YouTube-Player'='https://youtubei.googleapis.com/youtubei/v1/player?alt=proto'
  'RU-YouTube-Web'='https://www.youtube.com/youtubei/v1/browse'
}
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.module') {
  $text = [IO.File]::ReadAllText($file.FullName)
  Check (!($text -match '\[(General|Host|Proxy|Proxy Group)\]')) ($file.Name+' preserves routing and DNS')
  Check (!($text -match '(skip-cert-verify|ca-p12|ca-passphrase|hostname\s*=\s*%APPEND%\s*\*)')) ($file.Name+' no CA or broad MITM')
  Check (!($text -match '(?m)^(DOMAIN-KEYWORD|IP-CIDR)|,(DIRECT|PROXY)(?:,|\r?$)')) ($file.Name+' only ad decisions')
  foreach ($line in $text -split '\r?\n') {
    $scriptId = if ($line -match '^([A-Za-z0-9_-]+)\s*=\s*type=http-response') { $Matches[1] } else { '' }
    if ($line -match 'script-path=(\S+)') {
      $url = $Matches[1]
      Check ($url -match '^https://raw\.githubusercontent\.com/pivazyaa/blockads-ru/[a-f0-9]{40}/Russia/(social-json|youtube-player)\.js$') ($file.Name+' pinned script URL')
      Check (Test-Path -LiteralPath (Join-Path $root ([IO.Path]::GetFileName($url)))) ($file.Name+' script exists')
    }
    if ($line -match 'pattern=(.*?), requires-body=') {
      $pattern=$Matches[1]; $regex=New-Object Text.RegularExpressions.Regex($pattern)
      Check (!$regex.IsMatch('https://idmsa.apple.com/')) ($file.Name+' excludes Apple login')
      Check (!$regex.IsMatch('https://www.tbank.ru/')) ($file.Name+' excludes banking')
      Check (!$regex.IsMatch('https://api.x.com/graphql/test/HomeTimeline')) ($file.Name+' excludes native X API')
      Check (!$regex.IsMatch('https://x.com/i/api/graphql/test/TweetDetail')) ($file.Name+' excludes X post responses')
      Check ($patternCases.ContainsKey($scriptId) -and $regex.IsMatch($patternCases[$scriptId])) ($file.Name+' '+$scriptId+' endpoint matches')
    }
  }
}
$combined = [IO.File]::ReadAllText(($root+'\blockAds-RU.module'))
foreach ($section in @('Rule','Script','MITM')) {
  Check ([regex]::Matches($combined,('(?m)^\['+$section+'\]\r?$')).Count -eq 1) ('combined single '+$section+' section')
}
$combinedNames = @([regex]::Matches($combined,'(?m)^([A-Za-z0-9_-]+)\s*=\s*type=http-response') | ForEach-Object {$_.Groups[1].Value})
Check ($combinedNames.Count -eq 4) 'combined includes four compatible script entries'
Check (($combinedNames | Sort-Object -Unique).Count -eq 4) 'combined has no duplicate scripts'
foreach ($scriptId in $patternCases.Keys) { Check ($combinedNames -contains $scriptId) ('combined includes '+$scriptId) }
$hostMatch = [regex]::Match($combined,'(?m)^hostname\s*=\s*%APPEND%\s*([^\r\n]+)')
$combinedHosts = @($hostMatch.Groups[1].Value.Split(',') | ForEach-Object {$_.Trim()})
Check ($combinedHosts.Count -eq 11) 'combined MITM host count'
Check (($combinedHosts | Sort-Object -Unique).Count -eq 11) 'combined has no duplicate MITM hosts'
foreach ($url in $patternCases.Values) { Check ($combinedHosts -contains ([uri]$url).Host) ('combined MITM covers '+([uri]$url).Host) }
Check (!($combinedHosts | Where-Object {$_ -match '(^|\.)(apple\.com|icloud\.com|tbank\.ru|tinkoff\.ru|telegram\.org|googlevideo\.com|x\.com|twitter\.com|twimg\.com|t\.co)$'})) 'combined MITM excludes critical shared services and X'
$definition = [IO.File]::ReadAllText(($root+'\mitm-config.json')) | ConvertFrom-Json
Check ($definition.script_ref -match '^[a-f0-9]{40}$') 'definition pins scripts to a commit'
foreach ($entry in $definition.scripts) {
  Check ($combinedNames -contains $entry.id) ('definition included '+$entry.id)
  Check ($combined.Contains('/'+$definition.script_ref+'/Russia/'+$entry.file)) ('definition reference included '+$entry.file)
  foreach ($hostName in $entry.hosts) { Check ($combinedHosts -contains $hostName) ('definition host included '+$hostName) }
}
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.module') {
  $text = [IO.File]::ReadAllText($file.FullName)
  $match = [regex]::Match($text,'(?m)^hostname\s*=\s*%APPEND%\s*([^\r\n]+)')
  $hosts = @($match.Groups[1].Value.Split(',') | ForEach-Object {$_.Trim()})
  foreach ($compatibleRoot in $definition.passthrough_roots) {
    Check (!($hosts | Where-Object {$_ -eq $compatibleRoot -or $_.EndsWith('.'+$compatibleRoot)})) ($file.Name+' no decryption of '+$compatibleRoot)
  }
}
$legacyX = [IO.File]::ReadAllText(($root+'\X-RU.module'))
Check (!($legacyX -match '(?m)^RU-X\s*=|^hostname\s*=|^DOMAIN')) 'legacy X update does not restore incompatible interception'
$report = [ordered]@{checks=$checks;failures=@($failures);domain_rules=$rules.Count;combined_scripts=$combinedNames.Count;combined_mitm_hosts=$combinedHosts.Count;iphone_runtime_tested=$false}
$json=$report | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText(($root+'\release-checks.json'),$json,(New-Object Text.UTF8Encoding($false)))
$json
if ($failures.Count) { exit 1 }
