import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import hilog from '@ohos.hilog';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    // 前后台状态从 Ability 层拿：息屏时页面回调不一定可靠，系统回调更准。
    AppStorage.setOrCreate('appInBackground', false);
  }

  onForeground(): void {
    AppStorage.setOrCreate('appInBackground', false);
  }

  onBackground(): void {
    AppStorage.setOrCreate('appInBackground', true);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'DSHWatch', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, 'DSHWatch', 'loadContent ok');
    });
  }
}
