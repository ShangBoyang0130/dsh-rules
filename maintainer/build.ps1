<#
  build.ps1 —— 从你的 ~/.dsh/ 重新生成包里的派生部分

  跑法（在 PowerShell 里，先 cd 到本目录）：
      .\build.ps1 -Workspace D:\我的工作区

  它只刷新 rules\ 、skills\ 、launcher\ 这三块（都是"从源拷过来"的），
  不动 README.md / install.ps1 / build.ps1 自己。

  生成完会做痕迹检查：产物里一旦出现本机用户名、具体用户目录、或这次构建用的那条
  工作区路径，就直接失败 —— 免得把带痕迹的包推上去。这是机械保证，不靠人记得检查。

  生成 rules\workspace-AGENTS.md 时，还会把源里被 <!--本机专属--> … <!--/本机专属-->
  夹在**同一行**里的片段删掉（本机自己的主线路标、检查脚本路径这类），一个标记都没有就失败。
  只支持同一行：跨行写（开标记单独一行）会直接 throw，不会静默漏出去。

  另一道是泄露探测：拿工作区里的 活跃\本机词清单.txt（一行一个词，不进包）扫一遍
  派生出来的 rules\ / skills\ / launcher\，命中本机项目名就失败；没有清单就跳过。

  加 -Check 只核「包里的产物与源一致」，不写盘（退出码 1 = 不一致）：
      .\build.ps1 -Workspace D:\我的工作区 -Check

  注意：本文件必须存成 UTF-8 带 BOM，否则 Windows PowerShell 5.1 会把中文读成 ANSI。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Workspace,
  [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
  [switch]$Check
)

$ErrorActionPreference = 'Stop'
$here = Split-Path $PSScriptRoot -Parent

# ── -Check：先生成到临时目录，只比对、不写包 ─────────────────
$checking = $Check.IsPresent
if ($checking) {
  $destRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-rules-check-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $destRoot | Out-Null
  Write-Host '  [模式] -Check：只核一致性，不写盘' -ForegroundColor Yellow
} else {
  $destRoot = $here
}

Write-Host ''
Write-Host '=== 重新生成包 ===' -ForegroundColor Cyan
Write-Host "  源：$DshHome"
Write-Host "  工作区：$Workspace"

# ── 1. 规矩文件 ───────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path "$destRoot\rules" | Out-Null
Copy-Item "$DshHome\AGENTS.md"   "$destRoot\rules\global-AGENTS.md"    -Force
Copy-Item "$DshHome\术语表.md"    "$destRoot\rules\global-术语表.md"     -Force
Copy-Item "$Workspace\AGENTS.md" "$destRoot\rules\workspace-AGENTS.md" -Force
Write-Host '  [规矩文件] 3 个' -ForegroundColor Green

