# Antigravity 多开管理器 0.3.0

适用：Apple Silicon（M 系列）Mac，macOS 13 或更新版本。本工具是本机图形化管理器；安装包不包含 Google Antigravity 程序。

## 安装与使用

从 [Releases](https://github.com/bcblr1993/antigravity-multiplexer/releases) 下载 Apple Silicon 安装包，解压后将 `Antigravity 多开管理器.app` 放入“应用程序”。电脑还需安装官方 Apple Silicon 版 `Antigravity.app`。打开管理器后：

- “创建实例”：按原来的 Second、Third…英文序数命名。新实例有自己的 `.gemini-N`、窗口缓存、日志、凭据标识、应用与 Helper 身份、登录回调。创建完成会打开独立登录页；Google 登录由你在新窗口完成。
- “升级全部”：列出所有低于官方原版版本的实例（已领先原版的副本不会被降级），先构建并验签全部新程序，再关闭待升级实例，为每个实例备份旧程序、`.gemini-N` 和窗口数据，最后逐个替换程序。账号目录保持原路径，凭据标识及 Bundle ID 保持不变。请先保存各实例中的工作。
- “查看备份”：在访达中打开升级备份。备份位于 `~/Library/Application Support/Antigravity Multiplexer/Backups/`，按每次升级的时间分组。确认升级后账号和项目正常之前，不要清理备份。
- 每个实例右侧“…”可定位应用、查看日志。管理器保存新实例的版本与人工登录验收状态，不保存账号凭据。
- “检查更新”可随时查看管理器的新版本；默认每天自动检查、下载并在适当时机安装。齿轮按钮可以关闭自动更新。更新只替换管理器应用，不改写实例或账号目录。

从 0.2.1 升级到 0.3.0 需要手动安装一次；之后可通过应用内的更新入口升级。若管理器在 `/Applications` 中，安装更新时 macOS 可能要求授权。

创建与升级只接受已适配、完整签名的官方 Apple Silicon 原版。目前已验证的源程序版本是 2.15.1 和 2.16.0；若官方更新到新版本，管理器会停止创建和升级，需先适配并验证该版本。生成的副本关闭自动更新，升级统一从管理器执行。

## 已做的验证

- 图形界面实际创建第八实例，确认独立登录页、运行参数指向 `~/.gemini-7`、独立协议以及重复打开时只有一个主进程；后来按要求改名为 Antigravity Eighth。
- 从官方 2.16.0 Apple Silicon 安装包构建测试副本，签名和独立登录页检查通过。
- 对 Eighth 执行 2.15.1 → 2.16.0 的实际升级，旧程序和数据打包备份，原凭据标识和回调保留。对照备份，运行期的日志和缓存有变化，未发现账号文件缺失。
- 使用两份未登录的临时实例验证批量升级：两份均从 2.15.1 升到 2.16.0，数据目录文件与备份一致。测试实例已清理，原有其他实例未批量升级。
- 其余六个旧实例已完成 2.16.0 的构建与深度签名预检；未替换它们。真实已登录账号在跨版本升级后的保持情况仍需实际验收。

## 签名与边界

管理器为 ARM64 原生应用，正式安装包使用 Developer ID Application 签名并提交 Apple 公证。生成的 Antigravity 副本仅在本机使用 ad-hoc 签名，系统隐私权限可能要求每个实例单独授权；它们不是经过 Apple 公证的公开分发包。

Google 当前条款限制复制或修改其软件；此工具只打包自有管理器代码和本机适配逻辑，不附带也不分发 Google 程序。对外分发或商用前，请先确认 Google 授权与当前条款：https://policies.google.com/terms?hl=en 、https://antigravity.google/terms 。

仓库包含 SwiftUI 界面、Python 创建/升级引擎、图标与 `build.sh`。在源码目录执行 `./build.sh` 可本地重建；设置 `SIGN_IDENTITY` 环境变量可指定自己的代码签名身份。构建需要 Xcode 命令行工具和 SwiftPM；运行管理器需要 `/usr/bin/python3`、`codesign` 和 `ditto`。在线更新使用 [Sparkle 2](https://sparkle-project.org/)；公开的 Release 包由 Developer ID 与 Sparkle EdDSA 双重签名，私钥仅存于发布者的钥匙串。

## 发布后续版本

递增 `Info.plist` 中的 `CFBundleShortVersionString` 和 `CFBundleVersion`，更新 `RELEASE_NOTES.md`，保持 Bundle ID、`SUPublicEDKey` 与钥匙串中的 `AntigravityMultiplexer` 更新签名密钥不变。发布者在本机运行：

```sh
export SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-notarytool-profile'
./scripts/package-release.sh
```

脚本会构建 Apple Silicon 应用、签名、公证、附加票据并生成 `dist/` 下的 ZIP、`appcast.xml` 与 `SHA256SUMS.txt`。将版本提交并打 `v版本号` 标签后，把这三个文件上传到同版本 GitHub Release；先用草稿验证下载与校验和，再公开发布，确保该 Release 是最新正式版。应用从 `releases/latest/download/appcast.xml` 读取更新清单。不要把私钥或公证凭据提交到仓库；仅公开签名公钥。

本仓库不包含 Google Antigravity 程序，也不提供任何账号、凭据或用户数据。仅公开可审阅的管理器源码；第三方软件和标识的权利属于各自所有者。
