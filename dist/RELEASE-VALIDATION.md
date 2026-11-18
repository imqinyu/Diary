# macOS 1.1.1 Release 验证

构建日期：2026-11-18。build 3，普通日记创建后 24 小时可编辑，补写保持 12 小时；GitHub 自动同步调整为每次启动一次、之后半小时一次。包含附近同步、信任设备，以及此前的隐私内嵌图片协议。

- Release 构建通过，arm64 / x86_64 通用二进制。
- 本机 ad-hoc 签名验证通过；没有 Apple Developer ID 公证。
- DMG 完整性校验通过。安装包为 `Diary-macOS-1.1.1-Release.dmg`。
- 本轮 RegressionChecks、SyncChecks、StorageBackupChecks 通过。
- NearbyManager 与魅族 21 / Android 16 的 BLE → Wi-Fi Direct → 加密 TCP 同步真机通过；两端 VPN 保留。测试仅使用临时合成日记。
- 10 轮跨端真实 TCP 检查通过，覆盖分块图片、加密内容、增删改、冲突、并发编辑与断线恢复。

使用「设置 → 同步 → 附近同步」。两端开启蓝牙和 Wi-Fi，并允许相关系统权限。手机个人热点可能占用 Wi-Fi Direct 接口，使用前关闭热点。完成后系统恢复网络。

首次两端确认配对码并选择信任后，通过签名验证免码重连。后台自动同步需单独开启；Android 使用固定通知，系统可能限制调度。
