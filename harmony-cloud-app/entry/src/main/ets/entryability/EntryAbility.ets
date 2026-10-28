import UIAbility from '@ohos.app.ability.UIAbility'
import AbilityConstant from '@ohos.app.ability.AbilityConstant'
import Want from '@ohos.app.ability.Want'
import window from '@ohos.window'
import hilog from '@ohos.hilog'

const DOMAIN: number = 0x0000
const TAG: string = 'SparkHub'

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onCreate')
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onDestroy')
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err))
        return
      }
      hilog.info(DOMAIN, TAG, '%{public}s', 'Succeeded in loading the content.')
    })
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onWindowStageDestroy')
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onForeground')
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'EntryAbility onBackground')
  }
}
