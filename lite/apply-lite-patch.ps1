<#
.SYNOPSIS
    按 enabled-tools.txt 的选择，把一份干净的 PowerToys 上游源码裁剪成只包含指定工具的精简版。

.DESCRIPTION
    输入只有两样：
      · tools.catalog.json  —— 工具目录（数据文件，一般不用改）：每个工具需要哪些构建项目、哪些
                               安装包 .wxs、哪些模块 DLL。
      · enabled-tools.txt   —— 选择清单（使用者唯一需要编辑的文件）：一行一个工具 ID。

    脚本会先做两件事，再做修改：

    【A】把「目录 + 选择」合成为本次构建的有效配置。项目与模块 DLL 都是对着**当前检出的上游版本**
         现算出来的，不照抄目录里写死的路径——上游在版本之间会增删改名项目、会把模块在安装根目录
         与 WinUI3Apps 之间搬迁：
          buildProjects            = core.projects + 每个已启用工具 moduleDir 下现扫出的非测试项目
          publishProjects          = core.publishProjects + 已启用工具的 publishProjects
          installerWxs / …Groups   = 同上
          keptModuleDlls           = 已启用工具的 moduleDllNames，在 knownModules 里查出的真实路径
          unselectedModuleDlls     = 未启用工具同上（用于产物反向校验）

    【B】用上游源码校验目录是否仍然对得上（发现问题就把所有问题一次列全后退出）：
          · 已启用的工具在当前上游版本里确实存在（模块目录、可构建项目、模块 DLL 名）
          · 本体项目与 publish 项目文件都存在
          · 每个 .wxs 文件都存在
          · 组件分组与 .wxs 双向一致（既不缺声明，也不会有声明了却没被打包的分组）
          · 上游新增了但目录里没登记的工具 —— 仅告警

    然后才做修改（只做减法，完全幂等）。它只改动 13 个文件：

      1. src/runner/main.cpp
         knownModules 是硬编码列表。Release 构建下每个加载失败的模块都会弹一个模态错误框，
         因此必须把列表裁剪成只保留已启用的模块。
      2. installer/PowerToysSetupVNext/PowerToysInstallerVNext.wixproj
         - PreBuildEvent 置空：它原本会调用 publish.cmd（发布预览处理器）与 generateMonacoWxs.ps1
           （抓取 Monaco 资源），精简版既不需要它们，它们还会污染产物。
         - <Compile Include="*.wxs" /> 改为允许清单，剔除不再打包的模块的 wxs。
      3. installer/PowerToysSetupVNext/Product.wxs
         - CoreFeature 的 <ComponentGroupRef> 改为允许清单。
         - 移除修剪后已无人使用、也无卸载清理的 <Directory> 声明：
           目录会照旧在用户 profile 下创建，但内容与 <RemoveFolder> 都随模块一起没了，
           每用户安装包会因 ICE64（WIX0204）失败。
         - 移除 DSC 自定义动作（SetInstallDSCModuleParam / InstallDSCModule / UninstallDSCModule）。
           这几个动作被 <?if $(var.PerUser) = "true" ?> 包着——只打每用户包时它们会真正生效，
           而 InstallDSCModuleCA 要从安装目录的 DSCModules 复制 psd1/psm1（精简版不部署该目录），
           结果是每次安装都记一条失败日志，并留下一个空的 PowerShell 模块目录。
      4. installer/PowerToysSetupVNext/Core.wxs
         移除 DSC（Microsoft.PowerToys.Configure）组件。DSC 清单由 .pipelines/generateDscManifests.ps1
         在 CI 中生成，精简版不构建它，留着会因源文件缺失导致 WIX0103 而打包失败。
      5. installer/PowerToysSetupVNext/BaseApplications.wxs
         移除 Command Palette 的 .winmd 组件 —— 但如果 enabled-tools.txt 里启用了 cmdpal，
         这一步会自动跳过（那时这个 winmd 是必需的）。
      6. installer/PowerToysSetupVNext/generateAllFileComponents.ps1
         增加“源目录不存在则跳过”的保护。否则某模块被裁掉后，脚本会退化成 Get-ChildItem $null
         （等于扫描当前目录），把无关文件塞进安装包。
      7. src/Version.props
         写入版本号，让 MSI / Bootstrapper 的文件名与上游 Release 版本一致。
      8. installer/PowerToysSetupVNext/WinAppSDK.wxs
         WinAppSDKLocLanguageList 是一份硬编码的 56 种语言清单（和 Resources.wxs 的
         LocLanguageList 是两回事，后者随 Resources.wxs 一起不再编译了，前者仍然生效）。
         每个语言都会生成一个 WinUI3Apps\<lang> 目录、一个含 2 个 .mui 的组件和一个
         <RemoveFolder>，所以只保留 -KeepLanguages 指定的语言。
      9. src/common/utils/modulesRegistry.h
         「安装」用的 getAllOnByDefaultModulesChangeSets 里每一项都属于已移除模块
         （FileExplorerPreview 的 SVG/Markdown/Monaco/PDF/GCode/BGCode/QOI 预览与缩略图处理器、
         以及 RegistryPreview），它们指向的 DLL 已经不再打包，装上反而留下指向不存在文件的
         COM 注册。清空它即可；「卸载」用的 getAllModulesChangeSets 保持原样，
         这样从旧版升级上来的机器仍能清掉之前写进去的键。
      10. src/common/updating/updating.cpp
          更新检查默认打官方仓库（microsoft/PowerToys），会让精简版提示——甚至自动下载安装——
          官方完整版。改为 -UpdateSourceRepo 指定的仓库，并让版本解析接受我们的 lite-v<ver> 标签。
      11. src/settings-ui/Settings.UI.Library/EnabledModules.cs
          每个字段的初始值就是「默认启用」（文件注释写明了）。设置界面没有「已安装模块」过滤，
          开关状态就取自这份默认值，于是裁掉模块后界面上会留下一堆「已启用」的幽灵条目。
          把默认值为 true 的字段收敛到本次打包的工具，其余改回默认关闭。
      12. src/runner/UpdateUtils.cpp
          内置更新器在提权安装前要求安装包由 Microsoft Corporation 签名，而精简版不做代码签名，
          所以「下载并自动安装」必然失败。改为：两个检查入口都不再自动下载，且 LaunchPowerToysUpdate
          （设置界面与通知按钮共用的唯一入口）改为打开发布页。
      13. installer/PowerToysSetupVNext/PowerToys.wxs
          仅当 -DefaultInstallDir 指定时：改引导程序里 InstallFolder 的默认值（上游为
          [LocalAppDataFolder]PowerToys）。安装界面 Options 页的路径输入框与传给 MSI 的
          BOOTSTRAPPERINSTALLFOLDER 都取自它，所以 MSI 侧不用动。变量保持可覆盖，
          用户仍可在界面或命令行改路径。

    注意：本文件必须保存为 “UTF-8 with BOM”，否则 Windows PowerShell 5.1 会按 ANSI 解码中文而报语法错误。

.PARAMETER RepoRoot
    上游 PowerToys 源码根目录（绝对路径）。

.PARAMETER CatalogPath
    工具目录路径，默认与本脚本同目录的 tools.catalog.json。

.PARAMETER SelectionPath
    选择清单路径，默认与本脚本同目录的 enabled-tools.txt。

.PARAMETER Version
    可选。形如 0.95.1 的版本号，写入 src/Version.props。

.EXAMPLE
    # 直接沿用 enabled-tools.txt 的选择
    ./apply-lite-patch.ps1 -RepoRoot C:\src\PowerToys -Version 0.95.1

.EXAMPLE
    # 临时换一份清单，不动仓库里的文件
    ./apply-lite-patch.ps1 -RepoRoot C:\src\PowerToys -SelectionPath .\my-tools.txt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    # 留空表示使用与本脚本同目录的默认文件。
    # 注意：Windows PowerShell 5.1 在 param() 默认值里取不到 $PSScriptRoot，所以放到脚本正文解析。
    [string]$CatalogPath = '',

    [string]$SelectionPath = '',

    # 更新检查指向的仓库（owner/name）。留空 = 不改动更新源。
    # 工作流会传自己所在的仓库，这样 fork 出去也能正确指向自己。
    [string]$UpdateSourceRepo = '',

    # 安装包的**默认**安装位置，形如 D:\PowerToys。留空 = 保持上游默认值（每用户包是
    # %LOCALAPPDATA%\PowerToys）。只影响默认值：变量仍是 bal:Overridable="yes"，
    # 用户可以在安装界面的 Options 页改，或命令行 InstallFolder="..." 覆盖。
    # 我们只出每用户包（InstallPrivileges=limited，不提权），所以必须是当前用户可写的位置。
    [string]$DefaultInstallDir = '',

    # 把 .NET / WinUI3 应用从「自包含」改成「框架依赖」，不再把运行时打进包里。
    # 见下方 Patch-FrameworkDependent 的完整说明。
    # 默认关闭 —— 开启后机器上必须预装运行时，否则应用起不来，
    # 因此只适合「自用且能提权」的场景。
    [switch]$FrameworkDependent,

    # WinAppSDK.wxs 里保留的本地化语言，分号分隔。
    # 每个语言会带来一个目录 + 2 个 .mui 文件 + 一个 RemoveFolder，别留用不到的。
    # 必须是上游清单里确实存在、且有分支能生成合法 Id 的语言，否则脚本会报错。
    [string]$KeepLanguages = 'en-us;zh-CN;zh-TW',

    [string]$Version = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScriptDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ScriptDirectory)) {
    $script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    $CatalogPath = Join-Path $script:ScriptDirectory 'tools.catalog.json'
}
if ([string]::IsNullOrWhiteSpace($SelectionPath)) {
    $SelectionPath = Join-Path $script:ScriptDirectory 'enabled-tools.txt'
}
$CatalogPath = [System.IO.Path]::GetFullPath($CatalogPath)
$SelectionPath = [System.IO.Path]::GetFullPath($SelectionPath)

$script:UpdateSourceRepo = ([string]$UpdateSourceRepo).Trim()

