import XCTest

/// Drags tasks into a new order and types in them, on the sample lists debug builds show with -YANAScreenshots.
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
