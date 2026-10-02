# BTC 美元行情

## 来源

实时价格复用 [Blockchain.com Exchange Rates API](https://www.blockchain.com/explorer/_api/exchange_rates_api) 的 `https://blockchain.info/ticker`，读取 `USD.last`。服务不提供成交时间，界面注明获取时间。五分钟自动刷新，手动至少间隔一分钟；失败保留最后成功价格。

现代日 OHLC 来自 [Yahoo Finance BTC-USD](https://finance.yahoo.com/quote/BTC-USD/)，匿名 JSON 请求 `query1.finance.yahoo.com/v8/finance/chart/BTC-USD`。UTC 标签代表日开始，完整收盘下一午夜才可用于历史估值；当日行情以获取时刻截止并标为未收盘。null 不变成零价，高低价不能包围开收时只保留真实收盘。

最近七天 1 分钟优先 Yahoo BTC-USD，缺少或无效的完整蜡烛由 [Coinbase 历史蜡烛 API](https://docs.cdp.coinbase.com/api-reference/exchange-api/rest-api/products/get-product-candles) 补取真实 OHLC；主源失败则分页读取同一范围。其他盘中周期及较旧时间窗直接使用 Coinbase 原生 60 / 300 / 900 / 3600 / 21600 秒数据，按目标周期聚合。请求每页最多 300 个来源时段，去除边界重复，低于公开速率上限串行请求；不插值，不将日 K 拆成分钟 K。

Coinbase 缺少历史交易的时段仍可能留空；单次视窗最多 16,000 根目标蜡烛、100,000 个来源时段，过大请求明确要求缩短日期范围或选择更长周期。较细周期可选择历史日期，但不能承诺所有交易所成立前的分钟数据。

早期及现代缺日参考收盘来自 [Coin Metrics Community API](https://gitbook-docs.coinmetrics.io/packages/coin-metrics-community-data) 的每日 `PriceUSD`，直接保留美元数值。它不提供 OHLC，使用 `hasOHLC=false` 画灰线 / 灰点。[PriceUSD 定义](https://github.com/coinmetrics/docs-website/blob/master/asset-metrics/market/priceusd.md) 把价格标记在 UTC 日开始，值代表日终，因此下一午夜才可用于历史估值。全部视窗从 2009-01-03 开始；可靠价格之前留空，每条有效日记录都保留。

市场行情无需汇率换算。购买人民币换算美元单独使用 [Frankfurter 的 ECB 来源](https://frankfurter.dev/) 每日 USD/CNY 参考值，换算与精度说明见 [Accounting.md](Accounting.md)。

## 周期、范围与交互

提供 1 / 3 / 5 / 15 / 30 分钟，1 / 2 / 4 / 6 / 8 / 12 小时，日、3 日、周、月、3 月和年。时间范围含常用范围与自选起止日期。固定周期按 UTC 锚点聚合；周从周一开始，月 / 季度 / 年使用自然日期边界。OHLC 按首开、最高、最低、末收聚合；有缺口、参考记录或尚未收盘的周期不能标为完整。

历史数字排列在范围 / 周期选择旁，查看图时显示，点击图外收起。截止时刻按原始时间计算，界面显示到分钟，账本仅累计此前已发生事件；价格使用当时之前最近可得的收盘，注明行情时间。历史盈亏不借用未来行情或后来的购买 / 损耗。购买和转移仍逐事件改变成本线。

双指横移平移，图内捏合围绕指针缩放时间；右侧价格轴独立上下拖动缩放，双击恢复可见行情适配；点击图取得焦点后 ← / → 每次移动一根当前周期，表单不受影响。平移不自动改变纵轴比例，即使扩展到新的历史来源窗口；明确时间缩放在自动价轴模式下适配可见行情；手动价轴后只改变时间。重置 / 范围 / 周期切换恢复默认视图。横轴刻度按窗口时长与 UTC 锚点生成，平移不改变间距。正常窗口一屏显示；展开图幅增加高度，极小窗口保留可读内容并允许滚动。

## 缓存与失败处理

全新美元日、分钟和其他盘中周期缓存与旧人民币缓存隔离。日缓存四小时有效，最近分钟一分钟有效；尚未覆盖的盘中时间窗在平移 / 缩放停止后加载，已有覆盖直接读缓存。旧异步请求被取消后不发布数据或错误，历史数字不触发请求。手动刷新至少间隔一分钟，HTTP 429 退避。

来源失败时保留最后成功缓存及获取时间；早期参考源失败仍可显示现代日行情。无可用数据时显示错误，不用今天价格回填。匿名服务可能修正或缺失数据，参考收盘与真实 OHLC 始终区分。

无需 API Key、账户或订阅。请求只含固定币种和公共历史日期，不发送账本金额、账户或持仓。
