# V1 方案研究与取舍

核验日期：2026-10-01。先检查现成方案，再决定最小原生实现。这里记录来源与采用／不采用理由；不是依赖清单，也不把搜索索引时间当作已验证的最新发布版本。

## 开源成品能否直接使用或 fork

| 项目 | 已核实的符合点 | 不采用的原因 |
|---|---|---|
| [wilqq-the/BTC-Tracker](https://github.com/wilqq-the/BTC-Tracker) | Bitcoin-only；手工买卖与转账、费用、冷热存储分布；MIT | Next.js、React、Prisma、SQLite、Docker；带账号和多用户管理，桌面版本为 Windows Electron beta。切换成 SwiftUI 会重写主要部分，并非低维护成本的复用。 |
| [satsfort/satsfort](https://github.com/satsfort/satsfort) | Bitcoin-only、本地优先、只读；不保管私钥；提供 macOS 构建描述 | Tauri、React、Rust，以 xpub/address 的链上跟踪为中心；不是手工人民币账本。[Release 页面](https://github.com/satsfort/satsfort/releases) 核验时没有正式发布。 |
| [simonsruggi/StockDock](https://github.com/simonsruggi/StockDock) | SwiftUI、macOS 14+、本地数据、无账号、JSON 导入导出；MIT | 面向股票与多资产持仓数量／平均价，不是账户间转账与费用事件账本；含新闻、图表、通知、Sparkle、protobuf。删改和新增核心账务的工作比专用小程序更多。 |

本次有针对性的检索没有发现同时满足原生 macOS、Bitcoin-only、手工人民币账务、可追溯 BTC 手续费、内部转账守恒和本地备份的成熟成品。结论是自行实现小型账务层与专用界面，复用 Apple 提供的基础能力；没有复制这些项目的业务代码。

维护核验限制：已读取官方 GitHub 项目 README；Sats Fort 的 GitHub 主题索引显示更新于 2026-05-27。直接 GitHub API 查询返回 403，因此不宣称已取得上述每个项目的精确最新 push 时间。这些候选已经因产品／平台不匹配淘汰，没有因猜测维护状态而淘汰。

## Swift Package Index 检查

[Swift Bitcoin](https://swiftpackageindex.com/swift-bitcoin/swift-bitcoin) 包页核验时展示 0.1.8、9 次发布，页面更新于 2026-08-26；[官方仓库](https://github.com/swift-bitcoin/swift-bitcoin)说明它提供节点、密码学、交易协议、钱包与密钥派生能力。V1 不签名、不派生地址、不读取链上余额，这些能力没有必要。

因此不添加 Bitcoin SDK、密码学库、网络库、UI 框架或金融计算库。原生能力已满足需求时，不为「复用」而增加依赖。

## 采用 Apple 原生能力

| 需求 | 选择及依据 |
|---|---|
| macOS 界面 | [SwiftUI](https://developer.apple.com/documentation/swiftui)；原生窗口、侧栏、表单、工具栏、菜单、系统图标。无 WebView、Electron 或服务器。 |
| BTC 精度 | [Int64](https://developer.apple.com/documentation/swift/int64) 存 satoshi；纯整数 BTC 加减及溢出检测。 |
| 人民币与成本 | Foundation [Decimal](https://developer.apple.com/documentation/foundation/decimal)，Apple 定义的十进制数；[NSDecimalRound](https://developer.apple.com/documentation/foundation/nsdecimalround(_:_:_:_:)) 用明确的银行家舍入。输入从字符串解析，不从 Double 转换。 |
| 完整备份 | Foundation [JSONEncoder](https://developer.apple.com/documentation/foundation/jsonencoder)、[JSONDecoder](https://developer.apple.com/documentation/foundation/jsondecoder) 与 Codable；金额用字符串，保留原值和版本。 |
| HTTP 行情 | [URLSession](https://developer.apple.com/documentation/foundation/urlsession)；只发送公开行情请求，账本与账户名不进入网络请求。 |
| 文件选择 | AppKit [NSSavePanel](https://developer.apple.com/documentation/appkit/nssavepanel)、[NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)；由用户选择导出和导入位置。 |
| 本地可靠写入 | Foundation [Data.WritingOptions.atomic](https://developer.apple.com/documentation/foundation/data/writingoptions/atomic) 与 Application Support；先校验候选账本，再进行原子替换。 |
| 测试 | Apple／Swift 官方 [Swift Testing](https://developer.apple.com/documentation/testing)，验证纯 Foundation 的核心计算。 |

Apple 文档同时提供 `.md` 版本；Decimal 官方内容已读取，确认其 base-10 语义、字符串解析及舍入 API，未依赖对库功能的记忆。

窗口缩放补充核验：Apple [`WindowResizability.contentMinSize`](https://developer.apple.com/documentation/swiftui/windowresizability/contentminsize) 以内容最小尺寸约束窗口，不施加最大尺寸；[`AnyLayout`](https://developer.apple.com/documentation/swiftui/anylayout) 可切换横排和纵排布局。两者均支持 macOS 13 及以上，覆盖本项目最低 macOS 14。采用这些原生能力，将主窗口最小尺寸从 900 × 680 调整为 600 × 420，默认仍为 1100 × 800；内容区低于 650 时纵排卡片，并让列表日期和账户余额换行，无需第三方布局库。

操作面板补充核验：系统 [sheet](https://developer.apple.com/design/human-interface-guidelines/sheets) 提供模态隔离，但已核验的公开 API 没有点击父窗口空白直接取消的开关；[popover](https://developer.apple.com/design/human-interface-guidelines/popovers) 支持外部关闭，主要用于依附控件的少量内容。本项目采用原生 [`overlay`](https://developer.apple.com/documentation/swiftui/view/overlay(alignment:content:))，让父视图主导布局，并自行提供面板外点击取消；面板随可用窗口尺寸调整，标题和底栏固定、内容滚动。取消、×、Esc 和外部空白点击均按用户要求放弃草稿；保存成功才入账关闭，错误提示后仍可继续编辑。

Apple [`keyboardShortcut`](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut(_:)) 会在窗口和菜单命令中查找目标，因此面板开启时同时禁用背景、工具栏与备份菜单，不能只拦截鼠标。使用 [`FocusState`](https://developer.apple.com/documentation/swiftui/focusstate) 将初始焦点送入金额或名称，关闭后回侧栏；背景另从无障碍导航隐藏。这些能力均由 SwiftUI 提供，没有新增依赖。

## 本地持久化选择

首选项已经调查 [SwiftData](https://developer.apple.com/documentation/swiftdata)。当前 Mac 只有可用的 Command Line Tools 环境，实际编译探针发现 SwiftData 的宏支持不可用；为了让交付物在这台 Mac 立即可构建、可运行，V1 使用 Foundation Codable 与原子 JSON 文件保存，而不是安装重量级工具链或引入第三方数据库。

个人账本数据量小，全量重算、全量校验、原子替换足够简单，且本地格式与可读备份一致。UI 不知道磁盘格式，持久化与纯值类型分开；将来有完整 Xcode 或增加 iPhone 只读查看时，可保留交易和备份模型，替换持久化层。没有云数据库或登录系统。

## CSV 不引入库的理由

V1 只需导出固定字段的 CSV，不提供复杂 CSV 导入。Foundation 编码 UTF-8，固定列，按 [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180) 为逗号、引号、换行进行转义；一个短小、测试覆盖的导出函数足够。没有必要引入解析器或通用表格框架。

## BTC/CNY 行情 API

选用 [Blockchain.com Exchange Rates API 官方文档](https://www.blockchain.com/explorer/_api/exchange_rates_api) 所列的 `https://blockchain.info/ticker`，读取 `CNY.last`。官方 [API 目录](https://www.blockchain.com/explorer/_api) 提供免费使用入口，不需 API Key、账户或自建服务。

2026-10-01 05:44 UTC 公开端点实测 HTTP 200，`CNY.last` 为 564693.92，响应含 `Cache-Control: max-age=60`。该数值仅证明测试时端点可用，不能当作之后的现价；数据未提供成交时间戳，因此界面明确使用本机成功取得报价的时间。应用自动缓存 300 秒；手动请求至少相隔 60 秒，网络失败不覆盖最后成功值。

同时检查了 CoinGecko：无 Key 请求当时也返回 200，但其 [Keyless Public API 官方说明](https://docs.coingecko.com/docs/keyless-public-api) 明确不面向生产或定时轮询用法，因此没有把临时可访问当成长期承诺，也没有采用。

## 确实需要自己实现的部分

1. 约定明确的四类账务事件及费用快照。
2. 账户余额守恒、历史透支校验、移动平均成本和完整历史重算。
3. 贴合个人需求的 Dashboard、录入、账户和历史视图。
4. 固定格式 CSV 的安全导出及应用级备份验证。

所有成本与费用口径见 [Accounting.md](Accounting.md)。无需第三方包即可完成以上需求。
