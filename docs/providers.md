# 数据契约与扩展

共享服务从本机服务取得 Codex/Mac 汇总，从应用自己的目录取得 Starsg 汇总，经过字段白名单、数值范围和采集时间校验后，形成以下结构：

```text
fetchedAt: ISO 8601（本次组合响应的时间，不能当成采集时间）
account: {status, updatedAt, planType, windows[], resetCredits, error}
system: {updatedAt, cpu, memory, disk, battery, gpu, uptimeSeconds}
starsg: {status, updatedAt, periodLabel, entries[], error}
```

每个 `account.windows[]` 包含 `label`、`remainingPercent`、`usedPercent`、`windowDurationMins`、`resetsAt`。不要假设 primary 一定是 5 小时窗口，应使用平台返回的持续时间。

`resetCredits` 包含可用数量及 `{expiresAt, status, title}` 条目；不提供卡片 ID 或使用入口。仅对 status=available 的有效期作突出提示。

每个 `starsg.entries[]` 包含 `name`、`calls`、`amountUSD`、`sharePercent`。`sharePercent` 是费用占比，不是调用次数占比。名称是用户可编辑的外部文本，必须转义后呈现。保留金额的小数精度，不将格式化后的字符串再用作计算源。

时间统一用带时区的 ISO 8601 或明确的 Unix 秒数传递；当前中文界面使用北京时间显示。未知值用 null，不能以 0 填补。完整来源明确确认没有记录时，才可以显示零合计。

增加一个平台时，应先实现可独立测试的只读适配器，再扩展共享白名单和页面渲染。用虚构夹具覆盖：正常、空列表、缺失字段、登录失效、网络错误、旧时间戳和恶意名称。不要把认证上下文原样传给显示端。

可参考 Starsg 的设计：原生连接器维护其自有登录窗口，解析已显示的数据，并仅输出汇总。网站登录与页面结构可能变化，所以该适配器需要维护；不要把网页解析器描述成官方稳定 API。
