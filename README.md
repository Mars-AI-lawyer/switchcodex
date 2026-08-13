<div align="center">

# CodexSwitch DS

### 在 macOS 菜单栏切换 Codex 的 GPT 与 DeepSeek

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.8%2B-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Version](https://img.shields.io/badge/version-1.0.1-2F81F7)](Info.plist)
[![License](https://img.shields.io/badge/license-MIT-3DA639)](LICENSE)
[![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](#项目结构)

一个简单的 macOS 菜单栏工具，用来选择 Codex 当前使用 **GPT**、**DeepSeek V4 Flash** 还是 **DeepSeek V4 Pro**。

</div>

## 主要功能

- 点击菜单栏图标，打开 GPT / Flash / Pro 三档菜单。
- 菜单栏显示当前模型：`GPT`、`DS·F` 或 `DS·P`。
- 切换过程不弹出终端，也不显示 Dock 图标。
- 切换前保存 GPT 配置，切回 GPT 时完整恢复。
- 使用 DeepSeek 原生 Responses API，不需要本地代理。
- 原生 Swift 编写，没有第三方依赖。
- 支持开机自启。

## 使用方法

### 1. 编译并安装

```bash
./build.sh
```

应用会安装到：

```text
/Applications/SwitchCodex.app
```

### 2. 第一次启动

1. 首次使用前，建议先让 Codex 处于 GPT 状态。
2. 打开 `SwitchCodex.app`。
3. 输入 DeepSeek API Key，可在 [DeepSeek 开放平台](https://platform.deepseek.com/api_keys) 创建。
4. 点击菜单栏图标，选择 GPT、Flash 或 Pro。
5. 切换后重启 Codex，或新建一个任务。

## 三档模式

| 选项 | 实际使用的配置 |
| --- | --- |
| GPT | 恢复原来的 GPT 配置 |
| DeepSeek V4 Flash | `deepseek-v4-flash` |
| DeepSeek V4 Pro | `deepseek-v4-pro` |

配置文件位于：

```text
~/.codex/config.toml
```

## 与其他项目的区别

| 项目 | 适合什么需求 | CodexSwitch DS 的不同 |
| --- | --- | --- |
| [CodexModelSwitcher](https://github.com/hieunc229/CodexModelSwitcher) | 管理多个 Provider、模型和 OpenAI 账户 | CodexSwitch DS 只保留 GPT 与 DeepSeek 三档，更简单 |
| [DS4 Control](https://github.com/notatestuser/ds4-control) | 在高内存 Mac 上运行本地 DeepSeek V4 | CodexSwitch DS 使用云端 API，不需要下载大型模型 |
| [codex-shim](https://github.com/sybil-solutions/codex-shim) | 把更多第三方模型接入 Codex | CodexSwitch DS 不运行本地服务器，也不修改 Codex 应用 |
| [CC Switch](https://github.com/farion1231/cc-switch) | 管理多种 AI 编程工具、Provider、MCP 和 Skills | CodexSwitch DS 是轻量、单用途的 macOS 工具 |

简单来说：如果你只需要在自己的 Mac 上切换 **GPT / DeepSeek Flash / DeepSeek Pro**，CodexSwitch DS 会更直接。

## 数据与安全

DeepSeek API Key 只保存在本机。相关配置文件会设置为 `600` 权限，即仅当前用户可读写。

```text
~/.codex/switchcodex/
├── settings.json
├── gpt-config.toml
└── deepseek-config.toml
```

当前版本尚未使用 macOS Keychain，不建议在多人共用电脑上保存长期有效的 API Key。

## 当前说明

- 切换模型后，已经打开的 Codex 通常需要重启或新建任务。
- 当前安装包使用 ad-hoc 签名，适合本人电脑使用，尚未进行 Apple 公证。
- 项目展示名称为 **CodexSwitch DS**，当前应用文件名仍为 `SwitchCodex.app`，避免影响已有安装。

## 切换生效与桌面端限制

- Flash ⇄ Pro：属于同一提供商，只改 `model` 一行；新开任务即生效，无需退出 Codex，已打开的任务仍使用旧模型。
- GPT ⇄ DeepSeek：切换提供商、鉴权方式和模型目录；桌面端在启动时缓存配置、创建任务时绑定提供商，需要退出并重开 Codex 后新建任务才生效。
- 桌面模型选择器不显示 Flash/Pro 是 Codex 桌面端的通用限制（前端过滤本地 `model_catalog_json` 模型、模型列表不含提供商标识），与 macOS 无关；本工具通过直接修改 `config.toml` 绕过，使用的是官方配置键，安全且可回退。
- 不推荐修改桌面应用本体；如需在界面内直接选择模型，建议等待官方支持。

## 命令行模式（可选）

```bash
SwitchCodex --state
SwitchCodex --set gpt
SwitchCodex --set flash
SwitchCodex --set pro
```

日常使用不需要打开终端。

## 项目结构

```text
switchcodex/
├── Sources/main.swift
├── Assets/models.json
├── Assets/AppIcon.icns
├── Info.plist
├── build.sh
├── LICENSE
└── README.md
```

## 参考文档

- [DeepSeek：在 Codex 中接入 DeepSeek](https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex)
- [OpenAI：Codex 配置参考](https://developers.openai.com/codex/config-reference/)

## License

本项目采用 [MIT License](LICENSE)。
