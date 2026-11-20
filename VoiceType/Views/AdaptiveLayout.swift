import SwiftUI

/// The widest a page's content grows. A wider window keeps the page centered,
/// so the compact layout expands on the open iPhone Duo and on iPad instead of
/// stretching from edge to edge.
enum PageWidth {
    /// One reading column.
    static let reading: CGFloat = 720
    /// A page that divides into two columns.
    static let wide: CGFloat = 960
}

/// The scrolling, centered container that every tab's page shares.
struct TabPage<Content: View>: View {
    var maxWidth: CGFloat = PageWidth.reading
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A page's primary and secondary content: one column in a compact window, the
/// same views side by side once each column can be as wide as a phone.
///
/// The closed iPhone Duo and a portrait iPhone stack the two groups in order.
/// The open iPhone Duo in landscape, an iPad and a landscape iPhone show them
/// as two even columns, so unfolding the device widens the page rather than
/// rearranging it.
struct PageColumns<Primary: View, Secondary: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The gap between the views in a group, and between the stacked groups.
    var spacing: CGFloat = 24
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        // Accessibility text sizes wrap too hard in a half-width column.
        AdaptiveColumns(
            minimumColumnsWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : AdaptiveColumns.phoneColumnsWidth,
            rowSpacing: spacing
        ) {
            VStack(alignment: .leading, spacing: spacing) { primary }
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: spacing) { secondary }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Places its subviews in equal columns when the proposed width reaches
/// `minimumColumnsWidth`, and stacks them from the top otherwise.
///
/// The choice depends only on the proposed width, so measuring and placing
/// always agree, and the layout never asks which device it is running on.
struct AdaptiveColumns: Layout {
    /// Two columns that are each at least as wide as the content of a compact iPhone.
    static let phoneColumnsWidth: CGFloat = 640

    /// The narrowest container that shows columns. `.infinity` always stacks.
    var minimumColumnsWidth: CGFloat = AdaptiveColumns.phoneColumnsWidth
    var columnSpacing: CGFloat = 32
    var rowSpacing: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        if let column = columnWidth(in: proposal.width, count: subviews.count), let width = proposal.width {
            let columnProposal = ProposedViewSize(width: column, height: nil)
            let height = subviews.map { $0.sizeThatFits(columnProposal).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }

        let rowProposal = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(rowProposal) }
        return CGSize(
            width: sizes.map(\.width).max() ?? 0,
            height: sizes.map(\.height).reduce(0, +) + rowSpacing * CGFloat(subviews.count - 1)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let column = columnWidth(in: proposal.width, count: subviews.count) {
            let columnProposal = ProposedViewSize(width: column, height: nil)
            for (index, subview) in subviews.enumerated() {
                let x = bounds.minX + CGFloat(index) * (column + columnSpacing)
                subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: columnProposal)
            }
            return
        }

        let rowProposal = ProposedViewSize(width: proposal.width, height: nil)
        var y = bounds.minY
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: rowProposal)
            y += subview.sizeThatFits(rowProposal).height + rowSpacing
        }
    }

    /// The width of each column, or `nil` when the subviews stack.
    private func columnWidth(in width: CGFloat?, count: Int) -> CGFloat? {
        guard count > 1, let width, width.isFinite, width >= minimumColumnsWidth else { return nil }
        return (width - columnSpacing * CGFloat(count - 1)) / CGFloat(count)
    }
}

/// A toolbar button that carries an icon as well as a title.
///
/// The system can move a bar item onto a vertical bar, such as the side bar of
/// iPhone Duo, only when the item has both. Systems before iOS 26 keep the
/// familiar text button.
struct ToolbarActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
        } else {
            Button(title, action: action)
        }
    }
}
