# didi_don_not_forget

把 AI 用量放在视线里。一个运行在 Mac 上的桌面看板，也能把只读页面显示在 iPad、Kindle 或其他带浏览器的设备上。

**作者：[@areslnn](https://github.com/areslnn)。源码可见，非商业使用可修改和分享；商业使用须事先书面授权，向他人分发或通过网络提供的衍生版本必须提供对应源码并沿用许可。详见 [LICENSE](LICENSE)。本项目不是 MIT/GPL，也不属于 OSI 定义的开源软件。**

## 能看到什么

- **Codex 额度**：读取当前 Mac 上已登录的 Codex 账号，展示平台实际返回的额度窗口、剩余比例、重置时间及可用重置卡。
- **到期提醒**：重置卡剩余不超过 72 小时会突出显示；黑白模式用反白和文字，普通模式同时用红色。只展示，不使用卡片。
- **Mac 状态**：CPU、内存、磁盘、电源等可取得的指标。没有可靠来源的数值保持“—”。
- **Starsg 用量**：在应用自己的登录窗口登录一次，读取“模型服务 → 用量与记录 → 用量统计 → 最近 30 天”的 API Key 汇总。展示名称、调用次数、六位小数费用及费用占比，不显示密钥。
- **两张桌面卡片**：可移动、分别隐藏、记忆位置；可切换置顶。
- **浏览器副屏**：同一局域网内，输入连接码后查看只读页面；提供不依赖 JavaScript 的墨水屏版本。

这是独立项目，不是 OpenAI、Anthropic、Starsg、Apple 或 Amazon 的官方产品。Codex 额度不是 ChatGPT 网页聊天额度；Starsg 汇总不是 Claude 官方订阅额度。

## 界面预览

以下均为虚构示例数据。

![普通网页看板](docs/assets/display-demo.png)

<details><summary>墨水屏模式预览（无 JavaScript）</summary>

![墨水屏网页看板](docs/assets/kindle-demo.png)

</details>

## 从源码运行

目前采集端支持 **macOS 14 或更新版本**，需要 Python 3.9+ 和 Xcode Command Line Tools 中的 Swift 编译器。构建脚本使用本机架构；已进行的本地验证以 Apple Silicon 为准，其他机器仍应自行验证。

```bash
git clone https://github.com/areslnn/didi_don_not_forget.git
cd didi_don_not_forget
zsh scripts/build-macos.sh
open "build/AI Usage Dashboard.app"
```

脚本只在项目的 `build/` 中构建应用，不覆盖其他应用，不更改开机启动项。构建产物使用本机临时签名，未进行 Apple 公证；本仓库主要分发源码。

要显示 Codex 额度，先安装并登录支持 `app-server` 的 Codex 桌面应用或 CLI。要显示 Starsg，用组件菜单的“连接 Starsg / 管理登录”完成登录。登录保存在该应用自己的 WebKit 会话中，不会共用或导出 Safari、Chrome 的登录状态。

平台登录状态何时过期由平台决定。检测到失效时保留最近读数及其原时间，在组件中提示重新连接；当前没有系统通知弹窗。

## 在 iPad / Kindle 上显示

1. Mac、iPad 或 Kindle 连接同一个可信的局域网。
2. 在 Mac 组件菜单选择 **“在 iPad / Kindle 打开…”**，开启共享并查看地址与 8 位连接码。
3. 在设备浏览器输入这个地址，再输入连接码。
4. iPad 使用普通页面；Kindle 或旧浏览器选择 **“墨水屏版”**，也可直接打开地址后的 `/kindle`。
5. 保持 Mac 和桌面组件运行。关闭共享或退出组件后，设备不能继续取得新数据。

普通网页每 60 秒重新显示数据，墨水屏版每 300 秒刷新；底层 Codex 与 Starsg 的查询通常每 5 分钟一次，Mac 采样每 10 秒一次。页面时间和每个来源的采集时间分开显示。

**兼容边界：** 提供的是浏览器页面，不是所有型号都验证过的 Kindle 应用。Kindle 版不依赖脚本，但浏览器、Cookie、Wi-Fi 和休眠策略仍受具体设备限制。网页不能保证阻止所有设备自动休眠；Mac 休眠、浏览器停止刷新或 Wi-Fi 隔离时会停止更新。项目不会自动更改系统电源设置。

局域网模式使用 HTTP 和连接码，适合可信家庭/办公网络；它不是互联网远程服务，也不提供 TLS。不要把端口转发到公网。接口只提供筛选后的只读汇总，不提供登录凭据、账号操作或重置卡使用入口。更多说明见 [SECURITY.md](SECURITY.md)。

## 不登录也能预览开发界面

```bash
python3 scripts/preview.py
# 浏览器访问 http://127.0.0.1:8780/display 或 /kindle
```

此命令只使用 [examples/demo.json](examples/demo.json) 的虚构数据，页面明确标为“示例数据”。它不启动真实账号采集，也不向局域网开放。关闭 JavaScript 仍可阅读两种页面。

## 测试

```bash
python3 -m unittest discover -s tests -v
zsh scripts/build-macos.sh
```

Python 测试覆盖额度归一化、缺失值、历史读数、页面转义、到期边界、连接码与会话校验、Host/Origin 边界和共享进程退出。测试使用虚构数据和回环地址，不需要真实账号。

## 二次开发

```text
src/native/       AppKit 卡片、菜单、Starsg WebKit 连接、设备共享控制
src/service/      本机 Codex / Mac 采集和可选局域网只读服务
src/service/shared/ 服务端渲染的普通 / 墨水屏页面
examples/         明确标记的虚构示例数据
scripts/          构建和本地预览
tests/            不依赖真实账号的测试
docs/             架构与扩展契约
```

- 调整布局或适配屏幕：修改 `src/service/shared/`，保持无脚本页面可读。
- 接入其他平台：参考 [数据契约与扩展](docs/providers.md)，保留来源时间、缺失值和失联状态。
- 修改 Starsg 页面解析：只读取自有窗口中的可见统计；不要改成读取其他浏览器 Cookie、密码或私有存储。
- 贡献代码前阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可、署名与商业授权

允许非商业查看、使用、修改和分享。分发或提供服务时，需保留版权、许可及“基于 areslnn 的 didi_don_not_forget 项目”的署名和来源链接。向他人分发或通过网络提供衍生版本时，必须同时公开完整对应源码，并使用相同许可。私人修改不因修改行为本身而要求公开。

任何商业使用（包括商业服务、项目交付和企业内部生产用途）须取得事先书面授权。请通过本仓库议题联系作者，并说明用途；**不要在公开议题中放账号、密钥或其他秘密信息**。得到商业许可也不自动免除署名和源码义务，除非书面许可另有明确约定。

完整条款以 [LICENSE](LICENSE) 为准。限制商业使用与 [OSI 开源定义](https://opensource.org/osd) 不兼容，因此这里使用“源码可见”表述。

## English summary

A macOS AI-usage dashboard with movable desktop cards and an optional paired, read-only LAN display for tablets and e-ink browsers. The server-rendered Kindle mode does not require JavaScript. Collection currently runs on macOS; device compatibility and sleep behavior vary. Codex and Starsg data are separate providers, and missing/stale values are explicit.

This project is **source-available, not OSI open source**. Noncommercial modification and redistribution are allowed subject to attribution and source-sharing conditions. Commercial use requires prior written permission. The Chinese text of [LICENSE](LICENSE) controls.
