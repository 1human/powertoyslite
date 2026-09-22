<#
.SYNOPSIS
    校验 PowerToys Lite 的构建产物：该有的都在、不该有的都没进来。

.DESCRIPTION
    打包后、上传前跑一遍，把「精简没生效」的问题挡在发布之前。

    所有期望值都来自 apply-lite-patch.ps1 写出的构建清单（lite.build.json），
    因此改 enabled-tools.txt 之后这里不需要跟着改：
      · keptModuleDlls        —— 已启用工具的模块 DLL，必须存在于构建输出里
      · unselectedModuleDlls  —— 未启用工具的模块 DLL，必须不存在于构建输出里

    校验分三类：
      · 必须存在：PowerToys.exe、PowerToys.Settings.exe，以及每个已启用工具的模块 DLL。
      · 必须缺失：未启用工具的模块 DLL；每机器安装包（只出每用户包）。
      · 附加信息：默认安装目录是否已按清单改到位、安装包清单与构建输出体积。

    注意：本文件必须保存为 “UTF-8 with BOM”，否则 Windows PowerShell 5.1 会按 ANSI 解码中文而报语法错误。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    # 构建清单路径，默认与本脚本同目录的 lite.build.json（由 apply-lite-patch.ps1 生成）。
    [string]$ManifestPath = '',

    # 形如 0.95.1；留空表示用通配符匹配安装包。
    [string]$Version = '',

    [string]$Platform = 'x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $scriptDirectory 'lite.build.json'
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "构建清单不存在：$ManifestPath`n请先运行 apply-lite-patch.ps1。"
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$outputRoot = Join-Path $RepoRoot "$Platform\Release"
$winUI3Root = Join-Path $outputRoot 'WinUI3Apps'
$installerRoot = Join-Path $RepoRoot "installer\PowerToysSetupVNext\$Platform\Release"

$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-Present {
    param([string]$Path, [string]$Description)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Write-Host ("  [ ok ] {0}" -f $Description) -ForegroundColor Green
        return
    }
    Write-Host ("  [FAIL] {0} —— 缺失：{1}" -f $Description, $Path) -ForegroundColor Red
    $script:Failures.Add("$Description 缺失（$Path）") | Out-Null
}

function Assert-Absent {
    param([string]$Path, [string]$Description)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host ("  [ ok ] {0} 已剔除" -f $Description) -ForegroundColor Green
        return
    }
    Write-Host ("  [FAIL] {0} 仍然存在：{1}" -f $Description, $Path) -ForegroundColor Red
    $script:Failures.Add("$Description 未被剔除（$Path）") | Out-Null
}

# 模块 DLL 在清单里写作 "WinUI3Apps/PowerToys.Peek.dll" 这种相对安装根目录的路径
function Get-RelativeOutputPath {
    param([string]$RelativePath)
    return Join-Path $outputRoot ($RelativePath -replace '/', '\')
}

function Get-DirectorySizeMb {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [math]::Round($sum / 1MB, 1)
}

$enabledTools = @($manifest.enabledTools)
$keptModuleDlls = @($manifest.keptModuleDlls)
$unselectedModuleDlls = @($manifest.unselectedModuleDlls)

Write-Host ''
Write-Host '=== PowerToys Lite 产物校验 ===' -ForegroundColor Cyan

if ($enabledTools.Count -eq 0) {
    Write-Host '本次没有启用任何工具，只校验 PowerToys 本体。' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Host ("本次应包含 $($enabledTools.Count) 个工具：{0}" -f ([string]::Join(', ', @($enabledTools | ForEach-Object { $_.id }))))
}

Write-Host ''
Write-Host '[1/3] 必须存在的产物'
Assert-Present (Join-Path $outputRoot 'PowerToys.exe') 'PowerToys.exe（runner）'
Assert-Present (Join-Path $winUI3Root 'PowerToys.Settings.exe') 'PowerToys.Settings.exe（设置界面）'

foreach ($dll in $keptModuleDlls) {
    Assert-Present (Get-RelativeOutputPath $dll) "模块 $dll"
}

Write-Host ''
Write-Host '[2/3] 必须被剔除的产物'
if ($unselectedModuleDlls.Count -eq 0) {
    Write-Host '  （未启用工具的清单为空，跳过）' -ForegroundColor DarkGray
}
foreach ($dll in $unselectedModuleDlls) {
    # 既检查清单里记录的准确路径，也检查同名的裸文件名——
    # 防止它被别的项目以不同路径带到输出目录里。
    Assert-Absent (Get-RelativeOutputPath $dll) $dll
    $bareName = Split-Path $dll -Leaf
    if ($dll -notmatch '^WinUI3Apps/') {
        Assert-Absent (Join-Path $winUI3Root $bareName) "$bareName（误入 WinUI3Apps）"
    } else {
        Assert-Absent (Join-Path $outputRoot $bareName) "$bareName（误入安装根目录）"
    }
}

Write-Host ''
Write-Host '[3/3] 安装包（只发布每用户引导程序）'
# 不用 -Include：在「-LiteralPath + -Recurse」且路径不含通配符时它不会真正过滤。
$candidates = @(Get-ChildItem -LiteralPath $installerRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Extension -in '.exe', '.msi' -and
        $_.FullName -notmatch '\\obj\\' -and
        $_.Name -match '^PowerToys(User)?Setup-'
    })

