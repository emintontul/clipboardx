import XCTest
@testable import ClipboardXKit

final class ShortcutTests: XCTestCase {
    func testDefaultsDisplayLikeMacOS() {
        XCTAssertEqual(ShortcutAction.showShelf.defaultShortcut.display, "⇧⌘V")
        XCTAssertEqual(ShortcutAction.pasteStack.defaultShortcut.display, "⇧⌘C")
        XCTAssertEqual(ShortcutAction.nextBoard.defaultShortcut.display, "⌘→")
        XCTAssertEqual(ShortcutAction.previousBoard.defaultShortcut.display, "⌘←")
    }

    func testModifierOrderIsControlOptionShiftCommand() {
        let all = Shortcut(keyCode: 0, modifiers: Shortcut.control | Shortcut.option | Shortcut.shift | Shortcut.command)
        XCTAssertEqual(all.display, "⌃⌥⇧⌘A")
    }

    func testUnknownKeyCodeStillHasADisplay() {
        XCTAssertEqual(Shortcut(keyCode: 200, modifiers: Shortcut.command).display, "⌘Key 200")
    }

    func testGlobalShortcutNeedsACommandOptionOrControlModifier() {
        XCTAssertTrue(Shortcut(keyCode: 9, modifiers: Shortcut.command).isValidGlobal)
        XCTAssertTrue(Shortcut(keyCode: 9, modifiers: Shortcut.option | Shortcut.shift).isValidGlobal)
        XCTAssertFalse(Shortcut(keyCode: 9, modifiers: Shortcut.shift).isValidGlobal, "Shift alone would break typing")
        XCTAssertFalse(Shortcut(keyCode: 9, modifiers: 0).isValidGlobal)
    }
}

final class ShortcutStoreTests: XCTestCase {
    private func makeStore() -> (ShortcutStore, UserDefaults, String) {
        let suite = "clipboardx.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (ShortcutStore(defaults: defaults), defaults, suite)
    }

    func testStartsWithDefaults() {
        let (store, defaults, suite) = makeStore(); defer { defaults.removePersistentDomain(forName: suite) }
        for action in ShortcutAction.allCases { XCTAssertEqual(store.shortcut(for: action), action.defaultShortcut) }
    }

    func testChangePersistsAcrossInstances() throws {
        let (store, defaults, suite) = makeStore(); defer { defaults.removePersistentDomain(forName: suite) }
        let custom = Shortcut(keyCode: 9, modifiers: Shortcut.option | Shortcut.command)
        try store.set(custom, for: .showShelf)
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcut(for: .showShelf), custom)
    }

    func testConflictWithAnotherActionIsRejected() throws {
        let (store, defaults, suite) = makeStore(); defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertThrowsError(try store.set(ShortcutAction.pasteStack.defaultShortcut, for: .showShelf)) { error in
            XCTAssertEqual(error as? ShortcutStore.SetError, .conflict(with: .pasteStack))
        }
        XCTAssertEqual(store.shortcut(for: .showShelf), ShortcutAction.showShelf.defaultShortcut)
    }

    func testSettingTheSameShortcutOnTheSameActionIsFine() throws {
        let (store, defaults, suite) = makeStore(); defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNoThrow(try store.set(ShortcutAction.showShelf.defaultShortcut, for: .showShelf))
    }

    func testGlobalActionsRejectShortcutsWithoutAModifier() {
        let (store, defaults, suite) = makeStore(); defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertThrowsError(try store.set(Shortcut(keyCode: 9, modifiers: Shortcut.shift), for: .showShelf)) { error in
            XCTAssertEqual(error as? ShortcutStore.SetError, .needsModifier)
        }
    }

    func testResetRestoresDefaults() throws {
        let (store, defaults, suite) = makeStore(); defer { defaults.removePersistentDomain(forName: suite) }
        try store.set(Shortcut(keyCode: 9, modifiers: Shortcut.option | Shortcut.command), for: .showShelf)
        store.resetAll()
        XCTAssertEqual(store.shortcut(for: .showShelf), ShortcutAction.showShelf.defaultShortcut)
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcut(for: .showShelf), ShortcutAction.showShelf.defaultShortcut)
    }

    func testMatchesComparesKeyAndModifiers() {
        let (store, defaults, suite) = makeStore(); defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(store.matches(keyCode: 124, modifiers: Shortcut.command, action: .nextBoard))
        XCTAssertFalse(store.matches(keyCode: 124, modifiers: Shortcut.command | Shortcut.shift, action: .nextBoard))
    }

    func testCorruptStoredValueFallsBackToDefault() {
        let (store, defaults, suite) = makeStore(); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1, 2, 3]), forKey: "shortcuts.showShelf")
        XCTAssertEqual(store.shortcut(for: .showShelf), ShortcutAction.showShelf.defaultShortcut)
    }
}
