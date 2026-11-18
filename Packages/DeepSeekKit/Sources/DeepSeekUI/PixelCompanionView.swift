import SwiftUI
import DeepSeekCore

public enum CompanionMood: String, Sendable {
    case idle
    case thinking
    case coding
    case waitingApproval
    case happy

    public var bubbleText: String? {
        switch self {
        case .idle: return nil
        case .thinking, .coding: return "敲代码中…"
        case .waitingApproval: return "等你确认"
        case .happy: return "完成啦"
        }
    }
}

public enum CompanionCharacter: String, Codable, CaseIterable, Sendable {
    case whaleGirl = "whale_girl"
    case whale = "whale"
    case hidden = "hidden"

    public var label: String {
        switch self {
        case .whaleGirl: return "像素鲸鱼娘"
        case .whale: return "像素小蓝鲸"
        case .hidden: return "不显示"
        }
    }
}

/// Crisp procedural pixel companion perched on top of the chat input box.
/// Supports both the Pixel Whale-Girl ("鲸鱼娘": coding on keyboard with `</>` / happy `✓` / waiting `!` / sleeping `zZ`)
/// and the Pixel Blue Whale ("小蓝鲸").
public struct PixelCompanionView: View {
    public var mood: CompanionMood
    public var character: CompanionCharacter
    public var scale: CGFloat
    public var showStatusBubble: Bool
    @State private var patted: Bool = false

    public init(
        mood: CompanionMood,
        character: CompanionCharacter = .whaleGirl,
        scale: CGFloat = 2.6,
        showStatusBubble: Bool = false
    ) {
        self.mood = mood
        self.character = character
        self.scale = scale
        self.showStatusBubble = showStatusBubble
    }

    private var effectiveMood: CompanionMood {
        patted ? .happy : mood
    }

    public var body: some View {
        if character == .hidden {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                if showStatusBubble, let text = effectiveMood.bubbleText {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DeepSeekTheme.brandBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DeepSeekTheme.brandBlue.opacity(0.12))
                        )
                }

                TimelineView(.periodic(from: .now, by: 0.45)) { timeline in
                    let alt = Int(timeline.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
                    Canvas { context, _ in
                        switch character {
                        case .whaleGirl:
                            drawWhaleGirl(in: &context, alt: alt)
                        case .whale:
                            drawWhale(in: &context, alt: alt)
                        case .hidden:
                            break
                        }
                    }
                    .frame(
                        width: (character == .whaleGirl ? 28 : 25) * scale,
                        height: (character == .whaleGirl ? 24 : 18) * scale
                    )
                }
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
    }

    // MARK: - 28x24 Original Pixel Anime Whale-Girl ("鲸鱼娘")

