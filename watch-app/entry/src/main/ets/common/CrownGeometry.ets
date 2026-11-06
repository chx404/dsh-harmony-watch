// 所有行尺寸固定，滚动时只改变渲染缩放，避免重排反过来改变滚动位置。
export function crownContentInset(viewport: number, itemHeight: number): number {
  return Math.max(0, (viewport - itemHeight) / 2);
}

export function crownItemScale(index: number, offset: number, viewport: number,
  itemHeight: number, gap: number): number {
  const center: number = crownContentInset(viewport, itemHeight) +
    index * (itemHeight + gap) + itemHeight / 2 - offset;
  const distance: number = Math.min(1, Math.abs(center - viewport / 2) / Math.max(1, viewport / 2));
  return 1 - 0.30 * distance * distance;
}

// 使用原生可见行的实际坐标，避免 contentStartOffset 被重复计算导致偏向顶部。
export function crownMeasuredScale(top: number, height: number, viewport: number, stretch: number = 0): number {
  const center: number = top + height / 2 + stretch;
  const distance: number = Math.min(1, Math.abs(center - viewport / 2) / Math.max(1, viewport / 2));
  return 1 - 0.30 * distance * distance;
}

export function crownNativeOrigin(offset: number, top: number, index: number,
  viewport: number, itemHeight: number, gap: number): number {
  return offset + top - crownContentInset(viewport, itemHeight) - index * (itemHeight + gap);
}

export function crownItemOpacity(scale: number): number {
  return Math.max(0.58, Math.min(1, 0.58 + (scale - 0.70) * 1.4));
}
