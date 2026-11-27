import AppKit
import ServiceManagement

/// 开机自启。macOS 13 起用 `SMAppService.mainApp`：条目出现在
/// 系统设置 › 通用 › 登录项与扩展 里，用户可以随时在那里关掉。
///
/// 两个前提：
/// 1. 必须从 TokenNotch.app 里跑 —— `swift run` 出来的裸二进制没有 bundle id，系统不认；
/// 2. 装好之后不要再换位置（登录项记的是这个路径）。
///
/// ad-hoc 签名的 designated requirement 是 cdhash，所以每次重新编译后系统可能要求重新确认，
/// 那时在右键菜单里关掉再打开一次即可。
@MainActor
enum LaunchAtLogin {
    enum State: Equatable {
        case on                 // 已开启
        case off                // 没注册（或系统里查不到）
        case requiresApproval   // 注册了，但用户在系统设置里关掉了
        case unavailable        // 不是从 .app 启动，无法注册
    }

    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var state: State {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        // notFound：系统里还没有这个 app 的登录项记录（没注册过、或注册后换了路径）。
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    static var isOn: Bool { state == .on }

    /// 开启 / 关闭。成功返回 nil，失败返回给用户看的说明。
    @discardableResult
    static func set(_ on: Bool, _ t: L10n) -> String? {
        guard isBundled else { return t.launchAtLoginUnavailable }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let e = error as NSError
            // 1 = Operation not permitted：多半是 app 不在「应用程序」里，或者签名被换掉了。
            if e.domain == "SMAppServiceErrorDomain", e.code == 1 {
                return t.loginItemRefused + "\n\n" + e.localizedDescription
            }
            return e.localizedDescription
        }
        // register() 不一定能把用户之前关掉的条目打开：这种状态得让用户自己去系统设置里允许。
        if on, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        return nil
    }

    /// 状态的中文 / 英文短名，命令行和菜单提示共用。
    static func describe(_ state: State, _ t: L10n) -> String {
        switch state {
        case .on: return t.launchAtLoginOn
        case .off: return t.launchAtLoginOff
        case .requiresApproval: return t.launchAtLoginNeedsApproval
        case .unavailable: return t.launchAtLoginUnavailable
        }
    }
}

/// `TokenNotch --login-item status|on|off|where`：给 scripts/install.sh 和排障用。
/// 不进入界面，处理完直接退出；没带这个参数时返回 nil，正常启动。
enum LoginItemCommand {
    @MainActor
    static func run() -> Int32? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--login-item") else { return nil }
        let action = args.count > flag + 1 ? args[flag + 1] : "status"
        let t = L10n(lang: Lang.saved)

        switch action {
        case "status":
            print(LaunchAtLogin.describe(LaunchAtLogin.state, t))
            return LaunchAtLogin.state == .on ? 0 : 1
        case "where":
            print("path=\(Bundle.main.bundlePath)")
            print("id=\(Bundle.main.bundleIdentifier ?? "nil")")
            print("state=\(LaunchAtLogin.describe(LaunchAtLogin.state, t))")
            return 0
        case "on", "off":
            let on = action == "on"
            if let error = LaunchAtLogin.set(on, t) {
                FileHandle.standardError.write(Data((error + "\n").utf8))
                return 1
            }
            let state = LaunchAtLogin.state
            print(LaunchAtLogin.describe(state, t))
            return state == (on ? .on : .off) ? 0 : 1
        default:
            FileHandle.standardError.write(Data("usage: TokenNotch --login-item status|on|off|where\n".utf8))
            return 2
        }
    }
}
