# 发布记录

本仓库只保留当前公开版本 `0.1.9.2` 的文件和发布包。历史版本不在本仓库中重复保存。

| 版本 | 状态 | 发布包 | SHA-256 |
|---|---|---|---|
| 0.1.9.2 | 当前版本 | `dist/StableTune-prototype-v0.1.9.2-20260920.zip` | `C960E588958224C2B9CB446C56202C8EAE1F21D2B376D9B60B53302E42B574B2` |

## 当前推荐

`0.1.9.2` 是稳优 StableTune 的当前公开版本，包含 Qt 6 Widgets 界面、
PowerShell 后端、38 项可回滚规则和完整安全机制。GitHub Release 同时提供
可直接运行的 Windows x64 便携包。

本版本修复 `Start-StableTune.cmd` 在部分 Windows 系统上的换行和代码页解析
问题，启动器现在使用 CRLF 和纯 ASCII 状态信息。
