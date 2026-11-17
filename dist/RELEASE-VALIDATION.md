# macOS 1.1 Release 验证

构建日期：2026-11-17。build 2，包含附近同步，以及此前的隐私内嵌图片协议。

- Release 构建通过，arm64 / x86_64 通用二进制。
- 本机 ad-hoc 签名验证通过；没有 Apple Developer ID 公证。
- DMG 完整性校验通过。安装包为 `Diary-macOS-1.1-Release.dmg`。
- SyncChecks、PrivateImageChecks、LayoutChecks 通过。
- NearbyManager 与魅族 21 / Android 16 的 BLE → Wi-Fi Direct → 加密 TCP 同步真机通过；两端 VPN 保留。测试仅使用临时合成日记。
- 10 轮跨端真实 TCP 检查通过，覆盖分块图片、加密内容、增删改、冲突、并发编辑与断线恢复。

使用「设置 → 同步 → 附近同步」。两端开启蓝牙和 Wi-Fi，并允许相关系统权限。手机个人热点可能占用 Wi-Fi Direct 接口，使用前关闭热点。完成后系统恢复网络。
