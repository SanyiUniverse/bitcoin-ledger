# Bitcoin Ledger

本机 BTC 账本，只记录购买和转移；最低 macOS 14，适用于 Apple Silicon。

从 [Releases](https://github.com/SanyiUniverse/bitcoin-ledger/releases/latest) 下载 ZIP，解压后将 `Bitcoin Ledger.app` 放入 `/Applications` 并打开。

- **购买**：输入日期时间、实际投入人民币、实际到账 BTC 和账户；默认欧易。
- **转移**：输入来源、目标、转出及到账 BTC；差额计入损耗，不增加投入。默认欧易 → 自有钱包。
- **总览**：显示总持有、总成本、市值、浮盈和浮盈率。按钮旁先显示成本金额，后接小号「总成本」；右侧三项可拖动排序，市价与损耗横排在下方，宽窗与购买 / 转移处于同一底行。点击总持有展开钱包余额。
- **历史**：查看、编辑、删除记录；保存前验证完整历史，拒绝造成余额不足的修改。

购买以人民币输入，成本与行情以美元显示。每笔购买按当时已可用的每日参考汇率换算并固定保存；刷新行情不改变投入。计算与旧账本迁移见 [Accounting](Docs/Accounting.md)。

K 线叠加每 BTC 成本和购买 / 转移事件，支持分钟至年共 17 种周期及自选日期。摘要默认显示当前状态；移动鼠标查看历史，停下约 1.2 秒或移开后恢复。双指横移平移、图内捏合缩放时间；点击图后用 ← / → 移动。自动价格轴适配可见数据，右侧价格轴可独立拖动缩放、双击复位。正常窗口一屏显示，小窗口可滚动。

行情只使用真实 OHLC 或标明来源的参考收盘，缺失不补造；失败或超限会提示。来源、范围限制与缓存规则见 [PriceAPI](Docs/PriceAPI.md)。

账本保存在 `~/Library/Application Support/Bitcoin Ledger/ledger.json`。菜单支持 JSON 完整备份 / 恢复与 CSV 导出；升级和导入保留原始备份。行情请求不发送账本金额、账户或持仓，无需 API Key 或订阅。

## 构建与验证

使用 Apple SwiftUI、AppKit、Foundation、Charts、Swift Testing，无第三方依赖。安装 Command Line Tools 后运行：

```sh
./Scripts/test.sh
./Scripts/test-panels.sh
./Scripts/build-app.sh
```

构建输出上一级目录的 `Bitcoin Ledger.zip`。更新时先退出应用，再替换 `/Applications/Bitcoin Ledger.app`；账本独立保存。`--install` 仅用于尚未安装的机器，不覆盖已有应用。维护说明见 [Architecture](Docs/Architecture.md)，当前结果见 [Validation](Docs/Validation.md)。
