// 独立页面而非 Swiper 覆盖层，避免原生翻页内容压住引导。
// 以 233vp 圆屏设计：内容固定在中心安全区，按较短边等比缩放。
@Component
export struct QuickGuide {
  @Prop screenWidth: number = 233;
  @Prop screenHeight: number = 233;
  @State step: number = 0;
  onFinish: () => void = () => {};
  private titles: string[] = ['让 DSH 来到腕上', '左右滑，各有所用', '一句话，派个任务', '重要操作，由你决定', '准备好了，开始吧'];
  private descriptions: string[] = [
    '手机启动 DSH 手表插件\n手表填写地址与六位配对码\n配对信息会自动保存',
    '中间看对话，右滑进菜单\n左滑用快捷指令\n从屏幕中部滑，避开返回边缘',
    '点「发送指令」编辑并发送\n点模型胶囊切换下轮模型\n转动表冠，阅读更多消息',
    '收到审批，核对后允许或拒绝\n停止任务要连续确认两次\n不要批准不认识的操作',
    '菜单可管理会话、设置连接\n息屏后连接不保证一直在线\n菜单里的「使用引导」可重看'
  ];

  private u(value: number): number {
    return value * Math.min(this.screenWidth / 233, this.screenHeight / 233);
  }

  private move(delta: number): void {
    // 轻量淡入，不另建 Swiper，也不与主界面指示器共享状态。
    animateTo({ duration: 140, curve: Curve.EaseOut }, () => {
      this.step = Math.max(0, Math.min(4, this.step + delta));
    });
  }

  @Builder
  Chip(label: string, active: boolean, width: number) {
    Text(label)
      .fontSize(this.u(10))
      .fontColor(active ? '#102D29' : '#9BAFB3')
      .fontWeight(FontWeight.Medium)
      .textAlign(TextAlign.Center)
      .width(this.u(width))
      .height(this.u(28))
      .backgroundColor(active ? '#ADE9D9' : '#142126')
      .borderRadius(this.u(14))
  }

  @Builder
  Illustration() {
    if (this.step === 0) {
      Row({ space: this.u(7) }) {
        Text('DSH')
          .fontSize(this.u(13))
          .fontWeight(FontWeight.Bold)
          .fontColor('#ADE9D9')
        Text('→')
          .fontSize(this.u(14))
          .fontColor('#5E6E74')
        Column() {
          Text('123 456')
            .fontSize(this.u(14))
            .fontWeight(FontWeight.Medium)
            .fontColor('#EDF4F3')
            .height(this.u(19))
          Text('配对码示例')
            .fontSize(this.u(7))
            .fontColor('#9BAFB3')
            .height(this.u(10))
        }
        .justifyContent(FlexAlign.Center)
        .width(this.u(76))
        .height(this.u(36))
        .backgroundColor('#142126')
        .borderRadius(this.u(12))
        .accessibilityText('示例配对码，一二三四五六；实际配对码请在手机宿主插件中查看')
      }
      .height(this.u(40))
      .justifyContent(FlexAlign.Center)
    } else if (this.step === 1) {
      Row({ space: this.u(5) }) {
        this.Chip('菜单', false, 43)
        this.Chip('对话', true, 51)
        this.Chip('快捷', false, 43)
      }
      .height(this.u(40))
      .justifyContent(FlexAlign.Center)
    } else if (this.step === 2) {
      Column({ space: this.u(4) }) {
        Text('帮我总结一下')
          .fontSize(this.u(9))
          .fontColor('#102D29')
          .padding({ left: this.u(9), right: this.u(9) })
          .height(this.u(18))
          .backgroundColor('#ADE9D9')
          .borderRadius(this.u(9))
          .alignSelf(ItemAlign.End)
        Text('收到，正在整理…')
          .fontSize(this.u(9))
          .fontColor('#EDF4F3')
          .padding({ left: this.u(9), right: this.u(9) })
          .height(this.u(18))
          .backgroundColor('#142126')
          .borderRadius(this.u(9))
          .alignSelf(ItemAlign.Start)
      }
      .width(this.u(142))
      .height(this.u(40))
    } else if (this.step === 3) {
      Row({ space: this.u(7) }) {
        this.Chip('拒绝', false, 60)
        this.Chip('允许', true, 60)
      }
      .height(this.u(40))
      .justifyContent(FlexAlign.Center)
    } else {
      Text('✓')
        .fontSize(this.u(24))
        .fontWeight(FontWeight.Medium)
        .fontColor('#ADE9D9')
        .textAlign(TextAlign.Center)
        .width(this.u(40))
        .height(this.u(40))
        .backgroundColor('#193432')
        .borderRadius(this.u(20))
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row() {
          Text('上手指南  ' + (this.step + 1).toString() + ' / 5')
            .fontSize(this.u(9))
            .fontColor('#9BAFB3')
          Blank()
          Text('跳过')
            .fontSize(this.u(9))
            .fontColor('#ADE9D9')
            .width(this.u(40))
            .height(this.u(24))
            .textAlign(TextAlign.Center)
            .accessibilityText('跳过引导，以后可从菜单重新查看')
            .onClick(() => { this.onFinish(); })
        }
        .width(this.u(146))
        .height(this.u(24))
        .margin({ bottom: this.u(3) })

        this.Illustration()

        Text(this.titles[this.step])
          .fontSize(this.u(16))
          .fontWeight(FontWeight.Bold)
          .fontColor('#EDF4F3')
          .height(this.u(22))
          .margin({ top: this.u(7), bottom: this.u(4) })
          .textAlign(TextAlign.Center)
        Text(this.descriptions[this.step])
          .fontSize(this.u(10))
          .lineHeight(this.u(15))
          .fontColor('#B7C9CC')
          .textAlign(TextAlign.Center)
          .width(this.u(166))
          .height(this.u(45))
          .margin({ bottom: this.u(8) })

        Row({ space: this.u(6) }) {
          Text(this.step === 0 ? '稍后' : '上一步')
            .fontSize(this.u(10))
            .fontColor('#B7C9CC')
            .textAlign(TextAlign.Center)
            .width(this.u(54))
            .height(this.u(30))
            .backgroundColor('#142126')
            .borderRadius(this.u(15))
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              if (this.step === 0) { this.onFinish(); }
              else { this.move(-1); }
            })
          Text(this.step === 4 ? '开始使用' : '下一步')
            .fontSize(this.u(11))
            .fontWeight(FontWeight.Medium)
            .fontColor('#102D29')
            .textAlign(TextAlign.Center)
            .width(this.u(84))
            .height(this.u(30))
            .backgroundColor('#ADE9D9')
            .borderRadius(this.u(15))
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              if (this.step === 4) { this.onFinish(); }
              else { this.move(1); }
            })
        }
        Row({ space: this.u(4) }) {
          ForEach([0, 1, 2, 3, 4], (index: number) => {
            Text('')
              .width(this.u(index === this.step ? 12 : 4))
              .height(this.u(3))
              .borderRadius(this.u(2))
              .backgroundColor(index === this.step ? '#ADE9D9' : '#34474C')
          }, (index: number) => index.toString())
        }
        .height(this.u(3))
        .margin({ top: this.u(8) })
      }
      .width(this.u(168))
      // 总高 194vp，233vp 圆屏上下各留约 19vp；按钮位于较宽的中下部。
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#060A0D')
    .linearGradient({ angle: 150, colors: [['#162D32', 0], ['#0B151C', 0.4], ['#060A0D', 1]] })
  }
}
