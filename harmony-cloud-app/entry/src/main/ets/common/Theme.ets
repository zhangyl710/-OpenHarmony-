/**
 * 简约配色：白底 + 状态色，无渐变无发光
 *
 * 说明：text / textDim / textMute 是深灰系，配白底才看得清；
 *       accent / good / warn / bad 都比暗色版加深了一档，
 *       否则在白底上对比度不够（尤其 warn 的黄色）。
 *
 * 注：bg 还兼作按钮"选中态"的文字色（见 Index.ets 的
 *     fontColor(... ? Palette.bg : Palette.text)），
 *     选中时背景是 accent 蓝，所以白色文字正好。
 */
export class Palette {
  static readonly bg: string = '#FFFFFF'          // 页面底色：纯白
  static readonly surface: string = '#F7F8FA'     // 卡片：几乎白的浅灰
  static readonly surfaceAlt: string = '#F0F2F5'  // 数值框 / 未选中按钮
  static readonly border: string = '#E3E6EA'      // 边框 / 分隔线
  static readonly text: string = '#1F2328'        // 主文字：近黑
  static readonly textDim: string = '#4B5563'     // 次要文字
  static readonly textMute: string = '#6B7280'    // 弱化文字
  static readonly accent: string = '#1A73E8'      // 强调蓝
  static readonly good: string = '#1A7F37'        // 正常
  static readonly warn: string = '#9A6700'        // 接近阈值
  static readonly bad: string = '#CF222E'         // 报警
}

export class Metric {
  static readonly radius: number = 10
  static readonly gap: number = 12
  static readonly cardPad: number = 16
  static readonly titleSize: number = 14
  static readonly subSize: number = 11
  static readonly bodySize: number = 13
  static readonly smallSize: number = 11
  static readonly numSize: number = 30
}
