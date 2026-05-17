# 基于 CC Switch 的 Codex 会话同步工具

让 Windows 上的 Codex 在使用 cc-switch 切换官方 / 中转 provider 时，尽量保持同一套本地会话历史可见。

> English: A small Windows helper that keeps local Codex session history visible when switching Codex providers with cc-switch.

## 解决什么问题

Codex 的本地历史会同时依赖 rollout 文件、`state_5.sqlite` 和 `session_index.jsonl`。使用 cc-switch 切换不同 Codex provider 后，历史可能因为 `model_provider` 不一致而分裂或不可见。

这个工具会：

- 监听 cc-switch 的当前 Codex provider 变化。
- 运行时扫描 cc-switch 中现有的 Codex provider：官方 OpenAI 保持 `openai`，其余中转统一写成 `ccs`。
- 修复 Codex 本地历史索引和 SQLite 状态。
- 切换后弹出一个简洁进度窗口。
- 成功后自动启动 Codex。
- 每天首次同步前自动备份关键状态。

## 支持范围

- Windows
- OpenAI Codex Desktop / Codex CLI
- cc-switch
- PowerShell 5.1+
- Python 可用，且能运行标准库 `sqlite3`

## 安装

在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

安装脚本会：

- 复制核心脚本到 `$env:CODEX_HOME`，默认 `~\.codex`
- 创建 Windows 启动项 `Codex History Sync.lnk`
- 启动后台 watcher
- 备份安装前的相关状态到 `~\.codex\history-sync-tool-backups\install_<timestamp>`

## 使用

安装后正常使用 cc-switch。点击某个 Codex provider 的“启用”后：

1. watcher 检测到 provider 变化；
2. 弹出同步进度窗口；
3. 如果 Codex 正在运行，会询问是否关闭；
4. 自动同步会话历史；
5. 同步完成后自动启动 Codex。

手动同步：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CODEX_HOME\sync-codex-history.ps1"
```

## 恢复 / 卸载

只停用工具，不恢复数据库：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore.ps1
```

恢复最近一次安装备份：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore.ps1 -RestoreLatestBackup
```

恢复数据库前脚本会要求输入 `RESTORE` 确认。

## 风险说明

这个工具会修改 Codex 本地状态索引，包括：

- `config.toml`
- `session_index.jsonl`
- `state_5.sqlite`
- cc-switch 的 Codex provider 配置

它不会上传任何数据，也不会把你的会话同步到云端。所有处理都在本机完成。

注意：

- 中转历史会统一标记为 `ccs`，不会保留每条历史原始中转名；中转列表来自 cc-switch 运行时扫描，不依赖固定服务商名单。
- 如果你选择关闭 Codex，正在运行的任务可能会被中断。
- 工具不会备份 `auth.json`，也不会复制 API key 或登录 token。
- 不要把自己的 `.codex`、`.cc-switch`、备份、`auth.json`、SQLite 数据库提交到 GitHub。

## 不包含什么

- 不修改 cc-switch 本体。
- 不提供健康检查脚本。
- 不清理 Codex 的 `logs_2.sqlite` 运行日志。
- 不处理跨设备同步。

## License

MIT
