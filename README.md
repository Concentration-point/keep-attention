# keep-attention

原生 SwiftUI macOS 菜单栏/浮层工具，用 Orca 终端状态和 DeepSeek 四段式摘要帮助快速了解各终端进度。

## 环境要求

- macOS 14+
- Swift 6 / Swift Package Manager
- 纯 Command Line Tools 也可构建、运行和执行测试；不需要 Xcode 工程
- 运行时需要 `/usr/local/bin/orca`；DeepSeek 总结需要设置 `DEEPSEEK_API_KEY`

## 构建与测试

开发构建：

```sh
swift build
```

发布构建：

```sh
swift build -c release
```

测试必须使用独立 Swift Testing 可执行 runner（纯 CLT 下真实执行，不使用只编译 `.xctest` 的 `swift test`）：

```sh
swift run keep-attention-tests
```

该命令会逐项打印 `✔ Test ... passed`，末行打印实际执行统计，例如 `Test run with 35 tests in 6 suites passed`。

## 三种启动方式

### 1. 开发期启动

```sh
DEEPSEEK_API_KEY=sk-... swift run keep-attention
```

不配置 API Key 时应用仍会启动，摘要区域显示“未配置 API Key”。如果 Orca 尚未运行，浮层显示 Orca 不可用或暂无终端，不会崩溃。

### 2. 直接启动 release 二进制

```sh
swift build -c release
DEEPSEEK_API_KEY=sk-... .build/arm64-apple-macosx/release/keep-attention
```

如果使用 Intel Mac，请将路径中的 `arm64-apple-macosx` 替换为 SwiftPM 实际生成的目标目录。

### 3. 打包为 `.app` 后启动

```sh
DEEPSEEK_API_KEY=sk-... ./scripts/make-app.sh
open ./keep-attention.app
```

脚本会先执行 `swift build -c release`，然后生成 `keep-attention.app/Contents/Info.plist` 和 `Contents/MacOS/keep-attention`；`LSUIElement=true`，因此应用只显示菜单栏/浮层，不占 Dock。该 bundle 不签名、不公证，适合本机自用；首次运行可能需要在系统设置中允许来自未签名开发者的应用。

如需开机自启，可在登录项中添加 `keep-attention.app`，或自行编写 launchd LaunchAgent，注意在 plist 的 `EnvironmentVariables` 中配置 `DEEPSEEK_API_KEY`。

## 配置

- 轮询间隔默认 5 秒，可在展开面板设置中调整并持久化到 `UserDefaults`。
- DeepSeek 模型固定为 `deepseek-v4-flash`，请求使用 JSON Output。
