import SwiftUI
import DeepSeekCore

public enum CompanionMood: String, Sendable {
    case idle
    case thinking
    case coding
    case waitingApproval
    case happy
}

/// 100% Original Clean-Room Pixel Companion ("Puff / 小潮" — Pixel Sea-Bot Sprite).
/// Drawn procedurally via crisp nearest-neighbor pixel grid; zero third-party copyrighted sprite assets.
public struct PixelCompanionView: View {
    public var mood: CompanionMood
    public var scale: CGFloat
    @State private var frameToggle: Bool = false
    @State private var patted: Bool = false

    public init(mood: CompanionMood, scale: CGFloat = 3.2) {
        self.mood = mood
        self.scale = scale
    }

    private var effectiveMood: CompanionMood {
        patted ? .happy : mood
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { timeline in
            let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
            Canvas { context, size in
                drawSprite(in: &context, size: size, altFrame: tick)
            }
            .frame(width: 24 * scale, height: 20 * scale)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            patted = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                patted = false
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: patted)
    }

    private func drawSprite(in context: inout GraphicsContext, size: CGSize, altFrame: Bool) {
        let p = scale
        let navy = Color(red: 0.11, green: 0.18, blue: 0.48)
        let blue = Color(red: 0.302, green: 0.420, blue: 0.996)
        let sky = Color(red: 0.56, green: 0.70, blue: 1.00)
        let ice = Color(red: 0.93, green: 0.96, blue: 1.00)
        let blush = Color(red: 1.00, green: 0.54, blue: 0.65)
        let mint = Color(red: 0.13, green: 0.77, blue: 0.45)
        let amber = Color(red: 0.98, green: 0.72, blue: 0.18)
        let shadow = Color.black.opacity(0.08)

        func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ color: Color) {
            let rect = CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: CGFloat(w) * p, height: CGFloat(h) * p)
            context.fill(Path(rect), with: .color(color))
        }

        let bob = (effectiveMood == .happy && altFrame) ? -1 : (effectiveMood == .idle && altFrame ? 1 : 0)

        // Soft ground shadow
        px(7, 18, 11, 1, shadow)

        // Cute antenna spark on top of head
        let antennaY = 3 + bob
        px(12, antennaY, 1, 2, navy)
        px(11, antennaY - 1, 3, 1, effectiveMood == .waitingApproval ? amber : sky)

        // Rounded pixel hood/helmet (original capsule-bot silhouette with ear fins)
        let by = 5 + bob
        px(8, by, 9, 1, navy)
        px(7, by + 1, 11, 1, navy)
        px(8, by + 1, 9, 1, blue)

        px(6, by + 2, 13, 8, navy)
        px(7, by + 2, 11, 7, blue)
        px(8, by + 2, 9, 1, sky) // top specular highlight

        // Side ear-fins
        let finShift = altFrame ? 0 : 1
        px(5, by + 4 + finShift, 1, 3, navy)
        px(19, by + 4 + finShift, 1, 3, navy)

        // White face visor
        px(8, by + 4, 9, 5, ice)

        // Little pixel feet
        px(8, by + 10, 3, 1, navy)
        px(14, by + 10, 3, 1, navy)

        // Expressive eyes & mouth inside visor
        switch effectiveMood {
        case .idle:
            if altFrame {
                px(9, by + 5, 2, 2, navy)
                px(14, by + 5, 2, 2, navy)
            } else {
                // Blink frame
                px(9, by + 6, 2, 1, navy)
                px(14, by + 6, 2, 1, navy)
            }
            px(12, by + 7, 1, 1, navy)

        case .thinking:
            px(10, by + 5, 2, 2, navy)
            px(15, by + 5, 2, 2, navy)
            // Floating pixel thought dots
            px(20, by + (altFrame ? 0 : 1), 1, 1, blue)
            px(22, by - 2 + (altFrame ? 0 : 1), 2, 2, sky)

        case .coding:
            px(9, by + 6, 2, 1, navy)
            px(14, by + 6, 2, 1, navy)
            // Mini pixel laptop in front!
            px(1, by + 6, 5, 4, navy)
            px(2, by + 7, 3, 2, altFrame ? sky : mint)
            px(0, by + 10, 7, 1, navy)
            // Floating code brackets
            px(2, by + (altFrame ? 2 : 3), 2, 1, blue)
            px(4, by + (altFrame ? 1 : 2), 2, 1, amber)

        case .waitingApproval:
            px(9, by + 5, 2, 2, navy)
            px(14, by + 5, 2, 2, navy)
            // Raised hand + amber alert badge
            px(20, by + (altFrame ? 2 : 3), 2, 3, blue)
            px(20, by - 2, 3, 3, amber)
            px(21, by - 1, 1, 1, navy)

        case .happy:
            // Happy ^ ^ eyes + pink pixel cheeks + green check badge & confetti!
            px(9, by + 6, 1, 1, navy)
            px(10, by + 5, 1, 1, navy)
            px(11, by + 6, 1, 1, navy)

            px(13, by + 6, 1, 1, navy)
            px(14, by + 5, 1, 1, navy)
            px(15, by + 6, 1, 1, navy)

            px(8, by + 7, 2, 1, blush)
            px(15, by + 7, 2, 1, blush)

            // Green check badge above
            px(10, 0, 5, 3, mint)
            px(11, 1, 1, 1, .white)
            px(12, 2, 1, 1, .white)
            px(13, 0, 1, 2, .white)

            // Confetti pixels
            px(4, altFrame ? 2 : 3, 1, 1, blush)
            px(19, altFrame ? 1 : 2, 1, 1, amber)
            px(21, altFrame ? 4 : 5, 1, 1, sky)
        }
    }
}
