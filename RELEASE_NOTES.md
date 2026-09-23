# v0.3.0

## 新增

- 管理器界面和应用菜单增加“检查更新”，可下载并安装新版管理器。
- 默认每天自动检查、下载并在适当时机安装；可在齿轮设置中关闭。
- 更新包由 Developer ID 签名、Apple 公证，并使用 Sparkle EdDSA 签名验证。

## 验证

- Apple Silicon 构建、深度签名检查、Apple 公证与 Gatekeeper 检查通过。
- 发布包与 appcast 版本、下载地址、签名元数据已核对。

0.2.1 没有内置更新器，需要手动安装 0.3.0 一次。在线更新只替换管理器，不修改已有 Antigravity 实例或账号目录。Google Antigravity 程序不包含在安装包中。
