# BTC 人民币行情

## 来源与可得时间

实时价格复用 [Blockchain.com Exchange Rates API](https://www.blockchain.com/explorer/_api/exchange_rates_api) 的 `https://blockchain.info/ticker`，读取 `CNY.last`。本机记录获取时间，服务未提供成交时间；五分钟自动刷新，手动至少间隔一分钟，失败保留最后成功价格。

2014-09-17 起的人民币日行情来自 [Yahoo Finance BTC-CNY](https://sg.finance.yahoo.com/quote/BTC-CNY/)，页面注明提供者 CoinMarketCap。匿名 JSON 使用 `query1.finance.yahoo.com/v8/finance/chart/BTC-CNY`，参数为 `interval=1d`、`period1=0` 和当前截止时间 `period2`。UTC 时间戳标记日开始：完整收盘在下一午夜才可用于估值，当天行情以获取时刻截止并标为未收盘。null 不变成零价；高低价不能包围开收的记录只保留真实收盘，不修造 OHLC。

早期和缺日参考价格来自 [Coin Metrics Community API](https://gitbook-docs.coinmetrics.io/packages/coin-metrics-community-data) 的每日 `PriceUSD`，乘以 [Frankfurter ECB 来源](https://frankfurter.dev/) 的同日历史 USD/CNY 参考汇率。非发布日采用此前最近汇率，超过七天则留空。参考记录用 `hasOHLC=false` 标识，只画灰线或灰点。

[PriceUSD 定义](https://github.com/coinmetrics/docs-website/blob/master/asset-metrics/market/priceusd.md) 与 [时间戳约定](https://github.com/coinmetrics/docs-website/blob/master/market-data/market-data-faqs.md) 将日价格标记在区间开始，值代表日终，因此可得时间移至下一 UTC 午夜。最早可靠日标签为 2010-07-18；全部视窗从创世日 2009-01-03 开始，此前没有价格的部分留空。每个有真实来源的日记录均保留，不抽样成四日线，也不补造行情。

## 图表与历史状态

范围为 7 / 30 / 90 / 180 天、1 / 3 年及全部；周期为日 / 周 / 月。周从 UTC 周一开始，月按 UTC 自然月。有效 OHLC 按首开、最高、最低、末收聚合；含参考记录的周期画参考线，缺日或未收盘的周期不能标为完整。范围、周期、缩放、平移和重置只改变显示，展开图幅增加高度。

历史数字仅在查看图时显示在周期选择旁，横向排列并随窗口换行；点击图外收起，不影响图表。触控板双指横移平移时间，捏合按指针位置缩放；竖向滚动仍由总览处理。点击图取得焦点后，← / → 每次移动一天、一周或一个自然月，表单中的方向键保持原有行为。

账本按所选截止时间重放，价格取该时间之前最近可得的行情并标明行情时间。盈亏使用该历史价格估算，不能借用未来收盘或后来购买 / 损耗；同日事件按截止时间汇总，成本线与标记仍逐事件变化。

## 缓存与失败处理

完整日历史缓存在账本旁 `market-history-daily-v1.json`，四小时有效。手动刷新至少间隔一分钟，HTTP 429 退避；没有定时轮询，范围、周期和缩放不触发请求。

现代日 K 失败时保留最后成功缓存及时间；早期参考源失败仍显示现代日 K 和提示，并保留已有早期缓存。无可用行情时显示错误，不用今天价格回填历史。

无需 Key、账户或订阅。匿名服务没有稳定性保证，数据可能修正或缺失；参考线与真实 OHLC 始终分开。请求只含固定币种和公共历史日期，不发送账户、金额或持仓。
