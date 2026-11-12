import XCTest

final class AwakeUITests: XCTestCase {
  func testMediaInformationCanBeEditedWithoutChangingAudio() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["曲库"].tap()
    let song = app.buttons["song-qa-audio"]
    XCTAssertTrue(song.waitForExistence(timeout: 3))
    song.press(forDuration: 1)
    app.buttons["整理封面、歌词与乐评"].tap()
    let title = app.textFields["mediaTitle"]
    for _ in 0..<4 { if !title.isHittable { app.swipeUp() } }
    XCTAssertTrue(title.waitForExistence(timeout: 3))
    title.tap()
    title.press(forDuration: 1)
    if app.menuItems["全选"].exists { app.menuItems["全选"].tap(); title.typeText("Organized recording") }
    else { title.typeText(" Organized") }
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Media information editor"
    capture.lifetime = .keepAlways; add(capture)
    let save = app.buttons["saveMedia"]
    for _ in 0..<12 { if !save.exists || !save.isHittable { app.swipeUp() } }
    XCTAssertTrue(save.waitForExistence(timeout: 3)); save.tap()
    XCTAssertTrue(app.buttons["song-qa-audio"].waitForExistence(timeout: 3))
    app.buttons["song-qa-audio"].tap()
    XCTAssertTrue(app.buttons["打开正在播放"].waitForExistence(timeout: 3))
  }
  func testImportPickersPresentAndCancel() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["设置"].tap()
    let folderButton = app.buttons["importFolder"]
    for _ in 0..<5 { if !folderButton.isHittable { app.swipeUp() } }
    XCTAssertTrue(folderButton.waitForExistence(timeout: 5))
    folderButton.tap()
    var cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 8), app.debugDescription)
    cancel.tap()
    let fileButton = app.buttons["importAudioFiles"]
    for _ in 0..<5 { if !fileButton.isHittable { app.swipeUp() } }
    XCTAssertTrue(fileButton.waitForExistence(timeout: 5))
    fileButton.tap()
    cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 8), app.debugDescription)
    cancel.tap()
    XCTAssertTrue(app.buttons["addSource"].waitForExistence(timeout: 5))
    app.tabBars.buttons["曲库"].tap()
    let libraryFolder = app.buttons["importLibraryFolder"]
    XCTAssertTrue(libraryFolder.waitForExistence(timeout: 5))
    libraryFolder.tap()
    cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 8), app.debugDescription)
    cancel.tap()
    let libraryFile = app.buttons["importMusic"]
    XCTAssertTrue(libraryFile.waitForExistence(timeout: 5))
    libraryFile.tap()
    cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 8), app.debugDescription)
    cancel.tap()
    XCTAssertTrue(app.buttons["song-qa-audio"].waitForExistence(timeout: 5))
  }
  func testSwipePlayerEntryAndModes() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["曲库"].tap()
    app.buttons["song-qa-audio"].tap()
    let open = app.buttons["打开正在播放"]
    XCTAssertTrue(open.waitForExistence(timeout: 5))
    open.tap()
    let entry = app.buttons["swipeModeEntry"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
    let close = app.descendants(matching: .any)["closeSwipe"]
    XCTAssertTrue(close.waitForExistence(timeout: 8), app.debugDescription)
    XCTAssertTrue(app.staticTexts["QA 自生成测试音频"].waitForExistence(timeout: 5))
    // 切换到卡片模式并做一次左滑（没有下一首时也不应崩溃）。
    app.segmentedControls.firstMatch.buttons.element(boundBy: 1).tap()
    app.windows.firstMatch.swipeLeft()
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    app.segmentedControls.firstMatch.buttons.element(boundBy: 0).tap()
    app.windows.firstMatch.swipeUp()
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    close.tap()
    XCTAssertTrue(app.buttons["swipeModeEntry"].waitForExistence(timeout: 5))
  }
  func testPlaylistImportSheetPresents() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["曲库"].tap()
    let entry = app.buttons["importPlaylist"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
    XCTAssertTrue(app.navigationBars["导入歌单"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["playlistSource"].waitForExistence(timeout: 5))
    app.buttons["完成"].tap()
    XCTAssertTrue(app.buttons["importPlaylist"].waitForExistence(timeout: 5))
  }
  private func connectorFixtureIsRunning() -> Bool {
    let finished = expectation(description: "Check explicit loopback fixture")
    var available = false
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8766/v1/catalog")!)
    request.timeoutInterval = 2
    request.setValue("Bearer test-only-token", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: request) { _, response, _ in
      available = (response as? HTTPURLResponse)?.statusCode == 200
      finished.fulfill()
    }.resume()
    wait(for: [finished], timeout: 3)
    return available
  }
  func testTelegramSourceCanBeSelectedAndRequiresExplicitScope() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["设置"].tap()
    let addSourceButton = app.buttons["addSource"]
    for _ in 0..<3 { if !addSourceButton.isHittable { app.swipeUp() } }
    addSourceButton.tap()
    app.buttons["sourceKind"].tap()
    app.buttons["Telegram 个人媒体库"].tap()
    XCTAssertTrue(app.buttons["telegramBrowse"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["connectSource"].isEnabled)
    let name = app.textFields["sourceName"]
    name.tap(); name.typeText("Personal audio")
    let url = app.textFields["sourceURL"]
    url.tap(); url.typeText("http://127.0.0.1:8766/")
    let secret = app.secureTextFields["sourceSecret"]
    secret.tap(); secret.typeText("test-only-token")
    app.swipeUp()
    XCTAssertTrue(app.buttons["telegramBrowse"].isEnabled)
    XCTAssertFalse(app.buttons["connectSource"].isEnabled)
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Telegram source requires an explicit collection"
    capture.lifetime = .keepAlways
    add(capture)
    if connectorFixtureIsRunning() {
      app.buttons["telegramBrowse"].tap()
      let saved = app.switches["收藏夹"]
      XCTAssertTrue(saved.waitForExistence(timeout: 5))
      saved.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      XCTAssertEqual(saved.value as? String, "1")
      app.buttons["使用所选来源"].tap()
      let connect = app.buttons["connectSource"]
      for _ in 0..<3 { if !connect.exists { app.swipeUp() } }
      XCTAssertTrue(connect.waitForExistence(timeout: 3))
      XCTAssertTrue(connect.isEnabled)
      connect.tap()
      XCTAssertTrue(app.buttons["addSource"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.staticTexts["Personal audio"].exists)
      let completed = XCTAttachment(screenshot: app.screenshot())
      completed.name = "Telegram personal collection connected using local fixture"
      completed.lifetime = .keepAlways
      add(completed)
    }
  }
  private func revealEQSlider(_ app: XCUIApplication) -> XCUIElement {
    let slider = app.sliders["eqGainSlider"]
    for _ in 0..<6 {
      let frame = slider.frame
      if frame.minY > 220 && frame.maxY < app.frame.maxY - 220 { return slider }
      let movingUp = frame.maxY >= app.frame.maxY - 220
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: movingUp ? 0.65 : 0.4))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: movingUp ? 0.5 : 0.55))
      start.press(forDuration: 0.1, thenDragTo: end)
    }
    return slider
  }
  func testReducedMotionUsesStaticEffectConfirmation() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting", "--reduce-motion-ui"]
    app.launch()
    app.tabBars.buttons["声音"].tap()
    app.buttons["configureChain"].tap()
    app.buttons["saveChain"].tap()
    let slider = revealEQSlider(app)
    slider.adjust(toNormalizedSliderPosition: 0.75)
    let effect = app.descendants(matching: .any)["effectActivation"]
    XCTAssertTrue(effect.waitForExistence(timeout: 2))
    XCTAssertEqual(effect.value as? String, "减少动态效果")
  }
  func testEffectAnimationAndPlayerBadgeFollowBypass() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["曲库"].tap()
    app.buttons["song-qa-audio"].tap()
    app.tabBars.buttons["声音"].tap()
    app.buttons["configureChain"].tap()
    app.buttons["saveChain"].tap()
    let slider = revealEQSlider(app)
    XCTAssertTrue(slider.isEnabled)
    print("EFFECT_SLIDER_BEFORE=\(String(describing: slider.value)) frame=\(slider.frame)")
    slider.adjust(toNormalizedSliderPosition: 0.75)
    print(
      "EFFECT_SLIDER_AFTER=\(String(describing: slider.value)) badge=\(String(describing: app.buttons["soundEnhancementBadge"].value))"
    )
    let effect = app.descendants(matching: .any)["effectActivation"]
    XCTAssertTrue(effect.waitForExistence(timeout: 2))
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Awake headphone effect activation"
    capture.lifetime = .keepAlways
    add(capture)
    let soundBadge = app.buttons["soundEnhancementBadge"]
    XCTAssertTrue((soundBadge.value as? String ?? "").contains("EQ 增强"))
    let bypass = app.switches["bypassEQ"]
    if !bypass.isHittable { app.swipeUp() }
    bypass.tap()
    XCTAssertEqual(soundBadge.value as? String, "EQ 已旁路")
    let mini = app.buttons["miniEnhancementBadge"].firstMatch
    XCTAssertEqual(mini.value as? String, "EQ 已旁路")
    app.buttons["打开正在播放"].tap()
    let fullBadge = app.buttons["enhancementBadge"].firstMatch
    XCTAssertTrue(fullBadge.waitForExistence(timeout: 5))
    XCTAssertEqual(fullBadge.value as? String, "EQ 已旁路")
    fullBadge.tap()
    let restore = app.buttons["effectDetailsBypass"]
    XCTAssertTrue(restore.waitForExistence(timeout: 5))
    restore.tap()
    let restoredEffect = app.descendants(matching: .any)["effectActivation"]
    XCTAssertTrue(restoredEffect.waitForExistence(timeout: 2))
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: restoredEffect)
    XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed)
    app.navigationBars["声音增强"].buttons["完成"].tap()
    XCTAssertTrue((fullBadge.value as? String ?? "").contains("EQ 增强"))
    let playingCapture = XCTAttachment(screenshot: app.screenshot())
    playingCapture.name = "Awake player enhancement status"
    playingCapture.lifetime = .keepAlways
    add(playingCapture)
  }
  func testEquipmentGoalsAndSourcesCanBeSaved() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["声音"].tap()
    app.buttons["configureChain"].tap()
    let entry = app.buttons["equipmentEditor"]
    for _ in 0..<3 { if !entry.isHittable { app.swipeUp() } }
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
    let goal = app.buttons["listeningGoal"]
    XCTAssertTrue(goal.waitForExistence(timeout: 5))
    goal.tap()
    app.buttons["游戏定位"].tap()
    app.buttons["headphoneEvidencePicker"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("HD600")
    XCTAssertTrue(app.buttons["selectModel-hd600"].waitForExistence(timeout: 5))
    app.buttons["selectModel-hd600"].tap()
    app.buttons["headphoneEvidencePicker"].tap()
    XCTAssertTrue(app.buttons["自定义型号 / 未收录"].waitForExistence(timeout: 5))
    app.buttons["自定义型号 / 未收录"].tap()
    let clearedModel = app.textFields["equipmentHeadphoneModel"].value as? String
    XCTAssertTrue(clearedModel == "" || clearedModel == "耳机完整型号")
    app.buttons["headphoneEvidencePicker"].tap()
    let nextSearch = app.searchFields.firstMatch
    XCTAssertTrue(nextSearch.waitForExistence(timeout: 5))
    nextSearch.tap()
    nextSearch.typeText("HD600")
    XCTAssertTrue(app.buttons["selectModel-hd600"].waitForExistence(timeout: 5))
    app.buttons["selectModel-hd600"].tap()
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Awake iOS equipment evidence"
    capture.lifetime = .keepAlways
    add(capture)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["saveChain"].tap()
    XCTAssertTrue(app.buttons["configureChain"].waitForExistence(timeout: 5))
    app.buttons["configureChain"].tap()
    XCTAssertEqual(app.textFields["headphoneModel"].value as? String, "Sennheiser HD 600")
  }
  func testMainstreamCatalogBrandFilterAndSelection() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["声音"].tap()
    app.buttons["configureChain"].tap()
    let entry = app.buttons["equipmentEditor"]
    for _ in 0..<3 { if !entry.isHittable { app.swipeUp() } }
    entry.tap()
    app.buttons["headphoneEvidencePicker"].tap()
    let brands = app.buttons["catalogBrandPicker"]
    XCTAssertTrue(brands.waitForExistence(timeout: 5))
    brands.tap()
    app.buttons["索尼 Sony"].tap()
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("WF-1000XM5")
    let selection = app.buttons["selectModel-wf-1000xm5"]
    XCTAssertTrue(selection.waitForExistence(timeout: 5))
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Awake mainstream headphone catalog"
    capture.lifetime = .keepAlways
    add(capture)
    selection.tap()
    XCTAssertEqual(app.textFields["equipmentHeadphoneModel"].value as? String, "Sony WF-1000XM5")
  }
  func testListeningFeedbackAndSoftwareBench() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["曲库"].waitForExistence(timeout: 10))
    app.tabBars.buttons["曲库"].tap()
    let track = app.buttons["song-qa-audio"]
    XCTAssertTrue(track.waitForExistence(timeout: 5))
    track.tap()
    XCTAssertTrue(app.buttons["miniPlay"].waitForExistence(timeout: 5))
    app.tabBars.buttons["评测"].tap()
    let save = app.buttons["saveRating"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    save.tap()
    XCTAssertTrue(app.staticTexts["ratingSaved"].waitForExistence(timeout: 5))
    app.swipeUp()
    let bench = app.buttons["runBench"]
    if !bench.isHittable { app.swipeUp() }
    bench.tap()
    XCTAssertTrue(app.descendants(matching: .any)["benchResult"].waitForExistence(timeout: 15))
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Awake iOS listening lab"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testRouteConfigurationAndNativeThemes() {
    let app = XCUIApplication()
    app.launchArguments = ["--uitesting"]
    app.launch()
    app.tabBars.buttons["声音"].tap()
    app.buttons["configureChain"].tap()
    let name = app.textFields["chainName"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.press(forDuration: 1)
    name.typeText(" · QA")
    app.buttons["saveChain"].tap()
    XCTAssertTrue(app.buttons["configureChain"].waitForExistence(timeout: 5))
    app.tabBars.buttons["设置"].tap()
    XCTAssertTrue(app.buttons["themePicker"].waitForExistence(timeout: 5))
    app.buttons["themePicker"].tap()
    app.buttons["白色 · Paper"].tap()
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Awake iOS light theme"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
