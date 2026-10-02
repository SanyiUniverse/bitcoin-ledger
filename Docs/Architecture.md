# 本地架构

- **LedgerCore**：两类事件模型、Decimal / satoshi、当前与历史重放、备份迁移、文件保存、公共行情读取及日 / 周 / 月聚合。
- **BitcoinLedger**：SwiftUI 窗口、购买 / 转移表单、历史列表、覆盖面板与 Charts 图表。AppStore 先验证候选账本，保存成功才更新界面。
- **依赖**：Apple SwiftUI、AppKit、Foundation、Charts、Swift Testing；SwiftPM 管理构建，无第三方依赖。

账户展开继续使用 Dashboard 原有 `showLocations` 与同一 Button。覆盖面板禁用背景、固定标题和底栏、滚动内容；取消 / 关闭 / Esc / 外部点击丢弃草稿，保存失败保留草稿。默认窗口 1100×800，最小 600×420，小窗改为纵向布局和滚动。

LedgerRepository 串行使用 NSFileCoordinator、原子替换和读取字节冲突检测。目录 0700，账本及备份 0600；升级与导入先保留原始副本，读取失败不会用空账本覆盖原文件。

实时价格保存在账本文档，历史行情另存 `market-history-daily-v1.json`。公共行情请求不包含账本信息；缩放、范围和周期切换只操作缓存。来源及失败降级规则见 [PriceAPI.md](PriceAPI.md)。

构建脚本在系统临时目录组装应用，ad-hoc 签名并严格校验后输出 ZIP，避免 Documents 文件提供器附加元数据破坏签名。安装位置为 `/Applications/Bitcoin Ledger.app`。
