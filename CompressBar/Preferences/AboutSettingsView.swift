import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "rectangle.compress.vertical")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)

            Text("Snug")
                .font(.title2.bold())

            if let version = Bundle.main.releaseVersionNumber,
               let build = Bundle.main.buildVersionNumber {
                Text("Version \(version) (\(build))")
                    .foregroundStyle(.secondary)
            }

            Text("A utility to hide and organize your menu bar icons.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
