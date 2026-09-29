# NOTICE

本文件记录 Dynamic Peninsula 公共发行版的主要上游归属。完整第三方许可见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)；DMG 和源码归档内也保留对应许可文本。

## 上游项目

- **Boring Notch / TheBoredTeam**：本项目的上游基础项目，按 GNU GPL v3 相关条款发布。来源：[TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)。

## 主要第三方组件

| 组件 | 许可 | 用途或说明 |
| --- | --- | --- |
| MediaRemoteAdapter | BSD 3-Clause | macOS Now Playing 媒体信息适配 |
| Calendr | MIT | 日历相关能力来源之一 |
| DynamicNotchKit | MIT | 刘海区域界面相关能力来源之一 |
| NotchDrop | MIT | Shelf / 文件拖放能力来源之一 |
| swift-soc-metrics | MIT | 系统监控指标读取的适配材料来源之一 |
| Parrot | MPL 2.0 | 本地功能相关的开源组件归属 |

## 归属与分发

1. 分发 DMG 时应保留 `LICENSE` 和 `THIRD_PARTY_LICENSES.md`。
2. 不使用任何上游项目名称、作者名称或贡献者名称暗示其对本公共发行版提供背书。
3. 上表是便于阅读的摘要，不扩展或缩小各组件原始许可证授予的权利。
4. 每个应用 Release 同时提供对应的 `public-source.zip` 源码附件；仓库中的自动源码压缩包只包含文档。
