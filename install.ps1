<#
  install.ps1 —— 把这套规矩和 skill 装到本机

  跑法（在 PowerShell 里，先 cd 到本目录）：
      .\install.ps1
  指定工作区、不问：
      .\install.ps1 -Workspace D:\我的工作区

  它做四件事：问工作区 → 拷文件 → 填启动脚本的路径 → 报告。

  三类文件的装法**不一样**（2026-09-20 改，别按老话术理解）：
   · 三份「你自己的」规矩文件（全局 AGENTS.md / 术语表.md / 工作区 AGENTS.md）：
     **已有就一个字不碰** —— 包里的新版另写到旁边 `名字.新版.<时间戳>`，
     并印一句合并指路（读不读、合哪些，由你决定）；**不存在**时照常装，不旁存
   · skill 与 `skills\说明.txt`（包的内容 —— 必须能被更新修好）：
     已有就**先备份成 `.bak.<时间戳>` 再覆盖**；覆盖时提示你的旧版在哪个 .bak 里
   · 三份工作区空模板（交接 / 待办 / 归档索引）：已有就**直接跳过**（那是你写的活文档）
#>
[CmdletBinding()]
param(
  [string]$Workspace,
  [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh')
)

$ErrorActionPreference = 'Stop'
$here  = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:installed  = 0
$script:backedUp   = 0
$script:sideCopies = 0

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

# ── 2. 装一个**包的内容**文件（skill / 启动脚本）：先备份，再覆盖 ──
function Install-File {
  param([string]$From, [string]$To)
  # 开跑前先确认源在（2026-09-18 加）：解压工具若不认 zip 里的中文名，会在**第二个文件**上炸，
  # 结果是「只装了半套」而报错看起来像偶发。宁可这里就明确报出是哪个文件缺。
  if (-not (Test-Path $From)) {
    throw "包里的文件找不到：$From`n（多半是解压工具没认出中文文件名 —— 换一个解压工具重来，或从 GitHub 重新下载）"
  }
  $dir = Split-Path $To -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (Test-Path $To) {
    Copy-Item $To "$To.bak.$stamp" -Force
    $script:backedUp++
    Write-Host "  备份 → $(Split-Path $To -Leaf).bak.$stamp" -ForegroundColor DarkGray
    # 覆盖前多印这一句（2026-09-20 加）：这些是包的内容、本来就该被新版修好；
    # 但用户自己改过的话，得知道旧版去哪找 —— 否则「更新修好了它」和「更新吃掉了我的改动」
    # 从屏幕上分不出来。
    Write-Host "         （你自己改过它的话，你的版本就在这个 .bak 里）" -ForegroundColor DarkGray
  }
  Copy-Item $From $To -Force
  $script:installed++
  Write-Host "  装上 → $To" -ForegroundColor Green
}

# ── 2b. 装一份「用户自己的」规矩文件：已有就一个字不碰 ──────────
function Install-RulesFile {
  param([string]$From, [string]$To)
  # ⚠️ **这三份是用户自己的规矩文件**（2026-09-20 修，T9 只读核查查实的最坏一条）：
  #    用户会往全局 AGENTS.md / 术语表.md / 工作区 AGENTS.md 里写自己的路标和私有约定。
  #    旧行为是「备份后覆盖」—— 在真工作区上跑一次，根 AGENTS.md 从 66 行掉到 40 行，
  #    精确丢 24 整行 + 1 行截短（含「线清单表」「通用层清单」，那两块别处没有正本）。
  #    规矩跟模板那条一样：**用户已经写过的东西，一个字都不碰。**
  #    但规矩文件又必须能被更新 —— 所以：**发布版另写到旁边** `名字.新版.<stamp>`，
  #    再印一句合并指路；**不存在**时走正常安装（照装、无需旁存）。
  if (-not (Test-Path $From)) {
    throw "包里的文件找不到：$From`n（多半是解压工具没认出中文文件名 —— 换一个解压工具重来，或从 GitHub 重新下载）"
  }
  if (Test-Path $To) {
    $side = "$To.新版.$stamp"
    Copy-Item $From $side -Force
    $script:sideCopies++
    Write-Host "  已有，一个字没碰 → $To" -ForegroundColor Yellow
    Write-Host "  新版另放 → $(Split-Path $To -Leaf).新版.$stamp" -ForegroundColor Cyan
    Write-Host "  合并指路：你这份没动；包里的新版在 $side —— 读一遍，再决定把哪些合进来。" -ForegroundColor Cyan
    return
  }
  $dir = Split-Path $To -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Copy-Item $From $To -Force
  $script:installed++
  Write-Host "  装上 → $To" -ForegroundColor Green
}

# ── 3. 规矩文件 ───────────────────────────────────────────────
Write-Host ''
Write-Host '[规矩文件]'
# ⚠️ 这三份走 Install-RulesFile（**已有就一个字不碰**），不是 Install-File —— 见上面 2b 那段注释。
Install-RulesFile "$here\rules\global-AGENTS.md"    (Join-Path $DshHome 'AGENTS.md')
Install-RulesFile "$here\rules\global-术语表.md"     (Join-Path $DshHome '术语表.md')
Install-RulesFile "$here\rules\workspace-AGENTS.md" (Join-Path $Workspace 'AGENTS.md')

# ── 4. skill ──────────────────────────────────────────────────
# 整目录一起拷：有的 skill 带脚本（比如会话预检那套），只拷 SKILL.md 会装出个空壳。
Write-Host ''
Write-Host '[skill]'
$skillDst = Join-Path $DshHome 'skills'
foreach ($d in (Get-ChildItem "$here\skills" -Directory)) {
  $dstDir = Join-Path $skillDst $d.Name
  if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
  foreach ($f in (Get-ChildItem $d.FullName -Recurse -File)) {
    $to = Join-Path $dstDir $f.FullName.Substring($d.FullName.Length).TrimStart('\')
    Install-File $f.FullName $to
  }
}
Install-File "$here\skills\说明.txt" (Join-Path $skillDst '说明.txt')

# ── 5. 工作区骨架：目录 + 三份空模板 ─────────────────────────
# 为什么建这些：这套规矩的正文会提到「交接放 `活跃\`」「做完的归档到 `存放\`」「要干的活看待办」，
# 只装规矩文件的话，第一次用交接 skill 会撞上一个不存在的目录。所以装的时候顺手把骨架建出来。
# 已存在的文件**不覆盖**（这三份模板走「已有，跳过」），所以重复安装是安全的。
Write-Host ''
Write-Host '[工作区骨架]'
foreach ($d in @('活跃', '存放', '_tmp')) {
  $full = Join-Path $Workspace $d
  if (-not (Test-Path $full)) { New-Item -ItemType Directory -Force -Path $full | Out-Null }
}
Write-Host "  目录：活跃\ / 存放\ / _tmp\ —— 在 $Workspace 下" -ForegroundColor Green

$today = Get-Date -Format 'yyyy-MM-dd'
function Install-Template {
  param([string]$From, [string]$To)
  $dir = Split-Path $To -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # ⚠️ **模板只在「还没有这份文件」时装**（2026-09-18 修，独立复核抓出的最坏一条）：
  #    这些文件是**用户自己的活文档**（交接 / 待办 / 归档索引），重装或更新时必然已经有内容 ——
  #    备份后照样覆盖 = 活文件归零、下一会话读到空交接（内容只在 .bak 里，谁也不会去翻）。
  #    规矩：**用户已经写过的东西，一个字都不碰。**
  if (Test-Path $To) {
    Write-Host "  已有，跳过（不碰你的内容） → $To" -ForegroundColor Yellow
    return
  }
  $txt = Get-Content $From -Encoding UTF8 -Raw
  $txt = $txt -replace '__WORKSPACE__', $Workspace
  $txt = $txt -replace '__DATE__', $today
  [System.IO.File]::WriteAllText($To, $txt, (New-Object System.Text.UTF8Encoding($false)))
  $script:installed++
  Write-Host "  装上（空模板）→ $To" -ForegroundColor Green
}
if (Test-Path "$here\templates") {
  Install-Template "$here\templates\交接.md"     (Join-Path $Workspace '活跃\交接.md')
  Install-Template "$here\templates\待办.md"     (Join-Path $Workspace '活跃\待办.md')
  Install-Template "$here\templates\归档索引.md" (Join-Path $Workspace '活跃\归档索引.md')
} else {
  Write-Host '  （包里没有 templates\ —— 跳过空模板；目录已经建好了）' -ForegroundColor Yellow
}

# ── 6. 启动脚本：把占位符换成真路径 ───────────────────────────
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

# ── 7. 报告 ───────────────────────────────────────────────────
Write-Host ''
Write-Host '=== 装完了 ===' -ForegroundColor Cyan
Write-Host "  装上 / 覆盖：$script:installed 个文件 —— 都是「包的内容」那一类"
Write-Host '               （skill / 说明.txt / 启动脚本；规矩文件原来没有时也算在这里，'
Write-Host '                 所以这一个数里「新装」和「覆盖」是混着的 —— 靠下面的后缀分）'
Write-Host ''
Write-Host "  两种后缀，分清楚（后缀里的时间戳都是 $stamp）：" -ForegroundColor Cyan
Write-Host "   · .bak.$stamp —— 备份后覆盖：$script:backedUp 个"
Write-Host '       这些是**包的内容**：更新会把它们换成新版；你自己改过的话，'
Write-Host '       你的版本就在 同名.bak.<时间戳> 里（想退回就用它盖回去）。'
Write-Host "   · .新版.$stamp —— 一个字没碰：$script:sideCopies 个规矩文件"
Write-Host '       这些是**你自己写的**那三份（AGENTS.md / 术语表.md）：你那份原样留着，'
Write-Host '       包里的新版另放在 同名.新版.<时间戳> —— 两边对不上是正常的，读一遍再决定合哪些。'
Write-Host '   （确认没问题后 .bak.* 可以删；.新版.* 合完也可以删）'
Write-Host ''
Write-Host '接下来三步：'
Write-Host '  1. 如果 dsh 正在跑，先关掉；然后双击上面那个 启动dsh.bat'
Write-Host '  2. 在输入框打一个 / ，看 skill 是不是都在'
Write-Host '  3. 打开工作区里的 活跃\交接.md，照它的格式写下你的第一份交接'
Write-Host ''
Write-Host '关于工具（只提醒，不替你装）：' -ForegroundColor Cyan
Write-Host '  · 这套规矩本身只需要 Node.js + dsh，别的都不需要'
Write-Host '  · 以后做的事可能用到 Python（数据处理）、PowerShell 7（跨平台的 pwsh 脚本）、'
Write-Host '    git（版本管理）—— 用到了再说，装不装、装哪个版本由你决定'
if (-not (Get-Command dsh -ErrorAction SilentlyContinue)) {
  Write-Host ''
  Write-Host '  注意：这台机器上没找到 dsh 命令。先装 Node.js，再跑：' -ForegroundColor Yellow
  Write-Host '        npm i -g @deepseek-ai/dsh' -ForegroundColor Yellow
}
Write-Host ''
