import Foundation

/// 内置调音预设：介质与器材风格 + 曲风流派 + 二级分类。
///
/// 纪律（这一条决定这份表能不能信）：
/// 这些都是**编辑取向**，不是对某张唱片、某副耳机的实测。
/// 每条都带 `why`（为什么这么给）与 `caveat`（它不保证什么），界面必须把 caveat 一起显示，
/// 不能只留一个好听的风格名去暗示「这就是原味」。
///
/// 为什么不做「按歌手」的内置预设：歌手不是一种调音。同一位歌手不同专辑的母带，
/// 差异往往比两个曲风之间还大；替他定一条曲线等于编。
/// 对歌手更诚实的做法是从用户自己的库里聚合（见 Editorial 的同艺人专题）。
enum TuningPresets {
  enum Kind: String, CaseIterable, Identifiable {
    case hardware
    case genre
    case subgenre

    var id: String { rawValue }
    var title: String {
      switch self {
      case .hardware: return "介质与器材"
      case .genre: return "曲风"
      case .subgenre: return "二级分类"
      }
    }
  }

  struct Preset: Identifiable, Equatable {
    var id: String
    var name: String
    var subtitle: String
    var kind: Kind
    var gains: [Float]
    var why: String
    var caveat: String
  }

  /// 与 EQMath.frequencies 必须逐项相同；Debug 启动时由 assertMatchesAudioMath() 校验。
  /// 独立成一份是为了让 Tools/verify_tuning_presets.swift 能只编译这一个文件就跑到断言，
  /// 不必把 AVFoundation 那一串依赖拖进脚本。
  static let frequencies: [Float] = [
    20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250,
    1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
  ]

  #if DEBUG
    /// App 启动时调用；两份频率表一旦分叉，曲线会错位一段，必须在开发期就炸出来。
    static func assertMatchesAudioMath() {
      assert(frequencies == EQMath.frequencies, "TuningPresets 的频率表与 EQMath 不一致")
    }
  #endif

  static let all: [Preset] = hardware + genres + subgenres
  static func group(_ kind: Kind) -> [Preset] { all.filter { $0.kind == kind } }
  static func preset(_ id: String) -> Preset? { all.first { $0.id == id } }

  // MARK: - 介质与器材

  static let hardware: [Preset] = [
    Preset(
      id: "cassette", name: "磁带", subtitle: "高频滚降 · 低频温厚", kind: .hardware,
      gains: curve([(80, 1.2), (125, 1.5), (250, 0.6), (2000, 0.8), (8000, -1.5), (12500, -2.5), (16000, -3)]),
      why: "磁带的高频随频率自然滚降，低频略有磁头温厚；2kHz 附近的轻微隆起是很多人记住的「暖」。",
      caveat: "这是对磁带机听感的编辑式模仿，不是把音频重录一遍磁带；高频衰减会损失空气感。"),
    Preset(
      id: "minidisc", name: "MD", subtitle: "压缩前的紧 · 高频保守", kind: .hardware,
      gains: curve([(63, 0.8), (100, 1.0), (5000, 0.4), (12500, -1.2), (16000, -1.8)]),
      why: "ATRAC 压缩在极低频与极高频更保守，中低频比磁带紧。",
      caveat: "ATRAC 的编码伪影无法用静态 EQ 复现；这里只还原它的频响取向。"),
    Preset(
      id: "cd", name: "CD", subtitle: "平直 · 对照用", kind: .hardware,
      gains: curve([]),
      why: "16bit / 44.1kHz 的参考是平直；这条就是全零，用来当对照。",
      caveat: "全零不等于更好听，只是没有额外染色。"),
    Preset(
      id: "hifi", name: "HiFi 音响", subtitle: "落地箱 · 分频轻微凹陷", kind: .hardware,
      gains: curve([(50, 1.5), (80, 2.0), (250, -0.5), (3000, -1.0), (10000, 0.8), (12500, 1.0)]),
      why: "落地箱的低频下限更低，2–4kHz 的分频点常见轻微凹陷，球顶高音在 10kHz 后略抬。",
      caveat: "箱体的房间反射与指向性完全没被模拟，这只是频响层面的近似。"),
    Preset(
      id: "earbud", name: "平头塞", subtitle: "低频泄漏 · 中高频直达", kind: .hardware,
      gains: curve([(50, -3.0), (80, -2.0), (125, -1.5), (2000, 1.2), (5000, 1.0), (8000, 0.8)]),
      why: "平头塞没有密封腔，低频泄漏是结构性的；2–8kHz 因为直达声占比高而更亮。",
      caveat: "泄漏量随佩戴差异很大，这条按常见佩戴取中位。"),
    Preset(
      id: "monitor", name: "监听", subtitle: "近场 · 收箱声", kind: .hardware,
      gains: curve([(250, -0.8), (315, -0.8), (400, -0.6)]),
      why: "近场监听常把 200–400Hz 的箱声略作收敛，其余保持平直。",
      caveat: "「监听」不是一个统一的声音，不同厂牌的差异比这条曲线大。"),
  ]

