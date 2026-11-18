import SwiftUI
import DeepSeekCore

public enum CompanionMood: String, Sendable {
    case idle
    case thinking
    case coding
    case waitingApproval
    case happy
}

/// Pixel-art DeepSeek Whale: sleek S-curve royal-blue leaping whale with sapphire-contoured white belly,
/// V-forked tail fluke, and floating twin blowhole water droplets.
public struct PixelCompanionView: View {
    public var mood: CompanionMood
    public var scale: CGFloat
    @State private var patted: Bool = false

    public init(mood: CompanionMood, scale: CGFloat = 3.0) {
        self.mood = mood
        self.scale = scale
    }

    private var effectiveMood: CompanionMood {
        patted ? .happy : mood
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let alt = Int(timeline.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
            Canvas { context, _ in
                drawWhale(in: &context, alt: alt)
            }
            .frame(width: 25 * scale, height: 18 * scale)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            patted = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                patted = false
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: patted)
    }

    private func drawWhale(in context: inout GraphicsContext, alt: Bool) {
        let p = scale
        let royal = Color(red: 0.302, green: 0.420, blue: 0.996)  // #4D6BFE
        let deep = Color(red: 0.175, green: 0.275, blue: 0.855)   // #2D46DA
        let light = Color(red: 0.510, green: 0.625, blue: 1.000)  // #829FFF
        let ice = Color(red: 0.855, green: 0.906, blue: 1.000)    // #DAE7FF
        let navy = Color(red: 0.075, green: 0.125, blue: 0.365)   // #13205D
        let blush = Color(red: 1.000, green: 0.560, blue: 0.660)
        let amber = Color(red: 0.960, green: 0.650, blue: 0.140)
        let mint = Color(red: 0.120, green: 0.760, blue: 0.460)

        func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ c: Color) {
            let rect = CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: CGFloat(w) * p, height: CGFloat(h) * p)
            context.fill(Path(rect), with: .color(c))
        }

        let bob = (effectiveMood == .happy && alt) ? -1 : 0
        let tailLift = alt ? 0 : 1
        let spoutShift = (effectiveMood == .thinking && alt) ? -1 : 0

        // 1. Floating twin blowhole water droplets (clean air gap above head)
        px(7, 1 + spoutShift + bob, 2, 2, royal)
        px(10, 2 + spoutShift + bob, 2, 1, light)

        // 2. V-forked upward whale tail fluke
        px(17, 1 + tailLift + bob, 2, 1, royal)
        px(18, 2 + tailLift + bob, 2, 2, royal)
        px(22, 2 + tailLift + bob, 2, 1, royal)
        px(21, 3 + tailLift + bob, 2, 2, royal)
        px(19, 4 + bob, 3, 2, royal)

        // 3. Arched S-curve whale body & forehead
        px(18, 5 + bob, 3, 2, royal)
        px(6, 5 + bob, 6, 1, royal)
        px(4, 6 + bob, 10, 1, royal)
        px(14, 6 + bob, 2, 1, deep)
        px(17, 6 + bob, 3, 2, royal)

        px(3, 7 + bob, 16, 1, royal)
        px(5, 7 + bob, 6, 1, light)

        px(2, 8 + bob, 17, 1, royal)
        px(2, 9 + bob, 16, 1, royal)
        px(2, 10 + bob, 15, 1, royal)

        // Snout + smile curve + taper
        px(3, 11 + bob, 3, 1, royal)
        px(6, 11 + bob, 5, 1, deep)
        px(11, 11 + bob, 5, 1, royal)

        // Crisp sapphire-contoured white belly with baleen grooves
        px(3, 12 + bob, 1, 1, deep)
        px(4, 12 + bob, 8, 1, .white)
        px(6, 12 + bob, 1, 1, ice)
        px(9, 12 + bob, 1, 1, ice)
        px(12, 12 + bob, 3, 1, royal)

        px(4, 13 + bob, 1, 1, deep)
        px(5, 13 + bob, 6, 1, .white)
        px(7, 13 + bob, 1, 1, ice)
        px(5, 14 + bob, 6, 1, deep)

        // Pectoral flipper
        let finDrop = (effectiveMood == .coding && alt) ? 1 : 0
        px(11, 13 + bob, 3, 1, deep)
        px(12, 14 + bob + finDrop, 3, 1, deep)
        px(13, 15 + bob + finDrop, 2, 1, navy)

        // 4. Eye & mood expression
        switch effectiveMood {
        case .idle:
            if alt {
                px(6, 9 + bob, 2, 2, navy)
                px(6, 9 + bob, 1, 1, .white)
            } else {
                px(6, 10 + bob, 2, 1, navy)
            }
        case .thinking:
            px(6, 8 + bob, 2, 2, navy)
            px(6, 8 + bob, 1, 1, .white)
        case .coding:
            px(6, 9 + bob, 2, 2, navy)
            px(0, 9 + (alt ? 0 : 1), 1, 1, royal)
            px(1, 8 + (alt ? 0 : 1), 1, 1, light)
            px(1, 10 + (alt ? 0 : 1), 1, 1, light)
        case .waitingApproval:
            px(6, 9 + bob, 2, 2, navy)
            px(7, 0, 2, 1, amber)
        case .happy:
            px(5, 9 + bob, 1, 1, navy)
            px(6, 8 + bob, 1, 1, navy)
            px(7, 9 + bob, 1, 1, navy)
            px(8, 10 + bob, 2, 1, blush)
            px(13, 1, 2, 2, mint)
        }
    }
}
