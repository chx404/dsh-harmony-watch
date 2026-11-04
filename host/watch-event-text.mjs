// Keep complete readable text locally; do not flatten newlines or truncate chat.
export function messageBody(message) {
  const out = [];
  const visit = (blocks) => {
    if (typeof blocks === 'string') { out.push(blocks); return; }
    if (!Array.isArray(blocks)) return;
    for (const block of blocks) {
      if (!block || typeof block !== 'object') continue;
      if (block.type === 'text' && typeof block.text === 'string') out.push(block.text);
      else if (block.type === 'tool-result') visit(block.content);
    }
  };
  visit(message?.content);
  return out.join('\n');
}

// 图片块只带元数据（附件 id / 尺寸），真正的字节由 /api/image 按需取。
// offloaded 的图片已经不在会话里，跳过。
export function messageImages(message) {
  const out = []
  const visit = (blocks) => {
    if (!Array.isArray(blocks)) return
    for (const block of blocks) {
      if (!block || typeof block !== 'object') continue
      if (block.type === 'image' && block.attachment && typeof block.attachment === 'object') {
        if (!block.offloaded) out.push(block.attachment)
      } else if (block.type === 'tool-result') visit(block.content)
    }
  }
  visit(message?.content)
  return out
}

export function argumentsBody(raw) {
  if (typeof raw !== 'string') return raw == null ? '' : JSON.stringify(raw, null, 2);
  try { return JSON.stringify(JSON.parse(raw), null, 2); }
  catch { return raw; }
}

// Tool output may be large: snapshots carry a one-line summary; the expansion
// endpoint returns the original detail only when explicitly requested.
export function publicEvent(event) {
  const { detail, ...rest } = event;
  return typeof detail === 'string' ? { ...rest, hasDetail: true } : rest;
}
