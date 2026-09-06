import SwiftUI

struct ContentView: View {
  private let backend = ViviBackendRuntime()

  var body: some View {
    VStack(spacing: 12) {
      Text("Vivi")
        .font(.largeTitle)
      Text("Backend ABI \(backend.abiVersion)")
      Text(backend.statusMessage)
        .foregroundStyle(.secondary)
    }
    .padding(32)
    .frame(minWidth: 420, minHeight: 240)
  }
}

#Preview {
  ContentView()
}
