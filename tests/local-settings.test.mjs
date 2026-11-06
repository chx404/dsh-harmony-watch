import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const source = await readFile(process.env.LOCAL_CHAT_SOURCE || new URL('../watch-app/entry/src/main/ets/common/LocalChat.ets', import.meta.url), 'utf8');
const config = (id = 'one') => ({ baseUrl: `https://api-${id}.example.com/v1`, model: `model-${id}`, apiKey: `private-key-${id}`, protocol: 'chat' });
const profile = (id = 'one') => ({ ...config(id), id, name: `API ${id}` });
function extract(name) {
  const start = source.search(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
  assert.notEqual(start, -1, `missing ${name}`);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const names = ['pageChanged', 'handleCrown', 'u', 'loadConfig', 'loadProfiles', 'refreshProfiles', 'profileItems', 'profileAction', 'discardDraft', 'openProfile', 'editingChanged', 'fillDraft', 'draft', 'draftChanged', 'backRequested', 'returnTo', 'closePage', 'saveConfig', 'saveProfile', 'removeProfile', 'clearConfig', 'stopSend', 'newChat', 'send', 'backgroundChanged', 'beginProvision', 'pollProvision'];
const js = ts.transpileModule(`class Harness {\n${names.map(extract).join('\n')}\n}`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
function harness(overrides = {}) {
  const calls = { upsert: [], select: [], remove: [], profileConfigured: [], profilesChanged: 0, save: [], clear: 0, configured: [], cleared: 0, closed: 0, reset: 0, cancel: 0, send: 0, stopProvision: 0, editing: [], animations: [] };
  const copyConfig = c => ({ baseUrl: c.baseUrl, model: c.model, apiKey: c.apiKey, protocol: c.protocol });
  const validate = c => { if (!c.apiKey || !c.model || !c.baseUrl.startsWith('https://')) throw Error('invalid'); return copyConfig(c); };
  let records = [profile(), profile('two')], selectedId = 'one';
  const profileStore = {
    async load() { return { profiles: this.list(), selectedId, notice: '应用私有存储' }; },
    list() { return records.map(p => ({ ...p })); },
    active() { const p = records.find(p => p.id === selectedId); return p ? { ...p } : undefined; },
    async upsert(c, name, id) {
      calls.upsert.push({ config: { ...c }, name, id });
      if (id && !records.some(p => p.id === id)) throw Error('unknown id');
      const p = { ...c, id: id || 'new-id', name: name || 'New API' };
      records = id ? records.map(old => old.id === id ? p : old) : [...records, p]; return { ...p };
    },
    async select(id) { calls.select.push(id); selectedId = id; return { ...records.find(p => p.id === id) }; },
    async remove(id) { calls.remove.push(id); records = records.filter(p => p.id !== id); if (selectedId === id) selectedId = records[0]?.id || ''; }
  };
  const Harness = new Function('copyDirectConfig', 'validateDirectConfig', 'pollDirectProvision', 'CrownAction', 'animateTo', 'Curve', 'normalizeDirectProvisionHost', 'startDirectProvision', 'directProvisionQrLink', 'cancelDirectProvision', 'setTimeout', 'clearTimeout', `${js}\nreturn Harness;`)(
    copyConfig, validate, async () => ({ config: config('phone'), status: 'ready' }), { BEGIN: 0, UPDATE: 1, END: 2 },
    (options, change) => { calls.animations.push(options); change(); }, { EaseOut: 'ease-out' }, b => b,
    async () => ({ id: 'ticket', pagePath: '/phone', expiresAt: Date.now() + 300000 }),
    () => 'https://host.example/phone?ticket=public', async () => {}, () => 1, () => {}
  );
  const value = Object.assign(new Harness(), {
    settingsOnly: true, profileId: '', page: 'profiles', alive: true, loading: false, saving: false, configured: true,
    screenWidth: 233, screenHeight: 233, profiles: profileStore.list(), selectedProfileId: 'one', editingProfileId: '', nameDraft: '', inputEditing: false,
    crownMotion: { begin() {}, end() {}, cancel() {}, updateAtEdges(delta, offset) { return offset + delta; } },
    busy: false, appInBackground: false, imported: false, clearArmed: false, saveArmed: false,
    uiGeneration: 0, provisionGeneration: 1, status: '', storageNotice: '', prompt: 'keep draft', pendingText: '',
    messages: [{ role: 'user', content: 'persistent history sentinel' }], activeConfig: config(),
    baseDraft: '', keyDraft: '', modelDraft: '', protocolDraft: 'chat', hostBase: 'https://host.example', hostToken: 'private-host-token', qrBusy: false,
    settingsScroll: { scrollTo() {} }, profileStore,
    conversation: { reset() { calls.reset++; }, cancel() { calls.cancel++; }, async send() { calls.send++; } },
    stopProvision() { calls.stopProvision++; },
    store: { async load() { return { config: config(), persistent: true, notice: 'legacy' }; }, async save(c) { calls.save.push(c); return { config: c, persistent: true, notice: 'legacy' }; }, async clear() { calls.clear++; } },
    onConfigured(c) { calls.configured.push(c); }, onConfigCleared() { calls.cleared++; },
    onProfileConfigured(p) { calls.profileConfigured.push(p); }, onProfilesChanged() { calls.profilesChanged++; },
    onEditingChanged(editing) { calls.editing.push(editing); }, onClose() { calls.closed++; }, ...overrides
  });
  return { value, calls };
}
const newDraft = v => { v.openProfile(); v.fillDraft(config('new')); v.nameDraft = 'New endpoint'; };

test('生产加载多API列表，不填Key草稿、不进入旧聊天、不读旧单Key', async () => {
  const { value: v, calls: c } = harness({ loading: true });
  v.store.load = async () => { throw Error('must not read legacy'); };
  await v.loadConfig();
  assert.equal(v.loading, false); assert.equal(v.page, 'profiles'); assert.equal(v.profiles.length, 2);
  assert.equal(v.selectedProfileId, 'one'); assert.equal(v.keyDraft, ''); assert.equal(c.profileConfigured.length, 0);
  assert.deepEqual(v.profileItems().map(p => p.key), ['edit:one', 'edit:two', 'new', 'scan']);
  assert.doesNotMatch(JSON.stringify(v.profileItems()), /private-key/);
});

test('空列表有新增扫码入口；加载失败保留已有数据，错误不露Key', async () => {
  const empty = harness({ loading: true }); empty.value.profileStore.list = () => []; empty.value.profileStore.active = () => undefined;
  await empty.value.loadConfig(); assert.equal(empty.value.configured, false);
  assert.deepEqual(empty.value.profileItems().map(p => p.key), ['new', 'scan']);
  const failed = harness({ loading: true }); failed.value.profileStore.load = async () => { throw Error('private-key-one'); };
  await failed.value.loadConfig(); assert.equal(failed.value.loading, false); assert.equal(failed.value.profiles.length, 2);
  assert.equal(failed.value.page, 'profiles'); assert.doesNotMatch(failed.value.status, /private-key/);
});

test('条目编辑所有字段；父可指定profileId；新增草稿全部清空', async () => {
  const { value: v } = harness({ loading: true, profileId: 'two' }); await v.loadConfig();
  assert.equal(v.page, 'settings'); assert.equal(v.editingProfileId, 'two'); assert.equal(v.nameDraft, 'API two'); assert.deepEqual(v.draft(), config('two'));
  v.profileAction('new');
  for (const field of ['editingProfileId', 'nameDraft', 'baseDraft', 'modelDraft', 'keyDraft']) assert.equal(v[field], '');
});

test('新增两步确认upsert无id，select新id并交父回主聊天，不改旧Key和聊天', async () => {
  const { value: v, calls: c } = harness(); const history = v.messages; newDraft(v);
  await v.saveConfig(); assert.equal(c.upsert.length, 0); assert.match(v.status, /保存后返回主聊天/);
  await v.saveConfig(); assert.deepEqual(c.upsert, [{ config: config('new'), name: 'New endpoint', id: '' }]);
  assert.deepEqual(c.select, ['new-id']); assert.equal(v.profiles.length, 3); assert.equal(v.selectedProfileId, 'new-id');
  assert.equal(c.profileConfigured[0].id, 'new-id'); assert.equal(c.configured.length, 0); assert.equal(c.save.length, 0); assert.equal(c.clear, 0);
  assert.equal(v.page, 'settings'); assert.equal(v.messages, history); assert.equal(v.prompt, 'keep draft'); assert.equal(c.reset, 0); assert.equal(v.saving, false);
  c.profileConfigured[0].apiKey = 'parent mutation'; assert.equal(v.keyDraft, config('new').apiKey); assert.equal(v.activeConfig.apiKey, config('new').apiKey);
});

test('编辑只upsert指定id，不增条目不覆盖另一API；编辑改变撤销确认', async () => {
  const { value: v, calls: c } = harness(); v.profileAction('edit:two'); v.modelDraft = 'edited'; v.nameDraft = 'Renamed';
  await v.saveConfig(); v.draftChanged(); assert.equal(v.saveArmed, false);
  await v.saveConfig(); await v.saveConfig(); assert.equal(c.upsert[0].id, 'two'); assert.equal(v.profiles.length, 2);
  assert.equal(v.profiles.find(p => p.id === 'two').model, 'edited'); assert.deepEqual(v.profiles.find(p => p.id === 'one'), profile());
});

test('保存失败不通知父不露Key；select失败后重试沿用新增id，不重复新建', async () => {
  const failed = harness(); newDraft(failed.value); failed.value.profileStore.upsert = async () => { throw Error('private-key-new'); };
  await failed.value.saveConfig(); await failed.value.saveConfig(); assert.equal(failed.calls.profileConfigured.length, 0);
  assert.equal(failed.value.saving, false); assert.doesNotMatch(failed.value.status, /private-key/);
  const { value: v, calls: c } = harness(); newDraft(v); const select = v.profileStore.select;
  v.profileStore.select = async () => { throw Error('private-key-new'); };
  await v.saveConfig(); await v.saveConfig(); assert.equal(v.editingProfileId, 'new-id'); v.profileStore.select = select;
  await v.saveConfig(); await v.saveConfig(); assert.deepEqual(c.upsert.map(p => p.id), ['', 'new-id']); assert.equal(v.profiles.length, 3);
});

test('两次确认仅remove当前profile，更新active列表，父重新load，其他Key和会话保留', async () => {
  const { value: v, calls: c } = harness(); const history = v.messages; v.openProfile('one');
  await v.clearConfig(); assert.equal(c.remove.length, 0); assert.match(v.status, /仅删除当前 API/);
  await v.clearConfig(); assert.deepEqual(c.remove, ['one']); assert.equal(c.profilesChanged, 1); assert.equal(c.cleared, 0); assert.equal(c.clear, 0);
  assert.equal(v.page, 'profiles'); assert.equal(v.selectedProfileId, 'two'); assert.deepEqual(v.profiles, [profile('two')]);
  assert.equal(v.keyDraft, ''); assert.equal(v.messages, history); assert.equal(v.prompt, 'keep draft'); assert.equal(c.reset, 0); assert.equal(c.cancel, 0);
});

test('新草稿不能删除；删除失败保留配置，不通知父不露Key', async () => {
  const { value: v, calls: c } = harness(); newDraft(v); await v.clearConfig(); await v.clearConfig(); assert.equal(c.remove.length, 0);
  v.openProfile('two'); v.profileStore.remove = async () => { throw Error('private-key-two'); };
  await v.clearConfig(); await v.clearConfig(); assert.equal(c.profilesChanged, 0); assert.equal(v.profiles.length, 2);
  assert.equal(v.editingProfileId, 'two'); assert.equal(v.saving, false); assert.doesNotMatch(v.status, /private-key/);
});

test('扫码→编辑→列表→父历史返回；取消编辑不覆盖已保存API，内层返回有动画', () => {
  const { value: v, calls: c } = harness(); v.openProfile('two'); v.keyDraft = 'unsaved'; v.modelDraft = 'unsaved'; v.page = 'qr';
  v.backRequested(); assert.equal(v.page, 'settings'); assert.equal(c.closed, 0);
  v.backRequested(); assert.equal(v.page, 'profiles'); assert.equal(v.keyDraft, ''); assert.equal(c.closed, 0);
  assert.deepEqual(v.profiles.find(p => p.id === 'two'), profile('two'));
  v.backRequested(); assert.equal(c.closed, 1); assert.equal(c.animations.length, 2); assert.equal(c.upsert.length, 0); assert.equal(c.remove.length, 0);
  assert.match(extract('stopProvision'), /cancelDirectProvision\(base, token, ticket.id\)/);
});

test('编辑输入和保存期间暂停返回；上报父editing并取消表冠弹性', () => {
  const { value: v, calls: c } = harness(); v.openProfile('one'); let cancelled = 0; v.crownMotion.cancel = () => { cancelled++; };
  v.editingChanged(true); v.backRequested(); assert.equal(v.page, 'settings'); assert.equal(c.closed, 0); assert.equal(cancelled, 1);
  v.editingChanged(false); v.saving = true; v.backRequested(); assert.equal(v.page, 'settings'); assert.deepEqual(c.editing, [true, false]);
  assert.equal((source.match(/\.onEditChange\(\(editing: boolean\) => \{ this\.editingChanged\(editing\); \}\)/g) || []).length, 5);
  assert.match(extract('aboutToDisappear'), /this\.onEditingChanged\(false\)/);
});

test('编辑时手机扫码另建草稿，不覆盖profile；核对两次保存时才新增', async () => {
  const { value: v, calls: c } = harness(); v.openProfile('two'); await v.beginProvision();
  assert.equal(v.editingProfileId, ''); assert.equal(v.nameDraft, ''); assert.equal(v.imported, true); assert.equal(v.page, 'settings');
  assert.deepEqual(v.draft(), config('phone')); assert.equal(c.upsert.length, 0); assert.equal(c.profileConfigured.length, 0);
  assert.deepEqual(v.profiles, [profile(), profile('two')]); assert.match(v.status, /新草稿/); assert.match(v.status, /保存并返回主聊天/);
  await v.saveConfig(); await v.saveConfig(); assert.equal(c.upsert[0].id, ''); assert.equal(v.profiles.length, 3);
});

test('后台扫码退编辑，禁止保存；销毁后的异步保存不通知父', async () => {
  const { value: v, calls: c } = harness({ page: 'qr', appInBackground: true }); v.backgroundChanged();
  assert.equal(v.page, 'settings'); assert.equal(c.stopProvision, 1); await v.saveConfig(); assert.equal(c.upsert.length, 0);
  const pending = harness(); newDraft(pending.value); let finish;
  pending.value.profileStore.upsert = () => new Promise(resolve => { finish = resolve; });
  await pending.value.saveConfig(); const saving = pending.value.saveConfig(); pending.value.alive = false; pending.value.uiGeneration++;
  finish(profile('new-id')); await saving; assert.equal(pending.calls.profileConfigured.length, 0);
});

test('全高Scroll透明后置header，触摸Spring常开；圆屏u168/输入40/安全留白；不套索引公式', () => {
  const build = source.slice(source.indexOf('  build()')); const settings = source.slice(source.indexOf('  Settings()'), source.indexOf('  Chat()'));
  assert.match(build, /Stack\(\{ alignContent: Alignment.Top \}\)/); assert.ok(build.indexOf('this.Settings()') < build.indexOf('// Transparent overlay'));
  assert.match(build, /\.hitTestBehavior\(HitTestMode.None\)/); assert.match(build, /\.focusable\(true\)\.focusOnTouch\(false\)/);
  assert.match(build, /title: 'API设置', subtitle: ''/); assert.match(settings, /\.width\(this.u\(168\)\)\.padding\(\{ top: this.u\(62\), bottom: this.u\(88\) \}\)/);
  assert.match(settings, /\.width\('100%'\)\.height\('100%'\)\.scrollBar/); assert.match(settings, /\.edgeEffect\(EdgeEffect.Spring, \{ alwaysEnabled: true \}\)/);
  assert.match(settings, /\.translate\(\{ y: this.crownStretch \}\)\s*\}/); assert.doesNotMatch(settings, /crownItemScale|itemScale|contentStartOffset/);
  assert.equal((settings.match(/\.height\(this.u\(40\)\)/g) || []).length, 5);
  assert.doesNotMatch(source, /Button\(['"]返回['"]|清空全部|清空配置和对话|console\.|hilog\.|Text\(this.keyDraft\)/);
  assert.doesNotMatch(build, /this\.closePage\(\)|PanGesture/);
  assert.match(source, /\.type\(InputType.Password\)\.showPasswordIcon\(false\)\.showPassword\(false\)/);
  assert.match(source, /copyOption\(CopyOptions.None\)\.enableAutoFill\(false\)/);
  assert.match(settings, /if \(!this.settingsOnly \|\| this.editingProfileId.length > 0\)/);
  assert.match(extract('aboutToAppear'), /if \(this.settingsOnly\) \{\s*this.profileStore = new ApiProfileStore\(context\);\s*\} else \{/);
});

test('表冠BEGIN/UPDATE/END复用共享弹性，输入编辑禁用；切页后台销毁触摸取消', () => {
  for (const page of ['settings', 'chat']) {
    const events = []; const scroller = { currentOffset() { return { yOffset: 0 }; }, isAtEnd() { return true; }, scrollTo(o) { events.push(['scroll', o]); } };
    const { value: v } = harness({ page, settingsScroll: scroller, scroll: scroller, crownMotion: {
      begin() { events.push(['begin']); }, end() { events.push(['end']); }, cancel() { events.push(['cancel']); }, updateAtEdges(...a) { events.push(['update', ...a]); return 0; }
    } });
    v.handleCrown({ action: 0, degree: 0 }); v.handleCrown({ action: 1, degree: 10 }); v.handleCrown({ action: 2, degree: 0 });
    assert.deepEqual(events, [['begin'], ['update', -22, 0, true, true], ['scroll', { xOffset: 0, yOffset: 0, animation: false }], ['end']]);
    v.inputEditing = true; v.handleCrown({ action: 1, degree: 10 }); assert.deepEqual(events.at(-1), ['cancel']);
  }
  assert.equal((source.match(/\.translate\(\{ y: this\.crownStretch \}\)/g) || []).length, 2);
  for (const name of ['pageChanged', 'backgroundChanged', 'aboutToDisappear']) assert.match(extract(name), /this\.crownMotion\.cancel\(\)/);
  assert.match(source, /event.type === TouchType.Down\) \{ this.crownMotion.cancel\(\)/);
  assert.match(source, /@Prop @Watch\('backRequested'\) backRequest: number = 0/); assert.doesNotMatch(extract('backRequested'), /onClose|onRequestBack/);
});

test('生产send/newChat保护历史；默认旧模式依然可选但不会经过生产路径', async () => {
  const production = harness(); const history = production.value.messages; await production.value.send(); production.value.newChat();
  assert.equal(production.value.messages, history); assert.equal(production.calls.send, 0); assert.equal(production.calls.reset, 0);
  const { value: v, calls: c } = harness({ settingsOnly: false }); await v.loadConfig(); assert.equal(v.page, 'chat');
  v.page = 'settings'; await v.saveConfig(); await v.saveConfig(); assert.equal(c.save.length, 1); assert.equal(c.upsert.length, 0);
  assert.equal(c.reset, 1); assert.equal(v.page, 'chat'); assert.equal(c.profileConfigured.length, 0);
  v.page = 'compose'; v.backRequested(); assert.equal(v.page, 'chat');
});