# 注意变量命名：param() 里的 [string]$KeepLanguages 带类型约束，直接往它赋数组会被
# 静默转回字符串（Set-StrictMode 下就会报 "The property 'Count' cannot be found"）。
# 所以另起一个名字存解析后的列表。
$script:KeepLanguageList = @($KeepLanguages -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
if ($script:KeepLanguageList.Count -eq 0) {
    throw '-KeepLanguages 不能为空；至少保留一种语言，否则 WinAppSDK 的资源会找不到。'
}

# ---------------------------------------------------------------------------
# 基础设施
# ---------------------------------------------------------------------------

$script:ChangeCount = 0

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    switch ($Level) {
        'ok'   { Write-Host "  [ lite ] $Message" -ForegroundColor Green }
        'skip' { Write-Host "  [ lite ] $Message" -ForegroundColor DarkGray }
        'warn' { Write-Host "  [ lite ] $Message" -ForegroundColor Yellow }
        default { Write-Host "  [ lite ] $Message" -ForegroundColor Cyan }
    }
}

function Resolve-RepoFile {
    param([string]$RelativePath)
    $full = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "找不到上游文件，PowerToys 目录结构可能已变化：$RelativePath"
    }
    return (Resolve-Path -LiteralPath $full).Path
}

function Read-TextFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }
    return [pscustomobject]@{ Text = $text; HasBom = $hasBom }
}

function Write-TextFile {
    param([string]$Path, [string]$Text, [bool]$HasBom)
    $encoding = New-Object System.Text.UTF8Encoding($HasBom)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

# 把字符串中的换行统一成 CRLF，避免插入到 CRLF 文件里出现混合换行。
function ConvertTo-Crlf {
    param([string]$Text)
    return ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
}

<#
    读取文件 -> 交给 Transform 改写 -> 有变化才写回。
    返回 $true 表示内容确实发生了变化。
#>
function Update-File {
    param(
        [string]$Path,
        [scriptblock]$Transform,   # [string] -> [string]
        [string]$Description
    )

    $file = Read-TextFile -Path $Path
    $result = @(& $Transform $file.Text)
    if ($result.Count -ne 1) {
        throw "Transform 必须返回且仅返回一个字符串（$Description），实际返回 $($result.Count) 个对象。"
    }

    $updated = [string]$result[0]
    if ($updated -eq $file.Text) {
        Write-Log "$Description —— 已是最新，跳过" -Level skip
        return $false
    }

    Write-TextFile -Path $Path -Text $updated -HasBom $file.HasBom
    Write-Log "$Description —— 已应用" -Level ok
    $script:ChangeCount++
    return $true
}

<#
    按允许清单过滤形如 <Tag ... Attr="Value" ... /> 的自闭合元素。
    不在清单内的整行（含缩进与换行）被删除，清单内的原样保留。
    这样上游新增的元素会被自动剔除，升级时通常无需改脚本。
#>
function Filter-SelfClosingElements {
    param(
        [string]$Text,
        [string]$ElementName,
        [string]$AttributeName,
        [string[]]$AllowedValues,
        [string]$Comment
    )

    $pattern = '(?m)^[ \t]*<' + [regex]::Escape($ElementName) + '[ \t]+' +
               [regex]::Escape($AttributeName) + '="([^"]+)"[^>]*/>[ \t]*\r?\n'

    $allowed = @($AllowedValues)
    $removed = New-Object System.Collections.Generic.List[string]

    $evaluator = {
        param($match)
        $value = $match.Groups[1].Value
        if ($allowed -contains $value) { return $match.Value }
        $removed.Add($value) | Out-Null
        return ''
    }

    $result = [regex]::Replace($Text, $pattern, $evaluator)
    if ($removed.Count -gt 0) {
        Write-Log "  $Comment 剔除 $($removed.Count) 项：$([string]::Join(', ', $removed))" -Level skip
    }
    return $result
}

function Add-UniqueValues {
    param(
        [System.Collections.Generic.List[string]]$Target,
        [System.Collections.Generic.HashSet[string]]$Seen,
        $Values
    )
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($Seen.Add($value)) { $Target.Add($value) | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# 读取工具目录与选择清单
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "PowerToys 源码目录不存在：$RepoRoot"
}
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
    throw "工具目录不存在：$CatalogPath"
}
if (-not (Test-Path -LiteralPath $SelectionPath -PathType Leaf)) {
    throw "选择清单不存在：$SelectionPath"
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$allTools = @($catalog.tools)

if ($allTools.Count -eq 0) { throw "工具目录里没有任何工具：$CatalogPath" }

$toolIndex = @{}
foreach ($tool in $allTools) {
    if ([string]::IsNullOrWhiteSpace($tool.id)) { throw "工具目录里有条目缺少 id：$CatalogPath" }
    if ($toolIndex.ContainsKey($tool.id)) { throw "工具目录里有重复的 id：$($tool.id)" }
    $toolIndex[$tool.id] = $tool
}

# 选择清单是纯文本：忽略 # 之后的内容，去掉空白行。
#
# 工具 ID 大小写不敏感地映射到目录里的规范写法：上游的模块目录名大小写并不统一
# （peek 全小写、PowerOCR 是驼峰），写错大小写时给出提示并按规范写法处理，
# 而不是静默地一个工具都不启用。
$canonicalIds = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($tool in $allTools) { $canonicalIds[$tool.id] = $tool.id }

$selectedIds = New-Object System.Collections.Generic.List[string]
$unknownIds = New-Object System.Collections.Generic.List[string]

foreach ($rawLine in [System.IO.File]::ReadAllLines($SelectionPath)) {
    $line = $rawLine
    $hash = $line.IndexOf('#')
    if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
    $line = $line.Trim()
    if ($line.Length -eq 0) { continue }

    $canonical = ''
    if ($canonicalIds.TryGetValue($line, [ref]$canonical)) {
        if ($canonical -cne $line) {
            Write-Log "选择清单里的 $line 已按目录中的规范写法 $canonical 处理" -Level warn
        }
        if (-not $selectedIds.Contains($canonical)) { $selectedIds.Add($canonical) | Out-Null }
    } elseif (-not $unknownIds.Contains($line)) {
        $unknownIds.Add($line) | Out-Null
    }
}

if ($unknownIds.Count -gt 0) {
    $selectionName = [System.IO.Path]::GetFileName($SelectionPath)
    $validIds = ($allTools | ForEach-Object { $_.id } | Sort-Object) -join ', '
    throw ("$selectionName 里有 $($unknownIds.Count) 个无法识别的工具 ID：`n" +
           "    $([string]::Join("`n    ", $unknownIds))`n`n" +
           "可用的工具 ID（完整说明见 tools.catalog.json）：`n    $validIds")
}

$enabledTools  = @($allTools | Where-Object { $selectedIds.Contains($_.id) })
$disabledTools = @($allTools | Where-Object { -not $selectedIds.Contains($_.id) })

# ---------------------------------------------------------------------------
# 合成有效配置
#
# 这里刻意「现算」而不是照抄目录里写的路径，因为上游在不同版本之间一直在动：
#   · 构建项目 —— 扫描 moduleDir 下的非测试项目。项目文件会增删改名（例如 PowerOCR.Core
#                 只存在于 main，最新的 Release 上还没有），写死路径会让目录一升级就失效。
#   · 模块 DLL —— 目录里只存文件名，这里在 runner 的 knownModules 中按名查出该版本真实的
#                 相对路径。上游会把模块在安装根目录与 WinUI3Apps 之间搬迁
#                 （例如 PowerToys.MouseJump.dll → WinUI3Apps/PowerToys.MouseJump.dll）。
# ---------------------------------------------------------------------------

$installerDirRelative = 'installer/PowerToysSetupVNext'

# 排除测试 / 模板 / 示例项目：相对模块目录的路径中任一片段命中即跳过
$script:ProjectExcludePattern = '(?i)(test|fuzz)|(^|/)(obj|template|samplepages|processmonitor)(/|$)'

function Read-KnownModules {
    $mainCppPath = Join-Path $RepoRoot 'src/runner/main.cpp'
    if (-not (Test-Path -LiteralPath $mainCppPath -PathType Leaf)) {
        throw '找不到 src/runner/main.cpp，无法解析模块清单。'
    }
    $text = [System.IO.File]::ReadAllText($mainCppPath)
    $block = [regex]::Match($text, '(?s)std::vector<std::wstring_view>\s+knownModules\s*=\s*\{(.*?)\};')
    if (-not $block.Success) {
        throw '无法解析 src/runner/main.cpp 的 knownModules 初始化块，上游可能改了模块加载方式。'
    }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($block.Groups[1].Value, 'L"([^"]+)"')) {
        $list.Add($match.Groups[1].Value) | Out-Null
    }
    return , $list
}

# 把模块目录下应当构建的项目加入 Target，返回新增数量；目录不存在返回 -1
function Add-ModuleProjects {
    param(
        [string]$ModuleDir,
        [System.Collections.Generic.List[string]]$Target,
        [System.Collections.Generic.HashSet[string]]$Seen
    )

    $root = Join-Path $RepoRoot $ModuleDir
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return -1 }

    $prefixLength = $ModuleDir.Length + 1
    $added = 0
    # 注意：Get-ChildItem 的 -Include 在「-LiteralPath + -Recurse」且路径不含通配符时不会真正过滤，
    # 会把目录下所有文件都返回。实测确认过，所以这里显式按扩展名筛。
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.csproj', '.vcxproj' })
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($RepoRoot.Length + 1).Replace('\', '/')
        if ($relative.Length -le $prefixLength) { continue }
        $tail = $relative.Substring($prefixLength)
        if ($tail -match $script:ProjectExcludePattern) { continue }
        if ($Seen.Add($relative)) {
            $Target.Add($relative) | Out-Null
            $added++
        }
    }
    return $added
}

# 在 knownModules 里按文件名查出该版本真实的相对路径；找到返回 $true
function Resolve-ModuleDllName {
    param(
        [string]$DllName,
        [System.Collections.Generic.List[string]]$KnownModules,
        [System.Collections.Generic.List[string]]$Target,
        [System.Collections.Generic.HashSet[string]]$Seen
    )
    $hits = @($KnownModules | Where-Object { (Split-Path -Leaf $_) -ieq $DllName })
    if ($hits.Count -eq 0) { return $false }
    if ($Seen.Add($hits[0])) { $Target.Add($hits[0]) | Out-Null }
    return $true
}

$buildProjects   = New-Object System.Collections.Generic.List[string]
$publishProjects = New-Object System.Collections.Generic.List[string]
$installerWxs    = New-Object System.Collections.Generic.List[string]
$installerGroups = New-Object System.Collections.Generic.List[string]
$keptModuleDlls  = New-Object System.Collections.Generic.List[string]
$droppedModules  = New-Object System.Collections.Generic.List[string]
$missingTools    = New-Object System.Collections.Generic.List[string]

$sBuild   = New-Object 'System.Collections.Generic.HashSet[string]'
$sPublish = New-Object 'System.Collections.Generic.HashSet[string]'
$sWxs     = New-Object 'System.Collections.Generic.HashSet[string]'
$sGroup   = New-Object 'System.Collections.Generic.HashSet[string]'
$sDll     = New-Object 'System.Collections.Generic.HashSet[string]'
$sDropped = New-Object 'System.Collections.Generic.HashSet[string]'

$knownModules = Read-KnownModules

Add-UniqueValues $buildProjects   $sBuild   $catalog.core.projects
Add-UniqueValues $publishProjects $sPublish $catalog.core.publishProjects
Add-UniqueValues $installerWxs    $sWxs     $catalog.core.installerWxs
Add-UniqueValues $installerGroups $sGroup   $catalog.core.installerComponentGroups

foreach ($tool in $enabledTools) {
    $dllNames = @($tool.moduleDllNames)

    $projectCount = Add-ModuleProjects -ModuleDir $tool.moduleDir -Target $buildProjects -Seen $sBuild
    if ($projectCount -lt 0) {
        $missingTools.Add("$($tool.id) —— 源码目录不存在：$($tool.moduleDir)") | Out-Null
        continue
    }
    if ($projectCount -eq 0) {
        $missingTools.Add("$($tool.id) —— $($tool.moduleDir) 下没有可构建的项目") | Out-Null
        continue
    }

    # 一个工具可能对应多个模块 DLL（例如 MouseUtils 是 6 个鼠标工具一组）。
    # 上游会在版本之间新增/移除子模块，所以规则是：
    #   · 一个都解析不到 —— 整个工具在当前版本不存在，报错
    #   · 部分解析不到 —— 只是那些子功能还没被上游引入，降级为警告
    $missingDllNames = New-Object System.Collections.Generic.List[string]
    $resolvedCount = 0
    foreach ($dllName in $dllNames) {
        if (Resolve-ModuleDllName -DllName $dllName -KnownModules $knownModules -Target $keptModuleDlls -Seen $sDll) {
            $resolvedCount++
        } else {
            $missingDllNames.Add($dllName) | Out-Null
        }
    }
    if ($resolvedCount -eq 0) {
        $missingTools.Add("$($tool.id) —— runner 的 knownModules 里找不到任何模块 DLL：$([string]::Join(', ', $dllNames))") | Out-Null
        continue
    }
    if ($missingDllNames.Count -gt 0) {
        Write-Log ("{0}：当前上游版本还没有这些子模块，会被跳过：{1}" -f $tool.id, [string]::Join(', ', $missingDllNames)) -Level warn
    }

    Add-UniqueValues $publishProjects $sPublish $tool.publishProjects
    Add-UniqueValues $installerWxs    $sWxs     $tool.installerWxs
    Add-UniqueValues $installerGroups $sGroup   $tool.installerComponentGroups
}

foreach ($tool in $disabledTools) {
    foreach ($dllName in @($tool.moduleDllNames)) {
        # 未启用的工具在当前版本里不存在也没关系，跳过即可
        Resolve-ModuleDllName -DllName $dllName -KnownModules $knownModules -Target $droppedModules -Seen $sDropped | Out-Null
    }
}

# 已启用的工具在 runner 里加载，不需要再作为「应缺失」来检查
$droppedModules = @($droppedModules | Where-Object { -not $sDll.Contains($_) })

if ($enabledTools.Count -eq 0) {
    Write-Log '没有启用任何工具：只会打包 PowerToys 本体（运行器 + 设置界面）。' -Level warn
}

# ---------------------------------------------------------------------------
# 找出构建期被 <MSBuild> 任务调起的辅助项目（只需单独还原，不需要单独构建）
# ---------------------------------------------------------------------------
# 有些项目不是通过 ProjectReference 引入的，而是在编译前被 <MSBuild Projects="..."> 任务临时调起。
# 例如 PowerToys.Settings.csproj 会在 CoreCompile 之前调起 Settings.UI.XamlIndexBuilder 去生成
# 设置页的搜索索引，而它不是 ProjectReference，所以主项目的 -restore 不会顺带还原它，于是报：
#   NETSDK1004: Assets file '...\obj\project.assets.json' not found.
# 这里把这类项目从待构建的项目里扫出来，写进清单交给工作流单独还原。
function Get-BuildTimeHelperProjects {
    $helpers = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($project in @($buildProjects) + @($publishProjects)) {
        $full = Join-Path $RepoRoot $project
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $projectDir = Split-Path -Parent $full
        $text = [System.IO.File]::ReadAllText($full)

        foreach ($match in [regex]::Matches($text, '<MSBuild\s+Projects="([^"]+)"')) {
            # 路径可能是相对的，也可能写成 $(MSBuildProjectDirectory)\..\X\X.csproj
            $candidate = $match.Groups[1].Value -replace '\$\(MSBuildProjectDirectory\)', $projectDir
            if (-not [System.IO.Path]::IsPathRooted($candidate)) {
                $candidate = Join-Path $projectDir $candidate
            }
            $resolved = [System.IO.Path]::GetFullPath($candidate)
            if ($resolved -notmatch '\.(csproj|vcxproj)$') { continue }
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }

            $relative = $resolved.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            # 已经在构建/发布清单里的会被 -restore 顺带还原，不必重复
            if ($sBuild.Contains($relative) -or $sPublish.Contains($relative)) { continue }
            if ($seen.Add($relative)) { $helpers.Add($relative) | Out-Null }
        }
    }

    return $helpers
}

