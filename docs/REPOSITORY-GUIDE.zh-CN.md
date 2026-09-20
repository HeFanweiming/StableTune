# 仓库结构说明

本仓库采用 Git 优先的版本管理。提交、标签和 Release 保存版本历史，工作树
始终只保留当前实现，不创建版本号后缀的源码、测试或启动器副本。

## 快速入口

| 用途 | 文件 |
|---|---|
| 中文说明 | `README.md` |
| 当前发布摘要 | `CURRENT-RELEASE.md` |
| 启动器 | `Start-StableTune.cmd` |
| 程序入口 | `StableTune.ps1` |
| 当前源码 | `src/StableTune/` |
| 完整测试 | `tests/Run-Tests.ps1` |
| CI 冒烟测试 | `tests/Test-Smoke.ps1` |
| 当前发布包 | `dist/` |
| 发布记录 | `docs/RELEASES.md` |

## 目录职责

### `src/`

保存 PowerShell 模块、WPF 界面、规则目录和资源文件。功能变更直接修改当前
文件，由 Git 提交保存历史。

### `tests/`

保存 Pester 测试、无桌面环境冒烟测试和统一测试入口。新增规则或处理器时直接
修改当前测试文件。

### `dist/`

只保存当前版本的 ZIP、SHA-256 与 manifest。GitHub Release 保存对外发布
附件，仓库工作树不保留其他版本文件。

### `docs/`

保存仓库说明、发布记录和设计文档。

### `.github/workflows/`

保存 GitHub Actions 校验流程。CI 只执行只读测试，不会应用任何真实系统优化。

## 版本规则

1. 在稳定路径上修改当前实现，并通过独立提交保存一个版本。
2. 发布时使用语义化版本号和带注释标签，例如 `v0.1.6.2`。
3. 每次发布必须同步更新 `README.md`、`CURRENT-RELEASE.md` 和
   `release-index.json`。
4. 每次发布时用当前版本安装包和校验记录更新 `dist/`，仓库不保留其他版本文件。
5. 构建前运行 `tools/Verify-Repository.ps1`、完整测试和冒烟测试。
6. 不重写已发布历史，不强制推送，除非用户明确要求。

## 验证命令

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Test-Smoke.ps1
```

只读检查：

```powershell
pwsh -NoProfile -File .\StableTune.ps1 -Command Hardware
pwsh -NoProfile -File .\StableTune.ps1 -Command ChangeAudit
pwsh -NoProfile -File .\StableTune.ps1 -Command RollbackCheck
pwsh -NoProfile -File .\StableTune.ps1 -Command Logs
```

## 维护原则

- 运行数据位于 `%LOCALAPPDATA%\FelixOptimizer`，不得提交到仓库。
- 不提交日志、临时文件、快照或隔离区。
- 更新规则时同步更新规则元数据、兼容性说明和测试。
