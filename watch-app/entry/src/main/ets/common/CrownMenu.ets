import { crownContentInset, crownItemScale, crownItemOpacity, crownMeasuredScale, crownNativeOrigin } from './CrownGeometry';
import { CrownElastic } from './CrownElastic';

export interface CrownMenuItem {
  key: string;
  title: string;
  caption: string;
  symbol: string;
}

// Reload only the lazy data; the existing List and Scroller keep their position.
class CrownMenuDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: CrownMenuItem[] = [];
  private revision: number = 0;

  totalCount(): number { return this.items.length; }
  getData(index: number): CrownMenuItem { return this.items[index]; }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) { this.listeners.splice(index, 1); }
  }

  set(items: CrownMenuItem[]): void {
    this.items = items.slice();
    this.revision++;
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataReloaded();
    }
  }

  key(item: CrownMenuItem, index: number): string {
    // A reload must refresh titles and index closures, including reordered sessions.
    return this.revision.toString() + ':' + index.toString() + ':' + item.key;
  }
}

@Component
export struct CrownMenu {
  @Prop screenWidth: number = 233;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop focusId: string = 'crown-menu';
  @Prop @Watch('itemsChanged') items: CrownMenuItem[] = [];
  @Prop showBack: boolean = false;
  onAction: (key: string) => void = (_key: string) => {};
  onBack: () => void = () => {};
  @State scrollOffset: number = 0;
  @State viewport: number = 233;
  @State elasticStretch: number = 0;
  private elastic: CrownElastic = new CrownElastic((stretch: number) => {
    this.elasticStretch = stretch;
  });
  private scroller: Scroller = new Scroller();
  private itemSource: CrownMenuDataSource = new CrownMenuDataSource();
  private firstVisible: number = 0;
  private nativeOrigin: number = 0;

  aboutToAppear(): void {
    this.itemsChanged();
  }

  aboutToDisappear(): void {
    this.elastic.cancel();
  }

  private itemsChanged(): void {
    this.itemSource.set(this.items);
  }

  private u(value: number): number {
    return this.screenWidth * value / 233;
  }

  private itemScale(index: number): number {
    const fallback: number = crownItemScale(index, this.scrollOffset - this.nativeOrigin - this.elasticStretch,
      this.viewport, this.u(64), this.u(8));
    try {
      const rect: RectResult = this.scroller.getItemRect(index);
      if (rect.height > 0) { return crownMeasuredScale(rect.y, rect.height, this.viewport, this.elasticStretch); }
    } catch (e) { }
    return fallback;
  }

  private refreshGeometry(): void {
    try {
      const offset: number = this.scroller.currentOffset().yOffset;
      this.scrollOffset = offset;
      for (let index: number = this.firstVisible; index < Math.min(this.items.length, this.firstVisible + 4); index++) {
        const rect: RectResult = this.scroller.getItemRect(index);
        if (rect.height > 0) {
          this.nativeOrigin = crownNativeOrigin(offset, rect.y, index, this.viewport, this.u(64), this.u(8));
          break;
        }
      }
    } catch (e) { }
  }

  private focus(): void {
    try { this.getUIContext().getFocusController().requestFocus(this.focusId); } catch (e) { }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // The list owns the complete viewport, including the transparent title area.
      List({ space: this.u(8), scroller: this.scroller }) {
        LazyForEach(this.itemSource, (item: CrownMenuItem, index: number) => {
          ListItem() {
            Row({ space: this.u(10) }) {
              Text(item.symbol)
                .fontSize(this.u(18))
                .fontWeight(FontWeight.Medium)
                .fontColor('#ADE9D9')
                .textAlign(TextAlign.Center)
                .width(this.u(36))
                .height(this.u(36))
                .backgroundColor('#1B3335')
                .borderRadius(this.u(18))
              Column({ space: this.u(3) }) {
                Text(item.title)
                  .fontSize(this.u(14))
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#EDF4F3')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(item.caption)
                  .fontSize(this.u(8))
                  .fontColor('#9BAFB3')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text('›')
                .fontSize(this.u(18))
                .fontColor('#9BAFB3')
            }
            .width(this.u(193))
            .height(this.u(64))
            .padding({ left: this.u(12), right: this.u(14) })
            .backgroundColor('#0D181C')
            .border({ width: this.u(0.5), color: '#203B40' })
            .borderRadius(this.u(32))
            .scale({ x: this.itemScale(index), y: this.itemScale(index) })
            .opacity(crownItemOpacity(this.itemScale(index)))
            .accessibilityText(item.title + '，' + item.caption)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => { this.onAction(item.key); })
          }.width(this.u(193)).height(this.u(64))
        }, (item: CrownMenuItem, index: number) => this.itemSource.key(item, index))
      }
      .contentStartOffset(crownContentInset(this.viewport, this.u(64)))
      .contentEndOffset(crownContentInset(this.viewport, this.u(64)))
      .cachedCount(2)
      .alignListItem(ListItemAlign.Center)
      .id(this.focusId)
      .width('100%')
      .height('100%')
      .translate({ y: this.elasticStretch })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)
      .focusable(true)
      .focusOnTouch(true)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.elastic.cancel();
          this.focus();
        }
      })
      .onScroll(() => {
        this.refreshGeometry();
      })
      .onScrollIndex((start: number, _end: number) => { this.firstVisible = start; this.refreshGeometry(); })
      .onAreaChange((_old: Area, area: Area) => { this.viewport = area.height as number; this.refreshGeometry(); })
      .onDigitalCrown((event: CrownEvent) => {
        if (event.action === CrownAction.BEGIN) {
          this.elastic.begin();
        } else if (event.action === CrownAction.UPDATE) {
          this.refreshGeometry();
          const max: number = this.nativeOrigin + Math.max(0, this.items.length - 1) * this.u(72);
          const target: number = this.elastic.update(-event.degree * this.u(2.2),
            this.scroller.currentOffset().yOffset, this.nativeOrigin, max);
          this.scroller.scrollTo({ xOffset: 0, yOffset: target, animation: false });
        } else if (event.action === CrownAction.END) {
          this.elastic.end();
        }
      })
      Column() {
        Text(this.title)
          .fontSize(this.u(14))
          .fontWeight(FontWeight.Medium)
          .fontColor('#EDF4F3')
          .height(this.u(20))
          .width(this.u(152))
          .textAlign(TextAlign.Center)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(this.u(8))
            .fontColor('#9BAFB3')
            .height(this.u(13))
        }
      }
      .padding({ top: this.u(22) })
      .hitTestBehavior(HitTestMode.None)
    }
    .clip(true)
    .width('100%')
    .height('100%')
  }
}
