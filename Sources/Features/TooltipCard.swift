import SwiftUI

/// The speech-bubble tail, its point aimed at the hovered cell.
private struct TooltipTail: Shape {
    /// Which way the card sits relative to the notch — the tip points back the
    /// other way, at the cell.
    let direction: NotchEdge.TooltipDirection

    func path(in rect: CGRect) -> Path {
        // The tip, and the two corners of the base opposite it.
        let (tip, a, b): (CGPoint, CGPoint, CGPoint)
        switch direction {
        case .leading:   // card on the left, tip to the right
            tip = CGPoint(x: rect.maxX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))
        case .trailing:  // card on the right, tip to the left
            tip = CGPoint(x: rect.minX, y: rect.midY)
            (a, b) = (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY))
        case .down:      // card below, tip upward
            tip = CGPoint(x: rect.midX, y: rect.minY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY))
        case .up:        // card above, tip downward
            tip = CGPoint(x: rect.midX, y: rect.maxY)
            (a, b) = (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY))
        }

        var path = Path()
        path.move(to: a)
        path.addLine(to: tip)
        path.addLine(to: b)
        path.closeSubpath()
        return path
    }

    /// Long in the direction it points, wide across it.
    static func size(for direction: NotchEdge.TooltipDirection) -> CGSize {
        switch direction {
        case .leading, .trailing:
            return CGSize(width: NotchLayout.tailLength, height: NotchLayout.tailHeight)
        case .up, .down:
            return CGSize(width: NotchLayout.tailHeight, height: NotchLayout.tailLength)
        }
    }
}

/// The card chrome every tooltip shares: fixed width, the frame's padding and
/// corner, and the tail welded on so there is no seam between them.
private struct TooltipShell<Content: View>: View {
    /// Given explicitly rather than left to the contents.
    ///
    /// Sized by its contents, the card's height changes the instant they do —
    /// and the tail, centred on that height, jumps with it while the card's
    /// position is still gliding. The two halves then visibly come apart.
    let height: CGFloat
    /// Which side of the notch the card is on, so the tail goes on the other one.
    let direction: NotchEdge.TooltipDirection
    @ViewBuilder let content: Content

    private var card: some View {
        // The same arrangement that makes the notch fold work: the contents
        // are laid out once at their natural size and never move, and it is
        // the *mask* that changes size over them.
        //
        // The obvious alternative — putting the contents inside a frame of
        // the animating height — makes SwiftUI re-align them on every frame
        // of the animation, so the rows drift vertically inside the card and
        // the top ones slide out under the clip. Nothing should move here
        // except the boundary.
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(Palette.card)
                .frame(width: NotchLayout.cardWidth, height: height)

            content
                .padding(NotchLayout.cardPadding)
                .frame(width: NotchLayout.cardWidth, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: height, alignment: .top)
        .clipShape(
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
        )
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        // The tail is deliberately outside the clip: it is part of the card's
        // silhouette, not of its contents.
        return TooltipTail(direction: direction)
            .fill(Palette.card)
            .frame(width: size.width, height: size.height)
    }

    var body: some View {
        // Card first or tail first, laid out along whichever axis the tail
        // points. The pair is one silhouette either way.
        switch direction {
        case .leading:
            HStack(spacing: 0) { card; tail }
        case .trailing:
            HStack(spacing: 0) { tail; card }
        case .down:
            VStack(spacing: 0) { tail; card }
        case .up:
            VStack(spacing: 0) { card; tail }
        }
    }
}

private struct TooltipHeader<Mark: View>: View {
    let title: String
    /// Sits on the header's own line, so saying when a reading was taken costs
    /// the card no extra height.
    var note: String?
    @ViewBuilder let mark: Mark

