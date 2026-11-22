# token-notch

macOS 刘海（灵动岛）面板，一眼看到本机 AI 编码 agent 的 token 用量。

鼠标移到刘海区域，面板从顶部滑下来；移开就收回。不占菜单栏，不弹通知，不打断干活。

## 目标（MVP）

- **热区触发**：鼠标进入屏幕顶部中央（刘海及其两侧）滑下面板，移出收回；可调触发宽度与延迟
- **核心数字**：今日 token、7 天 token、缓存命中率、输出速度、按 provider / 模型的分解
- **趋势**：近 7 天柱状图，鼠标悬停看当天明细
- **多 agent**：Claude Code、Codex、（后续）DeepSeek Harness
- **零常驻开销**：空闲时不轮询磁盘，靠 FSEvents 变更通知 + 低频兜底

## 数据源

优先级从高到低，实现上互相独立，缺哪个就退到下一个：

| 来源 | 位置 | 覆盖 |
|---|---|---|
| cc-switch 用量库 | `~/.cc-switch/cc-switch.db`（SQLite，usage records） | Claude Code / Codex / Gemini / OpenCode 等，已算好费用 |
| 本地 session 日志 | `~/.claude/projects/**/*.jsonl`、`~/.codex/sessions/**/*.jsonl` | 原始 token 数，自己算成本 |
| tokstat 接口 | `http://127.0.0.1:47800/api/summary` | 现成的本机汇总，含子代理拆分 |

只读，绝不写入这些来源的库。

## 技术栈

- Swift 6 / AppKit：无边框 `NSPanel`（`.nonactivatingPanel`）+ SwiftUI 内容视图
- 定位在刘海下方，跟随屏幕 / 分辨率 / 多显示器变化
- 热区用 `NSEvent.addGlobalMonitorForEvents` 监听鼠标移动，配合面板自身的 hover
- 构建：`swiftc` 单文件即可出 app，不依赖 Xcode 工程

## 目录（规划）

```
Package.swift
Sources/TokenNotch/
  TokenNotchApp.swift     # 入口、NSApplication 生命周期
  NotchPanel.swift        # NSPanel 定位、滑入滑出动画
  HotZone.swift           # 全局鼠标监听与触发判定
  Metrics.swift           # 数据模型（Metrics / DayBucket / ModelBreakdown）
  Backends/
    CCSwitchBackend.swift # 读 cc-switch.db
    LogBackend.swift      # 直接解析 jsonl
    TokstatBackend.swift  # 读 47800 接口
scripts/build-app.sh      # 编译 + 打包 .app + 生成图标
```

## 状态

仓库刚建，骨架待写。

## 许可

待定。若从 boring.notch（GPL-3.0）抄代码，本项目必须同样 GPL-3.0；本仓库当前走干净实现，保持 MIT 的可能性。