  // MARK: - 曲风

  static let genres: [Preset] = [
    Preset(
      id: "classical", name: "古典", subtitle: "不夸张低频 · 留空气", kind: .genre,
      gains: curve([(31.5, -1.0), (50, -0.8), (10000, 0.6), (12500, 0.6)]),
      why: "管弦乐的低频已经在录音里，过补偿会糊掉定音鼓的层次；高频给一点空气。",
      caveat: "不同厂牌的古典录音差异极大（厅堂感 vs 近场），一条曲线覆盖不了。"),
    Preset(
      id: "jazz", name: "爵士", subtitle: "贝斯琴箱 · 铜管亮度", kind: .genre,
      gains: curve([(100, 1.0), (125, 0.8), (2500, 0.6), (4000, 0.8)]),
      why: "贝斯的琴箱共鸣在 100Hz 附近，铜管的亮度在 2.5–4kHz。",
      caveat: "三重奏与大乐队的密度完全不同，这条偏三重奏。"),
    Preset(
      id: "electronic", name: "电子", subtitle: "sub 与 kick · 合成器亮度", kind: .genre,
      gains: curve([(40, 1.8), (50, 2.0), (63, 1.5), (8000, 0.8), (12500, 1.0)]),
      why: "电子乐的 sub 与 kick 主要在 40–63Hz；高频给合成器的亮度。",
      caveat: "过度抬 sub 会让小耳塞失真，本预设已限在 +2dB。"),
    Preset(
      id: "rock", name: "摇滚", subtitle: "失真咬合 · 底鼓贝斯", kind: .genre,
      gains: curve([(80, 1.2), (100, 1.5), (2000, 1.0), (3150, 0.8)]),
      why: "电吉他失真的「咬」在 2–3kHz，底鼓与贝斯在 80–100Hz。",
      caveat: "老摇滚的高频本来就薄，再抬会刺。"),
    Preset(
      id: "acoustic", name: "民谣 / 原声", subtitle: "去琴腔浑浊 · 拨弦质感", kind: .genre,
      gains: curve([(200, -0.8), (315, -0.6), (5000, 0.8), (6300, 1.0)]),
      why: "原声吉他常被 200–315Hz 的琴腔浑浊掩盖，5–6kHz 是拨弦的质感。",
      caveat: "人声与吉他的平衡取决于母带，预设无法两者都兼顾。"),
    Preset(
      id: "hiphop", name: "说唱", subtitle: "808 骨架 · 人声不硬提亮", kind: .genre,
      gains: curve([(40, 1.5), (50, 2.0), (63, 1.5), (8000, 0.5)]),
      why: "808 与 sub bass 是骨架；人声清晰度靠中频，不需要整体提亮。",
      caveat: "Trap 的 hi-hat 密度高，8kHz 以上抬多了容易刺。"),
    Preset(
      id: "citypop", name: "City Pop", subtitle: "贝斯线 · 铜管与电钢", kind: .genre,
      gains: curve([(100, 1.2), (125, 1.0), (4000, 0.8), (6300, 1.0), (8000, 0.8)]),
      why: "80 年代日本都市流行乐的贝斯线在 100Hz 附近，铜管与电钢的亮度在 4–8kHz。",
      caveat: "同年代母带的数码化版本高频差很多，这条按常见重制版取。"),
    Preset(
      id: "metal", name: "金属", subtitle: "双踩 · 吉他攻击性", kind: .genre,
      gains: curve([(80, 0.8), (100, 1.0), (2000, 1.2), (3150, 1.5), (8000, 0.5)]),
      why: "双踩与贝斯在 80–100Hz，吉他的攻击性在 2–3kHz。",
      caveat: "响度战争下的金属母带已经很挤，再加中高频会更累。"),
    Preset(
      id: "lofi", name: "Lo-fi", subtitle: "带限 · 高频滚降", kind: .genre,
      gains: curve([(8000, -2.5), (10000, -3.0), (12500, -3.0)]),
      why: "Lo-fi 的听感核心就是高频滚降与带限。",
      caveat: "噪声、抖动与采样率伪影无法用 EQ 复现，这里只还原一半。"),
    Preset(
      id: "soundtrack", name: "影视原声", subtitle: "低频叙事 · 不动动态", kind: .genre,
      gains: curve([(31.5, 1.2), (40, 1.0), (16000, 0.5)]),
      why: "影视配乐的低频是叙事的一部分（爆炸、心跳、低频铺垫）。",
      caveat: "动态范围不该被压缩；本预设只动频响，不动动态。"),
  ]

  // MARK: - 二级分类

