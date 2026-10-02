# Bitcoin Ledger

本机 BTC 记账软件，只记录「购买」和「转移」。打开 `/Applications/Bitcoin Ledger.app` 使用；最低 macOS 14，当前打包用于 Apple Silicon。

- **购买**：日期、实际投入人民币、实际获得 BTC、到账账户；默认欧易。
- **转移**：日期、来源、目标、转出 BTC、实际到账 BTC、可选备注；默认欧易 → 自有钱包。转出与到账之差计入损耗，不增加人民币投入。
- **总览**：点击总持有 BTC 展开或收起账户余额。购买 / 转移按钮旁紧凑排列累计投入、购买、损耗、综合成本与盈亏；另显示参考市价及总市值。
- **历史**：查看、编辑、删除记录；保存前重算全部历史，余额不足时拒绝修改。

K 线叠加动态综合成本及购买 / 转移事件。查看图时，历史数字排列在周期选择旁；点击图外收起。支持触控板双指左右移动与捏合缩放，点击图后用 ← / → 按当前日 / 周 / 月周期逐单位移动。可选 7 / 30 / 90 / 180 天、1 / 3 年与全部范围，也可展开图幅、缩放和重置。全部范围从创世日起显示；没有可靠行情的日期留空，只有收盘价格的日期画参考线，不能当作 OHLC 蜡烛。详见 [行情说明](Docs/PriceAPI.md)。

账本仅保存在 `~/Library/Application Support/Bitcoin Ledger/ledger.json`。菜单支持 JSON 完整备份 / 恢复和 CSV 历史导出。升级前保留旧文件原始副本，无法确定的旧记录进入迁移报告，不猜数据。详见 [计算与迁移](Docs/Accounting.md)。行情请求不发送账户、金额或持仓；无需 API Key、账户或订阅。

## 开发

使用 Apple SwiftUI、AppKit、Foundation、Charts 与 Swift Testing，没有第三方依赖。

```sh
./Scripts/test.sh
./Scripts/test-panels.sh
./Scripts/build-app.sh
```

构建脚本在上一级目录生成 `Bitcoin Ledger.zip`。使用已安装 Command Line Tools，优先可用的 26.5 SDK，不修改系统开发设置；隔离测试与临时打包目录自动清理。维护细节见 [架构](Docs/Architecture.md) 和 [验证状态](Docs/Validation.md)。
