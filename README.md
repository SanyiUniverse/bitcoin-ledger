# Bitcoin Ledger

只服务个人的 Bitcoin-only macOS 原生账本。打开总览即可查看 BTC 数量、人民币参考价值、资产位置、成本与手续费；点击 `＋` 手工录入买入、转账、卖出 / 花费和费用。

没有账号、服务器、云数据库、广告、新闻、交易功能或私钥管理。所有账目留在 Mac；仅向 Blockchain.com 请求公共 BTC/CNY 行情，不发送任何账户、数量、备注或交易记录。

## 日常使用

1. 双击 **Bitcoin Ledger.app**。
2. 在「账户」添加自己的交易所或自托管钱包。
3. 点击右上角 `＋` 输入记录。买入填**实际到账 BTC**；转账填源账户实际扣除总量和目标实到账，手续费自动算出。
4. 使用工具栏「备份 → Export Backup · JSON」定期保存完整备份；CSV 用于查看交易明细。

应用首次启动是空账本。测试全部使用合成数据，不预置任何真实或示例资产。

## 技术与运行

- Swift 6、SwiftUI、AppKit 系统文件面板、Foundation、URLSession、Swift Testing。
- **零第三方依赖**。最低目标 macOS 14；本次验证平台为 Apple Silicon / macOS 26.7，交付包为 arm64。
- 数据存储采用 Foundation 协调文件访问与原子 JSON 替换。当前 Mac 只有 Command Line Tools，缺少 SwiftDataMacros；不安装完整 Xcode、不手写宏实现。小型个人事件账本使用版本化 JSON 更简单，未来仍可迁移 SwiftData。见 [架构](Docs/Architecture.md)。
- 本地构建，ad-hoc 签名；没有 Apple Developer ID 公证，不是 App Store 发行包。这里交付的包已经在本机启动验证。

安装了 Swift 6 工具链 / Command Line Tools 后：

```sh
./Scripts/test.sh
./Scripts/build-app.sh
```

构建脚本输出项目旁的 `Bitcoin Ledger.app`，无需终端即可日常使用。当前机器的默认 SDK27 缺少 SwiftUIMacros，脚本自动选择已安装的稳定 SDK26.5，不更改系统设置。可用 `BITCOIN_LEDGER_SDK` 指定其它兼容 SDK。在完整 Xcode 中也可打开 `Package.swift` 查看、修改和运行源码；打包使用上述脚本。

## 数据模型

- **Account**：稳定 UUID、用户命名、类型（selfCustody / exchange）。
- **LedgerEntry**：稳定 UUID、发生时间、顺序、类型、来源/目标账户、BTC 数量、人民币金额、费用币种/类别/数量/发生时价格/人民币等值、备注。
- **BackupDocument**：schemaVersion、exportedAt、完整账户与记录、最近成功行情。
- **LedgerSnapshot**：从全部历史重算的余额与成本，不另存一份可漂移的账户余额。

BTC 保存为 `Int64` satoshi，1 BTC = 100,000,000 satoshi。人民币计算使用 `Decimal`，JSON 金额为十进制字符串，避免跨语言二进制浮点误差。人民币输入最多 2 位小数；历史费用 BTC 单价最多 8 位；费用等值与成本分摊保留 12 位银行家舍入。JSON 时间为 Unix 毫秒，CSV 为 UTC ISO8601。

## 计算规则

完整定义与例子见 [Accounting.md](Docs/Accounting.md)，App 内点击 ⓘ 也可查看。

- **累计投入** = 买入人民币本金 + 额外支付的人民币手续费。不扣减卖出收入；不加入 BTC 费用估值；卖出实收已经扣过的人民币手续费不再作为额外投入。
- **累计购买 BTC** = 买入净到账 + 从本笔买入扣除的 BTC 手续费。
- **平均买入价格** = 累计买入人民币本金 ÷ 累计购买 BTC。
- **持仓总成本**使用个人全部账户共享的移动加权成本池；买入增加本金及人民币买入费。转账不转出成本；BTC 费用由剩余 BTC 承担，不按市场价再加一次成本。全部 BTC 消耗时剩余成本结转已实现损失。
- **实际成本价** = 剩余持仓总成本 ÷ 当前 BTC。
- **卖出**填写不含额外 BTC 手续费的 BTC 数量和**实际净到账人民币**。卖出数量及 BTC 手续费共同按卖出前加权成本分摊；已实现盈亏 = 净到账 − 分摊成本。直接花费时人民币填 0。
- **未实现盈亏** = 当前 BTC × 参考价格 − 持仓成本；**收益率** = 未实现盈亏 ÷ 持仓成本。
- **手续费占比** = 全部费用按发生时价格折合人民币 ÷ 累计人民币投入；分母为零时显示 `—`。

按发生时间、同时间录入顺序、UUID 稳定重算。任何编辑、删除或恢复若会使某个账户在历史任一时点余额为负，就不保存并说明原因。账户可重命名；BTC 余额为零时可以删除。有历史的空账户会隐藏，但保留内部引用和完整记录；无历史空账户直接移除。

## 价格与离线

Blockchain.com 公共 ticker 的 CNY.last；无需 API Key。启动/激活及运行时每 5 分钟尝试更新，手动刷新每分钟最多一次。API 没有提供行情自身时间戳，界面准确显示**成功获取时间**。失败保留本地缓存，超过 15 分钟标记缓存。该价格是参考行情，不保证可成交或实时；服务无 SLA。详见 [API 选型及文档](Docs/PriceAPI.md)。

## 备份与恢复

本地默认位置：`~/Library/Application Support/Bitcoin Ledger/ledger.json`。每次保存先保留 `ledger.previous.json`，目录仅当前用户可访问；文件仅当前用户可读写。此自动副本不能替代异地备份。

- **Export Backup · JSON**：完整可恢复备份（包括精确数量、费用快照、账户和最近价格）。
- **CSV**：UTF-8 BOM、标准 CSV 转义、完整历史日期、数量、金额与费用；自由文本做公式注入防护。CSV 不是恢复格式。
- **Import Backup**：先验证格式、版本、引用、数量精度与历史余额，再确认替换。替换前保存当前副本；损坏的本地文件不会被静默覆盖。
- 导出是明文文件，请自行选择可靠存储位置。App 不同步 iCloud。

## 当前状态与验证

V1 已实现总览、四类手工记录、编辑/删除、账户、原生备份导入导出、持久行情缓存与核心测试。详细交付验证结果见 [Validation.md](Docs/Validation.md)。

不包含 iPhone、链上导入、xpub、交易所 API、税务处理或图表。没有任何私钥/助记词相关输入或存储接口。

选型过程与候选项目评估见 [Research.md](Docs/Research.md)。
