import XCTest

final class AwakeUITests: XCTestCase {
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