# 注意 'PowerToysSetup-*' 不会匹配 'PowerToysUserSetup-*'，两者前缀不同。
if ([string]::IsNullOrWhiteSpace($Version)) {
    $perUserPattern = '^PowerToysUserSetup-'
} else {
    $perUserPattern = "^PowerToysUserSetup-$([regex]::Escape($Version))-"
}
$perUserPackages = @($candidates | Where-Object { $_.Name -match $perUserPattern })
$machinePackages = @($candidates | Where-Object { $_.Name -match '^PowerToysSetup-' })

# 现在只发布引导程序（.exe）。.msi 仍会被构建，但只是它的内嵌载荷，不再单独发布 ——
# 所以这里把 .exe 当作必要条件，.msi 只作为信息列出（避免"msi 有、exe 丢了"却校验通过）。
$perUserBundles = @($perUserPackages | Where-Object { $_.Extension -eq '.exe' })
$perUserMsis = @($perUserPackages | Where-Object { $_.Extension -eq '.msi' })

if ($perUserBundles.Count -eq 0) {
    Write-Host "  [FAIL] 在 $installerRoot 下没找到每用户引导程序（PowerToysUserSetup-*.exe）" -ForegroundColor Red
    $script:Failures.Add('未生成每用户引导程序（.exe）') | Out-Null
} else {
    foreach ($file in $perUserBundles) {
        Write-Host ("  [ ok ] {0}  ({1} MB)" -f $file.Name, [math]::Round($file.Length / 1MB, 1)) -ForegroundColor Green
    }
}

foreach ($file in $perUserMsis) {
    Write-Host ("  [info] {0}  ({1} MB) —— 内嵌在引导程序里，未单独发布" -f $file.Name, [math]::Round($file.Length / 1MB, 1))
}

foreach ($file in $machinePackages) {
    Write-Host ("  [FAIL] 不应存在的每机器安装包：{0}" -f $file.Name) -ForegroundColor Red
    $script:Failures.Add("生成了每机器安装包（$($file.Name)）") | Out-Null
}

# 默认安装目录：补丁若没生效，装出来的位置就不是我们承诺的那个，所以在这里确认一次。
# 查的是引导程序的定义（源码），不是产物 —— 这个值最终被编译进 .exe，从产物里读不出来。
$defaultInstallDir = ''
if ($manifest.PSObject.Properties.Name -contains 'defaultInstallDir') {
    $defaultInstallDir = [string]$manifest.defaultInstallDir
}
if (-not [string]::IsNullOrWhiteSpace($defaultInstallDir)) {
    $bundleWxs = Join-Path $RepoRoot 'installer\PowerToysSetupVNext\PowerToys.wxs'
    $target = $defaultInstallDir.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $bundleWxs -PathType Leaf)) {
        Write-Host ("  [FAIL] 找不到引导程序定义：{0}" -f $bundleWxs) -ForegroundColor Red
        $script:Failures.Add('找不到 installer/PowerToysSetupVNext/PowerToys.wxs') | Out-Null
    } elseif ([System.IO.File]::ReadAllText($bundleWxs) -match ('<Variable\s+Name="InstallFolder"\s+Type="formatted"\s+Value="' + [regex]::Escape($target) + '"')) {
        Write-Host ("  [ ok ] 默认安装目录：{0}" -f $target) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] 引导程序里的默认安装目录不是 {0}" -f $target) -ForegroundColor Red
        $script:Failures.Add("默认安装目录未生效（期望 $target）") | Out-Null
    }
}

Write-Host ''
Write-Host ('构建输出体积：{0} MB（其中 WinUI3Apps {1} MB）' -f (Get-DirectorySizeMb $outputRoot), (Get-DirectorySizeMb $winUI3Root))
Write-Host ''

if ($script:Failures.Count -gt 0) {
    Write-Host "校验未通过，共 $($script:Failures.Count) 个问题：" -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host '校验通过：构建产物与 enabled-tools.txt 的选择一致。' -ForegroundColor Green
exit 0
