import AppKit
import TokenCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var service: TokenService?
    var controller: NotchWindowController?
    var model: NotchModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let model = NotchModel(geometry: .current(for: screen))
        self.model = model
        controller = NotchWindowController(model: model)

        do {
            let service = TokenService(store: try Store.openDefault())
            var rendered = false
            service.onSnapshot = { [unowned service] snap in
                let ready = service.ready
                DispatchQueue.main.async {
                    withAnimationIfVisible { model.snapshot = snap }
                    if let dir = DebugRender.directory, ready, !rendered {
                        rendered = true
                        DebugRender.run(model: model, into: dir)
                    }
                }
            }
            service.onError = { error in
                NSLog("token-notch: \(error)")
            }
            service.start()
            self.service = service
        } catch {
            NSLog("token-notch: 无法打开 ~/.tokens/tokens.db：\(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        service?.stop()
    }

    func rebuild() { service?.rebuild() }
}

import SwiftUI

@MainActor
func withAnimationIfVisible(_ body: () -> Void) {
    withAnimation(NotchModel.wingsAnimation, body)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
