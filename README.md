<div align="center">

# CodexSwitch DS

### 在 macOS 菜单栏切换 Codex 的 GPT、DeepSeek 与智谱 GLM

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.8%2B-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Version](https://img.shields.io/badge/version-1.1-2F81F7)](Info.plist)
[![License](https://img.shields.io/badge/license-MIT-3DA639)](LICENSE)
[![Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen)](#项目结构)

一个简单的 macOS 菜单栏工具，用来选择 Codex 当前使用 **GPT**、**DeepSeek**（V4 Flash / V4 Pro / V4 Flash Vision）或 **智谱 Bigmodel GLM**（GLM-5.3-Flash / GLM-5.3）。

</div>

## 主要功能

- 点击菜单栏图标，在 GPT / DeepSeek 三档 / 智谱 GLM 两档之间切换。
- 菜单栏按当前提供商显示官方图标的单色简化版：GPT 用 OpenAI 花形外加圆角框（与官方 ChatGPT 客户端图标区分），DeepSeek 用鲸鱼轮廓，智谱用 Z.ai 的 Z 字标，自动适配深浅色菜单栏；具体模型悬停即可查看。
- 「思考程度」菜单可调节 `model_reasoning_effort`（low / high / max），两家模型通用。
- 每家提供商使用独立的 API Key，第一次切换时弹窗引导输入。
- 切换过程不弹出终端，也不显示 Dock 图标。
- 切换前保存 GPT 配置，切回 GPT 时完整恢复。
- DeepSeek 使用原生 Responses API；智谱使用官方 Codex 专属 Response 协议端点，均不需要本地代理。
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
2. 打开 `SwitchCodex.app`，按提示输入 DeepSeek API Key（可在 [DeepSeek 开放平台](https://platform.deepseek.com/api_keys) 创建）。
3. 要用智谱模型时，先通过菜单「修改智谱 Bigmodel API Key…」输入（在 [open.bigmodel.cn](https://open.bigmodel.cn) 用户中心的 API Keys 页面创建）；直接点击智谱模型项也会自动引导输入。
4. 点击菜单栏图标，选择任一模型。
5. 切换后重启 Codex，或新建一个任务。

## 六种模式

| 选项 | 提供商 | 实际使用的配置 |
| --- | --- | --- |
| GPT | OpenAI | 恢复原来的 GPT 配置 |
| DeepSeek V4 Flash | DeepSeek | `deepseek-v4-flash` |
| DeepSeek V4 Pro | DeepSeek | `deepseek-v4-pro` |
| DeepSeek V4 Flash Vision（实验） | DeepSeek | `deepseek-v4-flash-vision-exp` |
| GLM-5.3-Flash（智谱） | 智谱 Bigmodel | `glm-5.3-flash` |
| GLM-5.3（智谱） | 智谱 Bigmodel | `glm-5.3` |

- DeepSeek Flash / Pro / Vision 上下文均为 1M（1048576 tokens），Vision 为支持图像输入的实验版本。
- 智谱两款模型均为 1M 上下文、思考强制开启，工具写入的 `model_reasoning_effort` 即官方的调节入口（low / high / max，默认 high）。
- GLM-5.3-Flash 支持图像输入，是 GLM-5 系列首个原生多模态模型。
- 同一提供商内部切换只改 `model` 一行；跨提供商切换从干净的 GPT 快照重新生成整套配置，互不残留。

配置文件位于：

```text
~/.codex/config.toml
```

## 与其他项目的区别

| 项目 | 适合什么需求 | CodexSwitch DS 的不同 |
| --- | --- | --- |
| [CodexModelSwitcher](https://github.com/hieunc229/CodexModelSwitcher) | 管理多个 Provider、模型和 OpenAI 账户 | CodexSwitch DS 聚焦 GPT / DeepSeek / 智谱六档，更简单 |
| [DS4 Control](https://github.com/notatestuser/ds4-control) | 在高内存 Mac 上运行本地 DeepSeek V4 | CodexSwitch DS 使用云端 API，不需要下载大型模型 |
| [codex-shim](https://github.com/sybil-solutions/codex-shim) | 把更多第三方模型接入 Codex | CodexSwitch DS 不运行本地服务器，也不修改 Codex 应用 |
| [CC Switch](https://github.com/farion1231/cc-switch) | 管理多种 AI 编程工具、Provider、MCP 和 Skills | CodexSwitch DS 是轻量、单用途的 macOS 工具 |

简单来说：如果你只需要在自己的 Mac 上切换 **GPT / DeepSeek / 智谱 GLM**，CodexSwitch DS 会更直接。

## 数据与安全

DeepSeek 与智谱的 API Key 只保存在本机。相关配置文件会设置为 `600` 权限，即仅当前用户可读写。

```text
~/.codex/switchcodex/
├── settings.json
├── gpt-config.toml
├── deepseek-config.toml
└── bigmodel-config.toml
```

当前版本尚未使用 macOS Keychain，不建议在多人共用电脑上保存长期有效的 API Key。注意：智谱团队套餐 Key 与平台普通 API Key 不通用，请按你的计费方式选择正确的 Key。

## 当前说明

- 切换模型后，已经打开的 Codex 通常需要重启或新建任务。
- 当前安装包使用 ad-hoc 签名，适合本人电脑使用，尚未进行 Apple 公证。
- 项目展示名称为 **CodexSwitch DS**，当前应用文件名仍为 `SwitchCodex.app`，避免影响已有安装。

## 切换生效与桌面端限制

- 同提供商内切换（如 Flash ⇄ Pro ⇄ Vision）：只改 `model` 一行；新开任务即生效，无需退出 Codex，已打开的任务仍使用旧模型。
- 跨提供商切换（GPT / DeepSeek / 智谱之间）：切换提供商、鉴权方式和模型目录；桌面端在启动时缓存配置、创建任务时绑定提供商，需要退出并重开 Codex 后新建任务才生效。
- 桌面模型选择器不显示这些第三方模型是 Codex 桌面端的通用限制（前端过滤本地 `model_catalog_json` 模型、模型列表不含提供商标识），与 macOS 无关；本工具通过直接修改 `config.toml` 绕过，使用的是官方配置键，安全且可回退。
- 应用升级时会自动把内置的最新 `models.json` 同步到 `~/.codex/`，保证新增模型有完整元数据。
- 不推荐修改桌面应用本体；如需在界面内直接选择模型，建议等待官方支持。

## 命令行模式（可选）

```bash
SwitchCodex --state
SwitchCodex --set gpt
SwitchCodex --set flash          # deepseek-v4-flash
SwitchCodex --set pro            # deepseek-v4-pro
SwitchCodex --set vision         # deepseek-v4-flash-vision-exp
SwitchCodex --set glmflash       # glm-5.3-flash
SwitchCodex --set glm            # glm-5.3
SwitchCodex --effort low|high|max
```

也可以直接传完整模型 slug。可选参数 `--key <DeepSeek Key>` / `--bkey <智谱 Key>` 用于自动化场景。日常使用不需要打开终端。

## 项目结构

```text
switchcodex/
├── Sources/main.swift
├── Assets/models.json
├── Assets/AppIcon.icns
├── Assets/menu-gpt.svg          # 菜单栏 GPT（OpenAI）图标
├── Assets/menu-deepseek.svg     # 菜单栏 DeepSeek 鲸鱼图标
├── Assets/menu-bigmodel.svg     # 菜单栏智谱 Z.ai 图标
├── Info.plist
├── build.sh
├── LICENSE
└── README.md
```

## 参考文档

- [DeepSeek：在 Codex 中接入 DeepSeek](https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex)
- [智谱 BigModel 接入文档](https://docs.bigmodel.cn/cn/api/introduction)
- [智谱：在 Codex 中使用 GLM](https://docs.bigmodel.cn/cn/coding-plan/tool/codex)
- [OpenAI：Codex 配置参考](https://developers.openai.com/codex/config-reference/)

## License

本项目采用 [MIT License](LICENSE)。