  static let subgenres: [Preset] = [
    Preset(
      id: "chamber", name: "古典 · 室内乐", subtitle: "少补偿 · 中频自然", kind: .subgenre,
      gains: curve([(100, -0.5), (1250, 0.4)]),
      why: "室内乐编制小、录音近，任何低频补偿都会盖住琴体的自然衰减。",
      caveat: "弦乐四重奏与钢琴三重奏的平衡不同。"),
    Preset(
      id: "symphony", name: "古典 · 交响", subtitle: "厅堂低频 · 空气", kind: .subgenre,
      gains: curve([(40, 0.8), (63, 0.6), (12500, 0.5)]),
      why: "大编制需要一点 40–63Hz 的厅堂底与 12kHz 的空气。",
      caveat: "近场录音的交响不需要这条的低频。"),
    Preset(
      id: "vocaljazz", name: "爵士 · 人声", subtitle: "中频靠前 · 收齿音", kind: .subgenre,
      gains: curve([(1000, 0.5), (1600, 0.5), (6300, -0.5)]),
      why: "爵士人声的主体在 1–1.6kHz；6kHz 略收可避免齿音。",
      caveat: "男声女声的齿音位置不同，这条取中间。"),
    Preset(
      id: "ambient", name: "电子 · 氛围", subtitle: "收高频 · 留空间", kind: .subgenre,
      gains: curve([(12500, -1.5), (16000, -1.5)]),
      why: "氛围音乐靠长混响与空间，过亮的高频会把「远」的感觉拉近。",
      caveat: "不是所有氛围都暗，Drone 与 Ambient Techno 差别很大。"),
    Preset(
      id: "techno", name: "电子 · Techno", subtitle: "kick 主导 · 硬", kind: .subgenre,
      gains: curve([(40, 2.2), (50, 2.5), (63, 1.8)]),
      why: "Techno 的 kick 与 rumble 在 40–63Hz，是主要驱动力。",
      caveat: "小耳机承受不了这个量，可能削波。"),
    Preset(
      id: "indie", name: "摇滚 · 独立", subtitle: "中频突出 · 不修饰", kind: .subgenre,
      gains: curve([(500, 0.5), (800, 0.6), (1250, 0.5)]),
      why: "独立摇滚的吉他与人声都在 500–1250Hz，中频突出更接近它的粗糙感。",
      caveat: "低预算录音的高频常不够，这条不补。"),
    Preset(
      id: "fingerstyle", name: "民谣 · 指弹", subtitle: "弦的质感 · 泛音", kind: .subgenre,
      gains: curve([(5000, 1.2), (6300, 1.2), (8000, 0.8)]),
      why: "指弹的泛音与指甲触弦在 5–8kHz。",
      caveat: "低把位与高把位的泛音分布不同。"),
    Preset(
      id: "trap", name: "说唱 · Trap", subtitle: "808 更深 · hi-hat 更清", kind: .subgenre,
      gains: curve([(40, 2.2), (50, 2.5), (10000, 1.0), (12500, 0.8)]),
      why: "808 与 hi-hat 是 Trap 的两端，中间的人声不需要额外处理。",
      caveat: "hi-hat 抬太多会盖住人声的齿音区。"),
    Preset(
      id: "femalepop", name: "流行 · 女声", subtitle: "存在感 · 控齿音", kind: .subgenre,
      gains: curve([(2500, 0.6), (3150, 0.8), (6300, -0.8)]),
      why: "女声的存在感在 2.5–3kHz，齿音在 6kHz 附近。",
      caveat: "气声型与力量型女声的处理方向不同。"),
    Preset(
      id: "malepop", name: "流行 · 男声", subtitle: "胸腔厚度 · 中频", kind: .subgenre,
      gains: curve([(160, 0.8), (200, 0.8), (2500, 0.5)]),
      why: "男声的胸腔厚度在 160–200Hz，清晰度在 2.5kHz。",
      caveat: "低音男声与假声型男声不能用同一条。"),
  ]

  // MARK: - 曲线生成

  /// 按频率给一条曲线：中心点取全额，相邻段取一半、再外一段取两成，避免单点锯齿。
  /// 单段改动上限 ±6dB，与 agent 的规则一致 —— 手选预设也不该比 agent 更激进。
  static func curve(_ points: [(Float, Float)]) -> [Float] {
    var gains = [Float](repeating: 0, count: frequencies.count)
    for (hz, db) in points {
      guard let center = nearest(hz) else { continue }
      for offset in -2...2 {
        let index = center + offset
        guard gains.indices.contains(index) else { continue }
        let weight: Float = offset == 0 ? 1 : (offset == 1 ? 0.5 : 0.22)
        gains[index] += db * weight
      }
    }
    return gains.map { max(-6, min(6, $0)) }
  }

  static func nearest(_ hz: Float) -> Int? {
    frequencies.enumerated().min { lhs, rhs in
      abs(lhs.element - hz) < abs(rhs.element - hz)
    }?.offset
  }
}
