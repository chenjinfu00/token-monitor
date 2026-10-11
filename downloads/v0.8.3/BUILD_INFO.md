# Token Monitor 0.8.3 构建信息

- 源码提交：`5cbf54f8f4bdee69340471035e9ec30fb610fddf`
- 应用版本：0.8.3，构建号：22
- 架构：arm64 + x86_64，最低系统：macOS 13.0
- 签名：ad hoc；尚未 Apple 公证
- 许可证：项目代码 MIT；品牌图案说明见应用包 `Contents/Resources/BrandAssets.md`
- 本轮验证：30 组额度与显示检查（含分钟、秒、小时的切换边界），12 组 Claude 读取与时效检查；缩略每秒更新，59m / 59s 横竖布局宽度确认；双架构编译、严格签名、DMG 与 SHA256 校验。

本版缩略倒计时不足 1 小时显示整数分钟，不足 1 分钟显示整数秒，每秒更新。保存的是订阅额度百分比；安装包不包含个人历史、账号凭据或额度快照。

```text
d5ee63b2e264a4420bc97a95e296f61a0f9b52f3505042b3d8e8ebf5e97501e1  Token-Monitor-0.8.3-macos-universal.zip
c8166cd59f5eefa2b75d19cb4d4f9a7ecfdc89238449bf4314ed3a9d2dae24c4  Token-Monitor-0.8.3-macos-universal.dmg
```
