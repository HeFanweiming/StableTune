# 稳优 StableTune Qt 6 Widgets

该目录提供现有 PowerShell/WPF 版本的 Qt 6 Widgets 界面迁移。为保证规则行为、
状态文件和历史记录与旧版严格一致，PowerShell 模块仍是唯一权威后端；Qt 只
负责界面、输入、确认和 JSON 桥接，不直接执行系统优化规则。

## 架构

```text
Qt 6 Widgets
  -> PowerShellBridge
  -> cpp/backend/backend_host.ps1
  -> src/StableTune/StableTune.psm1
  -> 原规则、快照、验证、回滚、历史和日志实现
```

正式 Qt 入口是 `cpp/qt/src/main_backend.cpp`。原有 `cpp/core/` 和
`cpp/qt/src/main.cpp` 保留为独立 C++ 核心实验，不参与正式 Qt UI 的规则执行。

当前桥接覆盖原 WPF 的 7 个页面：

- 系统状态
- 优化分类
- 历史记录
- 恢复中心
- 日志
- 设置
- 关于我们

规则预检、执行、批量执行、恢复、回滚策略、日志、硬件识别、崩溃保险状态和
动态规则输入均通过 PowerShell 公开函数完成。

## 运行依赖

开发或源码运行需要：

- Windows 10/11 x64
- PowerShell 7.4 或更高版本，命令为 `pwsh.exe`
- Visual Studio 2022/2026，安装“使用 C++ 的桌面开发”
- CMake 3.24 或更高版本
- Qt 6.8+ MSVC 64-bit，包含 `Core`、`Concurrent`、`Gui`、`Widgets`、`Test`

安装包运行还需要：

- `bin` 目录中的 Qt 运行库和平台插件，安装步骤会通过 `windeployqt` 自动复制
- `bin/powershell/StableTune` 中的完整 PowerShell 模块
- `bin/powershell/backend_host.ps1`
- PowerShell 7.4+；Windows PowerShell 5.1 不满足模块要求
- 修改系统设置时按规则要求提供管理员权限

如果 `pwsh.exe` 不在 `PATH` 中，可以在启动前设置：

```powershell
$env:FELIX_POWERSHELL = 'C:\Program Files\PowerShell\7\pwsh.exe'
```

程序也会自动检查系统级、用户级、Microsoft Store、winget、Scoop、
Chocolatey 和 Codex 运行时中的常见 `pwsh.exe` 路径。

状态目录继续使用旧版路径，以保留已有历史、快照和回滚数据：

```text
%LOCALAPPDATA%\FelixOptimizer
```

也可以用 `FELIX_OPTIMIZER_HOME` 覆盖。

## 构建

```powershell
cmake -S cpp -B tmp\qt-build -G "Visual Studio 18 2026" -A x64 `
  -DCMAKE_PREFIX_PATH=C:\Qt\6.8.3\msvc2022_64 `
  -DBUILD_TESTING=ON
cmake --build tmp\qt-build --config Release --parallel
ctest --test-dir tmp\qt-build -C Release --output-on-failure
```

构建后，规则目录、PowerShell 模块和 `backend_host.ps1` 会自动复制到
`StableTune.exe` 旁。

源码树内直接运行时，如果 Qt DLL 尚未部署，需要把 Qt 的 `bin` 加入当前进程
`PATH`：

```powershell
$env:PATH = 'C:\Qt\6.8.3\msvc2022_64\bin;' + $env:PATH
.\tmp\qt-build\qt\Release\StableTune.exe
```

## 安装与运行

`--prefix` 使用绝对路径。相对路径会让 Qt 的部署脚本无法生成 `qt.conf`：

```powershell
$prefix = (Resolve-Path .\tmp).Path + '\StableTune'
cmake --install tmp\qt-build --config Release --prefix $prefix
& "$prefix\bin\StableTune.exe"
```

安装后的程序不需要再手工设置 Qt 的 `PATH`，但机器上仍必须安装
PowerShell 7.4+。

## 检查参数

```powershell
.\StableTune.exe --smoke-test
.\StableTune.exe --page rules --screenshot rules.png
.\StableTune.exe --page overview --screenshot overview.png
```

`--smoke-test` 检查 UI 资源、38 条规则和回滚策略入口后退出。