$restoreProjects = @(Get-BuildTimeHelperProjects)

# ---------------------------------------------------------------------------
# 框架依赖模式：把 WinAppSDK 自己的安装包定义整个摘掉
# ---------------------------------------------------------------------------
# 原因：WinAppSDK.wxs 是**手写**的，它要把 Windows App SDK 自己的文件装进 WinUI3Apps\：
#   · Microsoft.UI.Xaml\Assets\*.png|html
#   · 56 种语言各自的 <lang>\Microsoft.ui.xaml.dll.mui 等
# 这些文件来自「自包含」的 Windows App SDK，改成框架依赖后**根本不会出现在发布产物里**，
# 于是那份 wxs 就变成一堆指向不存在文件的 <File Source=...>，MSI 编译直接报：
#   WIX0103: Cannot find the File file '...\WinUI3Apps\en-us\Microsoft.ui.xaml.dll.mui'
# 同理，它定义的 WindowsAppSDKComponentGroup 也不该再被 CoreFeature 引用
# （运行时交给机器上的 Windows App Runtime）。
#
# 必须放在这里（清单刚构建完），而不是放进 Patch-FrameworkDependent —— 因为
# 下面的 <Compile> 允许清单和 <ComponentGroupRef> 允许清单都取自这两个变量，
# 而后面的一致性校验也会检查「清单里的分组与实际编译的 wxs 是否对得上」，
# 所以两边必须一起、且在校验之前摘掉。
if ($FrameworkDependent) {
    $removedWxs = @($installerWxs | Where-Object { $_ -match 'WinAppSDK\.wxs$' })
    foreach ($item in $removedWxs) { $installerWxs.Remove($item) | Out-Null }

    $removedGroups = @($installerGroups | Where-Object { $_ -eq 'WindowsAppSDKComponentGroup' })
    foreach ($group in $removedGroups) { $installerGroups.Remove($group) | Out-Null }

    Write-Log "框架依赖：WinAppSDK.wxs 不再编译（摘掉 $($removedWxs.Count) 个 wxs、$($removedGroups.Count) 个组件分组）；运行时改由系统上的 Windows App Runtime 提供。"
}

# ---------------------------------------------------------------------------
# 定出 NuGet 还原计划：本次构建真正需要哪些包，以及该还原哪几份 packages.config
# ---------------------------------------------------------------------------
# 仓库里有 90+ 份 packages.config，但绝大多数属于「没启用的工具」和 CI 自己的配置。
# 全部还原一遍不只是慢，还会下载几百 MB 用不到的包（实测：XamlApplication 185MB、
# Microsoft.UI.Xaml 123MB、WebView2 54MB，以及我们根本不用的 MSBuildCache 三件套 166MB），
# 并且会碰到取不到的微软内部包（.pipelines 里的 Microsoft.PowerToys.Telemetry → 401）。
#
# 所以改成闭包驱动，分两步：
#   1. 需要的包 —— 本次要构建的项目（含传递 ProjectReference、以及被 <MSBuild> 调起的项目）里出现的
#        $(RepoRoot)packages\<Id.Version>    packages.config 的还原目标（Id.Version 布局）
#        $(NUGET_PACKAGES)\<id>\<version>    全局缓存（CustomActions 靠它找 wcautil.lib / dutil.lib）
#   2. 要还原的配置 —— 每个需要的包，挑一份声明它的 packages.config 就够了。
#      因为包目录是共享的：nuget restore <任一配置> -PackagesDirectory <仓库根>\packages 装出来的
#      Id.Version 目录并不区分「由哪个项目声明」。
#
# 这一步只负责「尽量少还原」。够不够由工作流里的权威校验把关：缺包会立刻报错，
# 并在那里回退成「全仓库都还原一遍」，所以这里的判断偏保守也不会静默产出坏包。
function Get-RequiredNuGetPackages {
    # --- 1) 遍历闭包（含传递引用）---
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $visited = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($project in @($buildProjects) + @($publishProjects) + @($restoreProjects)) { $queue.Enqueue($project) }

    $packageDirNames = New-Object System.Collections.Generic.List[string]
    $requiredKeys = New-Object 'System.Collections.Generic.HashSet[string]'

    while ($queue.Count -gt 0) {
        $relative = $queue.Dequeue()
        if (-not $visited.Add($relative)) { continue }
        $full = Join-Path $RepoRoot $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $projectDir = Split-Path -Parent $full
        $text = [System.IO.File]::ReadAllText($full)

        foreach ($match in [regex]::Matches($text, '\$\(RepoRoot\)packages\\([^\\"]+)')) {
            $dirName = $match.Groups[1].Value
            if (-not $packageDirNames.Contains($dirName)) { $packageDirNames.Add($dirName) | Out-Null }
            $requiredKeys.Add($dirName.ToLowerInvariant()) | Out-Null
        }
        foreach ($match in [regex]::Matches($text, '\$\(NUGET_PACKAGES\)\\([^\\"$]+)\\([^\\"$]+)')) {
            $key = ($match.Groups[1].Value + '.' + $match.Groups[2].Value).ToLowerInvariant()
            $requiredKeys.Add($key) | Out-Null
        }

        foreach ($match in [regex]::Matches($text, '<(?:ProjectReference\s+Include|MSBuild\s+Projects)="([^"]+)"')) {
            $candidate = $match.Groups[1].Value -replace '\$\(MSBuildProjectDirectory\)', $projectDir
            if ($candidate -match '\$') { continue }
            if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $projectDir $candidate }
            if ($candidate -notmatch '\.(csproj|vcxproj|wixproj)$') { continue }
            $resolved = [System.IO.Path]::GetFullPath($candidate)
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
            $childRelative = $resolved.Substring($RepoRoot.Length) -replace '^[\\/]+', '' -replace '\\', '/'
            $queue.Enqueue($childRelative)
        }
    }

    # --- 2) 每个需要的包挑一份声明它的 packages.config ---
    # 按路径排序后再挑，保证多次运行结果稳定（幂等）。
    $allConfigs = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter 'packages.config' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'packages.config' -and $_.FullName -notmatch '\\packages\\|\\obj\\' } |
        Sort-Object -Property FullName)

    $chosen = New-Object System.Collections.Generic.List[string]
    $coveredKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($config in $allConfigs) {
        if ($coveredKeys.Count -ge $requiredKeys.Count) { break }
        $text = [System.IO.File]::ReadAllText($config.FullName)
        $hit = $false
        foreach ($match in [regex]::Matches($text, '<package\s+id="([^"]+)"\s+version="([^"]+)"')) {
            $key = ($match.Groups[1].Value + '.' + $match.Groups[2].Value).ToLowerInvariant()
            if ($requiredKeys.Contains($key) -and -not $coveredKeys.Contains($key)) {
                $coveredKeys.Add($key) | Out-Null
                $hit = $true
            }
        }
        if ($hit) {
            $configRelative = $config.FullName.Substring($RepoRoot.Length) -replace '^[\\/]+', '' -replace '\\', '/'
            $chosen.Add($configRelative) | Out-Null
        }
    }

    return [pscustomobject]@{
        PackageDirNames = @($packageDirNames)
        Configs         = @($chosen)
        MissingKeys     = @($requiredKeys | Where-Object { -not $coveredKeys.Contains($_) })
        TotalConfigs    = $allConfigs.Count
    }
}

