# dsh-watch（DSH 宿主插件）

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

## 独立 API 扫码配置（2.1.0）

更新插件后需要重启 DSH 引擎。独立 API 聊天本身由手表直接请求服务商，不经过本插件。

- `POST /api/direct-provision/start`：配对令牌请求五分钟临时票据；返回相对 `/configure#票据` 链接。
- `GET /configure`：手机填写 HTTPS API 地址、Key、模型和 chat / responses 协议的页面；票据在 URL 片段中，不发送到页面请求路径。
- `POST /api/direct-provision/submit`：手机凭临时票据提交，需通过同源校验；不会测试 API、不会连接提交的地址。
- `POST /api/direct-provision/poll`：配对令牌读取配置，领取一次即销毁；返回内容只是草稿，手表需人工确认保存。
- `DELETE /api/direct-provision`：配对令牌撤销票据。

票据和配置仅存内存，最多八张；五分钟到期或插件卸载时清除。配置路由不继承普通接口的宽松 CORS，设有 CSP、禁止缓存/引用来源、JSON 类型与 16KiB 请求体限制。Key 不进入状态、日志、SSE 或磁盘。HTTP 配置链路仍可被同网段窃听或篡改，优先使用 HTTPS；不要分享二维码。

## 兼容性

- 旧功能仅在 Android dsh-go 的 proot 环境、DSH `0.2.1-rc.4` 实机验证；未做 Windows / macOS 桌面端实机验证。新增扫码配置已做真实本机 HTTP 集成测试，手表端仍需设备验证；
- 只用公开的 Cordis 事件与 Service：`approval` / `agents` / `sessions` / `sessionPersistence` /
  `agentPresets` / `agentDefaultModel` / `sessionTitle`，缺哪个就降级（不加载就报错）。

## 卸载

删掉 profile 的 `cordis.patch.yml` 里 `# --- dsh-watch` 开始的那一段，重启 DSH 即可；
或 `pwsh -File tools\install-plugin.ps1 -Profile <name> -Remove`（会用 `.bak-dshwatch` 备份还原）。
