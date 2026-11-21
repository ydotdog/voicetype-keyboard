import SwiftUI
import UIKit
import XCTest
@testable import VoiceType

/// Checks when a page's two groups stack and when they sit side by side.
///
/// The window widths are approximate iPhone Duo sizes in points. A page's
/// content is 24 pt narrower than its window on each side.
@MainActor
final class AdaptiveLayoutTests: XCTestCase {
    private let stackedHeight: CGFloat = 100 + 24 + 60
    private let columnsHeight: CGFloat = 100

    func testCompactWindowsStackTheGroups() {
        // Half of the open display in each orientation, closed, and open in portrait.
        for width in [334, 466, 475, 669] as [CGFloat] {
            XCTAssertEqual(pageHeight(windowWidth: width), stackedHeight, accuracy: 0.5, "window width \(width)")
        }
    }

    func testOpenLandscapeWindowShowsTwoColumns() {
        XCTAssertEqual(pageHeight(windowWidth: 951), columnsHeight, accuracy: 0.5)
    }

    func testColumnsStartAtTheMinimumContentWidth() {
        let threshold = AdaptiveColumns.phoneColumnsWidth + 48
        XCTAssertEqual(pageHeight(windowWidth: threshold - 1), stackedHeight, accuracy: 0.5)
        XCTAssertEqual(pageHeight(windowWidth: threshold), columnsHeight, accuracy: 0.5)
    }

    func testAccessibilityTextSizesAlwaysStack() {
        XCTAssertEqual(pageHeight(windowWidth: 951, typeSize: .accessibility3), stackedHeight, accuracy: 0.5)
    }

    /// The height of a page whose groups are 100 pt and 60 pt tall: 184 pt when
    /// they stack with the default 24 pt gap, 100 pt when they share a row.
    private func pageHeight(windowWidth: CGFloat, typeSize: DynamicTypeSize = .large) -> CGFloat {
        let page = PageColumns {
            Color.red.frame(height: 100)
        } secondary: {
            Color.blue.frame(height: 60)
        }
        .padding(.horizontal, 24)
        .frame(width: windowWidth)
        .environment(\.dynamicTypeSize, typeSize)
        let hosting = UIHostingController(rootView: page)
        hosting.safeAreaRegions = []
        return hosting.sizeThatFits(in: CGSize(width: windowWidth, height: 10_000)).height
    }
}
