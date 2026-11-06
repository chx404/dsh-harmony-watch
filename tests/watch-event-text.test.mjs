// 图片消息的提取规则：只留元数据，offloaded 的图片不再展示。
import test from 'node:test';
import assert from 'node:assert/strict';
import { messageBody, messageImages, publicEvent } from '../host/watch-event-text.mjs';

test('图片块单独提取，文本块保留换行', () => {
  const message = {
    content: [
      { type: 'text', text: '看这张' },
      { type: 'text', text: '第二段' },
      { type: 'image', attachment: { attachmentId: 'a1', mediaType: 'image/png', width: 10, height: 10 } },
      { type: 'image', offloaded: true, attachment: { attachmentId: 'a2' } },
    ],
  };
  assert.equal(messageBody(message), '看这张\n第二段');
  const ids = messageImages(message).map((item) => item.attachmentId);
  assert.deepEqual(ids, ['a1']);
});

test('工具结果里的图片也能找到', () => {
  const message = {
    content: [
      { type: 'tool-result', content: [{ type: 'image', attachment: { attachmentId: 'b1' } }] },
    ],
  };
  assert.equal(messageImages(message).length, 1);
  assert.equal(messageBody(message), '');
});

test('没有内容也不报错', () => {
  assert.deepEqual(messageImages(undefined), []);
  assert.deepEqual(messageImages({ content: 'text' }), []);
  assert.equal(messageBody({ content: [] }), '');
});

test('publicEvent 用 hasDetail 替代正文', () => {
  const event = publicEvent({ seq: 1, detail: 'x'.repeat(1000), text: 't' });
  assert.equal(event.hasDetail, true);
  assert.equal(event.detail, undefined);
  assert.equal(event.text, 't');
});

test('图片事件序列化后仍然是纯元数据', () => {
  const event = publicEvent({
    seq: 2,
    kind: 'user',
    text: '',
    images: [{ attachmentId: 'c1', mediaType: 'image/jpeg', width: 4, height: 4 }],
  });
  assert.equal(JSON.stringify(event).includes('attachmentId'), true);
});
