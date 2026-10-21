# CodexOne 架构工作草案

本文件描述结构与取舍，不记录实现进度。产品边界见 [产品草案](../requirements/product.md)，行为契约以 [规范](../specs/README.md) 为唯一来源；方案可凭新证据按 [治理](../governance.md) 调整。验证结果与下一步只见 [STATUS](../../STATUS.md)。

## 定位与技术方向

自托管的 Codex/Responses 网关，以身份隔离、协议连续性、可解释治理与故障恢复为重点。采用 Swift 模块化单体：NIO 数据面、Vapor 管理面、AHC 上游，SQLite 单节点；管理台 TS/React/Vite 静态 SPA，Linux amd64 OCI/Compose。理由见 [ADR 0001](../decisions/0001-stack-and-topology.md)，实验依据见 [evidence](../evidence/README.md)。

原型的 Linux CI 和 macOS 真实 CLI 结果只属于原型，不能推导本项目通过。CLI 是外部测试客户端，服务器直接调用上游。原型特殊配置与双入口限制不作为生产默认。

## 模块与依赖

```mermaid
flowchart TD
  Main[CodexOne 组装入口] --> Runtime[CodexOneRuntime 寿命监督]
  Main --> Adapters[CodexOneAdapters 外部边界]
  Main --> Core[CodexOneCore 业务核心]
  Runtime --> Core
  Adapters --> Core
```

四个名称表达起始编译边界，具体 targets 在包切片中验证，不以空目录决定额外库。Core 内 Domain 表达状态与规则，Application 协调授权/准入/绑定/结算。Adapters 内分客户端协议、传输、上游 wire、持久化和管理 API；Runtime 管理有限任务、启动和关闭。入口注入具体实现，避免 Runtime/Adapters 互相 import。

[目录约定](../development/layout.md) 定义文件归属；[owner 与端口](ownership.md) 定义谁调用谁、持有什么状态，以及结束责任。网络 channel、SQL row、Vapor Request 不进入核心签名；不预建通用 AI schema 或插件 DSL。

## 请求与数据流

客户端解析/能力校验 → Core 应用命令 → 原子持久准入 → 提供者适配 → 语义证据 → 归属提交后输出 → 最终化/迟到证据。

客户端 wire 和提供者 wire 分开演进：客户端扩展字段留在有界协议层，上游适配器提供对象/usage/终态/拒绝证据，Core 决定授权与结算。透明数据仍需能力分类，不能以透传绕过未知对象/控制语义。

执行/WS 状态机、ID 暴露屏障和最终化的完整条款见 [execution-lifecycle](../specs/execution-lifecycle.md)；身份/刷新见 [identity](../specs/identity.md)，重试/模式见 [protocol](../specs/protocol.md)。本文件不复制第二份状态转移规则。

<a id="91-短期正文恢复缓存用户已确认首发"></a>

## 持久化、治理与恢复

核心库保存身份、策略、准入、归属和账本；恢复库保存可降级的加密正文。二者不做伪跨库事务，核心结算优先于缓存负载；资源隔离设计见 ownership。SQLite 的单节点限制、备份/旧快照恢复与保留条款见 [operations](../specs/operations.md)。

用量工作假设是兼容优先资源治理：预留与实际证据分开，不把有限执行数量宣称为绝对 token/金额上限，完整算法见 [usage](../specs/usage.md)。

短期恢复缓存的动机见 [ADR 0003](../decisions/0003-bounded-recovery-cache.md)，存储安全见 [recovery-cache](../specs/recovery-cache.md)。[RC-1 候选契约](../specs/recovery-contract.md) 先验证“同一执行完整结果取回”，避免先堆缓存再发现客户端无法使用；它不是已验证的 Codex 自动续传能力。断点续播与透明重执行不隐含在缓存承诺中。

## 管理与发行

管理台按账号、Key/策略、用量/请求、恢复/运维能力聚合。最小管理 API 先明确错误、ID、日期、单位、继承和 secret write-only 契约，前端不复制后端领域模型。管理同源/代理与认证边界在首个管理入口验证；见 [control-plane](../specs/control-plane.md)。

镜像由 CI 构建，弱服务器只运行；安全维护、恢复演练和容量证据属于发行验收，见 operations。路线是 [里程碑草案](../plans/roadmap.md)，执行顺序可随依赖和实验调整。

## 演进触发

第二个真实上游、实际编译/依赖污染、SQLite 写等待、多节点需求或新的恢复契约，都可触发新方案；先给证据与代价，再调整 ADR 和受影响规范。不要为假设扩展预建服务，也不要把原方案当作不能讨论的限制。
