import XCTest

/// Drags tasks into a new order, types in them, highlights them, and undoes deleting them, on the sample lists debug
/// builds show with -YANAScreenshots.
/// Groceries is Milk, Eggs, Coffee beans, Lemons, Sourdough.
final class ListUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-YANAScreenshots", "YES", "-YANAOpen", "1", "-sticky", "NO"]
        app.launch()
        XCTAssertTrue(task("Milk").waitForExistence(timeout: 15), app.debugDescription)
    }

    /// A task's text on screen, whether it's showing as text or as a text field
    func task(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "(label == %@ OR value == %@) AND elementType != %d", text, text,
                                  XCUIElement.ElementType.cell.rawValue))
            .firstMatch
    }

    func row(_ text: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }

    /// The tasks, top to bottom
    func order(_ texts: [String]) -> [String] {
        texts.sorted { task($0).frame.minY < task($1).frame.minY }
    }

    let groceries = ["Milk", "Eggs", "Coffee beans", "Lemons", "Sourdough"]

    func drag(from start: XCUICoordinate, to end: XCUICoordinate, holding: TimeInterval) {
        start.press(forDuration: holding, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
    }

    func testTouchAndHoldDragsATask() {
        drag(from: task("Milk").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
             to: row("Lemons").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), holding: 1.2)
        sleep(2)
        let now = order(groceries)
        XCTAssertNotEqual(now.first, "Milk", "\(now)\n\(app.debugDescription)")
        XCTAssertEqual(now.first, "Eggs", "\(now)")
        // And it's still a list you can type in, not stuck mid-drag
        XCTAssertFalse(app.keyboards.element.exists)
    }

    func testEditDragsATaskByItsHandle() {
        app.buttons["Edit"].tap()
        sleep(1)
        let start = row("Milk").coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
        let end = row("Lemons").coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.8))
        drag(from: start, to: end, holding: 0.6)
        sleep(1)
        app.buttons["Done"].firstMatch.tap()
        sleep(1)
        let now = order(groceries)
        XCTAssertEqual(now.first, "Eggs", "\(now)\n\(app.debugDescription)")
    }

    func testUndoPutsASwipedTaskBack() {
        row("Lemons").swipeLeft()
        // A short swipe shows Delete, and a long one deletes
        let delete = app.buttons["Delete"]
        if delete.waitForExistence(timeout: 2) { delete.tap() }
        undoBrings("Lemons", backInto: groceries)
    }

    func testUndoPutsClearedTasksBack() {
        app.buttons["Clear Checked (2)"].tap()
        let clear = app.buttons["Clear Checked"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), app.debugDescription)
        clear.tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(task("Sourdough").exists)
        undoBrings("Eggs", backInto: groceries)
    }

    /// Taps Undo, and checks the task is back in its place and the Undo bar has gone
    private func undoBrings(_ text: String, backInto all: [String]) {
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(task(text).exists)
        undo.tap()
        XCTAssertTrue(task(text).waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)
        XCTAssertEqual(order(all), all)
        XCTAssertFalse(undo.exists)
    }

    /// Something in the menu touching and holding a task shows, by what it says
    func menuItem(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Waits for what an element's value says to match, as VoiceOver would read it
    func waitFor(_ element: XCUIElement, value format: String, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    /// Keeps a screenshot in the test results, when the run asks for them with TEST_RUNNER_YANA_SHOTS=1
    func shoot(_ name: String) {
        guard ProcessInfo.processInfo.environment["YANA_SHOTS"] != nil else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTouchAndHoldHighlightsATask() {
        task("Coffee beans").press(forDuration: 1.2)
        let green = menuItem("Green")
        XCTAssertTrue(green.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(menuItem("Remove Highlight").exists)
        shoot("highlight-menu")
        green.tap()
        XCTAssertTrue(waitFor(task("Coffee beans"), value: "value == %@", "Green highlight"), app.debugDescription)
        sleep(1)
        shoot("highlighted")

        // And taken off again
        task("Coffee beans").press(forDuration: 1.2)
        let remove = menuItem("Remove Highlight")
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        shoot("highlight-menu-again")
        remove.tap()
        XCTAssertTrue(waitFor(task("Coffee beans"), value: "NOT (value == %@)", "Green highlight"),
                      app.debugDescription)
        // Nothing moved
        sleep(1)
        XCTAssertEqual(order(groceries), groceries)
    }

    func testTappingATaskTypesInIt() {
        let add = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Add a task")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.tap()
        app.typeText("Bread\n")
        sleep(1)
        app.typeText("Jam\n")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(task("Jam").waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)
        XCTAssertFalse(app.keyboards.element.exists)

        // Tapping Bread puts the keyboard at its end, and Return there starts a task below it
        task("Bread").tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)
        app.typeText("\nButter")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(task("Butter").waitForExistence(timeout: 5), app.debugDescription)
        sleep(1)
        XCTAssertEqual(order(["Jam", "Butter", "Bread", "Sourdough"]), ["Sourdough", "Bread", "Butter", "Jam"])
    }
}
