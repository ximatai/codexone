# 保留 JSON 对象键顺序

定义对象顺序契约、兼容性边界和迁移回退影响。

## 目标与依据

依据 [协议规范](../../reference/specs/protocol.md)，客户端和上游 JSON 经网关解析、改写、重新序列化后，应保留各层对象收到的键顺序。现有 Dictionary 丢失工具 schema 属性顺序，可能影响提供者提示缓存；已提供的证据不在本任务重新采集。真实上游缓存验收仍待发布后由维护者完成，本地合成验证不等同于缓存命中证明。

## 设计与验收

仅在 Adapters 引入无新依赖的有序对象；字面量、下标、过滤和迭代保持可读。替换已有字段保留位置，删除不扰动其他字段，新增按调用顺序追加。对象相等仍忽略顺序。Foundation 继续决定 JSON 接受范围、重复键、Decimal；独立扫描恢复顺序，独立 writer 避免 keyed container 顺序差异。保留 64 层限制和错误及斜杠转义选项。

以旧实现差分语料覆盖重复键、转义、Unicode、数字、深度和非法文档。通过二进制和本地假上游验证 HTTP、compact、WebSocket 的原始字节、响应顺序、重复请求及进程重启。审计请求正文和会话头的改写及动态值；记录约 1 MB、数百工具的前后解析加序列化性能。保留取消、超时、断流验收。

另一个独立提交仅放行 input_tokens_details.cache_write_tokens_details 内 ttl_30m_tokens 和 ttl_12h_tokens 非负整数，未知字段仍删除；依据 [用量规范](../../reference/specs/usage.md)。

## 迁移与回退

无 schema、凭证或配置迁移。旧版本可回退，但会再次丢失对象顺序，影响缓存稳定性；不保证缓存改善或既有会话缓存续用。不改版本号或发布标题，不访问真实提供者。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [验证](verification.md) · [协议](../../reference/specs/protocol.md)
