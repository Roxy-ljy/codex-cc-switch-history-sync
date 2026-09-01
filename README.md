# 基于 CC Switch 的 Codex 会话同步工具

用于 **Codex 聊天记录同步**、**Codex 历史会话同步**、**Codex 会话记录同步** 的 Windows 小工具。它可以在使用 cc-switch 切换官方 / 中转 provider 时，尽量保持同一套本地 Codex 会话历史可见。

> English: A Windows helper for Codex session history sync, Codex chat history sync, and keeping local Codex conversations visible when switching providers with cc-switch.

## 本次更新目标

本次更新主要解决 cc-switch 切换 Codex provider 后的状态残留问题：

- 修复同步窗口偶尔未真正执行，导致历史记录没有完成同步。
- 修复历史 provider 只能从官方改到中转、无法从中转改回官方的问题。
- 防止旧 provider 配置将当前 GPT-5.6 模型回退为 GPT-5.5 / GPT-5.4。
- 修复 Codex Desktop 使用过期登录缓存后出现的 `401 Unauthorized` / `token_expired`。
- 区分官方与中转 provider，避免模型配置和登录状态互相覆盖。
- 兼容新版 Codex Desktop 的 `ChatGPT.exe` 进程和 MSIX 启动方式。

更新后的自动流程为：检测 provider 变化 → 关闭 Codex → 按 provider 类型清理必要缓存 → 同步配置与历史记录 → 重新启动 Codex。

## 关键词

如果你在搜索这些问题，这个工具可能适用：

- Codex 聊天记录同步
- Codex 历史会话同步
- Codex 会话记录同步
- Codex conversations / sessions / history sync
- cc-switch 切换中转后 Codex 历史丢失
- Codex 切换 provider 后历史会话不可见
- Codex 本地会话恢复 / session_index 修复
- `~\.codex\sessions`、`state_5.sqlite`、`session_index.jsonl` 修复

## 解决什么问题

Codex 的本地历史会同时依赖 rollout 文件、`state_5.sqlite` 和 `session_index.jsonl`。使用 cc-switch 切换不同 Codex provider 后，历史可能因为 `model_provider` 不一致而分裂或不可见。

这个工具会：

- 监听 cc-switch 的当前 Codex provider 变化，并将检测到的 ProviderId 传入同步流程。
- 安全识别目标渠道：以 `cc-switch.db` 的当前 provider 为准，使用 watcher ProviderId 和 `settings.json` 作为回退；无法确定时停止同步，不猜测渠道。
- 每次切换时双向统一本地历史标记：官方 OpenAI 写成 `openai`，其余中转写成 `ccs`。
- 修复 Codex 本地历史索引和 SQLite 状态。
- 保留当前 Codex 顶层模型默认值，避免 cc-switch 旧 provider 配置把 `gpt-5.6-*` 回退成旧模型。
- 切到中转 provider 时清理会导致 `token_expired` 的 Codex Desktop 过期 web 登录缓存。
- 删除会覆盖 `auth.json` 的用户级 `CODEX_API_KEY` 环境变量。
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
3. 自动关闭正在运行的 Codex，避免旧 provider / 旧 token 状态残留；
4. 如果目标是中转 provider，清理 Codex Desktop 过期 web 登录缓存；
5. 按目标 provider 双向同步 rollout、SQLite 与会话索引；
6. 同步完成后自动启动 Codex。

手动同步：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CODEX_HOME\sync-codex-history.ps1"
```

手动同步会优先从 `cc-switch.db` 的当前记录识别目标 provider，并以 `settings.json` 作为回退；如果无法安全识别，脚本会在改写历史或认证状态前停止。

手动运行 UI 包装脚本时仍会询问是否关闭 Codex：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:CODEX_HOME\run-codex-history-sync-ui.ps1"
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
- Codex Desktop 的 Chromium web 登录缓存（仅中转 provider 自动切换时）
- 用户级 `CODEX_API_KEY` 环境变量覆盖项

它不会上传任何数据，也不会把你的会话同步到云端。所有处理都在本机完成。

注意：

- 同步会按当前目标渠道统一改写本地历史标记：官方为 `openai`，中转为 `ccs`；因此不会保留每条历史原始中转名。中转列表来自 cc-switch 运行时扫描，不依赖固定服务商名单。
- 官方与中转之间的往返切换均受支持；同步完成后，历史会按当前目标渠道重新标记并显示。
- 自动切换 provider 时会关闭 Codex，正在运行的任务可能会被中断。
- 工具不会备份 `auth.json`，也不会复制 API key 或登录 token；web 缓存清理前只做本地备份。
- 不要把自己的 `.codex`、`.cc-switch`、备份、`auth.json`、SQLite 数据库提交到 GitHub。

## 不包含什么

- 不修改 cc-switch 本体。
- 不提供健康检查脚本。
- 不清理 Codex 的 `logs_2.sqlite` 运行日志。
- 不处理跨设备同步。

## License

MIT
