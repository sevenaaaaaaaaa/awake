import Foundation

// 真实源码、真实断言：`Tools/run_library_import_harness.sh` 把
// `ios/Awake/LibraryImport.swift` 与本文件一起编译后运行。
// 这台机器起不来模拟器的 XCTest 服务，纯逻辑只能靠这条路径留下可重跑的验证。

var checks = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
  checks += 1
  if condition { return }
  failures += 1
  print("FAIL: \(label)")
}

func tempDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "harness-" + UUID().uuidString, isDirectory: true)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func touch(_ url: URL) {
  try? FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try? Data([0x49, 0x44, 0x33, 0x04]).write(to: url)
}

// MARK: - 扫描：App 自己的缓存目录不是来源

do {
  let root = tempDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  touch(root.appendingPathComponent("user-song.mp3"))
  touch(root.appendingPathComponent("nested/deep.m4a"))
  touch(root.appendingPathComponent("Music/leftover-copy.flac"))
  touch(root.appendingPathComponent("Speech/chapter.caf"))
  touch(root.appendingPathComponent("Artwork/cover.mp3"))
  touch(root.appendingPathComponent("notes.txt"))

  let plain = LibraryImport.audioFiles(in: root)
  check(plain.files.count == 5, "不设排除时普通扫描仍能看到所有音频（实际 \(plain.files.count)）")

  let filtered = LibraryImport.audioFiles(in: root, excludingManagedFrom: root)
  let names = Set(filtered.files.map(\.lastPathComponent))
  check(names == ["user-song.mp3", "deep.m4a"], "托管目录整棵跳过：\(names.sorted())")

  check(
    LibraryImport.isManagedFile(root.appendingPathComponent("Music/leftover-copy.flac"), root: root),
    "Music 下的文件算托管文件")
  check(
    !LibraryImport.isManagedFile(root.appendingPathComponent("user-song.mp3"), root: root),
    "用户放在根目录的文件不算托管")
}

// MARK: - 自吞循环：App 把副本写回被扫描目录时，候选集不该增长

do {
  let root = tempDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  touch(root.appendingPathComponent("user.mp3"))
  let music = root.appendingPathComponent("Music")
  try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)

  var counts: [Int] = []
  for _ in 0..<3 {
    let scan = LibraryImport.audioFiles(in: root, excludingManagedFrom: root)
    counts.append(scan.files.count)
    // 模拟导入：为每个候选在 Music/ 里写一份 UUID 副本（旧行为就是这么长大的）
    for _ in scan.files {
      touch(music.appendingPathComponent(UUID().uuidString + ".mp3"))
    }
  }
  check(counts == [1, 1, 1], "排除托管目录后反复扫描候选不增长：\(counts)")

  let unchecked = LibraryImport.audioFiles(in: root)
  check(
    unchecked.files.count > 1,
    "不排除时副本确实会被当成新文件（旧 bug 的复现）：\(unchecked.files.count) 个候选")
}

// MARK: - 身份：容器 UUID 变了，同一文件仍是同一个身份

do {
  let oldContainer = "/var/mobile/Containers/Data/Application/AAAAAAAA-0000-0000-0000-000000000000/Documents"
  let newContainer = "/var/mobile/Containers/Data/Application/BBBBBBBB-1111-1111-1111-111111111111/Documents"
  let oldPath = oldContainer + "/Awake/2.Blue Bird.mp3"
  let newPath = newContainer + "/Awake/2.Blue Bird.mp3"
  let documents = URL(fileURLWithPath: newContainer)
  let oldKey = LibraryImport.identityKey(oldPath, documents: documents)
  let newKey = LibraryImport.identityKey(newPath, documents: documents)
  check(oldKey == "own:Awake/2.Blue Bird.mp3", "旧容器路径折成相对身份：\(oldKey)")
  check(oldKey == newKey, "换了容器 UUID 仍是同一个身份")

  let privateOld =
    "/private/var/mobile/Containers/Data/Application/AAAAAAAA-0000-0000-0000-000000000000/Documents/Awake/x.m4a"
  check(
    LibraryImport.identityKey(privateOld, documents: documents) == "own:Awake/x.m4a",
    "/private/var 与 /var 折成同一个身份")

  let external = "/Volumes/NAS/Music/live-set.flac"
  check(
    LibraryImport.identityKey(external, documents: documents) == external,
    "容器外文件保留绝对路径：\(LibraryImport.identityKey(external, documents: documents))")

  check(
    LibraryImport.identityKey("own:Awake/x.m4a", documents: documents) == "own:Awake/x.m4a",
    "已经是 own: 的身份不会被再加一层前缀")

  let cue = LibraryImport.identityKey(
    "/var/mobile/Containers/Data/Application/AAAAAAAA-0000-0000-0000-000000000000/Documents/Awake/album.flac#cue-2",
    documents: documents)
  check(cue == "own:Awake/album.flac#cue-2", "CUE 分轨后缀原样保留：\(cue)")
}

// MARK: - 标题：UUID 文件名要被认出来

