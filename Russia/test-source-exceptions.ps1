# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
$buildPath = Join-Path $PSScriptRoot 'build-rules.ps1'
$workingBuild = Join-Path (Split-Path -Parent $PSScriptRoot) 'build-rules.ps1'
if ((Split-Path -Leaf $PSScriptRoot) -eq 'publish' -and (Test-Path -LiteralPath $workingBuild)) { $buildPath = $workingBuild }
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($buildPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Generator contains PowerShell syntax errors' }
$function = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-WildcardException'}, $true)
if (!$function) { throw 'Wildcard exception matcher is missing' }
# Load only the pure production matcher; do not run the builder or download sources.
Invoke-Expression $function.Extent.Text
$cases = @(
  @('pangle.io', $true, 'api*-access-sg.pangle.io', $true),
  @('pangle.io', $false, 'api*-access-sg.pangle.io', $false),
  @('api16-access-sg.pangle.io', $false, 'api*-access-sg.pangle.io', $true),
  @('child.api16-access-sg.pangle.io', $false, 'api*-access-sg.pangle.io', $true),
  @('i16-tb.isnssdk.com', $true, 'i*-tb.isnssdk.com', $true),
  @('isnssdk.com', $true, 'i*-tb.isnssdk.com', $true),
  @('dm.isnssdk.com', $true, 'i*-tb.isnssdk.com', $false),
  @('h5.isnssdk.com', $true, 'i*-tb.isnssdk.com', $false),
  @('imapi-sg.isnssdk.com', $true, 'i*-tb.isnssdk.com', $false),
  @('foo-tb.isnssdk.com', $true, 'i*-tb.isnssdk.com', $true),
  @('foo-tb.isnssdk.com', $false, 'i*-tb.isnssdk.com', $false),
  @('tb.isnssdk.com', $true, 'i*-tb.isnssdk.com', $false),
  @('otherpangle.io', $true, 'api*-access-sg.pangle.io', $false),
  @('pangle.io.example.org', $true, 'api*-access-sg.pangle.io', $false),
  @('I16-TB.ISNSSDK.COM', $true, 'i*-tb.isnssdk.com', $true),
  @('cdn.anyclip.com', $false, 'cdn*.anyclip.com', $true),
  @('cdn1.anyclip.com', $false, 'cdn*.anyclip.com', $true),
  @('api.anyclip.com', $false, 'cdn*.anyclip.com', $false),
  @('api.anyclip.com', $true, 'cdn*.anyclip.com', $true),
  @('api1-access-sg.pangle.io', $false, 'api*-access-*.pangle.io', $true),
  @('pangle.io', $true, 'api*-access-*.pangle.io', $true),
  @('example.org', $true, 'api*-access-*.pangle.io', $false),
  @('example.org', $true, 'optout*.*', $false),
  @('optout.example.org', $true, 'optout*.*', $true),
  @('example.com', $true, 'ads*.com', $false),
  @('ads1.com', $true, 'ads*.com', $true),
  @('vk.ru', $true, 'ads.vk.*', $false),
  @('ads.vk.ru', $false, 'ads.vk.*', $true)
)
$failures = New-Object 'System.Collections.Generic.List[string]'
foreach ($case in $cases) {
  $actual = Test-WildcardException $case[0] $case[1] $case[2]
  if ($actual -ne $case[3]) { $failures.Add(($case[0]+' suffix='+$case[1]+' exception='+$case[2])) }
}
[ordered]@{checks=$cases.Count;failures=@($failures);generator_executed=$false} | ConvertTo-Json -Depth 4
if ($failures.Count) { exit 1 }
