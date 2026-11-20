# Awake iOS 0.9.9

iOS 17+。这一版只修一件事：**播放页进得去、出不来。**

0.9.8 把「正在播放」从 sheet 改成 fullScreenCover，并把导航栏换成自绘顶部条。装上之后有人反馈：点开播放页，左上角那个下拉箭头没反应，页面里别的控件也不响应，只能杀进程。这个版本把呈现方式收回最朴素的一种。

## 改了什么

- **cover 只留一个宿主。** 0.9.8 把 `fullScreenCover` 挂在 `MiniPlayer` 上，而 `MiniPlayer` 被 `.playerInset()` 装进了五个 tab 的下缘插槽——同一份「打开播放页」的开关，在五个不同的宿主上各挂了一次呈现。现在挂到 `RootView` 的 `TabView` 上：一次状态，一次呈现。
- **关闭按钮不再只靠 `dismiss()`。** 现在先写状态（`store.playerSheetOpen = false`，cover 的 `isPresented` 绑的就是它），再调 `dismiss()` 收动画。只要呈现宿主和这个环境不是同一个，光调 `dismiss()` 就会是「按了有反馈、页面留在原地」。
- **播放页去掉 `NavigationStack` 外壳。** 0.9.8 保留它只是为了 `.toolbar(.hidden, for: .navigationBar)`。代价是整页被包进 `UINavigationTransitionView / UILayoutContainerView`，而顶部那条 44 pt 正是自绘箭头所在。没有导航栏要隐藏，就没有理由留这层容器。
- **自检通道加了两只探针**（仅 DEBUG）：`呈现层[depth]` 记录关键窗口被 cover 叠了几层，`命中[点] = view 链` 记录某个坐标按下时系统把事件交给谁。以后再遇到「看着正常、点不动」，不必靠猜。

## 验证到什么程度

在模拟器（iPhone 17 Pro / iOS 27）用应用内自检通道跑：

- 打开播放页：呈现层 `key:1`；命中测试在箭头 (21,62)、中部 (201,437)、播放键 (201,690) 都落在 cover 的内容视图上，不是别的层。
- 关闭后：呈现层 `key:0`，截图回到首页与 mini player。
- 视图层级从 `HostingView < UIViewControllerWrapperView < UINavigationTransitionView < UILayoutContainerView < UIKitPlatformViewHost<NavigationStackRepresentable>` 简化成 `HostingView < UITransitionView < UIWindow`。

**没做成的部分要说清楚：我没能在模拟器上复现你遇到的那个症状。** 0.9.8 的同一份代码在模拟器里 `dismiss()` 也能关掉、命中测试也正常——所以这一版是把「最可疑的那层结构」删掉并让关闭不再依赖单一通路，不是「复现 → 修好 → 回归测试」的闭环。如果你装 0.9.9 后仍然出不来，请把设置里的诊断日志发我：那里会有 `呈现层` 与 `命中` 两行，能直接看出事件被谁接走了。

## 仍未闭合

- iOS XCTest 在本机仍然跑不起来（模拟器 service hub 起不来），验收口径是「编译通过 + 模拟器实跑 + 应用内自检日志」。
- 播放页曲线仍只支持单段拖动，多选频段与桌面端的 Shift 涂抹还没对齐。
- 首页与侧栏还有 `YOUR LISTENING SPACE` 这类大写宽字距标签，以及渐变封面。

## 安装

未签名 IPA，需自行重签（TrollStore / AltStore / Sideloadly 均可）。同一份 IPA 也在 iCloud Drive 里。
