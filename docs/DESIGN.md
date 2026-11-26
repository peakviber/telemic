# RemoteMic 设计笔记

## 要解决的问题

远端主机（比如一台没有麦克风的 Mac mini）需要一个"麦克风"，声音来自本地任意一台 Mac。
SonoBus + BlackHole 能用，但主机上的 SonoBus 要把声音**播放**进 BlackHole，
UU 远程用 ScreenCaptureKit 采集所有应用的声音，于是把这段声音传回客户端，形成回声。

**原则：主机上没有任何进程"播放"这段声音。** 声音由接收进程直接交给虚拟麦克风驱动，
主机上的应用把它当麦克风录音，屏幕和声音采集工具看不到它。

## 架构

```
本地 Mac（发送端）                         主机 Mac mini（接收端）
┌──────────────────┐   Opus/UDP over    ┌────────────────────────────┐
│ RemoteMic.app    │   Tailnet          │ RemoteMic.app（主机模式）  │
│  采集麦克风       │ ─────────────────▶ │  接收、解码、抖动缓冲       │
│  Opus 编码       │                    │  选择：只听某一台 / 混合     │
└──────────────────┘                    │        │ 127.0.0.1 UDP（PCM）│
   × N 台                               │        ▼                    │
                                        │ RemoteMic.driver（HAL 插件）│
                                        │  只有输入的虚拟设备          │
                                        └────────┬───────────────────┘
                                                 ▼
                                         主机上的应用（选 RemoteMic 当麦克风）
```

- **驱动**（`Driver/`）：Core Audio AudioServerPlugIn，只有输入、没有输出的设备 "RemoteMic"，
  48 kHz、单声道、float32。它在本机回环地址上接收 PCM，放进无锁环形缓冲，
  在 IO 回调里交给录音的应用。缓冲先攒 40 ms 再开始输出，积压超过 250 ms 就跳到最新。
  解码和网络都不放在驱动里：接收程序崩溃不会拖垮系统的声音服务。
- **同一个应用，两种角色**：启动时选"主机"或"客户端"，以后可以切换。
  - 客户端：菜单栏开关"说话/停止"，选择输入麦克风，显示连接到哪台主机。
  - 主机：列出在线的客户端，选择"只听某一台"或"混合全部"，显示每台的电平。

## 自动发现（Tailnet）

- 直接分发（非 App Store）的应用可以读 Tailscale 的本地 API，拿到所有在线设备：
  - 开源 `tailscaled`（本机就是这种）：`/var/run/tailscaled.sock`，
    `GET http://local-tailscaled.sock/localapi/v0/status`。已在主机上验证可用。
  - Tailscale 独立版（DMG）：`/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json`。
- 拿到 `OS == "macOS"` 且在线的设备后，向每台的 RemoteMic 端口发一个 hello，
  回复里带角色（主机/客户端）和设备名，就完成发现。
- 安全：只监听 Tailscale 网卡地址，只接受来自本 Tailnet 的包。
- Tailnet 不支持多播，所以 Bonjour 无法跨 Tailnet 发现设备，只能用上面的方式。

## 能否上架 Mac App Store：主机端不行，客户端可以但意义不大

- **主机端需要虚拟音频驱动，而这两条路都走不通：**
  - HAL 插件（本项目用的方式）必须装到 `/Library/Audio/Plug-Ins/HAL`，需要管理员权限，
    沙盒应用做不到；审核指南 2.4.5 也不允许 App Store 应用另行安装驱动或附加代码。
  - AudioDriverKit 驱动扩展可以随 App Store 应用分发，但需要 Apple 授予
    `com.apple.developer.driverkit.family.audio` 权限。开发者论坛上 Apple 方面的回复是：
    AudioDriverKit 不支持纯虚拟音频设备，这类驱动不会获批，应继续用 HAL 插件。
    这是论坛回复，不是正式文档，最终以 Apple 的权限申请结果为准。
- **自动发现**在 App Store 沙盒里也受限：沙盒应用很可能读不到 Tailscale 的本地 API，
  只能让用户手动输入主机名（MagicDNS 名称）。
