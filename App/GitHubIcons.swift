import SwiftUI
import ShepherdrCore

/// GitHub's own colors in its dark theme, so a pull request or issue looks here as it does there.
enum GitHubColor {
    /// Open.
    static let open = Color(hex: 0x3FB950)
    /// Merged, or closed as completed.
    static let done = Color(hex: 0xA371F7)
    /// Closed without merging.
    static let closed = Color(hex: 0xF85149)
    /// Closed as not planned or as a duplicate.
    static let skipped = Color(hex: 0x8B949E)
}

/// The icon of a resource in the Resources panel: GitHub's Octicons for its pull requests and issues,
/// drawn on the same 16-point grid, and a mark for the rest.
struct ResourceIcon: View {
    enum Look: Equatable {
        case pullRequestOpen, pullRequestMerged, pullRequestClosed
        case issueOpen, issueCompleted, issueSkipped
        case artifact, link
    }

    let look: Look

    private var tint: Color {
        switch look {
        case .pullRequestOpen, .issueOpen: GitHubColor.open
        case .pullRequestMerged, .issueCompleted: GitHubColor.done
        case .pullRequestClosed: GitHubColor.closed
        case .issueSkipped: GitHubColor.skipped
        case .artifact: Color(hex: 0xD97757)
        case .link: Theme.dim
        }
    }

    var body: some View {
        Group {
            switch look {
            case .artifact: Text("✻").font(Theme.mono(14, .bold))
            case .link: Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
            default: Canvas { context, size in draw(in: &context, scale: size.width / 16) }
            }
        }
        .foregroundStyle(tint)
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, scale s: CGFloat) {
        let stroke = StrokeStyle(lineWidth: 1.6 * s, lineCap: .round, lineJoin: .round)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        func line(_ points: CGPoint...) -> Path {
            var path = Path()
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        func stroked(_ path: Path) { context.stroke(path, with: .foreground, style: stroke) }
        let node: CGFloat = 1.75

        switch look {
        case .pullRequestOpen, .pullRequestClosed:
            stroked(circle(3.5, 3.25, node)); stroked(circle(3.5, 12.75, node)); stroked(circle(12.5, 12.75, node))
            stroked(line(point(3.5, 3.25 + node), point(3.5, 12.75 - node)))
            if look == .pullRequestOpen {
                var path = Path()
                path.move(to: point(12.5, 12.75 - node))
                path.addLine(to: point(12.5, 6))
                path.addQuadCurve(to: point(10, 3.5), control: point(12.5, 3.5))
                path.addLine(to: point(8.6, 3.5))
                stroked(path)
                // The arrowhead, pointing back to the branch it merges into.
                context.fill(Path { head in
                    head.move(to: point(6.6, 3.5)); head.addLine(to: point(9.6, 0.7)); head.addLine(to: point(9.6, 6.3)); head.closeSubpath()
                }, with: .foreground)
            } else {
                stroked(line(point(12.5, 12.75 - node), point(12.5, 7.2)))
                stroked(line(point(10.6, 2.0), point(14.4, 5.8)))
                stroked(line(point(14.4, 2.0), point(10.6, 5.8)))
            }
        case .pullRequestMerged:
            stroked(circle(3.5, 3.25, node)); stroked(circle(3.5, 12.75, node)); stroked(circle(12.5, 8.25, node))
            stroked(line(point(3.5, 3.25 + node), point(3.5, 12.75 - node)))
            var path = Path()
            path.move(to: point(12.5 - node, 8.25))
            path.addLine(to: point(8.8, 8.25))
            path.addCurve(to: point(3.5, 5.0), control1: point(5.6, 8.25), control2: point(3.5, 7.0))
            stroked(path)
        case .issueOpen, .issueCompleted, .issueSkipped:
            stroked(circle(8, 8, 6.4))
            switch look {
            case .issueOpen: context.fill(circle(8, 8, 1.7), with: .foreground)
            case .issueCompleted: stroked(line(point(5.2, 8.3), point(7.3, 10.4), point(11, 5.9)))
            default: stroked(line(point(4.9, 11.1), point(11.1, 4.9)))
            }
        case .artifact, .link:
            break
        }
    }

    /// How a resource looks given what GitHub says about it: open until it landed or was dropped.
    static func look(of resource: SessionResource, outcome: ChecksMonitor.Outcome?, issue: IssueState?) -> Look {
        switch resource.kind {
        case .pullRequest:
            switch outcome {
            case .landed: return .pullRequestMerged
            case .dropped: return .pullRequestClosed
            case nil: return .pullRequestOpen
            }
        case .issue:
            switch issue {
            case .completed: return .issueCompleted
            case .notPlanned, .duplicate: return .issueSkipped
            case .open, nil: return .issueOpen
            }
        case .artifact: return .artifact
        case .link: return .link
        }
    }
}
