import SwiftUI

/// Modal progress bar with the Title for a running Import. Stays hidden for
/// the first half second, so quick Imports don't flash it. It dims and blocks
/// the UI beneath it, and has no Cancel.
struct ImportProgressModal: View {
    let running: RunningImport
    @State private var isShown = false

    var body: some View {
        ZStack {
            if isShown {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(running.title).font(.headline).lineLimit(2)
                    ProgressView(value: running.fraction)
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(.regularMaterial, in: .rect(cornerRadius: 14))
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            isShown = true
        }
    }
}
