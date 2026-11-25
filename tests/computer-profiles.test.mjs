import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

const source = await readFile(new URL('../watch-app/entry/src/main/ets/common/ComputerProfiles.ets', import.meta.url), 'utf8');
const { outputText, diagnostics } = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.ES2020, target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
});
assert.deepEqual(diagnostics, []);
const {
  COMPUTER_PROFILE_MAX_COUNT, normalizeComputerServer, normalizeComputerProfiles,
  parseComputerProfiles, upsertComputerProfile, removeComputerProfile
} = await import('data:text/javascript;base64,' + Buffer.from(outputText).toString('base64'));

const token = 'fake-test-credential';
const profile = (changes = {}) => ({ id: 'legacy', name: '我的电脑', server: 'http://local.test:8022', token, ...changes });
const snapshot = (profiles = [], selectedId = '') => ({ profiles, selectedId });

const assertGenericParseFailure = (raw) => assert.throws(() => parseComputerProfiles(raw), {
  name: 'Error', message: '电脑配对资料损坏'
});

test('empty storage is distinct from corruption and produces fresh snapshots', () => {
  const initial = parseComputerProfiles('');
  initial.profiles.push(profile());
  assert.deepEqual(parseComputerProfiles(''), snapshot());
  assert.deepEqual(parseComputerProfiles(JSON.stringify(snapshot())), snapshot());
  assertGenericParseFailure(' ');
});

test('parse and clone whitelist fields, preserve an explicit unselected state and normalize optional endpoints', () => {
  const input = profile({
    name: '  我的电脑  ', server: '  Local.TEST:8022/Dsh/  ',
    lan: '192.168.1.2:8022/', remote: '   ', mode: 'lan', extra: token
  });
  const expected = profile({ server: 'http://Local.TEST:8022/Dsh', lan: 'http://192.168.1.2:8022', remote: '', mode: 'lan' });
  assert.deepEqual(parseComputerProfiles(JSON.stringify({ ...snapshot([input]), extra: token })), snapshot([expected]));
  const directInput = snapshot([Object.freeze(input)], 'legacy');
  const clone = normalizeComputerProfiles(directInput);
  assert.deepEqual(clone, snapshot([expected], 'legacy'));
  clone.profiles[0].token = 'changed';
  assert.equal(directInput.profiles[0].token, token);
});

test('rejects corrupt snapshots as a whole, with the same credential-free error', () => {
  const first = profile();
  const invalid = [
    null, [], 42, {}, { ...snapshot(), profiles: {} }, { ...snapshot(), selectedId: 42 },
    snapshot([], 'not-saved'), snapshot([first], 'not-saved'), snapshot([first, first]),
    snapshot([first, null]), snapshot([first, profile({ id: '' })]), snapshot([profile({ id: 'a'.repeat(129) })]),
    snapshot([profile({ name: '' })]), snapshot([profile({ name: 'a'.repeat(121) })]),
    snapshot([profile({ name: 'multiline\nname' })]), snapshot([profile({ server: null })]),
    snapshot([profile({ server: 'https://user:' + token + '@local.test' })]),
    snapshot([profile({ token: 8 })]), snapshot([profile({ token: '' })]),
    snapshot([profile({ token: 'invalid\r\ncredential' })]), snapshot([profile({ token: 'a'.repeat(1025) })]),
    snapshot([profile({ server: 'https://local.test/' + 'x'.repeat(2048) })]),
    snapshot([profile({ lan: [] })]), snapshot([profile({ remote: 'ftp://local.test' })]), snapshot([profile({ mode: 'invalid' })])
  ];
  for (const value of invalid) {
    assertGenericParseFailure(JSON.stringify(value));
  }
  assertGenericParseFailure('{ "token": "' + token + '" INVALID JSON }');
  assertGenericParseFailure(null);
  assertGenericParseFailure(JSON.stringify({ ...snapshot(), extra: 'a'.repeat(1024 * 1024) }));
});

test('endpoint normalization preserves explicit ports and case-sensitive path/escape spelling', () => {
  for (const [raw, expected] of [
    ['  Computer.LAN:8022///  ', 'http://Computer.LAN:8022'],
    ['https://Machine.Example:443/Bridge/%2F/Inner//', 'https://Machine.Example:443/Bridge/%2F/Inner'],
    ['https://Machine.Example:00443/Bridge/../大小写', 'https://Machine.Example:00443/Bridge/../大小写'],
    ['[::1]:8022/', 'http://[::1]:8022'],
    ['https://[::FFFF:192.0.2.1]:443/Path/', 'https://[::FFFF:192.0.2.1]:443/Path']
  ]) {
    assert.equal(normalizeComputerServer(raw), expected);
  }
});

test('invalid API base addresses never disclose provided input', () => {
  for (const raw of [
    '', ' ', 'http://', '/api', 'https:///api', 'https://:80', 'https://localhost:', 'https://localhost:0',
    'https://localhost:65536', 'ftp://computer.test', 'https://a b.test', 'https://localhost\\elsewhere.test',
    'https://user:' + token + '@localhost', 'https://host/?key=' + token, 'https://host/#' + token,
    'https://[:::', 'https://[:::1]', 'https://[1:2:3:4:5:6:7:8:9]', 'https://[::ffff:999.0.0.1]'
  ]) {
    assert.throws(() => normalizeComputerServer(raw), { name: 'Error', message: '电脑地址无效' });
  }
});

