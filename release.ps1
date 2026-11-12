# ============ Per-mod release pipeline (self-contained) ============
# Usage: .\release.ps1 [-Yes] [-PackageOnly]
#   -PackageOnly  build+package+update.json only (suite publish uses this); no gate/tag/release
# Version authority: csproj <Version> (author-edited); Plugin.cs const must match.
param([switch]$Yes, [switch]$PackageOnly)
$ErrorActionPreference = 'Stop'
$repoDir = $PSScriptRoot
$root    = Split-Path $PSScriptRoot -Parent
$modName = Split-Path $repoDir -Leaf
$proj    = Join-Path $repoDir ('SurvivalLog.' + $modName)
$game    = 'E:\SteamLibrary\steamapps\common\Survival Log'
$dotnet  = Join-Path $root 'sdk\dotnet\dotnet.exe'
$ghExe   = Join-Path $root 'suite\tools\gh\bin\gh.exe'
$org     = 'survivallog-mods'

# ---- 1. version authority: csproj ----
$csproj = Join-Path $proj ('SurvivalLog.' + $modName + '.csproj')
$t = [IO.File]::ReadAllText($csproj)
$ver = [regex]::Match($t, '<Version>([\d.]+)</Version>').Groups[1].Value
if (-not $ver) { throw 'cannot read <Version> from csproj' }
$plug = Get-ChildItem $proj -Filter '*Plugin.cs' | Select-Object -First 1
if ($plug -and (([IO.File]::ReadAllText($plug.FullName)) -notmatch ('public const string Version\s*=\s*"' + [regex]::Escape($ver) + '"'))) {
    throw ($plug.Name + ' Version const != csproj ' + $ver)
}

# ---- 2. gates (release mode only) ----
# CHANGELOG.md lives inside the project dir in this mirror-repo layout (synced from mod_stack)
$logPath = Join-Path $proj 'CHANGELOG.md'
$logTxt = [IO.File]::ReadAllText($logPath)
if (-not $PackageOnly) {
    if ($logTxt -notmatch (('##\s*v' + [regex]::Escape($ver)) + '\b')) { throw ('CHANGELOG.md has no v' + $ver + ' section') }
    $dirty = @(git -C $repoDir status --porcelain)
    $blocking = @($dirty | Where-Object { $_ -notmatch 'CHANGELOG\.md\s*$' })
    if ($blocking.Count -gt 0) { $blocking | ForEach-Object { Write-Host ('  ' + $_) }; throw 'uncommitted changes - commit or stash first (CHANGELOG.md allowed)' }
    if (-not $Yes) { $a = Read-Host ('Release ' + $modName + ' v' + $ver + ' ? [Y/N]'); if ($a -notmatch '^[Yy]') { throw 'cancelled' } }
}

# ---- 3. build ----
$env:DOTNET_MULTILEVEL_LOOKUP = '0'; $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
& $dotnet build $proj -c Release --nologo | Out-Host
if ($LASTEXITCODE -ne 0) { throw ('build failed: ' + $modName) }
$dll = Join-Path $proj ('bin\Release\SurvivalLog.' + $modName + '.dll')
if (-not (Test-Path $dll)) { throw ('dll missing: ' + $dll) }

