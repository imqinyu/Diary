# macOS Release 验证 · 2026-11-17

版本 1.0，构建号 1，macOS 15.0 及以上。

- Xcode 16.4 / Release / Swift -O wholemodule 构建成功。
- Universal Binary：arm64、x86_64。
- 本地 ad-hoc 签名；构建产物和只读挂载的 DMG 内应用均通过 codesign --verify --deep --strict。
- DMG 完整校验通过；内含 Diary.app、Applications 快捷方式及安装说明。挂载后的可执行文件与构建产物 SHA-256 相同。
- 未启动应用、安装到 Applications 或迁移真实日记数据。
- 本机没有有效 Developer ID 证书，此包未做 Apple 公证。

DMG SHA-256：`98e2fd9b2e477c92c9b1d9c4fe8d293da49c5c0ff25f871f8458d170bc4f70b8`
