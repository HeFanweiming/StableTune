# 当前发布

- 当前版本：`0.1.9.2`
- 构建日期：`2026-09-20`
- 推荐启动器：`Start-StableTune.cmd`
- 推荐安装包：`dist/StableTune-prototype-v0.1.9.2-20260920.zip`
- 中文说明：`README.md`
- 仓库结构：`docs/REPOSITORY-GUIDE.zh-CN.md`
- 发布记录：`docs/RELEASES.md`

当前版本修复 Windows 启动器在部分系统上因 LF 换行和控制台代码页导致的
CMD 解析错误。启动器现统一使用 CRLF 和 ASCII 状态信息，便携版可从根目录
或 `tools` 目录定位 `bin\StableTune.exe`。38 项规则和执行行为保持不变；
内部 Felix API、`FELIX_*` 环境变量及旧状态目录继续保留，用于兼容已有历史、
快照和回滚数据。
