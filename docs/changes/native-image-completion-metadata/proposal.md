# 原生 Images 聚合保留逐图元数据

非流式 Images 客户端收到网关聚合后的 JSON 时，按 `data[]` 读取每张图的 `generation_id` 和 `image_metadata`。在 v1.26.56 的回环复现中，扁平 SSE 完成事件的首图字段出现在响应顶层，第二张图的字段丢失。固定上游 [Images 客户端类型](https://github.com/openai/codex/blob/357fe240c91563c1e6c9690bb27a2e609282d615/codex-rs/codex-api/src/images.rs) 从各自的图片项读取这两个字段。

按 [P27](../../reference/specs/protocol.md#p27开放协议透传)，聚合时把扁平完成事件的这两个已知字段与同事件的图片字节放入同一个 `data[]` 项，保留事件到达顺序。原生 JSON、流式客户端收到的 SSE、其他响应字段与用量归并沿用既有契约。

验收使用单图、多图及原生 JSON 对照夹具，核对每张图的字段归属、单次上游派发和持久结算。复现采用合成元数据，实际提供者的字段发送情况留待另行验证。无配置或 schema 迁移，回退使用上一版本二进制即可，扁平 SSE 聚合恢复至原有字段位置。

## 相关文档

[任务](tasks.md) · [协议规范](../../reference/specs/protocol.md)