# ---------------------------------------------------------------------------
# 用上游源码校验目录是否仍然对得上
# ---------------------------------------------------------------------------

function Test-CatalogAgainstRepo {
    $problems = New-Object System.Collections.Generic.List[string]

    # 1) 已启用的工具在当前上游版本里确实存在
    foreach ($missing in $missingTools) {
        $problems.Add("当前上游版本里没有这个工具：$missing") | Out-Null
    }

    # 2) 显式写出的项目路径存在（本体项目与 publish 项目）
    foreach ($p in @($catalog.core.projects)) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $p) -PathType Leaf)) {
            $problems.Add("本体项目不存在：$p") | Out-Null
        }
    }
    foreach ($p in $publishProjects) {
        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $p) -PathType Leaf)) {
            $problems.Add("发布项目不存在：$p") | Out-Null
        }
    }

    # 3) .wxs 文件存在，并收集它们声明的组件分组
    $declaredGroups = @{}
    foreach ($w in $installerWxs) {
        $wxsFullPath = Join-Path $RepoRoot (Join-Path $installerDirRelative $w)
        if (-not (Test-Path -LiteralPath $wxsFullPath -PathType Leaf)) {
            $problems.Add("安装包定义不存在：$installerDirRelative/$w") | Out-Null
            continue
        }
        $wxsText = [System.IO.File]::ReadAllText($wxsFullPath)
        foreach ($match in [regex]::Matches($wxsText, '<ComponentGroup[ \t]+Id="([^"]+)"')) {
            $declaredGroups[$match.Groups[1].Value] = $w
        }
    }

    # 4) 组件分组双向一致
    foreach ($g in $installerGroups) {
        if (-not $declaredGroups.ContainsKey($g)) {
            $problems.Add("组件分组 $g 不在任何保留的 .wxs 中（检查 tools.catalog.json 的 installerComponentGroups）") | Out-Null
        }
    }
    foreach ($g in $declaredGroups.Keys) {
        if (-not $sGroup.Contains($g)) {
            $problems.Add("保留的 $($declaredGroups[$g]) 声明了组件分组 $g，但它不在 installerComponentGroups 中 —— 该分组的文件不会被打包") | Out-Null
        }
    }

    # 5) 上游新增了、但目录里没登记的工具 —— 只告警
    if ($knownModules.Count -gt 0) {
        $catalogNames = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($tool in $allTools) {
            foreach ($dllName in @($tool.moduleDllNames)) { $catalogNames.Add($dllName) | Out-Null }
        }
        foreach ($dll in $knownModules) {
            if (-not $catalogNames.Contains((Split-Path -Leaf $dll))) {
                Write-Log "上游有未登记进工具目录的模块，它不会被任何选择包含：$dll" -Level warn
            }
        }
    }

    return $problems
}

Write-Host ''
Write-Log "PowerToys 源码：$RepoRoot"
Write-Log "工具目录：$CatalogPath"
Write-Log "选择清单：$SelectionPath"
Write-Host ''

Write-Host '  [ lite ] 本次打包的工具：' -ForegroundColor Cyan
if ($enabledTools.Count -eq 0) {
    Write-Host '           （无，只打包 PowerToys 本体）' -ForegroundColor DarkGray
} else {
    foreach ($tool in $enabledTools) {
        $mark = '  '
        if (-not $tool.verified) { $mark = ' *' }
        Write-Host ("          {0}{1}  ({2})" -f $mark, $tool.id, $tool.displayName) -ForegroundColor Gray
    }
}

$unverifiedTools = @($enabledTools | Where-Object { -not $_.verified })
if ($unverifiedTools.Count -gt 0) {
    Write-Host ''
    Write-Log "带 * 的 $($unverifiedTools.Count) 个工具未端到端实测过：$([string]::Join(', ', @($unverifiedTools | ForEach-Object { $_.id })))" -Level warn
    Write-Log '它们通常可以直接用；若 CI 失败，请把该轮日志与 binlog 产物（打不开就先看日志末尾的抛错行）贴出来排查。' -Level warn
}

Write-Host ''
Write-Log "合成配置：构建项目 $($buildProjects.Count) 个 / 发布项目 $($publishProjects.Count) 个 / 安装包定义 $($installerWxs.Count) 个 / 组件分组 $($installerGroups.Count) 个 / 模块 DLL $($keptModuleDlls.Count) 个"
if ($restoreProjects.Count -gt 0) {
    Write-Log "另有构建期辅助项目 $($restoreProjects.Count) 个，需要单独还原：$([string]::Join(', ', $restoreProjects))"
}
Write-Host ''

Write-Log '校验工具目录与上游源码的一致性 ...'
$catalogProblems = @(Test-CatalogAgainstRepo)
if ($catalogProblems.Count -gt 0) {
    Write-Host ''
    Write-Host "工具目录与上游源码对不上，共 $($catalogProblems.Count) 个问题：" -ForegroundColor Red
    foreach ($problem in $catalogProblems) { Write-Host "    - $problem" -ForegroundColor Red }
    throw '请修正 tools.catalog.json（或 enabled-tools.txt 的选择）后重试。'
}
Write-Log '目录校验通过。' -Level ok
Write-Host ''

# ---------------------------------------------------------------------------
# 1. runner：裁剪 knownModules
# ---------------------------------------------------------------------------