# 工作区 AGENTS.md 里有本机专属的内容（自己的主线路标、检查脚本路径…），源里在被删片段的
# **同一行**里用 <!--本机专属--> … <!--/本机专属--> 夹住，发布件把这些删掉 —— 发布件因此仍然
# 是从源派生的，不用另维护一份模板。一个标记都没有 = 源换过或标记被删，直接失败。
# 只支持同一行：跨行写（开标记单独一行）由下面那句 throw 拦住，不会静默漏出去。
$wsPub   = "$destRoot\rules\workspace-AGENTS.md"
$wsBytes = [System.IO.File]::ReadAllBytes($wsPub)
$wsBom   = $wsBytes.Length -ge 3 -and $wsBytes[0] -eq 0xEF -and $wsBytes[1] -eq 0xBB -and $wsBytes[2] -eq 0xBF
$wsText  = [System.Text.Encoding]::UTF8.GetString($wsBytes)
if ($wsBom) { $wsText = $wsText.Substring(1) }
$wsOpen  = '<!--\s*本机专属\s*-->'
$wsClose = '<!--\s*/本机专属\s*-->'
$wsDrop = 0
$wsTrim = 0
$wsKept = New-Object System.Collections.Generic.List[string]
foreach ($l in ($wsText -split "`n")) {
  if ($l -notmatch $wsOpen) { $wsKept.Add($l); continue }
  if ($l -notmatch $wsClose) { throw "工作区 AGENTS.md 有一行只写了半个标记，补成一对：$l" }
  $rest = ($l -replace "$wsOpen.*?$wsClose", '').TrimEnd()
  if ($rest.Trim() -eq '') { $wsDrop++ } else { $wsTrim++; $wsKept.Add($rest) }
}
if ($wsDrop + $wsTrim -eq 0) {
  throw '工作区 AGENTS.md 里一个 <!--本机专属--> 标记都没有 —— 标记被删了，或换了文件。停下来，免得把本机内容发出去。'
}
while ($wsKept.Count -gt 0 -and $wsKept[$wsKept.Count - 1].Trim() -eq '') { $wsKept.RemoveAt($wsKept.Count - 1) }
[System.IO.File]::WriteAllText($wsPub, (($wsKept -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($wsBom)))
Write-Host "  [工作区说明] 派生发布版：删掉 $wsDrop 行、截短 $wsTrim 行（标了 <!--本机专属--> 的内容）" -ForegroundColor Green

# ── 2. skills ─────────────────────────────────────────────────
Remove-Item "$destRoot\skills" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$destRoot\skills" | Out-Null
foreach ($d in (Get-ChildItem "$DshHome\skills" -Directory)) {
  Copy-Item $d.FullName (Join-Path "$destRoot\skills" $d.Name) -Recurse -Force
}
Copy-Item "$DshHome\skills\说明.txt" "$destRoot\skills\说明.txt" -Force
Write-Host "  [skills] $((Get-ChildItem "$destRoot\skills" -Directory).Count) 个" -ForegroundColor Green

# ── 3. 启动脚本：把这次的工作区路径换成占位符 ─────────────────
New-Item -ItemType Directory -Force -Path "$destRoot\launcher" | Out-Null
$bat = Get-Content "$Workspace\活跃\启动dsh.bat" -Encoding UTF8 -Raw
$bat = $bat -replace [regex]::Escape($Workspace), '__WORKSPACE__'
if ($bat -notmatch '__WORKSPACE__') {
  throw "启动脚本里没找到工作区路径 $Workspace —— 换过目录，或者脚本已经不是这一版了。"
}
[System.IO.File]::WriteAllText("$destRoot\launcher\启动dsh.bat", $bat, (New-Object System.Text.UTF8Encoding($false)))
Write-Host '  [启动脚本] 1 个（工作区已换成占位符）' -ForegroundColor Green

# ── 4. 痕迹检查：查"这次实际用到的标识"，不猜模式 ─────────────
$user    = $env:USERNAME
$userEsc = [regex]::Escape($user)
$wsEsc   = [regex]::Escape($Workspace)
$checks = [ordered]@{
  '本机用户名'     = '(?<![A-Za-z0-9])' + $userEsc + '(?![A-Za-z0-9])'
  '具体用户目录'   = 'C:\\Users\\[A-Za-z0-9]'
  '本次的工作区路径' = $wsEsc
}
$allow = '__WORKSPACE__|%USERPROFILE%|~[\\/]'
$skip  = @('build.ps1', 'install.ps1', 'README.md')   # 这三个自己就写着路径示例
$bad = 0
$scan = if ($checking) { $destRoot } else { $here }
foreach ($f in (Get-ChildItem $scan -Recurse -File)) {
  if ($skip -contains $f.Name) { continue }
  if ($f.Name -like '*.bak.*') { continue }
  $lines = Get-Content $f.FullName -Encoding UTF8
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $allow) { continue }
    foreach ($k in $checks.Keys) {
      if ($lines[$i] -match $checks[$k]) {
        Write-Host "  x [$k] $($f.Name) L$($i+1): $($lines[$i].Trim())" -ForegroundColor Red
        $bad++
      }
    }
  }
}

