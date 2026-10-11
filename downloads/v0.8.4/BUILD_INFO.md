# Token Monitor 0.8.4 构建信息

- 源码提交：`86217b0192c5c6bc78fb332fd3cb4ef15c129e7d`
- 应用版本：0.8.4，构建号：23
- 架构：arm64 + x86_64，最低系统：macOS 13.0
- 签名：ad hoc；尚未 Apple 公证
- 许可证：项目代码 MIT；品牌图案说明见应用包 `Contents/Resources/BrandAssets.md`
- 本轮验证：8 组自适应倒计时检查（小时、分钟、秒、天数、过期切换、空闲、双服务及颜色）；本地定时器的长间隔、秒级、停止、恢复和快照替换运行检查；显示切换旗标路径复核；双架构编译、严格签名、DMG 与 SHA256 校验。

本版缩略倒计时按下一次可见数字或颜色变化安排一次性本地更新，无有效期限时停表。隐藏视图停止本地倒计时，显示、唤醒、系统时间变更及新额度数据时立即重算。服务器查询频率保持原样。保存的是订阅额度百分比；安装包不包含个人历史、账号凭据或额度快照。

```text
dd36dedfc574f0dbff535672d7adce7650ea253724426c63cd6d01bc543e73bc  Token-Monitor-0.8.4-macos-universal.zip
8d6c0e998303bcd1ed02bea0ac0c523245f5504c567baa85f464dde6fe4d700c  Token-Monitor-0.8.4-macos-universal.dmg
```
