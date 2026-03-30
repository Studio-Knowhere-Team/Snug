import SwiftUI

struct AboutSettingsView: View {
    @State private var updaterController = UpdaterController.shared

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
            }

            Text("Snug")
                .font(.title2.bold())

            if let version = Bundle.main.releaseVersionNumber {
                Text("Version \(version)")
                    .foregroundStyle(.secondary)
            }

            Text("A utility to hide and organize your menu bar icons.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Check for Updates\u{2026}") {
                updaterController.checkForUpdates()
            }
            .disabled(!updaterController.canCheckForUpdates)

            #if DEBUG
            Divider()
                .frame(width: 120)

            Button("Reset Onboarding") {
                AppPreferences.shared.hasCompletedOnboarding = false
                OnboardingWindow.show()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            #endif

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
