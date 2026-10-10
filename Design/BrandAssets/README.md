# 服务标识矢量

这些图案用于界面内识别对应服务，不是 Token Monitor 自身的应用标志。

- `codex.svg`：OpenAI Blossom 结形，来自官方 ChatGPT 桌面应用的 `openai_logo_regular` 矢量资源。保留原始轮廓、内孔与宽高比，使用单色。参见 [OpenAI 设计指南](https://openai.com/brand/)。
- `claude.svg`：Claude Spark 放射形，来自官方 Claude 桌面应用的 ClaudeLogo 24px 矢量。保留原始不规则射线轮廓，使用 Claude 橙色 `#D97757`（深色模式提高亮度）。参见 [Claude](https://claude.com/)。

`ProviderBrandIcon.swift` 使用这些原始路径生成的原生 Core Graphics 绘图命令，不读取应用图标位图，也不需要运行时加载 SVG。展开、侧边竖排和顶部横排共用这一组件，背景透明且无边框。

项目 MIT 许可证适用于本项目代码；OpenAI 和 Anthropic 的名称与品牌图案由各自权利人所有，不通过本项目 MIT 许可证另行授权。本工具与它们无官方关联。
