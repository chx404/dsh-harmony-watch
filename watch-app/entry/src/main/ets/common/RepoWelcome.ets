const REPO_URL: string = 'https://github.com/chx404/dsh-harmony-watch';

@Component
export struct RepoWelcome {
  @Prop screenWidth: number = 233;
  @Prop screenHeight: number = 233;
  onDismiss: () => void = () => {};
  onSkip: () => void = () => {};

  // Reuse the guide's 233vp round-screen baseline and scale by the shorter edge.
  private u(value: number): number {
    return value * Math.min(this.screenWidth / 233, this.screenHeight / 233);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text('GitHub 项目')
          .fontSize(this.u(17))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FAFAFA')
          .height(this.u(20))

        Text('扫码查看电脑插件安装指南')
          .fontSize(this.u(12))
          .fontColor('#D0D0D0')
          .textAlign(TextAlign.Center)
          .width(this.u(154))
          .height(this.u(16))
          .margin({ top: this.u(1) })

        Column() {
          QRCode(REPO_URL)
            .width(this.u(80))
            .height(this.u(80))
            .color('#000000')
            .backgroundColor('#FFFFFF')
            .accessibilityLevel('yes')
            .accessibilityText('GitHub 项目二维码：' + REPO_URL)
        }
        // Keep a white quiet zone of at least four modules around the matrix.
        .padding(this.u(12))
        .backgroundColor('#FFFFFF')
        .borderRadius(this.u(5))
        .margin({ top: this.u(5), bottom: this.u(5) })

        Row({ space: this.u(6) }) {
          Button('这次跳过', { type: ButtonType.Capsule })
            .width(this.u(58))
            .height(this.u(44))
            .padding(0)
            .fontSize(this.u(12))
            .fontColor('#E5E5E5')
            .backgroundColor('#252525')
            .onClick(() => { this.onSkip(); })

          Button('今后不再显示', { type: ButtonType.Capsule })
            .width(this.u(94))
            .height(this.u(44))
            .padding(0)
            .fontSize(this.u(12))
            .fontColor('#111111')
            .backgroundColor('#F5F5F5')
            .onClick(() => { this.onDismiss(); })
        }
      }
      // Bias the column upward so the full capsules sit on the wider circular chord.
      .translate({ y: -this.u(6) })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#090909')
  }
}
