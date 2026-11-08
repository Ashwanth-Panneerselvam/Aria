import SwiftUI
import UIKit

/// Wi-Fi Transfer screen: starts a local web page your computer can open to
/// drag music straight into the library. Runs only while this screen is open
/// (and keeps the screen awake meanwhile).
struct WiFiTransferView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var libraryManager: LocalLibraryManager
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var server = WiFiTransferServer()

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    statusCard
                    if !server.uploads.isEmpty { uploadsCard }
                    howItWorks
                }
                .padding(DS.Spacing.lg)
            }
        }
        .ariaNavigationBar()
        .navigationTitle("Wi-Fi Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { server.configure(library: libraryManager) }
        .onDisappear {
            server.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: server.isActive) { active in
            // Uploads stop if the phone sleeps, so stay awake while serving.
            UIApplication.shared.isIdleTimerDisabled = active
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { server.stop() }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            switch server.state {
            case .stopped:
                Text("Send music from your computer over Wi-Fi — no cable, no Files app.")
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                primaryButton("Start Transfer") { server.start() }
            case .starting:
                HStack(spacing: DS.Spacing.sm) {
                    ProgressView().tint(tokens.textPrimary)
                    Text("Starting…").foregroundColor(tokens.textSecondary)
                }
            case .running(let address, let pin):
                Text("ON YOUR COMPUTER, OPEN")
                    .font(DS.Typography.micro).tracking(1)
                    .foregroundColor(tokens.textSecondary)
                Text(address)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundColor(tokens.textPrimary)
                    .textSelection(.enabled)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("PIN")
                    .font(DS.Typography.micro).tracking(1)
                    .foregroundColor(tokens.textSecondary)
                    .padding(.top, DS.Spacing.xs)
                Text(pin.map(String.init).joined(separator: " "))
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .foregroundColor(tokens.accent)
                    .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")
                HStack(spacing: DS.Spacing.xl) {
                    counter("\(server.importedCount)", "imported")
                    counter("\(server.skippedCount)", "already there")
                }
                .padding(.top, DS.Spacing.xs)
                Text("Keep this screen open until uploads finish. The iPhone stays awake meanwhile.")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                secondaryButton("Stop") { server.stop() }
            case .failed(let message):
                Text(message)
                    .font(DS.Typography.body)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                primaryButton("Try Again") { server.start() }
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(tokens.cardSurface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            .stroke(tokens.hairline, lineWidth: 0.5))
    }

    private func counter(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(DS.Typography.titleMedium.monospacedDigit())
                .foregroundColor(tokens.textPrimary)
            Text(label)
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Uploads

    private var uploadsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("UPLOADS")
                .font(DS.Typography.sectionHeader)
                .foregroundColor(tokens.textSecondary)
                .padding(.bottom, DS.Spacing.sm)
            ForEach(server.uploads) { upload in
                HStack(spacing: DS.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(upload.name)
                            .font(DS.Typography.body)
                            .foregroundColor(tokens.textPrimary)
                            .lineLimit(1)
                        if upload.status == .receiving {
                            ProgressView(value: upload.fraction)
                                .tint(tokens.textPrimary)
                        }
                    }
                    Spacer(minLength: DS.Spacing.sm)
                    statusLabel(upload.status)
                }
                .padding(.vertical, DS.Spacing.sm)
                Divider().background(tokens.hairline)
            }
        }
        .padding(DS.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).fill(tokens.cardSurface))
    }

    @ViewBuilder
    private func statusLabel(_ status: WiFiTransferServer.Upload.Status) -> some View {
        switch status {
        case .receiving:
            EmptyView()
        case .importing:
            Text("Importing…").font(DS.Typography.caption).foregroundColor(tokens.textSecondary)
        case .imported:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                .accessibilityLabel("Imported")
        case .duplicate:
            Text("Already there").font(DS.Typography.caption).foregroundColor(tokens.textSecondary)
        case .failed(let message):
            Text(message).font(DS.Typography.caption).foregroundColor(.orange).lineLimit(2)
        }
    }

    // MARK: - Help

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("HOW IT WORKS")
                .font(DS.Typography.sectionHeader)
                .foregroundColor(tokens.textSecondary)
            step(1, "Connect the iPhone and your computer to the same Wi-Fi.")
            step(2, "Tap Start Transfer. The first time, allow Aria to find devices on your local network.")
            step(3, "Open the address in a browser on your computer and enter the PIN.")
            step(4, "Drag albums or folders onto the page. Files go straight into your library.")
            Text("The page only works on your local network, only while this screen is open, and only with the PIN. Nothing goes to the internet.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Spacing.xs)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Text("\(n)")
                .font(DS.Typography.captionStrong.monospacedDigit())
                .foregroundColor(tokens.background)
                .frame(width: 20, height: 20)
                .background(Circle().fill(tokens.textSecondary))
            Text(text)
                .font(DS.Typography.body)
                .foregroundColor(tokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Buttons

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.bodyEm)
                .foregroundColor(tokens.background)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(tokens.textPrimary))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Typography.bodyEm)
                .foregroundColor(tokens.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Capsule().stroke(tokens.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
