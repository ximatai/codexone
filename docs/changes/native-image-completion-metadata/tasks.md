# 原生 Images 聚合保留逐图元数据

记录扁平 Images SSE 转为非流式 JSON 的字段归属与验收。

- [x] 2026-11-22 在 Darwin arm64 的 v1.26.56 回环验证中复现单图字段停留在顶层、多图后续字段丢失，并验证原生 JSON 对照和持久结算。
- [x] 修正扁平完成事件的逐图字段归属，更新 P27。
- [x] Darwin arm64 上用 Rust 1.96.0 构建后，单图、多图和原生 JSON 对照均通过。现有 `verify_images.py` 的 smoke 与完整检查通过，并保留多图聚合、单次派发、用量和费用断言。Images crate 的 20 项测试通过。

## 相关文档

[提案](proposal.md) · [协议规范](../../reference/specs/protocol.md)
