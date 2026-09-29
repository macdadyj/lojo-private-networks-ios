import SwiftUI

struct OnboardingView: View {
    let onFinish: (_ demo: Bool) -> Void
    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(icon: "point.3.connected.trianglepath.dotted",
             title: "Your devices.\nYour network.",
             body: "Connect the gear you already own — ranch Pis, gate cameras, pump relays, lab machines — into one private network you control."),
        Page(icon: "lock.shield.fill",
             title: "Private by design",
             body: "Your phone reaches them over an encrypted private overlay. Nothing is exposed to the public internet — no open ports, no public camera links."),
        Page(icon: "hand.tap.fill",
             title: "In your hands, anywhere",
             body: "See what's online, pull a fresh camera still, and switch relays with a confirmation step — on site Wi‑Fi or from the road."),
    ]

    var body: some View {
        ZStack {
            LojoTheme.brandGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("LOJO")
                        .font(.headline.weight(.heavy))
                        .tracking(3)
                    Text("Private Networks")
                        .font(.headline.weight(.regular))
                        .opacity(0.85)
                    Spacer()
                    if page < pages.count - 1 {
                        Button("Skip") {
                            withAnimation { page = pages.count - 1 }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.top, 12)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, p in
                        pageView(p).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                .onChange(of: page) { Haptics.selection() }

                VStack(spacing: 12) {
                    if page == pages.count - 1 {
                        Label("iOS will ask to let LOJO Networks find devices on your local network. Choose Allow so the app can reach your site gateway on Wi‑Fi.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                        Button {
                            Haptics.success()
                            onFinish(false)
                        } label: {
                            Text("Connect my network")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .foregroundStyle(LojoTheme.accentDeep)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                        }
                        Button {
                            Haptics.light()
                            onFinish(true)
                        } label: {
                            Text("Explore the demo network")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(.white)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1.5))
                        }
                    } else {
                        Button {
                            withAnimation { page += 1 }
                        } label: {
                            Text("Continue")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .foregroundStyle(LojoTheme.accentDeep)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.2), value: page)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func pageView(_ p: Page) -> some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                Circle().fill(.white.opacity(0.12)).frame(width: 150, height: 150)
                Circle().fill(.white.opacity(0.10)).frame(width: 110, height: 110)
                Image(systemName: p.icon)
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            Text(p.title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Text(p.body)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 32)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
