# 实验验证来源与适用范围

原项目：[ximatai/codexone](https://github.com/ximatai/codexone)，基准提交 `3af8a52fe131b81cbe1a5ca043eaf14e7cbe9bb5`。本地原型曾位于 `/Users/liurui/develop/workspace-github/codexone`；接手不要求该路径存在。

已复制 [报告](prototype/EXPERIMENTS.md)、[原型协议范围](prototype/PROTOCOL-VALIDATION.md)、原 README 和经过选择的无凭证 JSON；见 [SHA256 清单](prototype/MANIFEST.md)。不复制日志、真实 PNG、登录文件、运行目录、构建缓存或原型源码。报告中的实验参数/失败基线只解释实验，不能直接成为正式默认。

## 能证明与不能证明

- 原型 macOS 及 Linux amd64 合成传输 13 项，协议契约 11 项；Vapor 高层 HTTP 两项断连失败基线保留，未抹平。
- macOS Codex CLI 0.163.0 实测过文本、工具、续接、长输入、V2 压缩及原生 Images generation；真实运行不等于 Linux live 覆盖。
- 不证明正式目录已编译、账号 OAuth/刷新、多账号归属、幂等财务、持久恢复、缓存加密、长期容量或 ARM/systemd。

历史文件中的实验源码相对链接仍指向原型布局，当前快照不提供运行源码。架构 6 份初始文档从原项目未提交的 architecture 工作区迁入，属于 2026-10-21 设计产物，不声称包含在上述源码提交；其中当前 ARCHITECTURE 为设计基线，旧提案/评审为历史参考。

架构迁入快照共 6 份，迁入时已逐字节核对一致；正式项目后续修改当前架构与意见汇总时，应更新规范/ADR，历史提案和评审原稿继续保留。
