import SwiftUI
import UIKit
import XCTest

/// The library cell menu is built by a small view because `contextMenu`'s closure runs with every body pass of the
/// cell while the view returned from it is only built when the menu is shown. This pins both halves.
@MainActor
final class ContextMenuLazinessTests: XCTestCase {
    private final class Counter { var closure = 0; var body = 0 }

    private struct Items: View {
        let counter: Counter
        var body: some View {
            let _ = { counter.body += 1 }()
            Button("One") {}
        }
    }

    private struct Host: View {
        let counter: Counter
        var body: some View {
            Color.gray.frame(width: 80, height: 80)
                .contextMenu {
                    let _ = { counter.closure += 1 }()
                    Items(counter: counter)
                }
        }
    }

    func testMenuClosureRunsWithTheBodyButItsViewsDoNot() async {
        let counter = Counter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = UIHostingController(rootView: Host(counter: counter))
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(counter.closure, 0, "contextMenu's closure runs while the cell's body is built")
        XCTAssertEqual(counter.body, 0, "the menu's views are not built until the menu is shown")
        window.isHidden = true
    }
}