test('upsert replaces a matching ID in place and selects it without mutating or aliasing inputs', () => {
  const first = Object.freeze(profile());
  const second = Object.freeze(profile({ id: 'other', server: 'other.test' }));
  const baseline = Object.freeze({ profiles: Object.freeze([first, second]), selectedId: second.id });
  const update = Object.freeze(profile({ name: 'Renamed', server: 'https://second.test', token: 'rotated', lan: '', mode: 'remote' }));
  const next = upsertComputerProfile(baseline, update);
  assert.deepEqual(next, snapshot([{ ...update }, { ...second, server: 'http://other.test' }], first.id));
  next.profiles[0].name = 'changed';
  next.profiles[1].token = 'changed';
  assert.equal(update.name, 'Renamed');
  assert.equal(second.token, token);
  assert.equal(baseline.selectedId, second.id);
});

test('re-pairing the same normalized server and token preserves its ID and position', () => {
  const plain = profile({ server: 'http://Computer.LAN:8022/Bridge' });
  const other = profile({ id: 'other', server: 'http://other.test:8022/Bridge' });
  const baseline = snapshot([plain, other], other.id);
  const rePair = profile({ id: 'new', server: 'computer.lan:8022/Bridge/', name: 'new label' });
  const next = upsertComputerProfile(baseline, rePair);
  assert.deepEqual(next, snapshot([{
    ...rePair, id: plain.id, server: 'http://computer.lan:8022/Bridge'
  }, other], plain.id));
  assert.equal(rePair.id, 'new');
  assert.equal(baseline.profiles[0].token, token);
  const differentPc = upsertComputerProfile(baseline, { ...rePair, token: 'different-computer-token' });
  assert.equal(differentPc.profiles.length, 3);
  assert.equal(differentPc.selectedId, 'new');
});

test('same-ID edits take precedence, and different path, port or scheme is not deduped', () => {
  const first = profile({ server: 'https://host.test:443/Bridge/%2F' });
  let next = snapshot([first], first.id);
  for (const [i, server] of [
    'https://host.test:443/bridge/%2F', 'https://host.test:443/Bridge/%2f',
    'https://host.test/Bridge/%2F', 'http://host.test:443/Bridge/%2F'
  ].entries()) {
    const id = 'computer-' + i;
    next = upsertComputerProfile(next, profile({ id, server }));
    assert.equal(next.profiles.length, i + 2);
    assert.equal(next.selectedId, id);
  }
  const updated = upsertComputerProfile(next, profile({ token: 'rotated', server: next.profiles[1].server }));
  assert.equal(updated.profiles.length, next.profiles.length);
  assert.equal(updated.profiles[0].token, 'rotated');
  assert.deepEqual(updated.profiles[1], next.profiles[1]);
  assert.equal(updated.selectedId, first.id);
  assert.deepEqual(parseComputerProfiles(JSON.stringify(updated)), updated);
});

test('new servers stop at 12 without evicting; same server or ID can still update at capacity', () => {
  assert.equal(COMPUTER_PROFILE_MAX_COUNT, 12);
  let full = snapshot();
  for (let i = 0; i < COMPUTER_PROFILE_MAX_COUNT; i++) {
    full = upsertComputerProfile(full, profile({ id: `computer-${i}`, server: `http://computer-${i}.test` }));
  }
  const before = JSON.stringify(full);
  assert.throws(() => upsertComputerProfile(full, profile()), /数量上限/);
  assert.equal(JSON.stringify(full), before);
  assert.equal(upsertComputerProfile(full, { ...full.profiles[0], token: 'rotated' }).profiles.length, 12);
  const dedup = upsertComputerProfile(full, profile({ server: 'computer-0.test' }));
  assert.equal(dedup.profiles.length, 12);
  assert.equal(dedup.selectedId, 'computer-0');
  assertGenericParseFailure(JSON.stringify(snapshot([...full.profiles, profile()])));
});

test('removing active leaves no selection, inactive or missing removal never changes selection', () => {
  const first = profile();
  const second = profile({ id: 'other', server: 'http://other.test' });
  const original = snapshot([first, second], first.id);
  const missing = removeComputerProfile(original, 'absent');
  assert.deepEqual(missing, original);
  assert.notEqual(missing.profiles[0], first);
  assert.deepEqual(removeComputerProfile(original, second.id), snapshot([first], first.id));
  const remaining = removeComputerProfile(original, first.id);
  assert.deepEqual(remaining, snapshot([second]));
  assert.deepEqual(parseComputerProfiles(JSON.stringify(remaining)), remaining);
  assert.deepEqual(removeComputerProfile(remaining, second.id), snapshot());
  assert.deepEqual(original, snapshot([first, second], first.id));
});
