# 架构与原生能力选型

Bitcoin Ledger 是本机单用户账本。没有服务器、账号、CloudKit、钱包或交易权限，也没有第三方依赖。SwiftUI 负责原生窗口、导航、列表、表单和文件对话框；Foundation 负责精确十进制计算、JSON、文件协调及网络请求。LedgerCore 保存可测试的值类型和计算规则，UI 只展示结果并提交经过校验的完整快照。

主窗口默认 1100 × 800，内容最小尺寸由 900 × 680 降至 600 × 420，使用 `.windowResizability(.contentMinSize)`，不设置应用级最大尺寸。内容区域宽度低于 650 时，`GeometryReader` 配合 Apple `AnyLayout` 在 `HStackLayout` / `VStackLayout` 间切换，卡片改为纵排；列表日期和账户余额允许换行。继续使用原生 SwiftUI，不增加布局依赖。

## 本地持久化

本项目使用 `Codable` + `JSONEncoder`/`JSONDecoder`，账本位于 `~/Library/Application Support/Bitcoin Ledger/ledger.json`。BTC 使用 `Int64` satoshi，人民币与价格使用规范十进制字符串；计算才转换为 Foundation `Decimal`。JSON 结构含 `schemaVersion`，读入时拒绝不支持的版本和无效账目。

原计划优先使用 SwiftData。已实际验证这台 Mac 的 Command Line Tools 能编译 SwiftUI，但没有 SwiftData 的 `SwiftDataMacros` 编译插件，`@Model` 无法构建。为一个小型个人账本安装完整 Xcode、引入替代数据库或手工仿制宏生成代码都增加维护成本。因此采用 Apple Foundation 的原子 JSON 快照；它同时保持数据可读、完整、可移植。未来可把同一值类型快照迁移到 SwiftData，不改变业务计算或备份格式。

`LedgerRepository` 在主线程串行保存；先完整校验待保存文档，再通过 `NSFileCoordinator` 协调文件访问，以 `Data.write(options: .atomic)` 原子替换。保存成功后才更新内存。应用数据目录权限为 `0700`，账本及备份为 `0600`。替换前保留上一次有效快照 `ledger.previous.json`；它不是独立设备上的备份，仍应定期 Export Backup。

读取失败会报告错误并保留原文件，不静默建立空账本覆盖原数据。显式从备份恢复时，可在保留损坏字节为 `ledger.corrupt-UUID.json` 后恢复。导入前的有效账本另外保存为 `ledger.before-import-UUID.json`，不会被后续日常保存覆盖。已读取文件若在其他进程被改动，保存会拒绝覆盖，要求重新打开应用。持久化测试覆盖重新打开、权限、无效保存、上一版本备份、损坏检测、恢复和并发覆盖。

## 成本池与余额调整的最小扩展

继续复用原生 Decimal、Codable、NSFileCoordinator、SwiftUI 表单和导航。未引入库、新数据库、USDT 行情 API 或汇率服务；人民币成本来自真实现金和交易原值，不从实时汇率猜测。Foundation Decimal 和 NSDecimalRound 官方接口于本次升级再次核对。

`LedgerEntry` 在原有 BTC 事件上增加 buyUSDT / sellUSDT / adjustUSDT、BTC 买卖结算币种、USDT 数量与费用估价来源。`LedgerSnapshot` 提供单一 USDT 成本池、累计回款和逐笔 EntryValuation。业务逻辑仍只有一个完整重放引擎，不复制到 UI。首页只保留「买入比特币」「转移比特币」两个主要操作；USDT 买入和修改余额位于 USDT 页面。

`adjustUSDT` 是可编辑、可重放的余额目标事件。原始 `amountUSDT` 保存首次录入时的账面参考值，`receivedUSDT` 保存目标值；EntryValuation 的 `beforeUSDT` / `afterUSDT` 保存实际重放前后数量，前序记录修改后重新计算，不覆盖原始参考值。正目标保留池内人民币本金，零目标核销剩余本金并计入已兑盈亏；两者都不改变累计投入、回款、BTC 或已记手续费。详细口径见 Accounting.md。

备份版本 3 固定 `baseCurrency = CNY` 和 `accountingPolicy = cny-principal-moving-average-v1`，在原成本口径中扩展余额目标规则。序列化派生快照前重算，恢复时核验。版本 1 / 2 可读入并升级为内存版本 3；不会虚构 USDT 或余额调整记录。版本 2 / 3 必须保留完整 USDT 原始字段及逐笔估值；旧估值没有调整前后字段时仍可恢复。版本 1 / 2 不允许包含 adjustUSDT，避免旧版本标签掩盖新增语义。

读取旧版不改写文件。Repository 首次保存升级前，在确认文件未被外部改动后，将旧文件原始字节独立保留为 `ledger.before-upgrade-v1-UUID.json` 或 `ledger.before-upgrade-v2-UUID.json`，成功保留后才写入版本 3；后续日常保存不会覆盖这些文件。

## 构建与发布

SwiftPM 管理 `LedgerCore`、`BitcoinLedger` 和 Swift Testing 测试三个 target。最低部署版本 macOS 14；本次交付为当前 Mac 的 Apple Silicon 架构。本机默认 SDK 指向 27.0，但 CLT 缺少其新 `SwiftUIMacros` 插件；构建脚本在存在时采用已安装的 26.5 SDK，未修改系统开发环境设置，也未使用新于部署版本的 API。

`Scripts/build-app.sh` 用系统 Swift 编译器创建 release executable，按 Apple 标准 `Contents/MacOS`、`Contents/Resources`、`Info.plist` 组装 `.app`，然后使用本机 ad-hoc 签名并校验。此 Mac 的 Documents 文件提供器会持续给 `.app` 根目录添加 FinderInfo，导致严格签名校验失败。因此在系统临时目录签名，以 `Bitcoin Ledger.zip` 保存完整应用；`--install` 参数安装到 `/Applications/Bitcoin Ledger.app`，避免该文件提供器干扰。这适合此 Mac 个人使用；向其他 Mac 分发时需单独决定 Developer ID 签名和公证。完整 Xcode 不是本机运行交付物的依赖。

## 官方依据

- [Apple SwiftData ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer)
- [Apple Foundation Decimal](https://developer.apple.com/documentation/foundation/decimal)
- [Apple JSONEncoder](https://developer.apple.com/documentation/foundation/jsonencoder)
- [Apple NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [Apple FileDocument 导出](https://developer.apple.com/documentation/swiftui/view/fileexporter(ispresented:document:contenttype:defaultfilename:oncompletion:))
- [Apple Sidebar 界面规范](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple Toolbar 界面规范](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Apple App Bundle 文件布局](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)

资料和本机能力核验日期：2026-10-01。
