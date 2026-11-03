/** Session-only model selection bridge for the installed DSH controller generation. */
export function createWatchModelControl(ctx) {
  const mounted = new WeakMap()
  const service = (name) => {
    try { return ctx.get(name) } catch { return undefined }
  }
  const controller = () => service('sessionController')
  const failure = (code, message) => Object.assign(new Error(message), { code })
  const clean = (value) => {
    if (!value || typeof value.provider !== 'string' || !value.provider
      || typeof value.model !== 'string' || !value.model) return null
    return {
      provider: value.provider,
      model: value.model,
      ...(typeof value.reasoningEffort === 'string' && value.reasoningEffort
        ? { reasoningEffort: value.reasoningEffort } : {}),
    }
  }
  const installed = (agent, owner) => {
    if (!agent || !owner) return undefined
    const recorded = mounted.get(agent)
    return owner.selections?.get?.(agent)
      ?? (recorded?.owner === owner ? recorded.selection : undefined)
  }
  const current = (agent) => {
    try {
      const shared = installed(agent, controller()?.agents)
      if (shared) return clean(shared.current)
      const header = agent?.session?.requestHeader?.()
      if (header?.config) {
        const { reasoningEffort, ...route } = header.config
        return clean({ ...route,
          ...(header.adapterDefaults?.reasoningEffort === true ? {} : { reasoningEffort }),
        })
      }
      return clean(service('agentDefaultModel')?.currentSelection?.())
    } catch { return null }
  }
  const mount = (agent) => {
    const owner = controller()?.agents
    if (!agent || typeof owner?.selectionFor !== 'function') return false
    if (!installed(agent, owner)) {
      const selection = owner.selectionFor(agent)
      if (!selection) throw failure('model-control/unsupported', '当前 DSH 未提供会话模型选区。')
      mounted.set(agent, { owner, selection })
    }
    return true
  }
  const load = async () => {
    const sc = controller()
    if (typeof sc?.modelCatalog !== 'function') {
      throw failure('model-control/unsupported', '当前 DSH 不支持读取可用模型目录。')
    }
    const value = await sc.modelCatalog()
    if (!Array.isArray(value?.groups)) {
      throw failure('model-control/unsupported', '当前 DSH 模型目录格式不兼容。')
    }
    return value
  }
  const catalog = async (agent) => {
    const value = await load()
    return {
      providers: value.groups.filter(g => typeof g?.id === 'string' && Array.isArray(g.models))
        .map(g => ({
          id: g.id,
          name: typeof g.name === 'string' ? g.name : g.id,
          models: g.models.filter(m => typeof m?.id === 'string').map(m => ({
            id: m.id,
            name: typeof m.name === 'string' ? m.name : m.id,
          })),
        })),
      selection: current(agent) ?? clean(value.default),
    }
  }
  const select = async (agent, request) => {
    const { provider, model } = request ?? {}
    if (typeof provider !== 'string' || !provider.trim()
      || typeof model !== 'string' || !model.trim()) {
      throw failure('model-control/invalid', '请选择有效的供应商和模型。')
    }
    const sc = controller()
    const owner = sc?.agents
    const llm = service('llm')
    if (typeof sc?.modelCatalog !== 'function'
      || typeof owner?.selectForNextRequest !== 'function'
      || typeof owner?.serializeImageAdmission !== 'function'
      || typeof llm?.resolveCallConfig !== 'function') {
      throw failure('model-control/unsupported', '当前 DSH 不支持安全的会话级模型切换。')
    }
    if (!installed(agent, owner)) {
      throw failure('model-control/unmounted', '该会话尚未接入共享模型选区，请重启宿主后重新打开会话。')
    }
    return owner.serializeImageAdmission(agent, async () => {
      const value = await load()
      const target = value.groups.find(g => g.id === provider)?.models?.find(m => m.id === model)
      if (!target) throw failure('model-control/unavailable', '所选供应商或模型当前不可用，请刷新列表。')
      const previous = current(agent)
      const retained = previous?.provider === provider && previous.model === model
        && target.reasoning?.efforts?.some(e => e.id === previous.reasoningEffort)
        ? previous.reasoningEffort : undefined
      const effort = retained ?? target.reasoning?.defaultEffort
      const resolved = await llm.resolveCallConfig({
        provider, model,
        ...(effort === undefined ? {} : { reasoningEffort: effort }),
      })
      const selected = clean(resolved)
      if (!selected || selected.provider !== provider || selected.model !== model) {
        throw failure('model-control/unsupported', 'DSH 返回的模型选区与所选路由不一致。')
      }
      owner.selectForNextRequest(agent, selected)
      return { selected, appliesTo: 'next-request' }
    })
  }
  return { mount, current, catalog, select }
}