- **结论**：用 Developer ID 签名 + 公证，在 App Store 外分发（官网下载 .dmg 或 .pkg）。
  这是 Loopback、BlackHole 等虚拟音频软件的通行做法。
  如果以后一定要上 App Store，可以只上架客户端，主机端仍在外部分发。

## 分阶段计划

1. **概念验证**（当前）：驱动 + `remotemic-feed` 测试工具。验证主机应用能听到，而 UU 客户端听不到。
2. **打通链路**：客户端采集麦克风 → Opus → UDP → 主机解码 → 驱动。
3. **统一应用**：SwiftUI 菜单栏应用，角色切换、Tailnet 自动发现、主机端"选择一台/混合"。
4. **打磨发布**：时钟漂移补偿、断线重连、开机自启、签名公证、安装包与卸载。

## 第 3 阶段：菜单栏应用（App/）

- **一个应用，两种角色**：首次点开选「发送」或「接收」，之后可在底部「切换角色」。
- **接收端**
  - 显示本机地址：优先 Tailnet IP，没有就用局域网 IP；一键复制 `IP:47810`。
  - 新发送端第一次连接时弹出「允许 / 拒绝」，显示设备名和公钥指纹；决定会被记住。
  - 模式：「只听一台」（单选）或「混合全部」（多人同时说话时软限幅）；每台可单独静音、移除。
  - 驱动随应用打包；未安装、版本不符或未加载时提示安装（管理员授权），装完自动恢复原来的默认输入。
  - 运行时阻止系统空闲睡眠。
- **发送端**
  - 自动发现：读 Tailscale 状态拿到在线的 Mac，向每台发 discover；同时在局域网广播。也可手动输入地址。
  - 同一时间只绑定一个接收端（以后可以保存多个、一键切换）。
  - 麦克风开关：暂停时完全停止采集（橙色指示点熄灭）；可选输入设备。
  - 连接状态：连接中 / 等待允许 / 正在被收听 / 接收端在听另一台 / 被拒绝 / 密钥变化。
  - 名称被代理解析成 198.18.x.x 时给出警告。
- **两端都有**：开机自动打开（SMAppService）、退出。

### 加密与认证

- 每台 Mac 一把长期 X25519 密钥（`~/Library/Application Support/RemoteMic/identity.key`，权限 0600）。
- 每次会话发送端随机生成 salt，音频密钥 = HKDF(X25519(发送端, 接收端), salt)；音频用 ChaCha20-Poly1305 加密，序号做 nonce。
- 接收端只接受**用户允许过的公钥**发来的音频，只有持有对应私钥的设备能产生可解密的包。
- 发送端首次连接时记住接收端公钥（TOFU），之后公钥变化会警告。两端都显示指纹，可以人工核对。
- 局域网和 Tailnet 一样加密。

### 已知限制（第 4 阶段）

- ~~丢包没有补偿~~ → v0.3：每个包附带前 2 帧（冗余），接收端用抖动缓冲按序解码，连续丢 3 帧以上才用 Opus PLC 补；自测 ~9% 丢包补偿后 <1%。
- 时钟漂移只靠「积压超过 200 ms 跳到最新」处理，没有平滑重采样。
- 用 Command Line Tools 编译，SwiftUI 不能用 `@State` 宏；正式版用 Xcode 构建 + Developer ID 签名公证。

## 注意

- 主机不在身边：更新驱动只重启声音服务（`sudo killall coreaudiod`），不要重启电脑（FileVault）。
- 关掉 UU 远程的"远程通话/远程麦克风"功能，否则 UU 会读主机的默认输入，即 RemoteMic。
- 卸载：`sudo ./uninstall.sh`。

## 参考

- [How to implement and publish virtual audio driver to Apple App Store?](https://developer.apple.com/forums/thread/689617)
- [AudioDriverKit Extension for Virtual Devices?](https://developer.apple.com/forums/thread/682035)
- [Virtual Audio Device driver porting from CoreAudio to DriverKit](https://developer.apple.com/forums/thread/709883)
- [WWDC21: Create audio drivers with DriverKit](https://developer.apple.com/videos/play/wwdc2021/10190)
- [Three ways to run Tailscale on macOS](https://tailscale.com/kb/1065/macos-variants)