Write-Host ''
if ($bad -gt 0) {
  Write-Host "=== 痕迹检查失败：$bad 处 === 包没生成好，先别推。" -ForegroundColor Red
  exit 1
}

# ── 5. 泄露探测：拿工作区里的「本机词清单」扫派生出来的那几份 ──
# 痕迹检查管的是用户名与路径；这一步管的是本机自己的项目名（比如某条业务线的名字）。
# 清单住工作区、不进包；没有清单就跳过（只装来用的人不会有）。
$listPath = Join-Path $Workspace '活跃\本机词清单.txt'
if (-not (Test-Path $listPath)) {
  Write-Host "  [!] 没有私有词清单（$listPath）—— 泄露探测跳过" -ForegroundColor Yellow
} else {
  $words = @(Get-Content $listPath -Encoding UTF8 |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
  $hit = 0
  foreach ($sub in @('rules', 'skills', 'launcher')) {
    $dir = Join-Path $scan $sub
    if (-not (Test-Path $dir)) { continue }
    foreach ($f in (Get-ChildItem $dir -Recurse -File)) {
      $ls = Get-Content $f.FullName -Encoding UTF8
      for ($i = 0; $i -lt $ls.Count; $i++) {
        foreach ($w in $words) {
          if ($ls[$i] -like "*$w*") {
            Write-Host "  x [私有词:$w] $sub\$($f.Name) L$($i+1): $($ls[$i].Trim())" -ForegroundColor Red
            $hit++
          }
        }
      }
    }
  }
  if ($hit -gt 0) {
    Write-Host "=== 泄露探测失败：$hit 处（清单：$listPath）===" -ForegroundColor Red
    exit 1
  }
  Write-Host "  [泄露探测] $($words.Count) 个词，扫过 rules / skills / launcher：没命中" -ForegroundColor Green
}

if ($checking) {
  Write-Host ''
  Write-Host '=== 一致性比对（包 vs 源）===' -ForegroundColor Cyan
  $diff = 0
  foreach ($sub in @('rules', 'skills', 'launcher')) {
    $a = Join-Path $here $sub
    $b = Join-Path $destRoot $sub
    $pkg = @{}
    if (Test-Path $a) {
      foreach ($f in (Get-ChildItem $a -Recurse -File)) {
        $pkg[$f.FullName.Substring($a.Length).TrimStart('\')] = $f.FullName
      }
    }
    if (Test-Path $b) {
      foreach ($f in (Get-ChildItem $b -Recurse -File)) {
        $k = $f.FullName.Substring($b.Length).TrimStart('\')
        if (-not $pkg.ContainsKey($k)) {
          Write-Host "  + 源里有、包里没有：$sub\$k" -ForegroundColor Yellow
          $diff++
          continue
        }
        if ((Get-FileHash $pkg[$k] -Algorithm SHA256).Hash -ne (Get-FileHash $f.FullName -Algorithm SHA256).Hash) {
          Write-Host "  x 内容不一致：$sub\$k" -ForegroundColor Red
          $diff++
        }
      }
    }
    foreach ($k in $pkg.Keys) {
      if (-not (Test-Path (Join-Path $b $k))) {
        Write-Host "  - 包里有、源已删：$sub\$k" -ForegroundColor Red
        $diff++
      }
    }
  }
  Remove-Item $destRoot -Recurse -Force -ErrorAction SilentlyContinue
  if ($diff -gt 0) {
    Write-Host "=== 不一致 $diff 处 === 跑一次不带 -Check 的 build.ps1 重新生成。" -ForegroundColor Red
    exit 1
  }
  Write-Host '  包与源一致。' -ForegroundColor Green
  exit 0
}

Write-Host '=== 好了 ===' -ForegroundColor Cyan
Write-Host '  痕迹检查通过。接下来 git add / commit / push。'
Write-Host ''

exit 0
