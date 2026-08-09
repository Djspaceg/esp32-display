import SwiftUI

/// Lays a labelled row out as one third label, two thirds content.
///
/// `LabeledContent` in a grouped `Form` pushes its content to the trailing edge,
/// which separates a value from the label naming it by however wide the window
/// happens to be - and looks plainly wrong for tall content like the screensaver
/// editor, which ends up pinned to the right with a gulf beside it.
///
/// This restores the proportions the window's original hand-rolled grid used: a
/// right-aligned label column one third of the way across, content starting
/// immediately after it. Proportional rather than a fixed width, so the split
/// holds as the window resizes, and every row lands on the same boundary because
/// every row is measured against the same available width.
struct LabelColumnLayout: Layout {
    /// How the two halves line up vertically.
    enum RowAlignment {
        /// A one-line label level with the first line of what it names. Right
        /// for text against text.
        case firstTextBaseline
        /// Right when one side has no text baseline to speak of - an image, for
        /// instance, whose baseline is simply its bottom edge.
        case center
        case top
    }

    /// Share of the row given to the label.
    var labelFraction: CGFloat = 1.0 / 3.0
    var spacing: CGFloat = 12
    var alignment: RowAlignment = .firstTextBaseline

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        let total = proposal.replacingUnspecifiedDimensions().width
        let (labelWidth, contentWidth) = widths(for: total)
        let label = subviews[0].dimensions(in: .init(width: labelWidth, height: nil))
        let content = subviews[1].dimensions(in: .init(width: contentWidth, height: nil))

        switch alignment {
        case .firstTextBaseline:
            // Height has to cover both halves once they are pulled onto a
            // shared baseline, which is why it is not simply the taller of the
            // two.
            let baseline = max(label[.firstTextBaseline], content[.firstTextBaseline])
            let below = max(
                label.height - label[.firstTextBaseline],
                content.height - content[.firstTextBaseline])
            return CGSize(width: total, height: baseline + below)
        case .center, .top:
            return CGSize(width: total, height: max(label.height, content.height))
        }
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: proposal)
            return
        }
        let (labelWidth, contentWidth) = widths(for: bounds.width)
        let labelProposal = ProposedViewSize(width: labelWidth, height: nil)
        let contentProposal = ProposedViewSize(width: contentWidth, height: nil)
        let label = subviews[0].dimensions(in: labelProposal)
        let content = subviews[1].dimensions(in: contentProposal)

        let labelY: CGFloat
        let contentY: CGFloat
        switch alignment {
        case .firstTextBaseline:
            let baseline = max(label[.firstTextBaseline], content[.firstTextBaseline])
            labelY = baseline - label[.firstTextBaseline]
            contentY = baseline - content[.firstTextBaseline]
        case .center:
            labelY = (bounds.height - label.height) / 2
            contentY = (bounds.height - content.height) / 2
        case .top:
            labelY = 0
            contentY = 0
        }

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + labelY),
            proposal: labelProposal)
        subviews[1].place(
            at: CGPoint(
                x: bounds.minX + labelWidth + spacing, y: bounds.minY + contentY),
            proposal: contentProposal)
    }

    /// The label and content widths for a given row width. Split out so the
    /// measuring and placing passes cannot disagree.
    func widths(for total: CGFloat) -> (label: CGFloat, content: CGFloat) {
        let usable = max(0, total - spacing)
        let label = usable * labelFraction
        return (label, usable - label)
    }
}

/// `LabeledContent` laid out in the window's label column: right-aligned label,
/// left-aligned content.
struct LabelColumnStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabelColumnLayout() {
            configuration.label
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension LabeledContentStyle where Self == LabelColumnStyle {
    /// The app's standard row layout: a third for the label, the rest for the
    /// value, both meeting in the middle where they are easy to read together.
    static var labelColumn: LabelColumnStyle { LabelColumnStyle() }
}