    var body: some View {
        HStack(spacing: NotchLayout.headerGap) {
            mark
            Text(title)
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.textPrimary)
            if let note {
                Spacer(minLength: Design.px(20))
                Text(note)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

/// A label on the left and a quieter value on the right — the row shape the
/// design frame uses throughout.
private struct SplitRow: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = Palette.textPrimary
    var trailingColor: Color = Palette.textSecondary

    var body: some View {
        HStack(spacing: Design.px(20)) {
            Text(leading).foregroundStyle(leadingColor)
            Spacer(minLength: 0)
            Text(trailing).foregroundStyle(trailingColor)
        }
        .font(Typography.cardBody)
        .lineLimit(1)
    }
}

// MARK: - Providers

/// One metered window: label and reset copy on a line, a track bar, then the
/// percentage burned.
private struct LimitWindowRow: View {
    let window: LimitWindow
    let fidelity: Fidelity
    let now: Date

    private var band: UsageBand { UsageBand.band(for: window.usedFraction ?? 0) }
    private var trackWidth: CGFloat { NotchLayout.cardWidth - 2 * NotchLayout.cardPadding }
    private var fillWidth: CGFloat {
        let fraction = CGFloat(min(max(window.usedFraction ?? 0, 0), 1))
        return max(NotchLayout.barHeight, trackWidth * fraction)
    }

    /// Blank rather than invented: some providers never say when the window rolls.
    private var resetText: String {
        window.resetsAt.map { ResetCopy.text(for: $0, now: now) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SplitRow(leading: window.label, trailing: resetText)

            // No bar without a denominator — an empty track would read as "none
            // used", which is not what "we do not know the limit" means.
            if window.usedFraction != nil {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.barTrack)
                    Capsule().fill(band.color).frame(width: fillWidth)
                }
                .frame(width: trackWidth, height: NotchLayout.barHeight)
                .padding(.top, NotchLayout.labelToBar)
            }

            Text("\(window.usedFraction == nil ? "" : fidelity.qualifier)\(window.summary)")
                .font(Typography.cardBody)
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, NotchLayout.barToUsed)
        }
    }
}

private struct ProviderTooltip: View {
    let snapshot: ProviderSnapshot
    let now: Date

    /// When this reading was taken, said on every card rather than only on a
    /// dimmed one. A number with no age on it is read as live, and between the
    /// refresh interval and a rate-limit penalty it can be several minutes old
    /// while the ring looks perfectly healthy.
    private var readingAge: String? {
        guard snapshot.hasReading else { return nil }
        guard let taken = snapshot.fetchedAt ?? snapshot.status.staleSince,
              taken != .distantPast
        else { return nil }
        return ElapsedCopy.ago(since: taken, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TooltipHeader(title: "\(snapshot.displayName) Usage", note: readingAge) {
                ProviderGlyphView(glyph: snapshot.glyph)
                    .foregroundStyle(Palette.textPrimary)
            }

            // Whose account, when the provider can say. With two rings for the
            // same tool this is what tells them apart, so it sits under the
            // title rather than in the settings sheet alone.
            if let account = snapshot.accountLabel {
                Text(account)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.top, NotchLayout.accountToTitle)
            }

            if let block = snapshot.block {
                BlockedRow(text: block.summary(now: now))
                    .padding(.top, NotchLayout.headerToBlock)
            }

            if let message = snapshot.statusMessage {
                Text(message)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NotchLayout.headerToBlock)
            } else {
                ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
                    LimitWindowRow(window: window, fidelity: snapshot.fidelity, now: now)
                        .padding(.top, index == 0 ? NotchLayout.headerToBlock : NotchLayout.blockSpacing)
                }
            }
        }
    }
}

/// The line that says you are stopped.
///
/// Deliberately loud where the rest of the card is quiet: it is the one thing
/// here that changes what you can do next, and it can be true while the
/// percentage beside it still reads comfortable.
private struct BlockedRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchLayout.statusDotGap) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: NotchLayout.statusDot))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Typography.cardBody)
        .foregroundStyle(Palette.critical)
    }
}

// MARK: - Entry point

struct TooltipCard: View {
    let snapshot: ProviderSnapshot
    let now: Date
    /// Which way the card sits from the notch, which follows from the edge.
    var direction: NotchEdge.TooltipDirection = .leading

    /// The same figure the hover region uses, so what is drawn and what is
    /// reachable can never drift apart.
    private var height: CGFloat {
        NotchLayout.cardHeight(
            windowCount: snapshot.windows.count,
            statusMessage: snapshot.statusMessage,
            blockMessage: snapshot.block?.summary(now: now),
            accountLine: snapshot.accountLabel != nil
        )
    }

    var body: some View {
        TooltipShell(height: height, direction: direction) {
            // Stacked, not replaced in place: during a swap both sets of rows
            // exist for a moment, and in a ZStack they overlap and dissolve
            // instead of shoving each other around. Top-aligned so neither
            // drifts while the card resizes around them.
            ZStack(alignment: .topLeading) {
                ProviderTooltip(snapshot: snapshot, now: now)
                // An identity, so one provider's rows are never interpolated
                // into another's — that is what slid text through positions
                // belonging to neither layout. A crossfade rather than an
                // instant swap, so the change is part of the movement instead
                // of a cut in the middle of it.
                .id(snapshot.id)
                .transition(.opacity.animation(NotchMotion.crossfade))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
