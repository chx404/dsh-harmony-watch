# dsh-harmony-watch

在鸿蒙手表上遥控 DeepSeek Harness（DSH）的轻量客户端：看模型动作、发指令、审批提权、切会话、切模型、看图片消息。首次打开有五页上手引导，手表走 HTTP 轮询，手机或电脑跑一个 DSH 插件做桥。

> A HarmonyOS watch remote for DeepSeek Harness: live tool stream, prompts, approvals, session and model switching, with a built-in first-run guide. The watch talks to a small DSH plugin over HTTP.

> **关于作者**
>
> 这个项目由一名初三学生利用课余时间、在 AI 辅助下完成。能力和时间都有限，难免有粗糙或者没考虑到的地方，请多包涵。遇到问题欢迎提 issue，我会尽量修。

## 组成

```
鸿蒙手表 App ──HTTP/轮询──▶ dsh-harmony-watch 插件（跑在 DSH 进程里）
                              ├── 6 位配对码（24 小时有效）
                              ├── 审批转发（先于 Web UI）
                              ├── 工具/回复事件流
                              ├── 指令下发（followup / steer）
                              ├── 会话列表与恢复
                              ├── 当前会话模型切换
                              └── 图片消息（按需拉原图）
```

- `watch-app/`：鸿蒙工程（ArkTS，API 20+，WATCH 系列圆屏）
- `host/`：DSH 插件，零依赖，只用 Node 内建模块
- `scripts/`：一键安装脚本

## 快速开始

### 1. 装插件

```bash
./scripts/install.sh web      # macOS / Linux
powershell -File scripts/install.ps1 web   # Windows
```

脚本会装插件、备好 cloudflared，并打印后续配置提示。装完重启 DSH。

### 2. 装手表 App

用 DevEco Studio 或自己的工具链编译 `watch-app/`，签名后侧载到手表。

### 3. 配对

启动日志里会打印 6 位配对码和外网地址；手机浏览器打开 `http://127.0.0.1:8765/pair` 也能看。

手表连接页填地址和配对码，配对码一天内有效。

手表第一次启动会先显示五页引导，讲完再进配对页；不想看可以直接「跳过」，之后在「菜单 → 使用引导」里还能重看。

## 手表端功能

- **上手引导**：第一次打开时自动进入，五页讲清配对、左右切屏、发指令、审批和停止；可以跳过，之后从「菜单 → 使用引导」重看
- **三屏滑动**：菜单 / 对话 / 快捷三页横向切换，底部指示条跟着手指连续走，松手后的惯性段也同步，不会等页面停稳才补一下
- **会话流**：文字回复完整显示；工具调用、执行结果收成一行，点开看完整参数/输出；消息按左右气泡分列
- **图片消息（实验性）**：宿主会把图片元数据推给手表，但手表端渲染还没调通，目前可能看不到；文字消息、表情字符正常
- **审批**：主机请求提权时自动切到审批页，允许 / 拒绝；超时交还电脑
- **模型切换**：列表按服务商分组，切换后提示「下一轮生效」
- **停止**：两段式确认，第一下只是变红，3 秒内再点才真正中断
- **通知**：App 不在前台时，回合结束或出现新审批会发系统通知；诊断页可以测试通知、看后台状态
- **诊断**：菜单 → 诊断，看当前地址、链路、轮询间隔、失败次数、事件/会话数，可清空本地缓存
- **断线重连**：失败后按 2s → 4s → 8s → 16s → 30s 退避，连上立刻回到 2s

## 远程连接

插件默认 `tunnel: auto`，按顺序选择：

1. **局域网**：同一 Wi-Fi，填 `IP:8765`，零配置
2. **cloudflared 快速隧道**：没配置时自动下载并拉起，地址每次重启会变
3. **固定隧道**：配置 `tunnelToken` 和 `remoteUrl`，地址不变
4. **frp**：`tunnel: frp` 加 `frpServer` 等四项，需要自己的服务器和 frpc

手表会记住内网、外网两个地址。设置里可选「自动 / 内网 / 外网」：自动模式走外网时每 30 秒探测一次内网，回到同一 Wi-Fi 自动切回。

## 配置

改 profile 的 `cordis.patch.yml`，给 `dsh-harmony-watch` 加字段：

```yaml
- id: dsh-harmony-watch
  name: dsh-harmony-watch
  config:
    port: 8765
    tunnel: auto
    pairingTtlMs: 86400000
    # tunnelToken: <Cloudflare 隧道 token>
    # remoteUrl: https://你的域名
    # frpServer: 你的服务器
    # frpRemotePort: 6000
```

## 桌面端兼容性

代码不依赖 Android 或 proot，路径走 `os.homedir()`，子进程走 `spawn`。插件用的 DSH 服务：

`agents` / `sessions` / `agentPresets` / `agentDefaultModel` / `sessionPersistence` / `sessionTitle`，模型切换额外用 `sessionController` 和 `llm`（拿不到就明确失败，不影响其他功能）。

目前只在 **Android 版 dsh-go 的 proot 环境**（DSH 0.2.1-rc.4）实机验证过，没有在 Windows / macOS 桌面端测过。已知风险：

- Windows 下 cloudflared 下载与路径处理
- 桌面端防火墙首次放行 8765
- 不同 DSH 版本的服务接口差异，缺服务时会降级或报错

## 已知限制

- 快速隧道地址会变，长期使用建议固定隧道或 frp
- 图片显示是实验性的：`/api/image` 已能在宿主侧取到原图，手表端 `Image` 加载仍未验证通过（2.0.9+）；被 offload 出会话的旧图无法再取
- 审批卡片只展示工具名和原因摘要
- 穿戴设备不支持长时后台任务（`startBackgroundRunning` 返回 9800005），退后台后靠系统「延迟挂起」维持轮询，额度（通常几分钟）用完会暂停；长时间离开手表时通知可能收不到
- 后台通知还依赖系统允许通知，手表开了勿扰也不会响
- 引导的「已看过」标记存在手表本地偏好里，清除应用数据后会再出现一次
- 手表需侧载，签名和安装流程因设备而异

## License

MIT
