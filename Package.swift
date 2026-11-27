// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenNotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenNotch", targets: ["TokenNotch"]),
        .executable(name: "tokens", targets: ["TokensCLI"]),
    ],
    targets: [
        // 数据层：~/.tokens/tokens.db、增量解析、统计查询、文件监听
        .target(
            name: "TokenCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 刘海界面
        .executableTarget(
            name: "TokenNotch",
            dependencies: ["TokenCore"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        // 命令行：导入 + 打印统计，用于对账和调试
        .executableTarget(name: "TokensCLI", dependencies: ["TokenCore"]),
        .testTarget(name: "TokenCoreTests", dependencies: ["TokenCore"]),
    ],
    swiftLanguageModes: [.v5]
)
