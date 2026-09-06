import XCTest
import SwiftUI
@testable import Codenotch

/// Renders the tooltip with every limit window a provider reports.
///
/// Partly a smoke test — a card that fails to lay out fails here rather than on
/// someone's screen — and partly a way to actually look at it: set
/// `TOOLTIP_RENDER_PATH` and the frame is written there.
@MainActor
final class TooltipRenderTests: XCTestCase {
    func testTheCardLaysOutEveryLimitWindow() throws {
        let now = Date()
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [
                LimitWindow(id: "session", label: "Current session", usedFraction: 0.47,
                            resetsAt: now.addingTimeInterval(51 * 60)),
                LimitWindow(id: "week", label: "All models", usedFraction: 0.26,
                            resetsAt: now.addingTimeInterval(3 * 24 * 3600)),
                LimitWindow(id: "opus", label: "Scoped", usedFraction: 0.15,
                            resetsAt: now.addingTimeInterval(3 * 24 * 3600))
            ],
            accountLabel: "joseph@carepilot.com · CarePilot",
            fetchedAt: now.addingTimeInterval(-2 * 60)
        )

        let view = TooltipCard(snapshot: snapshot, now: now)
            .padding(20)
            .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)

        // Three window blocks, each a label, a bar and a percentage: a card
        // that silently collapsed would still render, just far too short.
        XCTAssertGreaterThan(image.size.height, NotchLayout.cardWidth * 0.5,
                             "the card laid out far shorter than three windows need")
        XCTAssertGreaterThan(image.size.width, NotchLayout.cardWidth)

        if let path = ProcessInfo.processInfo.environment["TOOLTIP_RENDER_PATH"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Two rings of one glyph are told apart by the address under the title,
    /// so the card has to lay that line out — and, with
    /// `TOOLTIP_ACCOUNT_RENDER_PATH` set, show it.
    func testTheCardLaysOutTheAccountLine() throws {
        let snapshot = ProviderSnapshot(
            id: "codex.gmail", displayName: "Codex Gmail", glyph: .openai,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "primary", label: "Weekly limit", usedFraction: 0.31,
                                  resetsAt: Date().addingTimeInterval(3 * 24 * 3600))],
            kind: .codex, accountLabel: "jctuterajr@gmail.com"
        )
        let plain = ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok, windows: snapshot.windows, kind: .codex
        )

        func render(_ snapshot: ProviderSnapshot) throws -> NSImage {
            let renderer = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: Date())
                .padding(20)
                .background(Color.black))
            renderer.scale = 3
            return try XCTUnwrap(renderer.nsImage)
        }

        let named = try render(snapshot)
        // The line is real height, so the named card is the taller of the two.
        XCTAssertGreaterThan(named.size.height, try render(plain).size.height)

        if let path = ProcessInfo.processInfo.environment["TOOLTIP_ACCOUNT_RENDER_PATH"] {
            let tiff = try XCTUnwrap(named.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The Claude Team card as it actually stood the morning this was reported:
    /// a real session percentage, taken eight hours ago, and no way to take a
    /// newer one. The note is the whole point — without it the card is a dimmed
    /// number with nothing to say for itself, which is what sent the user
    /// looking for a bug. `TOOLTIP_FROZEN_RENDER_PATH` writes the frame out.
    func testTheCardSaysWhyAReadingHasStopped() throws {
        let now = Date()
        let takenAt = now.addingTimeInterval(-8 * 3600)
        let snapshot = ProviderSnapshot(
            id: "claude.team", displayName: "Claude Team", glyph: .claude,
            fidelity: .official, status: .loginExpired(since: takenAt),
            windows: [
                LimitWindow(id: "session", label: "Current session", usedFraction: 0.79,
                            resetsAt: takenAt.addingTimeInterval(3 * 3600)),
                LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.24,
                            resetsAt: now.addingTimeInterval(2 * 24 * 3600))
            ],
            headlineID: "session", kind: .claude,
            accountLabel: "joseph@carepilot.com · CarePilot", fetchedAt: takenAt
        )

        func render(_ snapshot: ProviderSnapshot) throws -> NSImage {
            let renderer = ImageRenderer(content: TooltipCard(snapshot: snapshot, now: now)
                .padding(20)
                .background(Color.black))
            renderer.scale = 3
            return try XCTUnwrap(renderer.nsImage)
        }

        XCTAssertEqual(snapshot.frozenNote, ProviderSnapshot.expiredLoginNote)
        // The rows are still there: the note explains the numbers, it does not
        // replace them.
        XCTAssertNil(snapshot.statusMessage)

        var refreshed = snapshot
        refreshed.status = .ok
        let frozen = try render(snapshot)
        XCTAssertGreaterThan(frozen.size.height, try render(refreshed).size.height,
                             "the note drew no height, so it is not on the card")

        if let path = ProcessInfo.processInfo.environment["TOOLTIP_FROZEN_RENDER_PATH"] {
            let tiff = try XCTUnwrap(frozen.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
