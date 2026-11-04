# dsh-watch（电脑端插件）

跑在 DSH 进程里的最小 HTTP/SSE 服务，给手表 App / 浏览器用。

- 零依赖：只用 Node 内建模块（`node:http` / `node:crypto` / `node:fs`）；
- **审批**：`ctx.on('approval/request', …, { prepend: true })`，手表在线时抢在 Web UI 之前接管；
  手表离线 / 超时 / 回合取消 → 交还下一条应答者，不会把回合卡死；
- **事件**：`ctx.on('session/event')` 把 `tool/call`、`tool/result`、`assistant/message`、`turn/*`、
  `session/title` 归一化后推给手表；图片块只带附件 id 与尺寸，正文由 `/api/image` 按需读取；监听器全部带 guard，异常只记日志不外抛；
- **指令**：`agent.followup()`（排队下一轮）/ `agent.steer()`（插入当前回合下一步）；
- **会话**：`/api/sessions` 列出实时 + 持久化会话，`/api/new` 新建，`/api/select` 切到冷会话时
  用 `agentPresets.resolve/mount` + `agents.resume` 按需恢复。

## 配置

见 `cordis.patch.yml`。字段：`port` / `bind` / `token` / `approvalMode` / `approvalTimeoutMs` /
`defaultCwd` / `maxText` / `discovery` / `discoveryPort` / `pairingTtlMs`。

令牌自动生成并写到 `$DSH_HOME/dsh-watch.json`（也可用配置里的 `token` 覆盖）。
配对码只在本机 `/pair` 页面和启动日志里出现，每次配对成功自动换新。

## 接口

见仓库根 [README](../README.md#五http-接口自测--二次开发)。

图片：`GET /api/image?token=<token>&sessionId=<id>&seq=<事件序号>&i=<第几张>`，返回原图字节；
拿不到附件（内存后端 / 已 offload）时返回 404，手表显示占位。

## 兼容性

- 在 DSH `0.1.0-rc.6`（CLI）与 `0.2.0-rc.2`（桌面端同版本运行时）上实测通过；
- 只用公开的 Cordis 事件与 Service：`approval` / `agents` / `sessions` / `sessionPersistence` /
  `agentPresets` / `agentDefaultModel` / `sessionTitle`，缺哪个就降级（不加载就报错）。

## 卸载

删掉 profile 的 `cordis.patch.yml` 里 `# --- dsh-watch` 开始的那一段，重启 DSH 即可；
或 `pwsh -File tools\install-plugin.ps1 -Profile <name> -Remove`（会用 `.bak-dshwatch` 备份还原）。
