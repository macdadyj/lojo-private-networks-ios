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
        Page(icon: "qrcode.viewfinder",
             title: "Pair this phone",
             body: "On the site gateway, show the pairing code. Scan it with the Camera app, or paste it in Settings. Both phones must pair to the same site. You never type a relay address."),
        Page(icon: "lock.shield.fill",
             title: "Two private paths",
             body: "At the site, the phone uses Wi‑Fi. Away, connect the LOJO VPN profile and the phone uses the private overlay. Traffic stays on your network."),
        Page(icon: "iphone.gen3",
             title: "One phone plays.\nThe other controls.",
             body: "Open Remote Controller on the spare phone and leave that screen up. On this phone, play a sound, set a stop time, or save a schedule. The spare phone shows the address it tried if it cannot reach the gateway."),
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
                        .accessibilityIdentifier("onboarding.skip")
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
                            Text("Pair my site")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .foregroundStyle(LojoTheme.accentDeep)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                        }
                        .accessibilityIdentifier("onboarding.pair")
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
                        .accessibilityIdentifier("onboarding.demo")
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
                        .accessibilityIdentifier("onboarding.continue")
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
        ScrollView {
            VStack(spacing: 26) {
                ZStack {
                    Circle().fill(.white.opacity(0.12)).frame(width: 150, height: 150)
                    Circle().fill(.white.opacity(0.10)).frame(width: 110, height: 110)
                    Image(systemName: p.icon)
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
                .padding(.top, 28)
                Text(p.title)
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                Text(p.body)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 32)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}
