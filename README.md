# Dynamic Peninsula（半岛）

Dynamic Peninsula 是一个面向 macOS 刘海区域的本地桌面工具。本页对应公共发行版 `public-2.7.3-20260929`，只发布可安装的 App，不把个人电脑上的股票/Portfolio 功能带入公共包。

## 下载

[打开 `public-2.7.3-20260929` Release](https://github.com/zhn66776/dynamic-peninsula/releases/tag/public-2.7.3-20260929)，下载 `Dynamic-Peninsula-2.7.3-public-macOS26-universal.dmg`。

| 项目 | 说明 |
| --- | --- |
| 系统 | macOS 26 或更高版本 |
| 架构 | Apple 芯片 `arm64` 与 Intel `x86_64` |
| DMG | 约 13.62 MB |
| 签名 | ad-hoc 签名，未 notarized |
| 发布范围 | 公共版本，不含本地股票/Portfolio 模块 |

同一 Release 提供 `Dynamic-Peninsula-2.7.3-public-source.zip`，内含此安装版对应的源码、依赖版本和构建说明。GitHub 自动生成的 `Source code` 压缩包仅包含本仓库的文档；需要编译应用时，请下载带有 `public-source.zip` 名称的附件。

## 安装与首次打开

1. 打开 DMG，把 `Dynamic Peninsula.app` 拖到 `Applications`。
2. 从 `Applications` 启动应用。
3. 如果 macOS 首次启动时阻止打开，请进入“系统设置 > 隐私与安全性”，在安全性提示旁点击“仍要打开（Open Anyway）”，然后再次确认。参见 [Apple 的官方说明](https://support.apple.com/102445)。

不要关闭全局 Gatekeeper。此包没有经过 Apple notarization，因此不承诺 Gatekeeper 自动放行。

## 公共版本包含什么

公共版本保留以下功能；部分集成依赖用户本机的应用、登录状态或系统权限：

- 音乐控制与可视化；
- Codex 与 Claude 的账户用量/状态显示；
- AgentLight 与本机 agent 状态提示；
- 剪贴板历史、文件 Shelf 与 AirDrop；
- 系统监控与本机状态展示。

公共版本不包含股票/Portfolio 界面、股票通知或个人 Portfolio 数据依赖。开发者自己的 `Personal Build` 是另一套本地构建，保留个人功能，不随公共 DMG 分发。

## 账号、权限与网络

DMG 不预置账户 token、session cookie、API key 或个人数据。启动应用后，如果检测到本机 Codex 登录状态或钥匙串中已保存的 Claude session key，相关监控会自动查询账户用量；这一步不要求先打开对应标签页。没有相应凭据时，账户功能不可用。

Codex 和 Claude 的查询会将认证信息直接发送给各自服务的账户接口。打开对应标签页时，应用还会读取本地会话日志以统计用量。AgentLight 使用本机状态文件；日历、提醒事项、摄像头、音乐控制等功能按需使用 macOS 权限。

详见 [隐私说明](PRIVACY.md)。

## 许可证与致谢

本项目基于上游 [TheBoredTeam/boring.notch（Boring Notch）](https://github.com/TheBoredTeam/boring.notch) 修改发布，相关代码按 [GNU General Public License v3](https://www.gnu.org/licenses/gpl-3.0.html) 许可。发行包包含完整的 `LICENSE` 与第三方许可文本；本仓库的说明见 [LICENSE.md](LICENSE.md) 和 [NOTICE.md](NOTICE.md)。

本仓库只保存公开说明文档和 `.gitignore`；应用与对应源码通过 Releases 提供。开发历史、个人配置和股票功能不在此文档仓库中。
