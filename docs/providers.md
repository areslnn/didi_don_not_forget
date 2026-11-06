# 中转站连接与数据契约

中转站由用户配置，默认不连接任何网站。本项目提供一个可映射的 JSON 统计接口适配器和一个有明确结构要求的网页统计模板，不能保证任意站点开箱即用。

## 方式一：HTTPS JSON 统计接口

在 Mac 菜单打开“中转站设置…”，选择 API JSON，填写：

| 设置 | 含义 |
| --- | --- |
| 显示名称 | 自定义来源名称，例如“示例中转站”；会显示给已配对的副屏 |
| URL | 返回统计 JSON 的完整 HTTPS GET 地址；不是聊天、生成或模型推理地址 |
| 周期标签 | 例如“最近30天”；只负责显示，必须与接口查询范围一致 |
| `entriesPath` | JSON 中记录列表的点路径；留空表示根节点即列表 |
| `name` | 每条记录的昵称或别名路径；不要映射原始密钥 |
| `calls` | 每条记录的调用次数路径，可不映射 |
| `inputTokens` / `outputTokens` | 真实输入 / 输出 Token 的字段路径，可不映射 |
| `totalTokens` | 真实总 Token 的字段路径，可不映射 |
| `amountUSD` | 已以美元计价的费用路径，可不映射 |
| 可选凭据 | 统计接口的 Bearer token，单独存入本机钥匙串 |

路径使用点号分隔对象字段，也支持数字数组索引，例如 `groups.0.rows`。`entriesPath` 相对于整个响应，其余字段相对于每条记录。字段路径留空意味着未映射，不意味着零。

下面是**虚构响应**，演示统计结构；它不是某个厂商的真实接口：

```json
{
  "data": {
    "rows": [
      {
        "alias": "团队A",
        "usage": {
          "requests": 12,
          "input_tokens": 80000,
          "output_tokens": 12000,
          "total_tokens": 92000,
          "cost_usd": 0.42
        }
      }
    ]
  }
}
```

对应映射为：

```text
entriesPath:   data.rows
name:          alias
calls:         usage.requests
inputTokens:   usage.input_tokens
outputTokens:  usage.output_tokens
totalTokens:   usage.total_tokens
amountUSD:     usage.cost_usd
```

URL 的路径和查询参数需要由你使用的站点提供。例如，只有站点确认 `period=30d` 表示最近 30 天时，才可以用对应 URL 并标注“最近30天”。仅修改周期标签不会修改 API 请求范围，也不会把累计数据转换为期间数据。

认证只通过专用凭据输入框配置。不要在 URL 用户信息、查询参数、片段或显示名称中放入凭据。应用不接受 URL 用户信息、片段或常见凭据查询参数。接口只读不意味着应使用具有管理权限的密钥；如站点提供只读统计凭据，应优先使用。

## 数值规则

- 数值必须是 JSON 数值，不能是布尔值或数字字符串；计数应为非负整数，单字段不超过 `2^53 - 1`。
- `totalTokens` 优先使用直接返回的有效总数。只有 `inputTokens` 和 `outputTokens` 都有效且安全可相加时，适配器才生成总数；缺少任何一侧都不能当作 0。
- 只有所有记录的相关字段都已知时，才能合计该字段。某个 Key 缺少总 Token，则总 Token 显示“未提供”；该 Key 的已知调用次数或费用仍可独立显示。
- 成功确认的空列表可以显示零合计。未配置、认证失败、读取失败或缺少字段不能作为零。
- 单条美元金额只接受有限且在 `0` 到 `1e12` 之间的数值；超界保留为未提供，不能归零。完整合计可以超过单条上限，但必须有限。
- `amountUSD` 只能映射真实美元金额。平台 `quota`、积分、点数、配额和其他货币不能直接作为美元；当前适配器不做货币或积分换算。
- Token 不会从费用、配额、积分或调用次数反推。它们是不同的统计量。
- 费用占比只在所有费用都已知且总费用大于 0 时计算；零费用时占比未提供。它不是调用次数或 Token 占比。
- 保留原始数值用于计算，最后才格式化显示。金额明细显示六位小数，总费用显示两位小数。

**昵称也是外部文本。** `name` 必须选择可公开给副屏的昵称或别名，不要映射 `api_key`、`token`、`secret` 等原始密钥字段。文本会转义显示，但转义不会把秘密变成适合公开的信息。

## 方式二：网页统计模板

用户提供完整 HTTPS 统计页面 URL、来源名称和周期，在应用自有 WebKit 窗口登录。当前模板识别按 API Key 汇总的调用次数、费用与费用占比，并检查配置的完整 origin、路径、查询参数及周期控件。

这不是通用网页抓取器。页面表格、标签、统计图或登录跳转变化，都可能需要修改模板。当前模板没有 Token 数据来源，输出的 `inputTokens`、`outputTokens`、`totalTokens` 均为 `null`；Token 界面会明确显示未提供。不要为了填满界面而估算。

登录状态保留在本应用自己的 WebKit 会话中，不读取其他浏览器的 Cookie 或私有存储。更换配置会更新连接标识并清除旧读数；模板失败或登录过期保留同一来源最近一次有效汇总与原时间。

## 共享显示的数据契约

共享服务取得 Codex/Mac 汇总和本应用中转站缓存，经过字段白名单、数值与采集时间检查后，输出：

```text
fetchedAt: ISO 8601（本次组合响应的时间，不能当成采集时间）
account: {status, updatedAt, planType, windows[], resetCredits, error}
system: {updatedAt, cpu, memory, disk, battery, gpu, uptimeSeconds}
relay: {status, updatedAt, periodLabel, sourceLabel, entries[], error}
relay.entries[]: {
  name,
  calls?, inputTokens?, outputTokens?, totalTokens?,
  amountUSD?, sharePercent?
}
```

可选数值未知时使用 `null`。共享端不接收中转站 URL、字段映射、Bearer 凭据、WebKit Cookie、原始 API Key 或完整 API 响应；`sourceLabel` 和 `name` 都是明确的展示文本。

每个 `account.windows[]` 包含 `label`、`remainingPercent`、`usedPercent`、`windowDurationMins`、`resetsAt`。不要假设 primary 一定是 5 小时窗口，应使用平台返回的持续时间。

`resetCredits` 包含可用数量及 `{expiresAt, status, title}` 条目；不提供卡片 ID 或使用入口。仅对 `status=available` 的有效期作突出提示。

时间统一用带时区的 ISO 8601 或明确的 Unix 秒数传递；当前中文界面使用北京时间。显示层只展示规范化后的 Token，不再用费用或其他字段自行推算。

增加适配器时，用虚构夹具覆盖正常、空列表、缺失字段、认证失效、网络错误、旧时间戳、不同连接标识和恶意显示名称。不要把认证上下文原样传给显示端。
