# token-notch

macOS 刘海（灵动岛）面板，一眼看到本机 AI 编码 agent 的 token 用量。

- **收起**：空闲时和刘海融为一体。
- **活动**：有 agent 在跑时两翼浮出——左边是 agent，右边是实时 tok/s 和今日总量；多个 agent 同时在跑时每 4 秒交叉淡入轮播。
- **展开**：鼠标移到刘海上展开面板，移开收回。顶部是标签（概览 / 各 agent / 明细）和时间范围（今日 / 7 天 / 30 天 / 全部）。
  - 概览：所有 agent 合计、按 agent 占比、每日柱图（按 agent 叠加）、按模型分解与合计
  - 单个 agent：今日、范围合计、日均、实时速度、缓存命中 / 输出 / 缓存写入 / 子代理占比、每日柱图、模型构成
  - 明细：缓存命中构成、各 agent 命中率、项目耗费（bar 长度按项目对比，条内按 agent 分色）
- 右键面板：重新统计、打开 `~/.tokens`、退出。

设计稿：Claude Design 画布 A·静（多 agent 版）。

## 数据

自己的库，放在 `~/.tokens/tokens.db`（SQLite）。不依赖、也不读写 cc-switch，只把它的统计口径当参考。

| 来源 | 位置 | 说明 |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | assistant 行的 `message.usage`；同一响应多行，按 `message.id + requestId` 去重 |
| Codex | `~/.codex/sessions/**/*.jsonl`、`~/.codex/archived_sessions` | `token_count` 的累计用量取差值；`input` 含缓存命中，入库前拆成新输入 + 缓存读 |

- **回填历史**：首次启动全量导入安装前的所有日志（本机 2.7GB 约 4 秒）。
- **实时更新**：FSEvents 监听日志目录，每个文件记字节游标只读新增的完整行；文件被改写时按指纹检测并重读，事件按键去重，重读不会重复计数。每分钟兜底扫一遍。
- **口径**：总量 = 新输入 + 缓存读 + 缓存写 + 输出；缓存命中 = 缓存读 ÷（新输入 + 缓存读 + 缓存写）。日期按本地时区。
- **tok/s**：响应的输出 token ÷（响应写入日志时刻 − 上一次用户输入 / 上一次响应时刻）。这是估算：日志里没有真正的生成耗时，Codex 的间隔还包含工具执行时间。实时速度取最近 90 秒。
- **费用**：按模型计价，默认价格取自 cc-switch（MIT）的预置价格表；`~/.tokens/pricing.json` 可覆盖或补充：

  ```json
  {"some-model": {"input": 2, "output": 10, "cacheRead": 0.1, "cacheWrite": 2.5}}
  ```

## 构建与运行

```bash
./scripts/build-app.sh          # 生成 dist/TokenNotch.app 和 dist/tokens
open dist/TokenNotch.app
dist/tokens                     # 命令行：导入并打印各时间范围的统计（对账用）
swift test                      # TokenCore 单元测试
```

调试开关：
- `TOKEN_NOTCH_FORCE=expanded:overview:all`：固定在某个状态 / 页面 / 时间范围。
- `TOKEN_NOTCH_RENDER=<目录>`：拿到第一份快照后把各状态离屏渲染成 PNG 然后退出。

## 目录

```
Sources/TokenCore/      数据层：SQLite 封装、日志解析、增量导入、统计、计价、FSEvents 监听
Sources/TokenNotch/     刘海界面：窗口与热区、刘海形状、两翼、展开面板三页
Sources/TokensCLI/      tokens 命令行
Tests/TokenCoreTests/   解析、增量导入、计价、格式化的测试
scripts/build-app.sh    打包 .app（ad-hoc 签名）
```

## 路线图

1. **代码编辑行数**：把「缓存写入」格子换成编辑行数。每次编辑记 max(新增, 删除) 行，例如 +1−1 记 1 行，+7−5 和 +5−7 都记 7 行。来源是 Claude 的 Edit / Write / MultiEdit 工具调用和 Codex 的 apply_patch。
2. **中英文切换**：默认中文，可切换英文。
3. **更多 agent**：Gemini（Antigravity）、Grok、DeepSeek（DeepSeek Harness）。
4. 全屏应用时自动隐藏；开机自启（`SMAppService`）。

## 许可

MIT（待补 LICENSE 文件）。没有从 boring.notch（GPL-3.0）复制代码。
