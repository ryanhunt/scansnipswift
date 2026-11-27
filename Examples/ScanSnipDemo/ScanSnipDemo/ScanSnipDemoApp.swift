import ScanSnipProtocol
import SwiftUI

@main
struct ScanSnipDemoApp: App {
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { if model.autoScan { model.scan() } }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: ScanModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Scanner") {
                    TextField("IP address (blank to search)", text: $model.host)
                        .keyboardType(.decimalPad)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                    Picker("Colour", selection: $model.colorMode) {
                        Text("Automatic").tag(VENS.IX100ScanParameters.ColorMode.automatic)
                        Text("Colour").tag(VENS.IX100ScanParameters.ColorMode.color)
                        Text("Grey").tag(VENS.IX100ScanParameters.ColorMode.gray)
                        Text("Black and white").tag(VENS.IX100ScanParameters.ColorMode.blackAndWhite)
                    }
                    if model.busy {
                        Button("Stop", role: .destructive) { model.stop() }
                    } else {
                        Button("Scan") { model.scan() }
                        Button("Search the network") { model.search() }
                    }
                }
                if !model.pages.isEmpty {
                    Section("Pages") {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(model.pages) { page in
                                    VStack {
                                        if let image = page.image {
                                            Image(uiImage: image).resizable().scaledToFit().frame(height: 160)
                                        }
                                        Text("\(page.index + 1): \(page.byteCount / 1024) KB").font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Log") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("ScanSnip Demo")
        }
    }
}
