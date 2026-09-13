<#
  发布.ps1 —— 把这个包推上 GitHub

  前提：装了 git 和 gh，并且 gh 已经登录过（跑一次 gh auth login，在浏览器里授权）。
  凭据那一步刻意留给人：脚本只调用已登录的 gh，自己不碰任何令牌。

  跑法：
      .\发布.ps1 -Repo dsh-rules            # 公开仓库
      .\发布.ps1 -Repo dsh-rules -Private   # 私有仓库

  第一次跑：git init → commit → gh repo create --push
  以后跑：  就是一次普通的"提交并推送"（改了源先跑 build.ps1 再跑这个）

  注意：本文件必须存成 UTF-8 带 BOM，否则 Windows PowerShell 5.1 会把中文读成 ANSI。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Repo,
  [switch]$Private,
  [string]$Message = '更新 dsh-rules'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path $PSScriptRoot -Parent

function Need([string]$cmd, [string]$how) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "找不到 $cmd。$how" }
}

Write-Host ''
Write-Host '=== 发布 dsh-rules 到 GitHub ===' -ForegroundColor Cyan

Need 'git' '先装：winget install Git.Git —— 装完关掉窗口、重开一个 PowerShell'
Need 'gh'  '先装：winget install GitHub.cli —— 装完关掉窗口、重开一个 PowerShell'

gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
  throw 'gh 还没登录。先跑一次：gh auth login（选 GitHub.com → HTTPS → Login with a web browser）'
}
Write-Host '  gh 已登录 ✓'

$name  = git config user.name
$email = git config user.email
if (-not $name -or -not $email) {
  throw @'
git 身份还没配。先跑这两条（只要一次）：
    git config --global user.name  "你的名字"
    git config --global user.email "你的邮箱"
（公开仓库想不暴露真邮箱，可以用 GitHub 给你的 noreply 邮箱）
'@
}
Write-Host "  提交身份：$name <$email>"

Push-Location $here
try {
  if (-not (Test-Path '.git')) {
    git init | Out-Null
    git branch -M main
    Write-Host '  已 git init'
  }
  git add -A
  git commit -m $Message --allow-empty | Out-Null

  # gh 找不到仓库时会往 stderr 写东西；$ErrorActionPreference='Stop' 会把它变成
  # 终止错误，所以这里临时放宽，并把 stderr 一并吞掉。
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  gh repo view $Repo 2>&1 | Out-Null
  $exists = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $prevEap

  if ($exists) {
    Write-Host "  仓库已存在，推送中……"
    git push
  } else {
    $vis = if ($Private) { '--private' } else { '--public' }
    Write-Host "  新建仓库 $Repo（$vis）并推送中……"
    gh repo create $Repo $vis --source . --push
  }

  Write-Host ''
  Write-Host '=== 发布完成 ===' -ForegroundColor Cyan
  Write-Host "  $(gh repo view $Repo --json url -q .url)"
  Write-Host ''
} finally { Pop-Location }

exit 0
