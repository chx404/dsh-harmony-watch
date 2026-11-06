import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const current = await readFile(new URL('../host/index.js', import.meta.url), 'utf8');
// 将曾经的 DI 访问错误注回当前函数，避免测试依赖未提交的私人 backups。
const original = current
  .replace('const logged = agent?.session?.requestHeader?.()?.config', 'const logged = agent?.agent?.session?.requestHeader?.()?.config')
  .replace('installSelection(agentCtx, selectionFor(agent))', 'installSelection(agentCtx, selectionFor(agentCtx))');
assert.notEqual(original, current, '故障注入锚点必须仍存在');

function fixture(source, presetMode = 'absent', logged) {
  const handlers = new Map();
  const agentCtx = {
    on(name, callback) { handlers.set(name, callback); },
    get agent() { throw new Error('cannot get property "agent" without inject'); }
  };
  let selection = { provider: 'provider-a', model: 'model-a', reasoningEffort: 'high' };
  let mounted = false;
  const agent = { session: { requestHeader: () => logged ? { config: logged } : undefined } };
  const ctx = {
    get(name) {
      if (name === 'agentDefaultModel') return { currentSelection: () => selection };
      if (name === 'agentPresets') {
        if (presetMode === 'absent') return undefined;
        return {
          async resolve() {
            if (presetMode === 'failure') throw new Error('preset unavailable');
            return { id: 'standard' };
          },
          async mount(scope, id) {
            assert.equal(scope, agentCtx);
            assert.equal(id, 'standard');
            mounted = true;
          }
        };
      }
      throw new Error(`unexpected service ${name}`);
    }
  };
  // 执行实际插件函数，既不启动服务，也不访问生产会话或凭证。
  const install = source.slice(source.indexOf('function installSelection('), source.indexOf('\n// ---------------------------------------------------------------------------', source.indexOf('function installSelection(')));
  const composition = source.slice(source.indexOf('  function defaultSelection() {'), source.indexOf('  function agentOptionsFromPreset() {'));
  const sandbox = { ctx, warn() {} };
  vm.runInNewContext(`${install}\n${composition}\nglobalThis.compose = composeSetup;`, sandbox);
  return {
    async setup() {
      const result = await sandbox.compose();
      await result.setup(agentCtx, agent);
      return result;
    },
    async assemble() {
      const assembly = { variables: { existing: 'kept' } };
      return handlers.get('system-prompt/assemble')(assembly, { agent }, async () => assembly);
    },
    async request() {
      return handlers.get('agent/request')({}, async () => ({ provider: 'wrong', model: 'wrong', reasoningEffort: 'low', marker: true }));
    },
    update(next) { selection = next; },
    mounted() { return mounted; }
  };
}

for (const mode of ['absent', 'success', 'failure']) {
  test(`故障注入复现精确 DI 错误：${mode}`, async () => {
    const f = fixture(original, mode);
    await f.setup();
    await assert.rejects(f.assemble(), /cannot get property "agent" without inject/);
  });
  test(`修复后提示词及模型路由通过：${mode}`, async () => {
    const f = fixture(current, mode);
    await f.setup();
    const assembly = await f.assemble();
    assert.equal(assembly.variables.provider, 'provider-a');
    assert.equal(assembly.variables.model, 'model-a');
    assert.equal(assembly.variables.existing, 'kept');
    const request = await f.request();
    assert.equal(request.provider, 'provider-a');
    assert.equal(request.model, 'model-a');
    assert.equal(request.reasoningEffort, 'high');
    assert.equal(request.marker, true);
    assert.equal(f.mounted(), mode === 'success');
  });
}

test('恢复已有会话时保留其模型，不使用全局默认覆盖', async () => {
  const f = fixture(current, 'success', { provider: 'saved-provider', model: 'saved-model', reasoningEffort: 'medium' });
  await f.setup();
  await f.assemble();
  const request = await f.request();
  assert.equal(request.provider, 'saved-provider');
  assert.equal(request.model, 'saved-model');
  assert.equal(request.reasoningEffort, 'medium');
});

test('无请求头的新会话在组装时读取最新默认模型', async () => {
  const f = fixture(current);
  await f.setup();
  f.update({ provider: 'new-provider', model: 'new-model' });
  await f.assemble();
  const request = await f.request();
  assert.equal(request.provider, 'new-provider');
  assert.equal(request.model, 'new-model');
  assert.equal('reasoningEffort' in request, false);
});
