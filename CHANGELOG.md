# Changelog

## v0.1.9.2 - 2026-09-20

- 修复 `Start-StableTune.cmd` 在部分 Windows 版本中被 `cmd.exe` 错误解析的问题。
- 所有 Windows 启动器统一使用 CRLF 换行和纯 ASCII 状态信息，避免 LF 换行及
  控制台代码页导致命令残缺、中文乱码或程序路径误判。
- 便携启动器同时支持从发布包根目录和 `tools` 目录定位
  `bin\StableTune.exe`，并支持向主程序透传参数用于自动验证。
- 构建流程会再次规范 `.cmd` 和 `.bat` 文件换行，仓库校验和回归测试会阻止
  非 CRLF 或非 ASCII 的启动器进入发布包。

## v0.1.9.1 - 2026-09-20

- 程序正式更名为“稳优 StableTune”。
- Qt 主程序更名为 `StableTune.exe`。
- 修复更名后“关于我们”仍显示旧版本号的问题。
- 提供包含 Qt 运行库、插件、PowerShell 后端和全部 38 项规则的完整便携包。
- 保留旧状态目录 `%LOCALAPPDATA%\FelixOptimizer`，已有历史、快照和回滚数据继续可用。
- 全部规则、适用性判断、快照、恢复、防崩溃保险和批量执行行为保持不变。