    private func drawWhaleGirl(in context: inout GraphicsContext, alt: Bool) {
        let p = scale
        let darkOutline = Color(red: 0.08, green: 0.12, blue: 0.28)
        let hairDeep = Color(red: 0.16, green: 0.27, blue: 0.65)
        let hairBlue = Color(red: 0.27, green: 0.43, blue: 0.92)
        let hairLight = Color(red: 0.48, green: 0.64, blue: 1.00)
        let skin = Color(red: 1.00, green: 0.91, blue: 0.86)
        let blush = Color(red: 1.00, green: 0.58, blue: 0.66)
        let white = Color.white
        let ribbonGold = Color(red: 0.98, green: 0.78, blue: 0.28)
        let mint = Color(red: 0.16, green: 0.78, blue: 0.47)
        let amber = Color(red: 0.98, green: 0.76, blue: 0.22)
        let cyan = Color(red: 0.25, green: 0.78, blue: 0.98)

        func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ c: Color) {
            let rect = CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: CGFloat(w) * p, height: CGFloat(h) * p)
            context.fill(Path(rect), with: .color(c))
        }

        let bob = ((effectiveMood == .happy || effectiveMood == .coding) && alt) ? -1 : 0

        // 1. Cute curved ahoge (top hair strand)
        px(11, 2 + bob, 2, 1, hairBlue)
        px(10, 3 + bob, 1, 2, hairBlue)

        // 2. White ruffled maid/sailor headband
        px(8, 5 + bob, 9, 1, white)
        px(7, 6 + bob, 11, 1, white)
        px(16, 6 + bob, 2, 2, darkOutline) // little hair bow with gold star
        px(17, 7 + bob, 1, 1, ribbonGold)

        // 3. Blue anime hair crown & bangs + cute side whale-fin ears
        px(7, 7 + bob, 10, 2, hairBlue)
        px(8, 7 + bob, 7, 1, hairLight)
        px(6, 8 + bob, 12, 3, hairBlue)
        px(7, 9 + bob, 2, 2, hairDeep)
        px(11, 9 + bob, 2, 2, hairLight)
        px(15, 9 + bob, 2, 2, hairDeep)

        // Whale-fin ear tufts on sides
        px(4, 11 + bob, 2, 2, hairDeep)
        px(5, 12 + bob, 1, 1, white)
        px(18, 11 + bob, 2, 2, hairDeep)
        px(18, 12 + bob, 1, 1, white)

        // Flowing long blue hair locks on left & right
        px(5, 11 + bob, 2, 9, hairDeep)
        px(6, 12 + bob, 1, 7, hairBlue)
        px(17, 11 + bob, 2, 9, hairDeep)
        px(17, 12 + bob, 1, 7, hairBlue)

        // 4. Face & rosy cheeks
        px(7, 11 + bob, 10, 6, skin)
        px(8, 17 + bob, 8, 1, skin)
        px(7, 14 + bob, 2, 1, blush)
        px(15, 14 + bob, 2, 1, blush)

        // 5. Little swaying whale tail behind her on the right!
        let tailY = 17 + (alt ? 0 : 1)
        px(19, tailY + 2, 3, 2, hairDeep)
        px(21, tailY, 2, 2, hairBlue)
        px(22, tailY - 1, 2, 1, hairDeep)
        px(23, tailY + 1, 2, 1, hairDeep)

        // 6. Outfit (Navy & white ruffled collar + sleeves)
        px(8, 18 + bob, 8, 5, darkOutline)
        px(10, 18 + bob, 4, 4, white)
        px(11, 19 + bob, 2, 2, hairBlue) // chest ribbon

        // 7. Mood-specific eyes, hands, keyboard & floating status badges!
        switch effectiveMood {
        case .thinking, .coding:
            // Focused half-lidded coding eyes
            px(8, 12 + bob, 2, 1, darkOutline)
            px(8, 13 + bob, 2, 1, hairBlue)
            px(14, 12 + bob, 2, 1, darkOutline)
            px(14, 13 + bob, 2, 1, hairBlue)

            // Typing hands + mini white & navy pixel mechanical keyboard in front!
            px(7, 19 + (alt ? 0 : 1), 2, 2, skin)
            px(13, 19 + (alt ? 1 : 0), 2, 2, skin)
            px(4, 21, 14, 3, darkOutline)
            px(5, 21, 12, 2, white)
            px(6, 22, 2, 1, hairLight)
            px(10, 22, 2, 1, hairLight)

            // Floating `</>` and `{;}` pixel code glyphs top-right
            let codeY = alt ? 1 : 2
            px(19, codeY, 1, 2, cyan)
            px(21, codeY, 1, 2, amber)
            px(23, codeY, 1, 2, cyan)

        case .happy:
            // Happy `^ ^` curved anime eyes + open happy mouth
            px(8, 12 + bob, 2, 1, darkOutline)
            px(7, 13 + bob, 1, 1, darkOutline)
            px(10, 13 + bob, 1, 1, darkOutline)

            px(14, 12 + bob, 2, 1, darkOutline)
            px(13, 13 + bob, 1, 1, darkOutline)
            px(16, 13 + bob, 1, 1, darkOutline)
            px(11, 15 + bob, 2, 1, blush)

            // Clasped happy hands in front
            px(10, 19 + bob, 4, 3, skin)

            // Floating green checkmark badge `[✓]` top-right
            px(20, 2, 5, 4, mint)
            px(21, 4, 1, 1, white)
            px(22, 5, 1, 1, white)
            px(23, 3, 1, 2, white)

        case .waitingApproval:
            // Big attentive anime eyes + cute 'o' mouth
            px(8, 12 + bob, 2, 3, darkOutline)
            px(8, 12 + bob, 1, 1, white)
            px(14, 12 + bob, 2, 3, darkOutline)
            px(14, 12 + bob, 1, 1, white)
            px(11, 15 + bob, 2, 1, darkOutline)

            // Raised right hand waving for confirmation!
            px(4, 14 + (alt ? 0 : 1), 2, 4, skin)
            px(4, 18 + (alt ? 0 : 1), 2, 2, white)

            // Floating yellow `[!]` alert speech bubble top-right
            px(20, 1, 5, 5, amber)
            px(22, 2, 1, 2, darkOutline)
            px(22, 5, 1, 1, darkOutline)

        case .idle:
            // Peaceful sleeping / resting closed eyes + cute cyan sleep bubble & `zZ`
            px(8, 13 + bob, 2, 1, darkOutline)
            px(14, 13 + bob, 2, 1, darkOutline)
            if alt {
                px(13, 14 + bob, 2, 2, cyan.opacity(0.75))
            }
            px(10, 20 + bob, 4, 2, skin)
            // Floating `zZ`
            px(20, alt ? 4 : 5, 2, 1, hairLight)
            px(22, alt ? 2 : 3, 3, 1, hairBlue)
        }
    }

    // MARK: - 25x18 Pixel Blue Whale ("小蓝鲸")

    private func drawWhale(in context: inout GraphicsContext, alt: Bool) {
        let p = scale
        let royal = Color(red: 0.302, green: 0.420, blue: 0.996)
        let deep = Color(red: 0.175, green: 0.275, blue: 0.855)
        let light = Color(red: 0.510, green: 0.625, blue: 1.000)
        let ice = Color(red: 0.855, green: 0.906, blue: 1.000)
        let navy = Color(red: 0.075, green: 0.125, blue: 0.365)
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

        px(7, 1 + spoutShift + bob, 2, 2, royal)
        px(10, 2 + spoutShift + bob, 2, 1, light)

        px(17, 1 + tailLift + bob, 2, 1, royal)
        px(18, 2 + tailLift + bob, 2, 2, royal)
        px(22, 2 + tailLift + bob, 2, 1, royal)
        px(21, 3 + tailLift + bob, 2, 2, royal)
        px(19, 4 + bob, 3, 2, royal)

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

        px(3, 11 + bob, 3, 1, royal)
        px(6, 11 + bob, 5, 1, deep)
        px(11, 11 + bob, 5, 1, royal)

        px(3, 12 + bob, 1, 1, deep)
        px(4, 12 + bob, 8, 1, .white)
        px(6, 12 + bob, 1, 1, ice)
        px(9, 12 + bob, 1, 1, ice)
        px(12, 12 + bob, 3, 1, royal)

        px(4, 13 + bob, 1, 1, deep)
        px(5, 13 + bob, 6, 1, .white)
        px(7, 13 + bob, 1, 1, ice)
        px(5, 14 + bob, 6, 1, deep)

        let finDrop = (effectiveMood == .coding && alt) ? 1 : 0
        px(11, 13 + bob, 3, 1, deep)
        px(12, 14 + bob + finDrop, 3, 1, deep)
        px(13, 15 + bob + finDrop, 2, 1, navy)

        switch effectiveMood {
        case .idle:
            if alt {
                px(6, 9 + bob, 2, 2, navy)
                px(6, 9 + bob, 1, 1, .white)
            } else {
                px(6, 10 + bob, 2, 1, navy)
            }
        case .thinking, .coding:
            px(6, 9 + bob, 2, 2, navy)
            px(0, 9 + (alt ? 0 : 1), 1, 1, royal)
        case .waitingApproval:
            px(6, 9 + bob, 2, 2, navy)
            px(7, 0, 2, 2, amber)
        case .happy:
            px(5, 9 + bob, 1, 1, navy)
            px(6, 8 + bob, 1, 1, navy)
            px(7, 9 + bob, 1, 1, navy)
            px(8, 10 + bob, 2, 1, blush)
            px(13, 1, 2, 2, mint)
        }
    }
}