do {
  check(
    LibraryImport.isUUIDLike("1CA90D99-6998-4B48-9B3C-1F0A2C3D4E5F"),
    "标准 UUID 标题")
  check(
    LibraryImport.isUUIDLike("2B43A14E-323C-459B-8A11-000000000000"),
    "大写 UUID 标题")
  check(!LibraryImport.isUUIDLike("Blue Bird"), "正常标题不是 UUID")
  check(!LibraryImport.isUUIDLike("39.漠河舞厅"), "带序号的标题不是 UUID")
  check(!LibraryImport.isUUIDLike("2.Blue Bird"), "带点的标题不是 UUID")
  check(!LibraryImport.isUUIDLike("builtin-01"), "示例曲目标题不是 UUID")
}

// MARK: - 内容指纹与分组

do {
  let headA = Data(repeating: 0x41, count: 4096)
  let headB = Data(repeating: 0x42, count: 4096)
  check(LibraryImport.headHash(headA) != LibraryImport.headHash(headB), "不同内容哈希不同")
  check(LibraryImport.headHash(headA) == LibraryImport.headHash(headA), "同内容哈希稳定")
  check(
    LibraryImport.fingerprint(size: 1024, duration: 203.44)
      == LibraryImport.fingerprint(size: 1024, duration: 203.41),
    "0.1 秒内的时长抖动算同一指纹")

  let uuidTitle = "A1B2C3D4-1111-2222-3333-444455556666"
  let junk = LibraryImport.Entry(
    id: "junk", identity: "own:Awake/cache.m4a", fingerprint: "1024-2034", file: "cache.m4a",
    title: uuidTitle, artist: "未知艺人", hasArtwork: false, hasLyrics: false,
    referenced: true, addedAt: Date(timeIntervalSince1970: 2_000))
  let named = LibraryImport.Entry(
    id: "named", identity: "own:Awake/2.Blue Bird.m4a", fingerprint: "1024-2034",
    file: "named.m4a", title: "Blue Bird", artist: "王菲", hasArtwork: false, hasLyrics: false,
    referenced: false, addedAt: Date(timeIntervalSince1970: 1_000))

  let groups = LibraryImport.duplicateGroups([junk, named])
  check(groups.count == 1, "同指纹归到一组")
  check(groups.first?.keep == "named", "保留真实标题那一条：\(String(describing: groups.first?.keep))")
  check(groups.first?.drop == ["junk"], "UUID 标题那一条被合并")

  let single = LibraryImport.duplicateGroups([named])
  check(single.isEmpty, "只有一条时不成组")

  let differentSize = LibraryImport.Entry(
    id: "other", identity: "own:Awake/other.m4a", fingerprint: "2048-2034", file: "other.m4a",
    title: "Blue Bird", artist: "王菲", hasArtwork: false, hasLyrics: false, referenced: false,
    addedAt: Date())
  check(
    LibraryImport.duplicateGroups([named, differentSize]).isEmpty,
    "尺寸不同不合并（避免把两首不同的歌并掉）")
}

// MARK: - 横滑换 tab 的规则

do {
  let width: CGFloat = 402
  let center = CGPoint(x: 200, y: 500)

  check(
    TabPaging.nextTab(
      current: 1, count: 5, translation: CGSize(width: -120, height: 10), start: center,
      width: width, exempt: []) == 2,
    "向左滑 = 下一个")
  check(
    TabPaging.nextTab(
      current: 1, count: 5, translation: CGSize(width: 120, height: 10), start: center,
      width: width, exempt: []) == 0,
    "向右滑 = 上一个")
  check(
    TabPaging.nextTab(
      current: 4, count: 5, translation: CGSize(width: -120, height: 10), start: center,
      width: width, exempt: []) == nil,
    "最后一个 tab 向左滑不循环")
  check(
    TabPaging.nextTab(
      current: 0, count: 5, translation: CGSize(width: 120, height: 10), start: center,
      width: width, exempt: []) == nil,
    "第一个 tab 向右滑不循环")
  check(
    TabPaging.nextTab(
      current: 2, count: 5, translation: CGSize(width: -120, height: 90), start: center,
      width: width, exempt: []) == nil,
    "斜向拖动（竖直为主）不翻页")
  check(
    TabPaging.nextTab(
      current: 2, count: 5, translation: CGSize(width: -40, height: 2), start: center,
      width: width, exempt: []) == nil,
    "位移不够不翻页")
  check(
    TabPaging.nextTab(
      current: 2, count: 5, translation: CGSize(width: -120, height: 2),
      start: CGPoint(x: 8, y: 500), width: width, exempt: []) == nil,
    "屏幕左边缘留给返回手势")
  check(
    TabPaging.nextTab(
      current: 2, count: 5, translation: CGSize(width: -120, height: 2), start: center,
      width: width, exempt: [CGRect(x: 150, y: 450, width: 120, height: 100)]) == nil,
    "横向控件里横滑不翻页")
  check(
    TabPaging.nextTab(
      current: 2, count: 5, translation: CGSize(width: -81, height: 40), start: center,
      width: width, exempt: []) == 3,
    "刚好过线（81pt，竖直 40）算翻页")
}

print("LibraryImport harness: \(checks) 项断言，\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
