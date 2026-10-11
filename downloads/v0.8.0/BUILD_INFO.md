# Token Monitor 0.8.0 构建信息

- 源码提交：`605cfe4599100c84fbeedbcc0ee7b973cc1beca1`
- 应用版本：0.8.0，构建号：19
- 架构：arm64 + x86_64，最低系统：macOS 13.0
- 签名：ad hoc；尚未 Apple 公证
- 许可证：项目代码 MIT；品牌图案说明见应用包 `Contents/Resources/BrandAssets.md`
- 验证：16 组历史测试、29 组额度检查、12 组 Claude 检查、单实例检查及 32 组桥接测试；五种连续时间尺度、左右滚动、光暗与最小窗口、重置标记、日期清理和二次确认；双架构编译、严格签名、DMG 与 SHA256 校验。

本版新增默认每 15 分钟记录的额度峰值和重置事件、连续滚动历史图表，以及采样频率、占用空间与按日期清理设置。保存的是已观察到的额度百分比，并非精确 token 数；安装包不包含个人历史、账号凭据或额度快照。

```text
1b8b652a0175258f05093a4b5f266d02b105d770d71337203288e7db151585cc  Token-Monitor-0.8.0-macos-universal.zip
a70bb62c8c872af2262351f01431c519e9b268438ed3c409159e34b7414e2730  Token-Monitor-0.8.0-macos-universal.dmg
```
