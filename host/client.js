/**
 * dsh-watch — Client 半边（桌面端「设置 → 手表远程」入口）。
 *
 * 以 dsh.client bundle 形式加载：注册 settings.section 一页，展示
 *   插件是否在跑 / 局域网地址 / 在线设备数 / 审批模式，
 *   并提供「打开配对页」「复制地址」「刷新」。
 *
 * 安全：这里只读 /api/local-status（该接口服务端限定 loopback、且不含令牌和配对码）。
 * 配对码仍然只从 /pair 页面看，避免任意本机网页都能读到它。
 */
window.__ModuleLoader__.load({
  id: 'dsh-watch',
  factory: (require) => {
    const React = require('react')
    const h = React.createElement

    const module = { exports: {} }
    const exports = module.exports

    const DEFAULT_PORT = 8765
    const inject = ['slots']

    const CSS = [
      '.dsw-card{display:flex;flex-direction:column;gap:12px;font-size:13px;color:var(--dsw-alias-label-primary)}',
      '.dsw-card .head{display:flex;align-items:center;gap:8px}',
      '.dsw-card .dot{width:9px;height:9px;border-radius:50%;background:var(--dsw-alias-border-l2,#6b7280);flex:none}',
      '.dsw-card .dot.on{background:#22c55e}',
      '.dsw-card .dot.busy{background:#f59e0b}',
      '.dsw-card .name{font-weight:600}',
      '.dsw-card .muted{color:var(--dsw-alias-label-secondary);font-size:12px}',
      '.dsw-card .panel{background:var(--dsw-alias-bg-layer-1);border:1px solid var(--dsw-alias-border-l1);border-radius:10px;padding:10px 12px;display:flex;flex-direction:column;gap:6px}',
      '.dsw-card .row{display:flex;justify-content:space-between;gap:10px;align-items:center}',
      '.dsw-card code{background:var(--dsw-alias-bg-layer-2);border-radius:6px;padding:1px 6px;font-size:12px}',
      '.dsw-card .actions{display:flex;gap:8px;flex-wrap:wrap}',
      '.dsw-card button{background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary);border:1px solid var(--dsw-alias-border-l1);border-radius:8px;padding:5px 12px;font-size:12px;cursor:pointer}',
      '.dsw-card button:hover{border-color:var(--dsw-alias-brand-primary)}',
      '.dsw-card button.primary{background:var(--dsw-alias-button-primary-fill,var(--dsw-alias-brand-primary));border-color:transparent;color:var(--dsw-alias-label-primary-foreground,#fff)}',
      '.dsw-card .ok{color:#22c55e}',
      '.dsw-card .bad{color:#e5484d}',
    ].join('')

    function statusUrl() {
      return 'http://127.0.0.1:' + DEFAULT_PORT + '/api/local-status'
    }

    function Panel() {
      const [data, setData] = React.useState(null)
      const [error, setError] = React.useState('')
      const [copied, setCopied] = React.useState('')

      const refresh = React.useCallback(() => {
        Promise.resolve()
          .then(() =>
            fetch(statusUrl(), { cache: 'no-store' }).then((response) => {
              if (!response.ok) throw new Error('HTTP ' + response.status)
              return response.json()
            }),
          )
          .then((json) => {
            setData(json)
            setError('')
          })
          .catch((reason) => {
            setData(null)
            setError(String((reason && reason.message) || reason))
          })
      }, [])

      React.useEffect(() => {
        refresh()
        const timer = setInterval(refresh, 5000)
        return () => clearInterval(timer)
      }, [refresh])

      const copy = (text, label) => {
        try {
          navigator.clipboard.writeText(text)
          setCopied(label)
          setTimeout(() => setCopied(''), 1500)
        } catch (reason) {
          setCopied('复制失败')
        }
      }

      const running = data !== null
      const dotClass = 'dot' + (running ? (data.running ? ' busy' : ' on') : '')
      const addresses = (data && Array.isArray(data.addresses) ? data.addresses : []).filter(Boolean)

      return h(
        'div',
        { className: 'dsw-card' },
        h(
          'div',
          { className: 'head' },
          h('span', { className: dotClass }),
          h('span', { className: 'name' }, running ? '插件运行中' : '插件未运行'),
          running ? h('span', { className: 'muted' }, 'v' + data.version + ' · 端口 ' + data.port) : null,
        ),
        running
          ? h(
              'div',
              { className: 'panel' },
              h(
                'div',
                { className: 'row' },
                h('span', { className: 'muted' }, '这台电脑'),
                h('code', null, data.host),
              ),
              h(
                'div',
                { className: 'row' },
                h('span', { className: 'muted' }, '在线设备'),
                h('span', null, String(data.devices || 0) + ' 台'),
              ),
              h(
                'div',
                { className: 'row' },
                h('span', { className: 'muted' }, '会话'),
                h('span', null, String(data.sessions || 0) + ' 个' + (data.running ? '（模型在跑）' : '')),
              ),
              h(
                'div',
                { className: 'row' },
                h('span', { className: 'muted' }, '审批'),
                h('span', null, data.approvalMode === 'watch' ? '手表在线时由手表审批' : '只旁观（仍走界面弹窗）'),
              ),
            )
          : h(
              'div',
              { className: 'panel' },
              h('span', { className: 'bad' }, error ? '连接失败：' + error : '没有响应'),
              h(
                'span',
                { className: 'muted' },
                '确认 DSH 已重启并加载 dsh-watch 插件；端口不是 ' + DEFAULT_PORT + ' 时请改插件配置。',
              ),
            ),
        running && addresses.length > 0
          ? h(
              'div',
              { className: 'panel' },
              h('span', { className: 'muted' }, '手表/手机可用的地址'),
              ...addresses.map((address, index) =>
                h(
                  'div',
                  { className: 'row', key: address + index },
                  h('code', null, address),
                  h(
                    'button',
                    { onClick: () => copy(address, address) },
                    copied === address ? '已复制' : '复制',
                  ),
                ),
              ),
            )
          : null,
        h(
          'div',
          { className: 'actions' },
          h(
            'button',
            {
              className: 'primary',
              onClick: () => window.open('http://127.0.0.1:' + DEFAULT_PORT + '/pair', '_blank'),
            },
            '打开配对页（6 位码）',
          ),
          h('button', { onClick: refresh }, '刷新'),
        ),
        h(
          'div',
          { className: 'muted' },
          '配对：手表「连接电脑」选这台电脑 → 输入配对页上的 6 位数字。' +
            '手表与电脑要在同一 WiFi；防火墙需放行 TCP ' + DEFAULT_PORT + ' 与 UDP 8766。',
        ),
        h('style', null, CSS),
      )
    }

    function apply(ctx) {
      const slots = ctx.get ? ctx.get('slots') : undefined
      if (!slots) return
      slots.inject('settings.section', () =>
        slots.register(
          { name: 'settings.section', id: 'watch', order: 42, label: '手表远程' },
          () => h(Panel, {}),
        ),
      )
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  },
})