function Patch-RunnerKnownModules {
    $path = Resolve-RepoFile 'src/runner/main.cpp'

    Update-File -Path $path -Description 'src/runner/main.cpp：裁剪 knownModules' -Transform {
        param([string]$text)

        $pattern = '(?s)(std::vector<std::wstring_view>\s+knownModules\s*=\s*\{).*?(\};)'
        if (-not [regex]::IsMatch($text, $pattern)) {
            throw 'src/runner/main.cpp 中找不到 knownModules 初始化块，上游可能改了模块加载方式。'
        }

        $entries = @($keptModuleDlls | ForEach-Object { '            L"' + $_ + '",' })
        $body = [string]::Join("`r`n", $entries)

        $evaluator = {
            param($m)
            return $m.Groups[1].Value + "`r`n" + $body + "`r`n        " + $m.Groups[2].Value
        }

        return [regex]::Replace($text, $pattern, $evaluator)
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 2. 安装包工程：PreBuildEvent 置空 + Compile 允许清单
# ---------------------------------------------------------------------------

function Patch-InstallerWixproj {
    $path = Resolve-RepoFile 'installer/PowerToysSetupVNext/PowerToysInstallerVNext.wixproj'

    Update-File -Path $path -Description 'PowerToysInstallerVNext.wixproj：裁剪安装包定义与预生成步骤' -Transform {
        param([string]$text)

        # 2a. PreBuildEvent 置空（跳过 publish.cmd 与 generateMonacoWxs.ps1）
        $text = [regex]::Replace($text, '(?s)<PreBuildEvent>.*?</PreBuildEvent>', '<PreBuildEvent></PreBuildEvent>')

        # 2b. 不再使用的 Monaco 抓取路径常量
        $text = $text -replace 'MonacoSRCHarvestPath=\$\(ProjectDir\)[^;"]*;', ''

        # 2c. <Compile Include="*.wxs" /> 允许清单
        $text = Filter-SelfClosingElements -Text $text -ElementName 'Compile' `
            -AttributeName 'Include' -AllowedValues $installerWxs `
            -Comment 'PowerToysInstallerVNext.wixproj：<Compile>'

        # 2d. PostBuildEvent 中对已剔除 wxs 的 .bk 还原动作
        $allowedNames = @($installerWxs | Where-Object { $_ -notmatch '[\\/]' })
        $text = [regex]::Replace($text, '(?m)^[ \t]*call move /Y [^\r\n]*?([A-Za-z0-9_]+\.wxs)\.bk[^\r\n]*\r?\n', `
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($m)
                if ($allowedNames -contains $m.Groups[1].Value) { return $m.Value }
                return ''
            })

        return $text
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 3. Product.wxs：CoreFeature 的组件分组允许清单
# ---------------------------------------------------------------------------

function Patch-ProductWxs {
    $path = Resolve-RepoFile 'installer/PowerToysSetupVNext/Product.wxs'

    Update-File -Path $path -Description 'Product.wxs：裁剪 CoreFeature 组件分组' -Transform {
        param([string]$text)
        return Filter-SelfClosingElements -Text $text -ElementName 'ComponentGroupRef' `
            -AttributeName 'Id' -AllowedValues $installerGroups `
            -Comment 'Product.wxs：<ComponentGroupRef>'
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 3b. Product.wxs：移除 DSC 自定义动作
# ---------------------------------------------------------------------------

function Patch-ProductWxsRemoveDsc {
    $path = Resolve-RepoFile 'installer/PowerToysSetupVNext/Product.wxs'

    Update-File -Path $path -Description 'Product.wxs：移除 DSC 自定义动作' -Transform {
        param([string]$text)

        # 这几个动作被 <?if $(var.PerUser) = "true" ?> 包着，只打每用户包时会真正生效：
        # InstallDSCModuleCA 要从安装目录的 DSCModules 复制 psd1/psm1，但精简版不部署该目录
        # （DscResources.wxs 已被剔除），于是每次安装都会记一条
        # "Couldn't install DSC module!" 失败日志，并留下一个空的 PowerShell 模块目录。
        $dscActions = @('SetInstallDSCModuleParam', 'InstallDSCModule', 'UninstallDSCModule')

        foreach ($action in $dscActions) {
            $sequencePattern = '\r?\n[ \t]*<\?if \$\(var\.PerUser\) = "true" \?>\r?\n' +
                               '[ \t]*<Custom Action="' + [regex]::Escape($action) + '"[^\r\n]*\r?\n[ \t]*<\?endif\?>'
            $text = [regex]::Replace($text, $sequencePattern, '')
        }

        # 序列里不再引用之后，这些 <CustomAction> 定义也一并清掉
        foreach ($action in $dscActions) {
            $definitionPattern = '(?m)^[ \t]*<CustomAction Id="' + [regex]::Escape($action) + '"[^\r\n]*\r?\n'
            $text = [regex]::Replace($text, $definitionPattern, '')
        }

        # 注意不能用 'DSCModule' 做断言：<Directory Id="DSCModulesReferenceFolder" ...> 要保留
        if ($text -match 'InstallDSCModule|UninstallDSCModule') {
            throw 'Product.wxs 中的 DSC 自定义动作未能完全移除，请检查上游是否改动。'
        }
        return $text
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 4. Core.wxs：移除 DSC 组件
# ---------------------------------------------------------------------------

function Patch-CoreWxsRemoveDsc {
    $path = Resolve-RepoFile 'installer/PowerToysSetupVNext/Core.wxs'

    Update-File -Path $path -Description 'Core.wxs：移除 DSC（Microsoft.PowerToys.Configure）组件' -Transform {
        param([string]$text)

        # 4a. 每机器安装时的 DSC PowerShell 模块落盘
        $blockPattern = '(?s)\r?\n[ \t]*<\?if \$\(var\.PerUser\) = "true" \?>\r?\n' +
                        '[ \t]*<!-- DSC module files for PerUser handled in InstallDSCModule custom action\. -->\r?\n' +
                        '[ \t]*<\?else\?>\r?\n.*?</StandardDirectory>\r?\n[ \t]*<\?endif\?>'
        $text = [regex]::Replace($text, $blockPattern, '')

        # 4b. CoreComponents 中对 DSC 组件的引用
        $refPattern = '(?s)\r?\n[ \t]*<\?if \$\(var\.PerUser\) = "false" \?>\r?\n' +
                      '[ \t]*<ComponentRef Id="PowerToysDSC" />\r?\n[ \t]*<\?endif\?>'
        $text = [regex]::Replace($text, $refPattern, '')

        if ($text -match 'Id="PowerToysDSC"') {
            throw 'Core.wxs 中的 DSC 组件未能完全移除，请检查上游是否改动。'
        }
        return $text
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 5. BaseApplications.wxs：移除 Command Palette winmd（启用 cmdpal 时跳过）
# ---------------------------------------------------------------------------

function Patch-BaseApplicationsRemoveCmdPal {
    if ($selectedIds.Contains('cmdpal')) {
        Write-Log 'BaseApplications.wxs：启用了 cmdpal，保留 Command Palette winmd 组件 —— 跳过' -Level skip
        return
    }

    $path = Resolve-RepoFile 'installer/PowerToysSetupVNext/BaseApplications.wxs'

    Update-File -Path $path -Description 'BaseApplications.wxs：移除 Command Palette winmd 组件' -Transform {
        param([string]$text)

        $blockPattern = '(?s)[ \t]*<!-- winmd must be in WinUI3Apps.*?</DirectoryRef>\r?\n'
        $text = [regex]::Replace($text, $blockPattern, '')

        $text = [regex]::Replace($text, '(?m)^[ \t]*<ComponentRef Id="Microsoft_CommandPalette_Extensions_winmd" />[ \t]*\r?\n', '')

        if ($text -match 'Microsoft_CommandPalette_Extensions_winmd') {
            throw 'BaseApplications.wxs 中的 CmdPal winmd 未能完全移除，请检查上游是否改动。'
        }
        return $text
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 6. generateAllFileComponents.ps1：源目录缺失时跳过抓取
# ---------------------------------------------------------------------------

function Patch-GenerateAllFileComponents {
    $path = Resolve-RepoFile 'installer/PowerToysSetupVNext/generateAllFileComponents.ps1'

    # 两个独立的改动各用各的 marker，各自幂等 —— 这样以后再加东西时，
    # 已经打过前一轮补丁的仓库也能补上，不会被一个笼统的 marker 挡住。
    Update-File -Path $path -Description 'generateAllFileComponents.ps1：补上 New-Guid 垫片与缺失源目录保护' -Transform {
        param([string]$text)

        # a) New-Guid 垫片。
        #    这个脚本是 CustomActions 的 PreBuildEvent 用
        #       powershell.exe -NonInteractive -executionpolicy Unrestricted -File ...
        #    调起的，宿主继承的是 VsDevCmd 之后的环境。实测该环境下连内置的 New-Guid 都解析不到
        #    —— 而同一个模块里的 Write-Host / Get-ChildItem 一切正常，说明是随 Windows 版本
        #    更新、尚未出现在旧宿主里的 cmdlet。用 [System.Guid]::NewGuid() 等价替代，
        #    免得整个打包流程卡在一个跟「精简」毫无关系的地方。
        $shimMarker = '[powertoys-lite] New-Guid 垫片'
        if (-not $text.Contains($shimMarker)) {
            $shimAnchor = 'Function Generate-FileList() {'
            if (-not $text.Contains($shimAnchor)) {
                throw 'generateAllFileComponents.ps1 的 Generate-FileList 定义已变化，找不到垫片插入点。'
            }

            $shim = @'
# [powertoys-lite] New-Guid 垫片：宿主没有这个 cmdlet 时补一个等价实现。
if (-not (Get-Command New-Guid -ErrorAction SilentlyContinue)) {
    function New-Guid { [System.Guid]::NewGuid() }
}

'@

            $text = $text.Replace($shimAnchor, (ConvertTo-Crlf $shim) + $shimAnchor)
        }

        # b) 缺失源目录保护。
        $guardMarker = '[powertoys-lite] 精简构建会删掉部分模块'
        if (-not $text.Contains($guardMarker)) {
            $anchor = '    $fileWxs = Get-Content $wxsFilePath;'
            if (-not $text.Contains($anchor)) {
                throw 'generateAllFileComponents.ps1 的 Generate-FileList 结构已变化，找不到插入锚点。'
            }

            $guard = @'
    # [powertoys-lite] 精简构建会删掉部分模块，其产物目录 / deps.json 随之消失。
    # 若不在这里提前返回，下面的 Get-ChildItem $fileDepsRoot 会因为 $fileDepsRoot 为 $null
    # 而退化成扫描“当前目录”，把无关文件塞进安装包。
    $liteProbe = if ($fileDepsJson -eq [string]::Empty) { $depsPath } else { $fileDepsJson }
    if (-not [string]::IsNullOrWhiteSpace($liteProbe)) {
        $liteMissing = @($liteProbe.Split(';') | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($liteMissing.Count -gt 0) {
            # 拼接出来的正则要保证括号平衡：曾经写成 "(<\?define ..." 少一个右括号，
            # 结果是 InvalidRegularExpression，-replace 静默失效（define 没被清空）。
            $litePattern = '<\?define ' + [regex]::Escape($fileListName) + '=[^?]*\?>'
            $fileWxs = $fileWxs -replace $litePattern, ('<?define ' + $fileListName + '=?>')
            Set-Content -Path $wxsFilePath -Value $fileWxs
            Write-Host "[powertoys-lite] skip $fileListName (missing: $($liteMissing -join ', '))"
            return
        }
    }

'@

            # 必须插在 $fileWxs 赋值之后，守卫里要用它回写空的 define。
            $text = $text.Replace($anchor, $anchor + "`r`n" + (ConvertTo-Crlf $guard))
        }

        return $text
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 7. 版本号
# ---------------------------------------------------------------------------

function Patch-VersionProps {
    if ([string]::IsNullOrWhiteSpace($Version)) {
        Write-Log 'src/Version.props：未指定版本号，保持上游默认值' -Level skip
        return
    }

    $path = Resolve-RepoFile 'src/Version.props'

    Update-File -Path $path -Description "src/Version.props：写入版本号 $Version" -Transform {
        param([string]$text)

        $pattern = '<Version>[^<]*</Version>'
        if ($text -notmatch $pattern) {
            throw 'src/Version.props 中找不到 <Version> 节点。'
        }
        return [regex]::Replace($text, $pattern, "<Version>$Version</Version>", 1)
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 7. 安装包目录声明：移除「已无人使用」的目录（每用户包 ICE64）
# ---------------------------------------------------------------------------

<#
    精简模块时，某些目录的「内容 + 卸载清理」是一起被剔除的 —— 例如 CliShims.wxs 里有
    <RemoveFolder>，而 CliShims.wxs 随模块一起不再参与编译 —— 但 <Directory> 声明还留在
    Product.wxs 里。结果是这个目录仍会在用户 profile 下被创建，却没有任何东西在卸载时清理它，
    每用户安装包报：

        WIX0204: ICE64: The directory X is in the user profile but is not listed in the RemoveFile table.

    判定口径与 WiX 的 ICE64 同源：只看真正参与编译的 wxs（$installerWxs）。找出来之后，连
    指向它们的悬空引用一起删掉 —— 既然没人往里面装东西，就不该创建它（延续补丁「只做减法」）。
#>
function Get-OrphanDirectoryIds {
    $installerDir = Join-Path $RepoRoot 'installer\PowerToysSetupVNext'
    $declared = New-Object 'System.Collections.Generic.HashSet[string]'
    $cleaned = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($relative in $installerWxs) {
        $full = Join-Path $installerDir $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $text = [System.IO.File]::ReadAllText($full)

        foreach ($match in [regex]::Matches($text, '<Directory\s+Id="([^"]+)"')) {
            $declared.Add($match.Groups[1].Value) | Out-Null
        }
        foreach ($match in [regex]::Matches($text, '<RemoveFolder\b[^>]*?\bDirectory="([^"]+)"')) {
            $cleaned.Add($match.Groups[1].Value) | Out-Null
        }
    }

    $orphans = New-Object System.Collections.Generic.List[string]
    foreach ($id in $declared) {
        if (-not $cleaned.Contains($id)) { $orphans.Add($id) | Out-Null }
    }
    return @($orphans | Sort-Object)
}

function Patch-RemoveOrphanFolders {
    # 反复「探测 -> 移除」：删掉一个目录后，它的父目录可能因此变成新的孤立目录
    # （例如 WinUI3Apps\Microsoft.UI.Xaml\Assets 被删后，Microsoft.UI.Xaml 也随之变空）。
    # 每一轮都**重新探测**，所以只有确实「没有组件、没有子目录、也没有卸载清理」的目录才会被删。
    # 这一点很关键：判断必须来自孤立目录清单，不能“看着像空容器就删”——
    # 比如 WinAppSDK.wxs 仍然编译时，它引用的 Assets 目录虽然自己没内容，却是有用的。
    $installerDir = Join-Path $RepoRoot 'installer\PowerToysSetupVNext'

    for ($round = 1; $round -le 8; $round++) {
        $orphans = @(Get-OrphanDirectoryIds)
        if ($orphans.Count -eq 0) {
            if ($round -eq 1) { Write-Log '安装包目录声明：没有无人使用的孤立目录' -Level skip }
            return
        }

        Write-Log ("安装包目录声明：第 $round 轮，移除 $($orphans.Count) 个既无内容、也无卸载清理的目录：$([string]::Join(', ', $orphans))")

        foreach ($relative in $installerWxs) {
            $full = Join-Path $installerDir $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

            # 13 个 wxs 里只有少数几个会命中，先探一下再交给 Update-File，免得刷 13 行「跳过」。
            $probe = [System.IO.File]::ReadAllText($full)
            $relevant = $false
            foreach ($id in $orphans) {
                if ($probe.Contains($id)) { $relevant = $true; break }
            }
            if (-not $relevant) { continue }

            Update-File -Path $full -Description "安装包定义 $relative：移除孤立目录声明" -Transform {
                param([string]$text)

                foreach ($id in $orphans) {
                    $escaped = [regex]::Escape($id)

                    # <Directory Id="X" ... /> 自闭合声明，连同整行一起删
                    $text = [regex]::Replace($text,
                        "(?m)^[ \t]*<Directory\s+Id=`"$escaped`"[^>]*?/>[ \t]*\r?\n", '')

                    # 同名的容器写法：开标签与闭标签之间只剩空白时整块删。
                    # 只按 $orphans 里的 id 精确匹配，所以不会碰到仍有内容的目录。
                    $text = [regex]::Replace($text,
                        "(?m)^[ \t]*<Directory\s+Id=`"$escaped`"[^>]*?>\s*</Directory>[ \t]*\r?\n", '')

                    # 指向该目录的悬空引用，例如把 DSCModules 追加进 PATH 的
                    # <Environment ... Value="[X]" />。目录都没了还留着引用，WiX 会报未定义引用。
                    $text = [regex]::Replace($text,
                        "(?m)^[ \t]*<[A-Za-z][A-Za-z0-9]*[^>]*?Value=`"\[$escaped\]`"[^>]*?/>[ \t]*\r?\n", '')
                }

                return $text
            } | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# 8. 安装包语言：WinAppSDK 本地化清单裁剪
# ---------------------------------------------------------------------------

<#
    WinAppSDK.wxs 自带一份 56 种语言的清单，每个语言都会生成一个 WinUI3Apps\<lang> 目录、
    一个含 2 个 .mui 的 <Component> 和一个 <RemoveFolder>。我们不含本地化资源、界面也只有英文，
    所以只保留 -KeepLanguages 指定的语言。

    动手前先校验：要保留的语言必须在上游清单里存在，并且有分支能生成合法的 WiX Id
    （例如 en-us -> en_us）。宁可直接报错，也不要产出一个引用了不存在资源的安装包。
#>
function Patch-WinAppSdkLanguageList {
    $path = Resolve-RepoFile 'installer/PowerToysSetupVNext/WinAppSDK.wxs'
    $keep = @($script:KeepLanguageList)

    Update-File -Path $path -Description ('WinAppSDK.wxs：本地化清单裁剪为 ' + [string]::Join(';', $keep)) -Transform {
        param([string]$text)

        $definePattern = '<\?define WinAppSDKLocLanguageList = ([^?]*)\?>'
        $current = [regex]::Match($text, $definePattern)
        if (-not $current.Success) {
            throw 'WinAppSDK.wxs 里找不到 WinAppSDKLocLanguageList 定义，上游结构可能已变化。'
        }

        $upstream = @($current.Groups[1].Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        $unknown = @($keep | Where-Object { $upstream -notcontains $_ })
        if ($unknown.Count -gt 0) {
            throw ("-KeepLanguages 里有上游清单中不存在的语言：$([string]::Join(', ', $unknown))。" +
                   "上游共有：$([string]::Join(', ', $upstream))")
        }

        foreach ($language in $keep) {
            $safe = $language -replace '-', '_'
            if ($text -notmatch [regex]::Escape($safe)) {
                throw "WinAppSDK.wxs 里没有 $language 对应的分支（期望出现 IdSafeLanguage = $safe）。"
            }
        }

        $wanted = '<?define WinAppSDKLocLanguageList = ' + [string]::Join(';', $keep) + '?>'
        if ($current.Value -eq $wanted) { return $text }
        return [regex]::Replace($text, $definePattern, $wanted)
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 9. 安装时的注册表变更集：不再写入已移除模块的键
# ---------------------------------------------------------------------------

<#
    modulesRegistry.h 里「安装」用的 getAllOnByDefaultModulesChangeSets，每一项都属于已移除模块：
    FileExplorerPreview 的 SVG/Markdown/Monaco/PDF/GCode/BGCode/QOI 预览与缩略图处理器、
    以及 RegistryPreview。它们指向的 DLL 已经不再打包，装上只会留下一批指向不存在文件的
    COM / 文件关联注册。

    「卸载」用的 getAllModulesChangeSets 刻意保持原样 —— 这样从旧版升级上来的机器
    仍能把之前写进去的键清掉。
#>
function Patch-ModulesRegistryApplySet {
    $path = Resolve-RepoFile 'src/common/utils/modulesRegistry.h'

    Update-File -Path $path -Description 'modulesRegistry.h：安装不再写入已移除模块的注册表项' -Transform {
        param([string]$text)

        $pattern = '(?s)inline std::vector<registry::ChangeSet> getAllOnByDefaultModulesChangeSets\([^)]*\)\s*\{.*?return\s*\{.*?\};'
        if (-not [regex]::IsMatch($text, $pattern)) {
            throw 'modulesRegistry.h 里找不到 getAllOnByDefaultModulesChangeSets 的实现，结构可能已变化。'
        }

        # 注意：这段替换文本里不能出现 $，否则会被 [regex]::Replace 当成替换组引用。
        $replacement = @'
inline std::vector<registry::ChangeSet> getAllOnByDefaultModulesChangeSets(const std::wstring installationDir)
{
    // [powertoys-lite] 这个集合里的每一项都属于已移除的模块（FileExplorerPreview 的
    // SVG/Markdown/Monaco/PDF/GCode/BGCode/QOI 预览与缩略图处理器、以及 RegistryPreview），
    // 它们指向的 DLL 已不再打包。原行为会在安装时把这些 COM / 文件关联写进注册表，
    // 留下指向不存在文件的注册，所以这里直接返回空集合。
    // 卸载用的 getAllModulesChangeSets 保持原样，旧版写入的键仍然能被清理。
    (void)installationDir;
    return {};
'@

        return [regex]::Replace($text, $pattern, $replacement)
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 10. 更新源：指向自己的仓库
# ---------------------------------------------------------------------------

<#
    上游的更新检查打的是官方仓库（src/common/updating/updating.cpp 的 LATEST_RELEASE_ENDPOINT）。
    对精简版来说这是错的：它会提示、甚至在开启"自动下载更新"时直接安装官方完整版，
    把精简版覆盖掉。这里改成 -UpdateSourceRepo 指定的仓库。

    两个细节：
      · Release 标签：我们用 lite-v<version>，而 VersionHelper::fromString 认的是 v<version>，
        所以先剥掉 lite- 前缀，其余解析逻辑保持上游原样。
      · 资产匹配不用改：更新器按 "powertoysusersetup" + 架构 + .exe 来找资产，
        我们的 PowerToysUserSetup-<ver>-x64.exe 正好符合。
#>
function Patch-UpdateSource {
    if ([string]::IsNullOrWhiteSpace($script:UpdateSourceRepo)) {
        Write-Log '更新源：未指定 -UpdateSourceRepo，保持上游默认（仍指向 microsoft/PowerToys）' -Level warn
        return
    }

    $repo = $script:UpdateSourceRepo
    $path = Resolve-RepoFile 'src/common/updating/updating.cpp'

    Update-File -Path $path -Description "updating.cpp：更新源改为 $repo" -Transform {
        param([string]$text)

        # 1) 端点里的仓库
        $endpoint = 'api.github.com/repos/microsoft/PowerToys/releases'
        if ($text.Contains($endpoint)) {
            $text = $text.Replace($endpoint, "api.github.com/repos/$repo/releases")
        } elseif (-not $text.Contains("api.github.com/repos/$repo/releases")) {
            throw 'updating.cpp 里找不到预期的 GitHub 端点，上游结构可能已变化。'
        }

        # 2) 版本标签前缀
        $anchor = 'return VersionHelper::fromString(release_object.GetNamedString(L"tag_name"));'
        if ($text.Contains($anchor)) {
            $newBody = @'
std::wstring tag{ release_object.GetNamedString(L"tag_name") };
        // [powertoys-lite] 我们的 Release 标签形如 lite-v0.100.2，先剥掉 lite- 前缀。
        constexpr std::wstring_view lite_tag_prefix{ L"lite-" };
        if (tag.starts_with(lite_tag_prefix))
        {
            tag.erase(0, lite_tag_prefix.size());
        }
        return VersionHelper::fromString(tag);
'@
            $text = $text.Replace($anchor, $newBody)
        } elseif (-not $text.Contains('lite_tag_prefix')) {
            throw 'updating.cpp 里找不到 extract_version_from_release_object 的解析语句，结构可能已变化。'
        }

        return $text
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 11. 默认启用的模块清单：收敛到本次打包的工具
# ---------------------------------------------------------------------------

<#
    src/settings-ui/Settings.UI.Library/EnabledModules.cs 里每个字段的初始值就是「默认启用」，
    文件自己的注释也写明了这一点：
        // Default values for enabled modules should match their expected "enabled by default" values.

    设置界面没有「已安装模块」过滤（导航是按 ModuleType 枚举出来的），开关状态就来自这份默认值。
    于是裁掉模块之后，界面上会留下一堆「已启用」的幽灵条目 —— 模块 DLL 根本不存在。

    这里把默认值为 true 的字段收敛到本次真正打包的工具，其余一律改回默认关闭。
    工具 id 与字段名按大小写不敏感匹配（powerrename -> powerRename、PowerOCR -> powerOCR …）。
    只要有一个打包中的工具在这里找不到对应字段，就直接报错，而不是悄悄把它默认关掉。
#>
function Patch-DefaultEnabledModules {
    $path = Resolve-RepoFile 'src/settings-ui/Settings.UI.Library/EnabledModules.cs'
    $keep = @($enabledTools | ForEach-Object { [string]$_.id })

    Update-File -Path $path -Description 'EnabledModules.cs：默认启用的模块收敛到本次打包的工具' -Transform {
        param([string]$text)

        # 全部字段（不论默认值）：用来校验工具 id 能对上，避免上游改名后静默失效
        $allFields = @([regex]::Matches($text, 'private\s+bool\s+(\w+)\s*[;=]') | ForEach-Object { $_.Groups[1].Value })
        if ($allFields.Count -eq 0) {
            throw 'EnabledModules.cs 里没找到任何 private bool 字段，上游结构可能已变化。'
        }

        foreach ($tool in $keep) {
            if (-not ($allFields | Where-Object { $_ -ieq $tool })) {
                throw ("EnabledModules.cs 里找不到与工具 $tool 对应的字段（上游可能改名了）。" +
                       "现有字段：$([string]::Join(', ', $allFields))")
            }
        }

        # 默认值为 true 的字段就是「默认启用」清单，不在本次打包范围内的改回默认关闭。
        #
        # 注意：这里要「去掉初始化器」，不能写成 `= false`。显式初始化成默认值会触发
        # 代码分析规则 CA1805（Settings.UI.Library 把分析器告警当错误），
        # 上游自己的写法也是这样 —— 默认关闭的字段都不写初始化器：
        #     private bool shortcutGuide; // defaulting to off
        $defaultOn = @([regex]::Matches($text, 'private\s+bool\s+(\w+)\s*=\s*true\s*;') | ForEach-Object { $_.Groups[1].Value })
        foreach ($field in $defaultOn) {
            if ($keep | Where-Object { $_ -ieq $field }) { continue }
            $pattern = 'private\s+bool\s+' + [regex]::Escape($field) + '\s*=\s*true\s*;'
            # 注释保持纯 ASCII：C# 源文件的编码无法本地验证，中文注释在这里没有收益
            # （解释都留在本脚本里），却多担一份编码风险。
            $text = [regex]::Replace($text, $pattern, "private bool $field; // [powertoys-lite] module not packaged; default off")
        }

        return $text
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 12. 更新方式：不再自动下载安装，改为提示 + 打开发布页
# ---------------------------------------------------------------------------

<#
    内置更新器在提权安装前会校验下载来的安装包必须由 Microsoft Corporation 签名
    （src/common/updating/installer.cpp 的 verified_signer_is_microsoft），而精简版不做代码签名
    —— 所以「下载并自动安装」这条路必然失败。改成：只做版本检查与提示，把「立即更新」
    变成打开发布页，由用户自行下载安装。

    只动 src/runner/UpdateUtils.cpp 两处：
      1. 两个更新检查入口（后台轮询 PeriodicUpdateWorker / 手动检查 CheckForUpdatesCallback）
         里的 download_update 恒为 false —— 不再后台下载，也避免"下载成功但装不上"的中间态；
      2. LaunchPowerToysUpdate（唯一调用方是 main.cpp 的 powertoys://update_now/ 分支，
         设置界面的更新按钮与通知按钮都走这里）改为打开发布页：优先用版本检查时记下的
         releasePageUrl，取不到（还没成功检查过）就用编译期写死的仓库地址兜底。
#>
function Patch-UpdateToManualDownload {
    $path = Resolve-RepoFile 'src/runner/UpdateUtils.cpp'
    $repo = $script:UpdateSourceRepo
    if ([string]::IsNullOrWhiteSpace($repo)) {
        # 没有指定更新源时，兜底地址与上游默认保持一致（更新源本身不改）
        $repo = 'microsoft/PowerToys'
    }

    Update-File -Path $path -Description 'UpdateUtils.cpp：不再自动下载，改为提示 + 打开发布页' -Transform {
        param([string]$text)

        # 1) 关掉自动下载（两个入口用的是同一行表达式）
        $downloadExpr = 'bool download_update = !IsMeteredConnection() && get_general_settings().downloadUpdatesAutomatically;'
        if ($text.Contains($downloadExpr)) {
            $text = $text.Replace(
                $downloadExpr,
                'bool download_update = false; // [powertoys-lite] 不做代码签名，内置更新器无法完成提权安装，只提示')
        } elseif ($text -notmatch 'download_update = false; // \[powertoys-lite\]') {
            throw 'UpdateUtils.cpp 里找不到 download_update 的赋值语句，上游结构可能已变化。'
        }

        # 2)「立即更新」-> 打开发布页
        $fnPattern = '(?s)SHELLEXECUTEINFOW LaunchPowerToysUpdate\(const wchar_t\* cmdline\)\s*\{.*?\n\}'
        if (-not [regex]::IsMatch($text, $fnPattern)) {
            throw 'UpdateUtils.cpp 里找不到 LaunchPowerToysUpdate 的实现，上游结构可能已变化。'
        }

        # 替换文本里不要出现 $（会被 [regex]::Replace 当成替换组引用），仓库地址稍后替换占位符。
        $newFn = @'
SHELLEXECUTEINFOW LaunchPowerToysUpdate(const wchar_t* cmdline)
{
    // [powertoys-lite] 原生行为是启动 PowerToys.Update.exe 去下载并提权安装新版本，但内置更新器
    // 在提权安装前要求安装包由 Microsoft Corporation 签名（common/updating/installer.cpp 的
    // verified_signer_is_microsoft），而精简版不做代码签名 —— 那条路必然失败。
    // 所以这里改为打开发布页，由用户自行下载安装。
    (void)cmdline;

    std::wstring releaseUrl = UpdateState::read().releasePageUrl;
    if (releaseUrl.empty())
    {
        // 还没成功做过一次版本检查，退回到编译期写死的仓库地址
        releaseUrl = L"https://github.com/REPO_PLACEHOLDER/releases";
    }

    Logger::info(L"Opening the release page for a manual update: {}", releaseUrl);
    ShellExecuteW(nullptr, L"open", releaseUrl.c_str(), nullptr, nullptr, SW_SHOWNORMAL);

    SHELLEXECUTEINFOW sei{ sizeof(sei) };
    return sei;
}
'@
        $newFn = $newFn.Replace('REPO_PLACEHOLDER', $repo)
        return [regex]::Replace($text, $fnPattern, $newFn)
    } | Out-Null
}

# ---------------------------------------------------------------------------
# 把 .NET / WinUI3 应用从「自包含」改成「框架依赖」（可选，由 -FrameworkDependent 打开）
# ---------------------------------------------------------------------------
# 默认情况下 PowerToys 是**自包含**发布的：.NET 运行时、WPF/WinForms、Windows App SDK、
# CsWinRT 投影都跟着应用本体走。代价是「安装根目录」和「WinUI3Apps\」各带一份 ——
# 实测 661 MB 的安装里有 285 MB 属于这种"两份中的一份"。
#
# 为什么上游要这么做：这是**免管理员的每用户安装**的代价。运行时由包自带，
# 不要求机器上预装任何东西，装完即用。把它挪到机器上就必然要求提权（.NET Desktop Runtime
# 的安装器是机器级的），这也正是上游不肯这么做的原因。
#
# 所以这是一个「自用且能提权」场景下的取舍开关。打开后：
#   · 两棵应用树里的运行时全部消失（安装目录约 661 → 350 MB，安装包本身也变小）
#   · 机器上必须预装，否则应用会起不来（.NET 与 WinAppSDK 各自会给出明确提示）：
#       - .NET 10 Desktop Runtime（x64）
#       - Windows App Runtime（版本要与上游 Microsoft.WindowsAppSDK 一致）
#   · hostfxr.dll 不再随包安装 —— 注意上游的 RCA 里，Explorer 预览宿主会从安装根目录加载它，
#     所以万一你用到「文件资源管理器加载项」（本精简版默认不打包），那类功能会受影响。
#
# 只翻 true -> false，涉及两个属性：
#   <SelfContained>                —— 由 src/Common.SelfContained.props 统一下发到各项目
#   <WindowsAppSDKSelfContained>   —— 各 WinUI3 应用自己设
# 外加各应用发布配置（Properties\PublishProfiles\*.pubxml）里的 <SelfContained>。
# 幂等：已经是 false 的不会再改。
function Patch-FrameworkDependent {
    $changed = New-Object System.Collections.Generic.List[string]

    # 1) 共享的 .NET 自包含开关（覆盖绝大多数 .NET 项目）
    $sharedProps = Resolve-RepoFile 'src/Common.SelfContained.props'
    $before = $script:ChangeCount
    Update-File -Path $sharedProps -Description 'src/Common.SelfContained.props：改为框架依赖' -Transform {
        param([string]$text)
        return [regex]::Replace($text, '(?i)(<SelfContained>)\s*true\s*(</SelfContained>)', '${1}false${2}')
    } | Out-Null
    if ($script:ChangeCount -gt $before) { $changed.Add('src/Common.SelfContained.props') | Out-Null }

    # 2) 闭包内的项目与它们的发布配置（各 WinUI3 应用的 WindowsAppSDKSelfContained 在这里）
    $targets = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($project in @($buildProjects) + @($publishProjects) + @($restoreProjects)) {
        $full = Join-Path $RepoRoot $project
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $targets.Add($full) | Out-Null

        $profileDir = Join-Path (Split-Path -Parent $full) 'Properties\PublishProfiles'
        if (Test-Path -LiteralPath $profileDir) {
            foreach ($pubxml in @(Get-ChildItem -LiteralPath $profileDir -Filter '*.pubxml' -File -Recurse -ErrorAction SilentlyContinue)) {
                $targets.Add($pubxml.FullName) | Out-Null
            }
        }
    }

    foreach ($target in $targets) {
        $relative = $target.Substring($RepoRoot.Length) -replace '^[\\/]+', '' -replace '\\', '/'
        $before = $script:ChangeCount
        Update-File -Path $target -Description "$relative：改为框架依赖" -Transform {
            param([string]$text)
            $text = [regex]::Replace($text, '(?i)(<SelfContained>)\s*true\s*(</SelfContained>)', '${1}false${2}')
            $text = [regex]::Replace($text, '(?i)(<WindowsAppSDKSelfContained>)\s*true\s*(</WindowsAppSDKSelfContained>)', '${1}false${2}')
            return $text
        } | Out-Null
        if ($script:ChangeCount -gt $before) { $changed.Add($relative) | Out-Null }
    }

    Write-Log "框架依赖：翻转为 false 的属性出现在 $($changed.Count) 个文件里"
    foreach ($item in $changed) { Write-Log "  $item" }
    Write-Log '提示：开启后这台机器必须预装 .NET 10 Desktop Runtime 与 Windows App Runtime，否则应用起不来。' -Level warn
}

# ---------------------------------------------------------------------------
# 13. 默认安装目录
# ---------------------------------------------------------------------------

# 把默认安装位置从 [LocalAppDataFolder]PowerToys 改成 -DefaultInstallDir 指定的路径。
#
# 只改一处就够：引导程序里的 InstallFolder 变量（PowerToys.wxs）。它同时是
#   · 安装界面 Options 页那个路径输入框的初值（RtfTheme.xml 的 <Editbox Name="InstallFolder">）
#   · 传给 MSI 的 BOOTSTRAPPERINSTALLFOLDER（<MsiProperty Name="BOOTSTRAPPERINSTALLFOLDER" Value="[InstallFolder]" />）
# 所以 MSI 侧（Product.wxs 的 INSTALLFOLDER 与 InstallDirDlg）不用动。
#
# 两件必须留意的事：
#   · 我们只构建「每用户安装包」（InstallPrivileges=limited、注册表写 HKCU），所以目标必须是
#     **当前用户可写**的位置；指到 Program Files 这类要提权的目录会安装失败。
#   · 这只是一个**默认值**：变量上的 bal:Overridable="yes" 保持不变，用户仍可在安装界面的
#     Options 页改，或用 InstallFolder="..." 命令行覆盖。因此目标盘不存在的机器不是「装不了」，
#     而是要用户自己改路径才能装。
#
# 另外提醒一句（不是本补丁引入的问题，但换到驱动器根目录下的自建目录会变明显）：D:\PowerToys
# 这类目录会从盘根继承「Authenticated Users: Modify」，也就是本机其他标准用户也能往里写。
# 上游对这个场景有明确态度 —— Common.wxi 给 per-machine 的 PATH 目录加了严格 DACL，并注明
# per-user 安装**不要**用那套 SDDL（会把安装用户自己降成只读 + 执行）。所以这里不碰 ACL。
function Patch-DefaultInstallDir {
    if ([string]::IsNullOrWhiteSpace($DefaultInstallDir)) {
        Write-Log 'installer/PowerToysSetupVNext/PowerToys.wxs：未指定默认安装目录，保持上游默认值' -Level skip
        return
    }

    # 只接受本机盘符路径（形如 D:\PowerToys）。UNC（\\server\share）与相对路径都会引出
    # 意料之外的行为，直接拒绝；路径含 XML 特殊字符也拒绝，免得把 wxs 写坏。
    if ($DefaultInstallDir -notmatch '^[A-Za-z]:\\') {
        throw "默认安装目录必须是本机盘符路径（形如 D:\PowerToys），实际是：$DefaultInstallDir"
    }
    if ($DefaultInstallDir -match '[<>&"'']') {
        throw "默认安装目录不能包含 XML 特殊字符（< > & 引号）：$DefaultInstallDir"
    }
    $target = $DefaultInstallDir.TrimEnd('\')

    $path = Resolve-RepoFile 'installer/PowerToysSetupVNext/PowerToys.wxs'
    $before = $script:ChangeCount

    Update-File -Path $path -Description "installer/PowerToysSetupVNext/PowerToys.wxs：默认安装目录改为 $target" -Transform {
        param([string]$text)

        # 幂等判断必须放在「识别分支」之前：改过之后再跑，那一行的值已经是目标值、
        # 不再含 [LocalAppDataFolder]，若先按分支找就会误报「找不到」而抛错。
        # 不会误判到 per-machine 那行 —— 目标值只可能是盘符路径，而它的值是 $(var.PlatformProgramFiles)…
        if ($text -match ('<Variable\s+Name="InstallFolder"\s+Type="formatted"\s+Value="' + [regex]::Escape($target) + '"')) {
            return $text
        }

        # 只认每用户分支那一行（值是 [LocalAppDataFolder]PowerToys）；per-machine 分支的值是
        # $(var.PlatformProgramFiles)PowerToys，我们不出 per-machine 包，不动它。
        $match = [regex]::Match($text, '<Variable\s+Name="InstallFolder"\s+Type="formatted"\s+Value="([^"]*)"\s+bal:Overridable="yes"\s*/>')
        while ($match.Success -and $match.Groups[1].Value -notlike '*LocalAppDataFolder*') {
            $match = $match.NextMatch()
        }
        if (-not $match.Success) {
            throw 'installer/PowerToysSetupVNext/PowerToys.wxs 里找不到每用户分支的 InstallFolder 默认值 —— 上游可能改了写法，请同步本补丁。'
        }

        # 只替换捕获组那一小段，并且用字面量拼接（不走正则替换串，免得路径里的 $ 被当成反向引用）
        $group = $match.Groups[1]
        return $text.Substring(0, $group.Index) + $target + $text.Substring($group.Index + $group.Length)
    } | Out-Null

    if ($script:ChangeCount -gt $before) {
        Write-Log "默认安装目录：$target（只改引导程序的默认值，用户仍可在安装界面或命令行覆盖）"
        Write-Log '  注意：安装机器上必须存在该盘符，且当前用户对其有写权限（只出每用户包，不提权）。' -Level warn
        Write-Log '  注意：该目录会从盘根继承「其他标准用户可写」的权限；机器上若还有别的用户，建议放到自己的目录下。' -Level warn
    } else {
        Write-Log "默认安装目录：已经是 $target，无需改动" -Level skip
    }
}

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------

Write-Log '开始对上游源码应用精简补丁 ...'
Write-Host ''

Patch-RunnerKnownModules
Patch-InstallerWixproj
Patch-ProductWxs
Patch-ProductWxsRemoveDsc
Patch-CoreWxsRemoveDsc
Patch-BaseApplicationsRemoveCmdPal
Patch-GenerateAllFileComponents
# 必须放在其它补丁之后：孤立目录是按「其它补丁都跑完」的最终状态判定的
# （例如 Core.wxs 里的 DSC 目录子树是被 Patch-CoreWxsRemoveDsc 移除的）。
Patch-RemoveOrphanFolders
Patch-WinAppSdkLanguageList
Patch-ModulesRegistryApplySet
Patch-UpdateSource
Patch-UpdateToManualDownload
Patch-DefaultEnabledModules
Patch-VersionProps
Patch-DefaultInstallDir
if ($FrameworkDependent) {
    Patch-FrameworkDependent
}

Write-Host ''
Write-Log "完成，共修改 $script:ChangeCount 处。" -Level ok

# ---------------------------------------------------------------------------
# 算出 NuGet 还原计划（放在补丁之后：补丁会置空 wixproj 的 PreBuildEvent 等，
# 从而去掉一批其实不会再用到的 $(NUGET_PACKAGES)\... 引用；工作流做权威校验时看的是
# 补丁后的源码，这里保持一致才不会多算出「假需求」。）
# ---------------------------------------------------------------------------
Write-Host ''
$nugetPlan = Get-RequiredNuGetPackages
Write-Log "NuGet 还原计划：本次构建需要 $($nugetPlan.PackageDirNames.Count) 个包目录，只从 $($nugetPlan.Configs.Count) 份 packages.config 还原（全仓库共 $($nugetPlan.TotalConfigs) 份）。"
foreach ($configRelative in $nugetPlan.Configs) {
    Write-Log "  restore $configRelative"
}
if ($nugetPlan.MissingKeys.Count -gt 0) {
    Write-Log "以下包被工程引用、但没有任何 packages.config 声明它，构建很可能失败：$([string]::Join(', ', $nugetPlan.MissingKeys))" -Level warn
}

# ---------------------------------------------------------------------------
# 输出构建清单：工作流与产物校验脚本都以它为准，避免在多处重复描述「选了哪些工具」
# ---------------------------------------------------------------------------

$manifest = [ordered]@{
    generatedBy        = 'apply-lite-patch.ps1'
    version            = $Version
    enabledTools       = @($enabledTools | ForEach-Object { [ordered]@{ id = $_.id; displayName = $_.displayName } })
    unverifiedTools    = @($unverifiedTools | ForEach-Object { $_.id })
    keptModuleDlls     = @($keptModuleDlls)
    unselectedModuleDlls = @($droppedModules)
    buildProjects      = @($buildProjects)
    publishProjects    = @($publishProjects)
    restoreProjects    = @($restoreProjects)
    # NuGet 还原计划：只需要还原这几份 packages.config，以及还原完该有哪些包目录。
    # 工作流按前者还原、按后者做权威校验；校验不过就回退成「全仓库都还原一遍」。
    nugetRestoreConfigs  = @($nugetPlan.Configs)
    requiredPackageDirs  = @($nugetPlan.PackageDirNames)
    installerWxs       = @($installerWxs)
    installerComponentGroups = @($installerGroups)
    # 默认安装目录（空 = 用上游默认值 %LOCALAPPDATA%\PowerToys）。校验脚本据此确认
    # 这个默认值真的落进了安装包定义，避免「补丁没生效却照常出货」。
    defaultInstallDir  = $DefaultInstallDir
}

$manifestPath = Join-Path $script:ScriptDirectory 'lite.build.json'
($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Log "已写出构建清单：$manifestPath" -Level skip
Write-Host ''
