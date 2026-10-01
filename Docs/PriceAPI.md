# 行情 API 决策

核验日期：2026-10-01。使用 Apple Foundation / URLSession，第三方依赖为零。

## 选择：Blockchain.com Exchange Rates

- 官方说明：[免费开发 API](https://www.blockchain.com/explorer/_api)、[Exchange Rates API](https://www.blockchain.com/explorer/_api/exchange_rates_api)。旧的 `/explorer/api/exchange_rates_api` 地址目前会重定向，文档使用 `_api` 路径。
- 请求：`GET https://blockchain.info/ticker`。无参数、无 API Key、无用户注册。只读 `CNY.last`，官方定义为最近市场参考价格；不用 `15m`。
- 实测：HTTP 200，响应包含 `CNY.last`；`Cache-Control: public; max-age=60`。行情接收代码将 JSON 数字直接解码为 `Decimal`，不经过 `Double`。
- 返回体没有行情时间戳。`fetchedAt` 仅表示本机成功获取时间，界面必须写“价格获取于”，不能冒充交易所最后成交时间。HTTP `Date` / `Last-Modified` 也不是成交时间。
- App 打开或回到前台时，距成功获取至少 5 分钟才自动请求；支持手动刷新。由界面层节流，禁止高频重试。失败保留已持久化的最后成功价格与原获取时间，不用零替代价格。
- 只发送固定行情 URL，不发送账户名称、余额、交易记录、地址或其他个人账本信息。临时 URLSession 不保存 Cookie 或认证信息，无自建服务器。

官方 ticker 文档没有承诺具体配额或 SLA，不能宣称“无限调用”或“保证实时”。[API 条款](https://www.blockchain.com/legal/api-terms) 允许查询当前 Bitcoin 市场价格，禁止过量请求，且服务可能变化或停止。

## 已核验但未采用：CoinGecko Keyless

[官方 Keyless 文档](https://docs.coingecko.com/docs/keyless-public-api) 明确允许免注册免 Key，动态共享 IP 配额约 10–30 次/分钟，同时说明不适合生产负载、计划轮询或高频更新。实测 `/api/v3/simple/price?ids=bitcoin&vs_currencies=cny&include_last_updated_at=true&precision=full` 返回 HTTP 200。

[Simple Price 文档](https://docs.coingecko.com/reference/simple-price) 提供 `last_updated_at`，但上述使用条件不适合作为长期自动刷新主来源。因此未增加第二套自动行情依赖，也不引入 Key、账号或额外费用。

## 费用快照与实时价格分开

费用始终保留原币数量。手工历史 BTC/CNY 价格作为固定快照保留；按成本链自动估算的 BTC / USDT 费用明确标为成本折算，不冒充历史行情。编辑前序账目重算成本折算值，手工历史价格不变；实时行情只用于当前 BTC 市值。USDT 余额调整不依赖行情或汇率 API，也不冲减之前已记录的手续费。

## 备份与 CSV

JSON schemaVersion 为 3，含固定 CNY 本位和现金本金口径，兼容版本 1 / 2。读取不改写旧文件，首次保存升级前先确认没有外部修改，再将原始字节保留为独立的 `ledger.before-upgrade-v1-UUID.json` 或 `ledger.before-upgrade-v2-UUID.json`。金额为十进制字符串、BTC 数量为整数 satoshi、日期为 Unix epoch 毫秒（保留小数毫秒，不截断交易顺序）。使用 Foundation Codable，不引入 JSON 或 CSV 库。导入最大 20 MiB，先完整解码和重放验证，版本不支持、缺失账户、重复 ID 或透支等错误不得改变现有数据。

余额调整同时保留原始 `amountUSDT` 参考值、`receivedUSDT` 目标值，以及重放得到的 `beforeUSDT` / `afterUSDT`。前序历史变化时只重算派生估值，不覆盖原始审计字段；正目标保留原成本，零目标核销剩余成本，不改变外部现金流。

CSV 使用 RFC 4180 引号转义、CRLF 换行、UTF-8 BOM。导出完整时间、账户 ID/名称/类型、所有整数 satoshi、人民币金额、USDT 扣款/到账/费用、费用换算来源、逐笔人民币本金、费用单价与等值。调整行另有 `adjustment_before_usdt`、`adjustment_after_usdt`、`adjustment_delta_usdt` 三列，均使用实际重放结果，其余行留空。自由文本若可能触发表格公式，前置单引号；原文完整保存在 JSON 备份。CSV 用于查看和携出，JSON 用于恢复。
