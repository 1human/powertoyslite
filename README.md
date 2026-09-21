# PowerToys Lite

**PowerToys Lite** 是一个基于 [microsoft/PowerToys](https://github.com/microsoft/PowerToys) 的精简版本方案。它通过定制构建流程，**只打包你勾选的那几个工具**，显著缩减安装包体积，并通过 GitHub Actions 实现上游版本的自动追踪与独立编译发布。

## 🚀 保留的工具

| 工具 ID | 工具名称 | 说明 |
| --- | --- | --- |
| `MeasureTool` | Screen Ruler（屏幕标尺） | 屏幕像素测量 |
| `peek` | Peek（速览） | 空格键快速预览文件 |
| `colorPicker` | Color Picker（颜色选取器） | 屏幕取色 |
| `FileLocksmith` | File Locksmith | 查看文件被哪个进程占用 |
| `powerrename` | PowerRename | 批量重命名 |
| `PowerOCR` | Text Extractor（文本提取器） | 屏幕 OCR 取字 |

> 这张表就是当前 `lite/enabled-tools.txt` 的选择结果。想改打包哪些工具请看下面的 **自定义工具增删**，**不需要动任何代码**。
>
> 目录里 `verified: false` 的工具表示**尚未端到端实测过**（当前是 `PowerOCR`）。它们能通过目录校验、路径也能正确解析，但首次构建仍可能暴露上游问题，届时请把 CI 日志贴出来排查。

---

## 🛠️ 快速开始

### 1. 部署你自己的构建仓库
1. 在 GitHub 上创建一个新仓库，将本项目的所有文件推送到你的仓库中。
2. 开启 Actions 写权限：前往仓库的 **Settings → Actions → General → Workflow permissions**，选择 **Read and write permissions**（用于自动创建 Release）。

### 2. 触发自动化构建
* **自动触发**：每周一 UTC 20:17 自动检查上游是否有新版本，若有则自动构建并发布 Release。
* **手动触发**：前往 **Actions → Build PowerToys Lite → Run workflow**：
  - `upstream_ref`：可指定上游 tag/分支（留空默认取最新 Release）。
  - `force`：强制重新构建。

### 3. 安装产物
构建成功后将在 Release 中生成以下产物（仅限 x64 架构）：
* `PowerToysUserSetup-<version>-x64.exe`：每用户安装包（**无需管理员权限**，装至 `%LOCALAPPDATA%`）。
* `PowerToysUserSetup-<version>-x64.msi`：MSI 格式安装包。
* `SHA256SUMS.txt`：文件校验值。

---

## ⚙️ 自定义工具增删

如果需要修改打包的工具，只需编辑 `lite/enabled-tools.txt`：
* **启用/禁用**：一行一个工具 ID，在行首添加或去掉 `#` 注释即可（全部注释掉 = 只打包 PowerToys 本体）。
* **可用 ID**：完整的工具映射可以在 `lite/tools.catalog.json` 中查看。如果误填了不存在的 ID，构建流程会安全报错并中止，同时列出全部可用 ID。

### 这个目录为什么不用跟着上游改

`tools.catalog.json` 里**刻意不写死任何路径**，所以上游怎么调整结构都不需要你维护：

* **构建项目**：只记 `moduleDir`（模块源码目录），具体项目在构建时现扫，自动排除 test / 模板 / 示例。
* **模块 DLL**：只记 `moduleDllNames`（文件名），构建时在 runner 的 `knownModules` 里查出该版本真实的相对路径——上游会把模块在安装根目录与 `WinUI3Apps\` 之间搬迁（例如 `PowerToys.MouseJump.dll`）。

因此同一份目录对最新的 Release tag 与 `main` 分支都能用，并各自解析出正确的项目与 DLL。

### 两道自动关卡

1. **打补丁之前**：拿工具目录逐条对照上游源码——已启用的工具在当前版本是否存在、本体/publish 项目是否在、每个 `.wxs` 与组件分组是否双向对得上。所有问题会一次列全再退出，不会改到一半才炸。
2. **打包之后**：`verify-lite-output.ps1` 读构建清单，检查该有的 DLL 都在、未选中工具的 DLL 一个都没混进来、且只产出了每用户安装包。

---

## ⚠️ 重要说明与已知局限

1. **与官方版本冲突**：精简版与官方 PowerToys 使用相同的产品标识，安装前**必须先卸载官方版本**。
2. **纯英文界面**：由于官方本地化资源依赖内部服务下发，精简版目前**仅支持英文界面**。
3. **设置界面残留**：为了保证稳定性，未对设置界面的 UI 导航进行侵入式修改。点击未打包的工具页面会显示为空，不影响已启用工具的使用。
4. **未进行代码签名**：安装时 Windows SmartScreen 可能会提示“未知发布者”，属于正常现象，请核对 SHA256 校验值后安装。
5. **仅支持每用户安装**：默认不产出全系统安装包（Per-Machine），以此将构建时间和体积缩减一半。

---

## 📂 项目结构

* `.github/workflows/`：GitHub Actions 自动化构建流定义。
* `lite/enabled-tools.txt`：**【唯一需要高频编辑的文件】** 决定打包哪些工具。
* `lite/tools.catalog.json`：上游工具与项目、WXS 文件的映射关系数据库。
* `lite/apply-lite-patch.ps1`：幂等补丁脚本，用于在构建前裁剪上游源码。
* `lite/verify-lite-output.ps1`：构建后校验脚本，确保未选中的工具没有混入安装包。
* `lite/lite.build.json`：**生成物**（不入库），记录本次构建清单，供工作流与校验脚本读取。
