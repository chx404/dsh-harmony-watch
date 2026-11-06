export interface WatchLocation {
  view: string;
  page: number;
}

export function sameWatchLocation(a: WatchLocation, b: WatchLocation): boolean {
  return a.view === b.view && (a.view !== 'main' || a.page === b.page);
}

// 保存页面来源而不是把所有返回都硬编码为 main；横向 Swiper 手势不另建历史。
export class ViewHistory {
  private entries: WatchLocation[] = [];

  record(current: WatchLocation, next: WatchLocation): void {
    if (sameWatchLocation(current, next)) { return; }
    this.entries.push({ view: current.view, page: current.page });
    if (this.entries.length > 32) { this.entries.shift(); }
  }

  pop(): WatchLocation | undefined {
    const location = this.entries.pop();
    return location ? { view: location.view, page: location.page } : undefined;
  }

  size(): number { return this.entries.length; }
  clear(): void { this.entries = []; }
}

// 左边缘交给系统返回，组件只补充中央区域的明确右滑；编辑文字时不抢光标。
export function isWatchBackSwipe(startX: number, offsetX: number, offsetY: number,
  screenWidth: number, editing: boolean): boolean {
  const unit: number = screenWidth / 233;
  return !editing && startX > 22 * unit && offsetX >= 50 * unit &&
    Math.abs(offsetY) < Math.abs(offsetX) * 0.55;
}
