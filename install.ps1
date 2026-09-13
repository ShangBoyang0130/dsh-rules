<#
  install.ps1 —— 把这套规矩和 skill 装到本机

  跑法（在 PowerShell 里，先 cd 到本目录）：
      .\install.ps1
  指定工作区、不问：
      .\install.ps1 -Workspace D:\我的工作区

  它做四件事：问工作区 → 拷文件 → 填启动脚本的路径 → 报告。
  已存在的文件先备份成 .bak.<时间戳>，再覆盖。
#>
[CmdletBinding()]
param(
  [string]$Workspace,
  [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh')
)

$ErrorActionPreference = 'Stop'
$here  = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:installed = 0
$script:backedUp  = 0

Write-Host ''
Write-Host '=== dsh 规矩包 安装 ===' -ForegroundColor Cyan
Write-Host ''

# ── 1. 问工作区 ───────────────────────────────────────────────
if (-not $Workspace) {
  $suggest = Join-Path $env:USERPROFILE 'dsh-workspace'
  Write-Host 'dsh 的工作区目录（agent 只在这个目录里读写文件）'
  $answer = Read-Host "  直接回车用默认：$suggest"
  $Workspace = if ([string]::IsNullOrWhiteSpace($answer)) { $suggest } else { $answer.Trim() }
}
$Workspace = $Workspace.TrimEnd('\')
if (-not (Test-Path $Workspace)) {
  Write-Host "  工作区不存在，创建：$Workspace"
  New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
}
Write-Host "  工作区：$Workspace"
Write-Host "  规矩目录：$DshHome"

# ── 2. 装一个文件：先备份，再覆盖 ─────────────────────────────
function Install-File {
  param([string]$From, [string]$To)
  $dir = Split-Path $To -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (Test-Path $To) {
    Copy-Item $To "$To.bak.$stamp" -Force
    $script:backedUp++
    Write-Host "  备份 → $(Split-Path $To -Leaf).bak.$stamp" -ForegroundColor DarkGray
  }
  Copy-Item $From $To -Force
  $script:installed++
  Write-Host "  装上 → $To" -ForegroundColor Green
}

# ── 3. 规矩文件 ───────────────────────────────────────────────
Write-Host ''
Write-Host '[规矩文件]'
Install-File "$here\rules\global-AGENTS.md"    (Join-Path $DshHome 'AGENTS.md')
Install-File "$here\rules\global-术语表.md"     (Join-Path $DshHome '术语表.md')
Install-File "$here\rules\workspace-AGENTS.md" (Join-Path $Workspace 'AGENTS.md')

# ── 4. skill ──────────────────────────────────────────────────
Write-Host ''
Write-Host '[skill]'
$skillDst = Join-Path $DshHome 'skills'
foreach ($d in (Get-ChildItem "$here\skills" -Directory)) {
  Install-File (Join-Path $d.FullName 'SKILL.md') (Join-Path $skillDst "$($d.Name)\SKILL.md")
}
Install-File "$here\skills\说明.txt" (Join-Path $skillDst '说明.txt')

# ── 5. 启动脚本：把占位符换成真路径 ───────────────────────────
Write-Host ''
Write-Host '[启动脚本]'
$batSrc = Get-Content "$here\launcher\启动dsh.bat" -Encoding UTF8 -Raw
if ($batSrc -notmatch '__WORKSPACE__') {
  throw '启动脚本里找不到 __WORKSPACE__ 占位符——它可能已经被改过。停下来，以免装出半套。'
}
$batDst = Join-Path $Workspace '活跃\启动dsh.bat'
$batDir = Split-Path $batDst -Parent
if (-not (Test-Path $batDir)) { New-Item -ItemType Directory -Force -Path $batDir | Out-Null }
if (Test-Path $batDst) {
  Copy-Item $batDst "$batDst.bak.$stamp" -Force
  $script:backedUp++
  Write-Host "  备份 → 启动dsh.bat.bak.$stamp" -ForegroundColor DarkGray
}
[System.IO.File]::WriteAllText($batDst, ($batSrc -replace '__WORKSPACE__', $Workspace), (New-Object System.Text.UTF8Encoding($false)))
$script:installed++
Write-Host "  装上 → $batDst" -ForegroundColor Green
Write-Host "         （里面的工作区已填成 $Workspace）"

# ── 6. 报告 ───────────────────────────────────────────────────
Write-Host ''
Write-Host '=== 装完了 ===' -ForegroundColor Cyan
Write-Host "  新装 / 覆盖：$script:installed 个文件"
Write-Host "  备份：$script:backedUp 个（后缀 .bak.$stamp，确认没问题后可以删）"
Write-Host ''
Write-Host '接下来三步：'
Write-Host '  1. 如果 dsh 正在跑，先关掉；然后双击上面那个 启动dsh.bat'
Write-Host '  2. 在输入框打一个 / ，看 skill 是不是都在'
Write-Host '  3. 想加新 skill，看 skills\说明.txt'
if (-not (Get-Command dsh -ErrorAction SilentlyContinue)) {
  Write-Host ''
  Write-Host '  注意：这台机器上没找到 dsh 命令。先装 Node.js，再跑：' -ForegroundColor Yellow
  Write-Host '        npm i -g @deepseek-ai/dsh' -ForegroundColor Yellow
}
Write-Host ''
