# PowerToys Lite

基于 [microsoft/PowerToys](https://github.com/microsoft/PowerToys) 的精简构建：**只打包你勾选的工具**，用 GitHub Actions 自动追踪上游版本并发布独立安装包。

## 打包的工具

| ID | 工具 |
| --- | --- |
| `MeasureTool` | Screen Ruler（屏幕标尺）|
| `peek` | Peek（速览）|
| `colorPicker` | Color Picker（颜色选取器）|
| `FileLocksmith` | File Locksmith（占用查看）|
| `powerrename` | PowerRename（批量重命名）|
| `PowerOCR` | Text Extractor（屏幕 OCR）|


文字提取功能现在已经集成到了系统截图里面，但我安装了start all back后快捷键有冲突，所以才打包。

选择启用哪些工具只需编辑 `lite/enabled-tools.txt`，**不用动代码**（见 [换工具](#换工具)）。

## 使用

### 1. 部署

1. 新建一个 GitHub 仓库，把本项目推上去。
2. **Settings → Actions → General → Workflow permissions** 选 **Read and write permissions**（发布 Release 需要）。

### 2. 构建

- **自动**：每周一北京时间 08:00 检查上游是否有新版本，有则构建并发布。
- **手动**：**Actions → Build PowerToys Lite → Run workflow**（`upstream_ref` 可指定上游 tag/分支，`force` 强制重建）。

### 3. 安装

Release 里只需要下载 `PowerToysUserSetup-<version>-x64.exe`（每用户安装，**默认装到 `D:\PowerToys`**），`SHA256SUMS.txt` 是校验值。`.msi` 仍会构建但不单独发布 —— 它是这个 exe 的内嵌载荷。

默认路径只是默认值，装的时候可以改：点安装界面的 **Options**，或命令行给 `InstallFolder`：

```powershell
.\PowerToysUserSetup-<version>-x64.exe InstallFolder="E:\PowerToys"          # 静默加 /quiet
```

机器上没有 `D:` 盘时必须先改这个路径，否则装不上。升级会沿用上次装的目录，不会跳回默认值。

**先装好下面两个前置条件（当前是「框架依赖」模式，需要管理员权限）：**

- [**.NET 10 Desktop Runtime（x64）**](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)
- [**Windows App Runtime 2.X**](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads)

## 换工具

编辑 `lite/enabled-tools.txt`：一行一个 ID，行首加/去 `#` 即禁用/启用；全部注释掉就只打包 PowerToys 本体。ID 填错会在构建前报错并列出全部可用 ID。

`lite/tools.catalog.json` 只需读、不用改 —— 它刻意不写死任何路径（只记模块目录与 DLL 文件名），所以上游怎么调整目录结构都不用跟着维护。

## 两道自动关卡

1. **打补丁前**：拿工具目录逐条对照上游源码（工具是否存在、本体/publish 项目与 `.wxs`、组件分组是否双向对得上），问题一次列全再退出。
2. **打包后**：`verify-lite-output.ps1` 检查该有的 DLL 都在、未选中工具的 DLL 一个都没混进来。

## 已知局限

1. **与官方版冲突**：产品标识相同，安装前必须先卸载官方 PowerToys。
2. **仅英文界面**：官方本地化资源依赖内部服务下发。
3. **设置界面有残留**：未对导航做侵入式修改，未打包工具的页面点开是空的，不影响已启用工具。
4. **未签名**：SmartScreen 会提示"未知发布者"，请核对 SHA256 后安装。
5. **仅每用户安装**：不产出 Per-Machine 包，以此省掉一半构建时间与体积。

## 文件说明

| 路径 | 作用 |
| --- | --- |
| `.github/workflows/` | 构建流水线 |
| `lite/enabled-tools.txt` | **唯一需要常改的文件**：打包哪些工具 |
| `lite/tools.catalog.json` | 工具 ↔ 项目/wxs 的映射数据 |
| `lite/apply-lite-patch.ps1` | 幂等补丁：构建前裁剪上游源码 |
| `lite/verify-lite-output.ps1` | 打包后校验产物 |
| `lite/lite.build.json` | 生成物（不入库）|

## 感谢

Love From AI
