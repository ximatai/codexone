# 模型目录透传：以提供者条目为准

日期：2026-10-30。用户要求终端无感：Desktop/CLI 使用体验与直连标准 Codex 服务一致。本提案改变 [P16](../../specs/protocol.md) 的“网关合成目录”方向，延续[开放协议透传](../open-protocol-passthrough/proposal.md)的原则。

## 问题

`GET /models?client_version=` 的 Codex 条目由网关按少量 profile 字段拼装，其余字段写死：`shell_type=unified_exec`、`supports_search_tool=false`、仅文本输入（除非 visionInput）、固定截断策略与 3/4 自动压缩阈值、`support_verbosity=false`，且丢弃提供者条目中的其他成员（工具类型、apply_patch 类型、reasoning summary 默认值、speed/service tier、model_messages 等）。Desktop 依据目录决定提供哪些工具、何时压缩和发送哪些参数，因此与提供者实际目录不同的条目会让客户端行为偏离直连（例如提供者为 `shell_command` 而网关声明 `unified_exec`，搜索工具被隐藏）。目录指导上限 32 KiB 也低于提供者当前指导长度。

## 新契约

- 受信 profile 快照条目可携带 `upstream`：提供者 Codex 目录中该模型的原始条目对象（管理员离线采集）。存在时，Codex 目录条目以它为准原样输出，网关只覆盖自身职责字段：
  - `slug` 必须等于配置模型 ID（不符拒绝启动）；`priority` 取配置顺序；
  - 无视觉权限（`visionInput` 非 true）时从 `input_modalities` 移除 `image`；
  - 未启用原生 WS（`upstreamTransport` 非 `websocket`）时 `prefer_websockets=false`；
  - 附加 `codexone_profile` 来源信息。
- `upstream` 条目须含非空字符串 `base_instructions`；单条目上限 256 KiB，快照文件上限提升至 4 MiB，模型上限仍为 32。其余成员不做白名单校验，未知成员原样输出。
- 旧 `catalog` 形式保留兼容（合成行为不变），同一条目不得同时给出 `catalog` 与 `upstream`；部署内联 `catalog` 覆盖规则不变。
- 提供 `scripts/import_model_profiles.py`：把管理员保存的提供者目录 JSON（含 `models` 数组）按选定模型 ID 转换成 0600 私有快照，不联网、不读取个人客户端配置。

## 不变项与排除

目录不授予权限；模型白名单、视觉/生图权限、准入与账本不变。普通 OpenAI `data` 列表不变。不做运行时联网拉取目录（另立变更）；不改变 schema、管理面与恢复语义。目录内容与指导仍进入策略版本，计价版本不变。

## 验收

- 单元：`upstream` 条目原样输出（含未知成员），覆盖字段正确；slug 不符、缺指导、超限、`catalog`+`upstream` 并存均拒绝启动；旧 `catalog` 行为不变。
- socket：HTTP 两种前缀的 `/models?client_version=` 返回透传条目；`verify_protocol.py` 等现有脚本通过。
- 部署后以真实 Desktop 发现并采用该目录（另经用户授权）。
