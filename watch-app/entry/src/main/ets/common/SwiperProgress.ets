// 单页、等宽、无间距、非循环 Swiper 的视口页坐标。
// position 是回调中 index 页的左边缘 / 页宽，不是 selectedIndex 到 index 的进度。
// 同一帧可能依次报告多页：例如 index=0, position=-0.3 和 index=1, position=0.7，
// 两次都必须得到 0.3。该回调同时覆盖拖动、松手动画和回弹。
export function swiperProgress(index: number, position: number, pageCount: number): number {
  return Math.max(0, Math.min(pageCount - 1, index - position));
}

// 只缩放，不取整：指示器一个页面仅移动 10vp，取整会丢掉大部分动画帧。
export function indicatorTranslation(progress: number, step: number): number {
  return progress * step;
}
