import test from 'node:test'
import assert from 'node:assert/strict'
import { createWatchModelControl } from '../host/watch-model-control.mjs'

function fixture() {
  const calls = { mounts: 0, commits: [], resolves: [], locks: 0, defaults: 0 }
  const agent = { session: { requestHeader: () => undefined }, running: true }
  const directory = {
    default: { provider: 'a', model: 'one' },
    groups: [
      { id: 'a', name: 'A', secret: 'never expose', models: [
        { id: 'one', name: 'One', reasoning: { efforts: [{ id: 'high' }, { id: 'low' }], defaultEffort: 'low' } },
        { id: 'plain', name: 'Plain' },
      ] },
      { id: 'b', name: 'B', models: [
        { id: 'two', name: 'Two', reasoning: { efforts: [{ id: 'high' }, { id: 'auto' }], defaultEffort: 'auto' } },
      ] },
    ], failures: [{ id: 'offline', message: 'private upstream error' }],
  }
  let chain = Promise.resolve()
  const owner = {
    selections: new WeakMap(),
    selectionFor(agent) {
      const old = this.selections.get(agent)
      if (old) return old
      calls.mounts++
      const selection = { current: { provider: 'a', model: 'one', reasoningEffort: 'high' } }
      this.selections.set(agent, selection)
      return selection
    },
    serializeImageAdmission(_agent, operation) {
      calls.locks++
      const next = chain.then(operation)
      chain = next.catch(() => {})
      return next
    },
    selectForNextRequest(agent, selection) {
      calls.commits.push(selection)
      this.selectionFor(agent).current = selection
    },
  }
  const services = {
    sessionController: { agents: owner, modelCatalog: async () => directory },
    agentDefaultModel: {
      currentSelection: () => directory.default,
      saveSelection: () => { calls.defaults++; throw new Error('must not write defaults') },
    },
    llm: { resolveCallConfig: async config => {
      calls.resolves.push(config)
      return { ...config, maxTokens: 4096, unrelated: 'not selected' }
    } },
  }
  const ctx = { get: name => services[name] }
  return { control: createWatchModelControl(ctx), calls, agent, directory, owner, services }
}

test('mount is idempotent; current/catalog never install hooks', async () => {
  const { control, calls, agent } = fixture()
  assert.deepEqual(control.current(agent), { provider: 'a', model: 'one' })
  await control.catalog(agent)
  assert.equal(calls.mounts, 0)
  assert.equal(control.mount(agent), true)
  assert.equal(control.mount(agent), true)
  assert.equal(calls.mounts, 1)
  assert.equal(control.current(agent).reasoningEffort, 'high')
})

test('existing UI agent shares selection without duplicate installation', async () => {
  const { control, calls, agent, owner } = fixture()
  owner.selectionFor(agent)
  control.mount(agent)
  await control.select(agent, { provider: 'b', model: 'two' })
  assert.equal(calls.mounts, 1)
  assert.deepEqual(control.current(agent), { provider: 'b', model: 'two', reasoningEffort: 'auto' })
})

test('catalog exposes only safe names and opaque IDs', async () => {
  const { control, agent } = fixture()
  const result = await control.catalog(agent)
  assert.deepEqual(result, {
    providers: [
      { id: 'a', name: 'A', models: [{ id: 'one', name: 'One' }, { id: 'plain', name: 'Plain' }] },
      { id: 'b', name: 'B', models: [{ id: 'two', name: 'Two' }] },
    ], selection: { provider: 'a', model: 'one' },
  })
})

test('same model keeps supported effort; ignores client effort and extra fields', async () => {
  const { control, agent, calls } = fixture()
  control.mount(agent)
  assert.deepEqual(await control.select(agent, { provider: 'a', model: 'one', reasoningEffort: 'low' }), {
    selected: { provider: 'a', model: 'one', reasoningEffort: 'high' }, appliesTo: 'next-request',
  })
  assert.equal(calls.defaults, 0)
  assert.equal(calls.locks, 1)
  assert.deepEqual(calls.commits, [{ provider: 'a', model: 'one', reasoningEffort: 'high' }])
})

test('cross-provider switch does not reuse even a supported same-named effort', async () => {
  const { control, agent, calls } = fixture()
  control.mount(agent)
  await control.select(agent, { provider: 'b', model: 'two' })
  assert.deepEqual(calls.resolves[0], { provider: 'b', model: 'two', reasoningEffort: 'auto' })
  assert.equal(agent.running, true)
})

test('nonreasoning model clears inherited effort', async () => {
  const { control, agent, calls } = fixture()
  control.mount(agent)
  await control.select(agent, { provider: 'a', model: 'plain' })
  assert.deepEqual(calls.commits[0], { provider: 'a', model: 'plain' })
})

test('removed same-model effort falls back to target default', async () => {
  const { control, agent, directory, calls } = fixture()
  control.mount(agent)
  directory.groups[0].models[0].reasoning.efforts = [{ id: 'low' }]
  await control.select(agent, { provider: 'a', model: 'one' })
  assert.equal(calls.commits[0].reasoningEffort, 'low')
})

test('unknown provider/model and malformed inputs fail without resolving or committing', async () => {
  const { control, agent, calls } = fixture()
  control.mount(agent)
  for (const value of [{ provider: 'missing', model: 'one' }, { provider: 'a', model: 'missing' },
    { provider: '', model: 'one' }, { provider: 'a', model: 1 }]) {
    await assert.rejects(control.select(agent, value))
  }
  assert.equal(calls.resolves.length, 0)
  assert.equal(calls.commits.length, 0)
})

test('unmounted agents fail closed instead of installing another set of hooks', async () => {
  const { control, agent, calls } = fixture()
  await assert.rejects(control.select(agent, { provider: 'a', model: 'one' }), { code: 'model-control/unmounted' })
  assert.equal(calls.mounts, 0)
})

test('missing generation capabilities fail closed and mount supports fallback', async () => {
  const control = createWatchModelControl({ get: () => undefined })
  assert.equal(control.mount({}), false)
  assert.equal(control.current({}), null)
  await assert.rejects(control.catalog({}), { code: 'model-control/unsupported' })
  await assert.rejects(control.select({}, { provider: 'a', model: 'one' }), { code: 'model-control/unsupported' })
})

test('header display excludes adapter-defaulted effort without mounting', () => {
  const { control, agent, calls } = fixture()
  agent.session.requestHeader = () => ({
    config: { provider: 'a', model: 'one', reasoningEffort: 'high', apiKey: 'not returned' },
    adapterDefaults: { reasoningEffort: true },
  })
  assert.deepEqual(control.current(agent), { provider: 'a', model: 'one' })
  assert.equal(calls.mounts, 0)
})

test('failed capability normalization does not commit', async () => {
  const { control, agent, services, calls } = fixture()
  control.mount(agent)
  services.llm.resolveCallConfig = async () => { throw new Error('unsupported effort') }
  await assert.rejects(control.select(agent, { provider: 'a', model: 'one' }), /unsupported effort/)
  assert.equal(calls.commits.length, 0)
})

test('concurrent selections use shared controller serialization', async () => {
  const { control, agent, calls } = fixture()
  control.mount(agent)
  await Promise.all([
    control.select(agent, { provider: 'b', model: 'two' }),
    control.select(agent, { provider: 'a', model: 'one' }),
  ])
  assert.equal(calls.locks, 2)
  assert.deepEqual(calls.commits.map(s => [s.provider, s.model, s.reasoningEffort]), [
    ['b', 'two', 'auto'], ['a', 'one', 'low'],
  ])
})
