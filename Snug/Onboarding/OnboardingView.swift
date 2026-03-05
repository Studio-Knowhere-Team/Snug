import SwiftUI

struct OnboardingView: View {
    @State private var step = 0
    @State private var accessibilityGranted = AccessibilityMenuBarHelper.isGranted
    @State private var pollTimer: Timer?

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            Group {
                switch step {
                case 0: welcomeStep
                case 1: howItWorksStep
                case 2: accessibilityStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step)

            // Step indicator dots
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 360)
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
            }

            Text("Welcome to Snug")
                .font(.largeTitle.bold())

            Text("A tiny utility that keeps your menu bar tidy.")
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Get Started") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    step = 1
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
                .frame(height: 24)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Step 2: How It Works

    private var howItWorksStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("How It Works")
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("Hold \u{2318} (Cmd) and drag menu bar icons to the left of the open circle to hide them.")
                } icon: {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                }

                Label {
                    Text("Click the icon to toggle and the circle splits open or closes shut.")
                } icon: {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                }

                Label {
                    Text("When closed, the filled circle shows how many icons are hidden.")
                } icon: {
                    Image(systemName: "number")
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                }

                Label {
                    Text("Right-click the icon to see hidden items and open their menus.")
                } icon: {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundStyle(.blue)
                        .frame(width: 20)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)

            Spacer()

            Button("Continue") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    step = 2
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
                .frame(height: 24)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Step 3: Accessibility

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Spacer()

            if accessibilityGranted {
                Image(systemName: "checkmark.shield.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: "lock.shield")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.secondary)
            }

            Text("Accessibility Access")
                .font(.title.bold())

            if accessibilityGranted {
                Text("All set! Snug can now show the names of your hidden icons.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Snug uses Accessibility to read the names of your hidden menu bar icons and let you interact with them from the dropdown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            if accessibilityGranted {
                Button("Done") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Grant Access") {
                    AccessibilityMenuBarHelper.promptForAccess()
                    startPolling()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Skip for now") {
                    finishOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
            }

            Spacer()
                .frame(height: 24)
        }
        .padding(.horizontal, 40)
        .onAppear {
            // Check once on appear in case it was already granted
            accessibilityGranted = AccessibilityMenuBarHelper.isGranted
            if !accessibilityGranted {
                startPolling()
            }
        }
    }

    // MARK: - Helpers

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let granted = AccessibilityMenuBarHelper.isGranted
                if granted != accessibilityGranted {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        accessibilityGranted = granted
                    }
                }
            }
        }
    }

    private func finishOnboarding() {
        pollTimer?.invalidate()
        pollTimer = nil
        AppPreferences.shared.hasCompletedOnboarding = true
        onComplete()
    }
}
