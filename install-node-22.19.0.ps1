#Requires -Version 5.1
<#
.SYNOPSIS
    绕过 winget，直接下载并安装 Node.js 22.19.0 (Windows)。

.DESCRIPTION
    本机系统内不存在 winget.exe（App Installer 包不含 winget 二进制），
    因此改用 Node.js 官方发行包安装。

    默认行为：
      1. 校验 SHA256
      2. 卸载现有的 Node.js（例如已装的 24.x）
      3. 静默安装 node-v22.19.0-x64.msi
      4. 校验 node -v 是否为 v22.19.0

    需要管理员权限，脚本会自动弹出 UAC 提权窗口。

.PARAMETER Version
    要安装的 Node 版本，默认 22.19.0。

.PARAMETER Arch
    x64（默认）或 x86。

.PARAMETER KeepExisting
    保留已安装的旧版 Node，不执行卸载（降级可能被 Windows Installer 拒绝）。

.PARAMETER Portable
    免管理员模式：只下载 zip 解压到用户目录，不改动系统。
    注意：系统 PATH 中的 C:\Program Files\nodejs 优先级高于用户 PATH，
    所以此模式不会自动顶掉旧版 node，需自行调整 PATH。

.PARAMETER Proxy
    下载走的代理，例如 http://127.0.0.1:7890。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-node-22.19.0.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-node-22.19.0.ps1 -Proxy http://127.0.0.1:7890

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-node-22.19.0.ps1 -Portable
#>
[CmdletBinding()]
param(
    [string] $Version = '22.19.0',
    [ValidateSet('x64', 'x86')] [string] $Arch = 'x64',
    [switch] $KeepExisting,
    [switch] $Portable,
    [string] $Proxy
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

# 官方 SHASUMS256.txt 中的校验值
$MsiHash = @{
    'x64' = '9d75369d5c62f1d24340c7163cbb252fe29e1950b58095ea5f495998930ccefa'
    'x86' = '96aae9a1053d3f8c81d04f15d3db6debbbb9dad418a0b71dcebaeeb8a5c76ae8'
}
$ZipHash = @{
    'x64' = 'ea3fad0e67a991d8477d8c01344b56e69c676ccb733f065b22436994b1253f86'
    'x86' = '708b8a297a19e9ac433e32ac0fc496755757c5e00bd5a0683917e73cae5fe8ea'
}
# 仅 22.19.0 的校验值有效；换版本时跳过校验
$HashKnown = ($Version -eq '22.19.0')

function Write-Step { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  [OK] $m"  -ForegroundColor Green }
function Write-Note { param($m) Write-Host "  [!]  $m"  -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "  [X]  $m"  -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Remote {
    param([string] $Url, [string] $Dest, [string] $ProxyUrl)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $iwr = @{ Uri = $Url; OutFile = $Dest; UseBasicParsing = $true; TimeoutSec = 600 }
    if ($ProxyUrl) { $iwr['Proxy'] = $ProxyUrl }
    try {
        Invoke-WebRequest @iwr
        return
    } catch {
        Write-Note "Invoke-WebRequest 失败（$($_.Exception.Message)），改用 curl.exe 重试"
    }

    $curl = @('-L', '--fail', '--silent', '--show-error', '-o', $Dest, $Url)
    if ($ProxyUrl) { $curl = @('-x', $ProxyUrl) + $curl }
    & curl.exe @curl
    if ($LASTEXITCODE -ne 0) { throw "下载失败：$Url" }
}

function Get-InstalledNode {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Node.js*' } |
        Select-Object DisplayName, DisplayVersion, PSChildName
}

# ---------------------------------------------------------------- 前置检查
Write-Host "`nNode.js $Version ($Arch) 安装脚本" -ForegroundColor White

if (-not $Portable -and -not (Test-Admin)) {
    Write-Note '需要管理员权限，正在请求提权（请在弹出的 UAC 窗口点“是”）...'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
              '-Version', $Version, '-Arch', $Arch)
    if ($KeepExisting) { $argv += '-KeepExisting' }
    if ($Proxy)        { $argv += @('-Proxy', $Proxy) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argv -Verb RunAs
    exit 0
}

if (-not $Portable) {
    $running = Get-Process node -ErrorAction SilentlyContinue
    if ($running) {
        Write-Note "检测到 $($running.Count) 个正在运行的 node 进程（可能是 VS Code / 开发服务器 / 其他工具）："
        $running | Select-Object -First 8 Id, ProcessName, Path |
            Format-Table -AutoSize | Out-String | Write-Host
        Write-Note '安装/卸载 Node 前请先关闭它们，否则可能报错 1603。'
        if (-not $KeepExisting -and -not $PSCmdlet.ShouldContinue('是否仍然继续？', 'Node 进程正在运行')) {
            Write-Bad '已取消。'
            exit 1
        }
    }
}

# ---------------------------------------------------------------- 下载
$file = if ($Portable) { "node-v$Version-win-$Arch.zip" } else { "node-v$Version-$Arch.msi" }
$url  = "https://nodejs.org/dist/v$Version/$file"
$dest = Join-Path $env:TEMP $file

Write-Step "下载 $file"
Write-Host "  来源: $url"
if (Test-Path $dest) { Remove-Item $dest -Force }
Get-Remote -Url $url -Dest $dest -ProxyUrl $Proxy
Write-Ok "已下载到 $dest ($([math]::Round((Get-Item $dest).Length / 1MB, 1)) MB)"

# ---------------------------------------------------------------- 校验
Write-Step '校验 SHA256'
$expected = if ($Portable) { $ZipHash[$Arch] } else { $MsiHash[$Arch] }
$actual   = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLower()
if (-not $HashKnown) {
    Write-Note "未内置 $Version 的校验值，跳过比对（实际: $actual）"
} elseif ($actual -eq $expected) {
    Write-Ok $actual
} else {
    Remove-Item $dest -Force -ErrorAction SilentlyContinue
    throw "SHA256 不匹配！`n  期望: $expected`n  实际: $actual`n文件已删除，请勿使用。"
}

# ---------------------------------------------------------------- 免管理员模式
if ($Portable) {
    Write-Step '解压到用户目录（免管理员）'
    $outDir = Join-Path $env:LOCALAPPDATA "Programs\node-v$Version"
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    $tmp = Join-Path $env:TEMP "node-unzip-$([guid]::NewGuid().ToString('n'))"
    Expand-Archive -Path $dest -DestinationPath $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    Move-Item $inner.FullName $outDir
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "已解压到 $outDir"

    Write-Step '结果'
    & (Join-Path $outDir 'node.exe') --version
    Write-Host ''
    Write-Note '此模式未修改系统。要用它，请手动把下面这个目录放到 PATH 最前面：'
    Write-Host "    $outDir" -ForegroundColor White
    Write-Note '注意：系统 PATH 里的 C:\Program Files\nodejs 优先级更高，'
    Write-Note '      所以要么先从“应用和功能”卸载旧版 Node，要么改系统 PATH。'
    exit 0
}

# ---------------------------------------------------------------- 卸载旧版
$found = Get-InstalledNode
if ($found) {
    Write-Step '检测到已安装的 Node.js'
    $found | ForEach-Object {
        Write-Host ("  - {0} {1}  [{2}]" -f $_.DisplayName, $_.DisplayVersion, $_.PSChildName)
    }

    if ($KeepExisting) {
        Write-Note '-KeepExisting 已指定，跳过卸载。若安装失败提示“已安装更高版本”，请去掉该参数重跑。'
    } else {
        foreach ($item in $found) {
            Write-Host "`n  卸载 $($item.DisplayName) $($item.DisplayVersion) ..."
            $p = Start-Process msiexec.exe -ArgumentList @('/x', $item.PSChildName, '/qn', '/norestart') -Wait -PassThru
            if ($p.ExitCode -in 0, 1605, 3010) {
                Write-Ok "卸载完成 (exit $($p.ExitCode))"
            } else {
                throw "卸载失败，msiexec 退出码 $($p.ExitCode)。常见原因：node 进程仍在运行（1603）。"
            }
        }
    }
} else {
    Write-Note '未在注册表中发现已安装的 Node.js。'
}

# ---------------------------------------------------------------- 安装
Write-Step "安装 Node.js $Version"
$msiArgs = @('/i', "`"$dest`"", '/qn', '/norestart')
$p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($p.ExitCode -in 0, 3010) {
    Write-Ok "安装完成 (exit $($p.ExitCode))"
    if ($p.ExitCode -eq 3010) { Write-Note '需要重启才能完全生效。' }
} else {
    throw "安装失败，msiexec 退出码 $($p.ExitCode)。"
}

# ---------------------------------------------------------------- 验证
Write-Step '验证结果'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')

$nodeExe = Join-Path $env:ProgramFiles 'nodejs\node.exe'
if (Test-Path $nodeExe) {
    $v = & $nodeExe --version
    $npm = & (Join-Path $env:ProgramFiles 'nodejs\npm.cmd') --version 2>$null
    Write-Host "  node: $v" -ForegroundColor White
    Write-Host "  npm : $npm" -ForegroundColor White
    if ($v -eq "v$Version") {
        Write-Ok "已成功切换到 Node $Version"
    } else {
        Write-Bad "期望 v$Version，实际 $v"
    }
} else {
    Write-Bad "未找到 $nodeExe"
}

Write-Host "`n提示：请新开一个终端窗口，让 PATH 变更生效。" -ForegroundColor Cyan
