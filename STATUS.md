# 当前状态（唯一全局状态入口）

更新时间：2026-10-21（Asia/Shanghai）。阶段：正式项目的架构、治理及目录基础；尚无产品运行代码。

## 进展与边界

- 本地 Git 分支 `codex/project-foundation`，未关联远程、未推送；未改动 Ali 或实验项目。
- 产品/技术方向已整理为可演进工作草案，规范集中定义行为，架构解释组织；历史提案、评审和实验快照保留。
- 已按结构评审调整 owner/事务/协议边界、核心/缓存资源配额和少量计划 targets 的目录。
- README/HANDOFF/目录说明不再复制状态；后续只在本文件维护全局进度。
- RC-1 是待验证的显式完整结果取回候选，不是已上线接口或原生 Codex 自动续传能力。

## 下一步

[M1 持久执行切片](docs/changes/foundation-runtime/proposal.md) / [任务](docs/changes/foundation-runtime/tasks.md)：确定真实 Swift 包/工具链/SQLite 原子事务实现，验证准入 → intent → ID 屏障 → 最终化 → 重启 pending/exposure。按 [owner 表](docs/architecture/ownership.md) 落实依赖和结束责任。

在重型缓存实现前先核实 [RC-1](docs/specs/recovery-contract.md) 的客户端可行性。若原生目标客户端不能使用，应及时沟通显式恢复客户端或其他方案，不能仅靠缓存存储成功宣称恢复功能交付。

## 尚待实现

Swift 包及依赖锁、进程/数据面、账号授权/刷新与账号池、事务/缓存/加密、管理 API/前端、正式 CI/镜像/Compose 和产品级恢复/长压验收。驱动、加密库、UI 组件和容量默认值按实际切片选择；无产品构建、协议、性能或安全测试通过结论。

## 可运行检查

```sh
python3 scripts/check_docs.py
```

只检查文档结构和本地文件链接，排除依赖/构建目录，不锁定业务目录或活动变更名。其他构建/测试命令待相应实现加入，不臆造启动说明。

## 最新验证

本次变更的实际命令、结果及未覆盖范围见 [验证记录](docs/changes/refine-architecture-governance/verification.md)。原型的 13/11 项及 live 证据只属于 [实验来源](docs/evidence/README.md)，不等于正式项目通过。

## 风险与需沟通事项

恢复客户端契约尚未验证；RC-1 涉及私有扩展头，普通客户端不会因此自动具备恢复能力。它不阻止 M1 持久执行骨架开始，但必须在缓存重型建设和发布前解决。业务范围与技术方案均允许调整；遇到不可行或更优方案时提供证据和取舍，不为守旧草案硬做。
