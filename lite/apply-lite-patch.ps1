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

    然后才做修改（只做减法，完全幂等）。它只改动 7 个文件：

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
    Write-Log '它们通常可以直接用；若 CI 失败，请对照 README 的排查清单。' -Level warn
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
    $orphans = @(Get-OrphanDirectoryIds)
    if ($orphans.Count -eq 0) {
        Write-Log '安装包目录声明：没有无人使用的孤立目录' -Level skip
        return
    }

    Write-Log ("安装包目录声明：移除 $($orphans.Count) 个既无内容、也无卸载清理的目录：$([string]::Join(', ', $orphans))")

    $installerDir = Join-Path $RepoRoot 'installer\PowerToysSetupVNext'
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

                # 指向该目录的悬空引用，例如把 DSCModules 追加进 PATH 的
                # <Environment ... Value="[X]" />。目录都没了还留着引用，WiX 会报未定义引用。
                $text = [regex]::Replace($text,
                    "(?m)^[ \t]*<[A-Za-z][A-Za-z0-9]*[^>]*?Value=`"\[$escaped\]`"[^>]*?/>[ \t]*\r?\n", '')
            }

            return $text
        } | Out-Null
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
Patch-VersionProps

Write-Host ''
Write-Log "完成，共修改 $script:ChangeCount 处。" -Level ok

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
    installerWxs       = @($installerWxs)
    installerComponentGroups = @($installerGroups)
}

$manifestPath = Join-Path $script:ScriptDirectory 'lite.build.json'
($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Log "已写出构建清单：$manifestPath" -Level skip
Write-Host ''
