<#
  build.ps1 —— 从你的 ~/.dsh/ 重新生成包里的派生部分

  跑法（在 PowerShell 里，先 cd 到本目录）：
      .\build.ps1 -Workspace D:\我的工作区

  它只刷新 rules\ 、skills\ 、launcher\ 这三块（都是"从源拷过来"的），
  不动 README.md / install.ps1 / build.ps1 自己。

  生成完会做痕迹检查：产物里一旦出现本机用户名、具体用户目录、或这次构建用的那条
  工作区路径，就直接失败 —— 免得把带痕迹的包推上去。这是机械保证，不靠人记得检查。

  注意：本文件必须存成 UTF-8 带 BOM，否则 Windows PowerShell 5.1 会把中文读成 ANSI。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Workspace,
  [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path $PSScriptRoot -Parent

Write-Host ''
Write-Host '=== 重新生成包 ===' -ForegroundColor Cyan
Write-Host "  源：$DshHome"
Write-Host "  工作区：$Workspace"

# ── 1. 规矩文件 ───────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path "$here\rules" | Out-Null
Copy-Item "$DshHome\AGENTS.md"   "$here\rules\global-AGENTS.md"    -Force
Copy-Item "$DshHome\术语表.md"    "$here\rules\global-术语表.md"     -Force
Copy-Item "$Workspace\AGENTS.md" "$here\rules\workspace-AGENTS.md" -Force
Write-Host '  [规矩文件] 3 个' -ForegroundColor Green

# ── 2. skills ─────────────────────────────────────────────────
Remove-Item "$here\skills" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$here\skills" | Out-Null
foreach ($d in (Get-ChildItem "$DshHome\skills" -Directory)) {
  Copy-Item $d.FullName (Join-Path "$here\skills" $d.Name) -Recurse -Force
}
Copy-Item "$DshHome\skills\说明.txt" "$here\skills\说明.txt" -Force
Write-Host "  [skills] $((Get-ChildItem "$here\skills" -Directory).Count) 个" -ForegroundColor Green

# ── 3. 启动脚本：把这次的工作区路径换成占位符 ─────────────────
New-Item -ItemType Directory -Force -Path "$here\launcher" | Out-Null
$bat = Get-Content "$Workspace\活跃\启动dsh.bat" -Encoding UTF8 -Raw
$bat = $bat -replace [regex]::Escape($Workspace), '__WORKSPACE__'
if ($bat -notmatch '__WORKSPACE__') {
  throw "启动脚本里没找到工作区路径 $Workspace —— 换过目录，或者脚本已经不是这一版了。"
}
[System.IO.File]::WriteAllText("$here\launcher\启动dsh.bat", $bat, (New-Object System.Text.UTF8Encoding($false)))
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
foreach ($f in (Get-ChildItem $here -Recurse -File)) {
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
Write-Host '=== 好了 ===' -ForegroundColor Cyan
Write-Host '  痕迹检查通过。接下来 git add / commit / push。'
Write-Host ''

exit 0
