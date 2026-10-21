# 架构取舍与评审索引

本文件解释设计来源，不记录全局完成状态；进度见 [STATUS](../../STATUS.md)。产品与技术方向都是可修订工作基线，ADR 保存采用或替代的理由。

## 设计来源

[独立提案](PROPOSED-ARCHITECTURE.md)、[首轮评审](ARCHITECTURE-REVIEW.md)、[聚焦复核](ARCHITECTURE-REVIEW-FOLLOWUP.md) 是有日期的历史设计证据；[中长期结构审查](../reviews/2026-10-21-architecture-and-layout.md) 解释后续组织风险。历史意见不自动成为规范，旧“默认不保存正文”建议由限期限量缓存方案取代。

## 保留的判断

- 模块化单体和 SQLite 优先服务弱服务器；NIO 掌握数据面寿命，Vapor 承担管理业务，CLI 只做测试客户端。
- 客户端与上游协议分开演进，核心围绕身份/执行/用量证据而非通用模型 DTO。
- 核心结算、ID 归属和可丢弃缓存具有不同可靠性责任；Runtime 是寿命监督，不是全局业务服务。
- 治理预留不是绝对费用保证；恢复正文不是重执行授权，客户端恢复契约先于重型缓存建设。
- 规范独占行为规则，架构说明组织，状态集中；常规工程决定自主，重大行为/边界变化及时沟通。

## 审查意见的设计归属

| 意见 | 设计入口 |
|---|---|
| R1 可用恢复路径 | [recovery-contract](../specs/recovery-contract.md) |
| R2 单一行为来源 | [specs](../specs/README.md)、[governance](../governance.md) |
| R3 owner/事务 | [ownership](ownership.md) |
| R4 wire 边界 | [architecture](ARCHITECTURE.md)、[layout](../development/layout.md) |
| R5 核心/缓存配额 | ownership、[缓存规范](../specs/recovery-cache.md) |
| R6 target/检查器 | layout、[验证约定](../development/verification.md) |
| R7 前端/API | layout、[管理规范](../specs/control-plane.md) |

设计归属不等于实现验收。遇到新证据应调整相应规范/ADR，不在此新增实时状态列表。
