# 用量分析：模型/客户端分布与 CSV 导出

日期：2026-10-31。用户在管理台基础层阶段 2 之后优先排期。上一轮见 [管理台第二轮](../admin-round2/proposal.md)，口径见 [用量 U10/U12/U14](../../specs/usage.md) 与 [管理面](../../specs/control-plane.md)。

## 问题

管理员能看到总量与逐条明细，但回答不了“额度主要花在哪个模型”“大家在用哪些客户端、哪个版本”。后者还是[客户端协议跟踪](../../development/client-protocol-watch.md)的缺口：不知道线上实际客户端版本，就无法判断新协议的影响面。明细也不能导出离线分析。

## 范围

### 后端

1. **请求客户端记录**：准入时把客户端归类写入现有 `admission_json`（与模型、Key revision 同样方式，不改 schema、不回填历史）：
   - `clientKind`：固定枚举 `cli`、`exec`、`desktop`、`vscode`、`sdk`、`other_codex`、`non_codex`，由 User-Agent/originator 判定（复用官方客户端识别规则）；
   - `clientVersion`：可空，从官方客户端 UA 解析的版本号，仅数字与点（最多 32 字节），解析不出为 null。
   - 不保存原始 User-Agent、操作系统、终端或其他请求头；HTTP、WS 与原生 Images 三条入口一致。历史记录缺字段按“未知”统计。
2. **分布查询**：`GET /api/usage/breakdown`，参数与 `/api/usage` 相同的时间与筛选（start/end、key、model、mode、failure、failedOnly、state），加 `by=model|client|clientVersion|key`。每组返回 requests、succeeded、failed、cancelled、metrics（与 totals 同口径，缺失保持 null/下界语义）。按请求数降序最多 50 组，其余合并为 `other`；未知值单独成组。复用单只读 reader、单在途、扫描预算与取消门禁，参数与鉴权错误契约同 A13。
3. 明细行新增可空 `clientKind`、`clientVersion`，用量筛选新增可选 `client`（clientKind 枚举）。

### 前端

1. 用量页新增“分布”区：按模型、客户端、客户端版本、Key 切换；横向条形图（请求数）+ 表格（请求、失败、Token、估算费用），随页面筛选与时间范围联动，点击组可把该值加入筛选。
2. 明细与详情抽屉显示客户端与版本。
3. **CSV 导出**：在浏览器端按当前筛选分页读取 `/api/usage`，最多 10,000 行，进度可取消；超出时提示缩小范围。列为时间（UTC 与本地）、Key 主体、模型、模式、客户端、版本、结果、失败类别、各类 Token、估算费用、首事件与总耗时；不含请求 ID 以外的标识。文件名含时间范围。不新增后端导出接口。

## 不做

- 不保存原始请求头或正文；不按 IP、地区统计。
- 不回填历史请求的客户端信息。
- 不新增 schema、不改结算与治理口径。
- 首页卡片调整与深色模式另行处理。

## 验收

- 三条入口（HTTP/SSE、WS、原生 Images）各记录正确的 clientKind/version；畸形或超长 UA 记为 non_codex/null，不拒绝请求。
- 分布查询：鉴权/来源、参数边界、空数据、未知组、50 组截断与 other、与 `/api/usage` totals 对账一致、繁忙 429、取消。
- 前端：分布切换与点击筛选、导出分页/取消/上限提示的 vitest 与 Playwright；1440×900 走查。
- 完整 `verify.sh --backend`、`--web --chrome` 与 Linux verification。
