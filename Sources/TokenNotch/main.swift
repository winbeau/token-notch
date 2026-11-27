import AppKit
import ServiceManagement
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
            // TOKEN_NOTCH_DEMO=1：临时库 + 演示数据，不读任何真实日志（截图、演示视频用）
            let demo = ProcessInfo.processInfo.environment["TOKEN_NOTCH_DEMO"] != nil
            let service: TokenService
            if demo {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("token-notch-demo.db").path
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
                let store = try Store(path: path)
                try DemoData.populate(store)
                service = TokenService(store: store, sources: [])
            } else {
                service = TokenService(store: try Store.openDefault())
            }
            var rendered = false
            service.onSnapshot = { [unowned service] snap in
                let ready = service.ready
                DispatchQueue.main.async {
                    withAnimationIfVisible { model.snapshot = snap }
                    if let dir = DebugRender.directory, ready, !rendered {
                        rendered = true
                        DebugRender.run(model: model, into: dir)
                    } else if let dir = DemoVideo.directory, ready, !rendered {
                        rendered = true
                        DemoVideo.run(model: model, into: dir)
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

    /// 右键菜单里的「开机自启」：改失败或需要用户确认时弹一个说明。
    func setLaunchAtLogin(_ on: Bool) {
        let t = model?.t ?? L10n(lang: .saved)
        switch LaunchAtLogin.state {
        case .unavailable:
            alert(t.loginItemUnavailableTitle, t.loginItemUnavailableMessage)
            return
        case .requiresApproval where on:
            SMAppService.openSystemSettingsLoginItems()
            alert(t.loginItemNeedsApprovalTitle, t.loginItemNeedsApprovalMessage)
            return
        default:
            break
        }
        if let error = LaunchAtLogin.set(on, t) {
            alert(t.loginItemFailedTitle, error)
            return
        }
        if on, LaunchAtLogin.state == .requiresApproval {
            alert(t.loginItemNeedsApprovalTitle, t.loginItemNeedsApprovalMessage)
        }
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: (model?.t ?? L10n(lang: .saved)).alertOK)
        alert.runModal()
    }
}

import SwiftUI

@MainActor
func withAnimationIfVisible(_ body: () -> Void) {
    withAnimation(NotchModel.wingsAnimation, body)
}

MainActor.assumeIsolated {
    // 只处理登录项开关，不进界面：`TokenNotch --login-item status|on|off`
    if let code = LoginItemCommand.run() { exit(code) }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