# ---- 4. package ----
$pkg = Join-Path $env:TEMP ('slpkg_' + $modName + '_v' + $ver)
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item (Join-Path $pkg 'BepInEx\plugins') -ItemType Directory -Force | Out-Null
New-Item (Join-Path $pkg 'BepInEx\config')  -ItemType Directory -Force | Out-Null
Copy-Item $dll (Join-Path $pkg 'BepInEx\plugins') -Force
# ---- cfg preset: generated canonical preset (five categories, default 500ms) ----
# (ported from mod_stack tools\make_quickaction_release.ps1; matches mod ReadBoot()
#  defaults; Chinese lines written via [regex]::Unescape to keep this file ASCII-only)
$cfgName = 'com.local.survivallog.quickaction.cfg'
$dstCfg = Join-Path $pkg ('BepInEx\config\' + $cfgName)
$lines = @(
    [regex]::Unescape('[\u5206\u7c7b\u4fee\u6539]'),
    ([regex]::Unescape('\u7269\u54c1\u4f7f\u7528') + 'Ms = 500'),
    ([regex]::Unescape('\u5bb6\u5177\u529f\u80fd') + 'Ms = 500'),
    ([regex]::Unescape('\u623f\u5c4b\u7ef4\u62a4') + 'Ms = 500'),
    ([regex]::Unescape('\u6742\u9879\u4ea4\u4e92') + 'Ms = 500'),
    ([regex]::Unescape('\u5a31\u4e50\u953b\u70bc') + 'Ms = 500'),
    '',
    [regex]::Unescape('[\u5176\u4ed6]'),
    'Overrides = '
)
[System.IO.File]::WriteAllLines($dstCfg, $lines, (New-Object System.Text.UTF8Encoding($false)))
Copy-Item (Join-Path $repoDir 'ReleaseREADME.md') (Join-Path $pkg 'README.md') -Force
$relDir = Join-Path $repoDir 'release'
New-Item $relDir -ItemType Directory -Force | Out-Null
$zip = Join-Path $relDir ('SurvivalLog.' + $modName + '_v' + $ver + '.zip')
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $zip -CompressionLevel Optimal

# ---- 5. update.json (contract: mod/version/asset/md5/gamekb) ----
$md5 = (Get-FileHash $zip -Algorithm MD5).Hash.ToLower()
$gk = Get-ChildItem (Join-Path $root 'gamekb') -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d+$' } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $gk) { throw 'no gamekb snapshot under <root>\gamekb' }
# v2.2.0：CHANGELOG 本版节 = 发版说明唯一源头——同一份进 update.json.notes、GitHub release
# body、versions.json 台账行。抽取原 ---- 6 ---- 的正则上移（6 节继续用 $notes）。
$notes = [regex]::Match($logTxt, ('(?s)##\s*v' + [regex]::Escape($ver) + '\b.*?(?=\r?\n(---|#{1,2}\s)|\z)')).Value.Trim()
$uj = @{ mod = $modName; version = $ver; asset = (Split-Path $zip -Leaf); md5 = $md5; gamekb = $gk.Name; notes = $notes } | ConvertTo-Json
$updatePath = Join-Path $env:TEMP 'update.json'
[IO.File]::WriteAllText($updatePath, $uj, (New-Object Text.UTF8Encoding($false)))
Write-Host $uj
if ($PackageOnly) { Write-Host ('package-only done: ' + $zip); exit 0 }

# v2.2.0 版本台账：gh release create **之前**拉桶内旧 versions.json → 顶部 unshift 本版行。
# 失败语义：HTTP 404 = 首版起建；其余失败（网络/5xx）throw 中止发版——一次网络抖动静默把
# 全史台账重置成单行是本文件最贵的坏法，此时 GitHub release 未发、无半态。
# 同版本行先剔除（删 release 补发场景防双行）。
$cosBase = 'https://survival-log-1302318873.cos.ap-shanghai.myqcloud.com'
$versPath = Join-Path $env:TEMP ('versions_' + $modName + '.json')
$vrows = New-Object System.Collections.Generic.List[object]
try {
    $vr = Invoke-WebRequest -UseBasicParsing -Uri ($cosBase + '/mods/' + $modName + '/versions.json')
    $vtxt = $vr.Content; if ($vtxt -is [byte[]]) { $vtxt = [Text.Encoding]::UTF8.GetString($vtxt) }
    foreach ($r in @(($vtxt | ConvertFrom-Json).versions)) { if ($r.version -ne $ver) { $vrows.Add($r) } }
} catch {
    $code = 0
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -ne 404) { throw ('拉取桶内版本台账失败（非404，中止防静默重置）: ' + $_.Exception.Message) }
    # 404 = 首版起建
}
$vrows.Insert(0, [ordered]@{ version = $ver; date = (Get-Date -Format 'yyyy-MM-dd'); notes = $notes; asset = (Split-Path $zip -Leaf); md5 = $md5; gamekb = $gk.Name })
[IO.File]::WriteAllText($versPath, ([ordered]@{ generatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); mod = $modName; versions = $vrows } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))

# ---- 6. release notes + tag + GitHub release ----
# $notes 已在 ---- 5 ---- 上移抽取（v2.2.0：说明进 update.json/台账）
$notesFile = Join-Path $env:TEMP ('relnotes_' + $modName + '_v' + $ver + '.md')
[IO.File]::WriteAllText($notesFile, $notes, (New-Object Text.UTF8Encoding($false)))
& $ghExe release create ('v' + $ver) --repo ($org + '/' + $modName) --title ('v' + $ver) --notes-file $notesFile $zip $updatePath
if ($LASTEXITCODE -ne 0) { throw ('gh release create failed: ' + $modName) }

# ---- 7. COS 主源双发（v2.1.0：zip + update.json → 桶内 mods/<mod>/，国内直连下载）----
# 失败不炸发版（GitHub 回退源已就绪，玩家暂见旧版），醒目提示补救；zip 先传、update.json 后传
# ——中途失败时桶内 update.json 仍旧版，版本与 zip 保持一致不出现 404 下载。
try {
    & (Join-Path $root 'suite\tools\sync-cos.ps1') -Mod $modName -Zip $zip -UpdateJson $updatePath -Versions $versPath
} catch {
    Write-Warning ('COS 上传失败（GitHub 已发版成功，玩家暂见旧版）：' + $_.Exception.Message)
    Write-Warning ('补救：suite\tools\sync-cos.ps1 -Mod ' + $modName + ' -Zip ' + $zip + ' -UpdateJson ' + $updatePath + ' -Versions ' + $versPath)
    Write-Warning ('补传后记得重跑套件根 publish-index.ps1 刷新聚合索引')
}
Write-Host ('=== ' + $modName + ' v' + $ver + ' released ===')
Write-Host 'Nexus Mods stays a separate author-confirmed step (docs/08). Not automated.'
