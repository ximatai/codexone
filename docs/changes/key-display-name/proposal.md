# Key 显示名

日期：2026-10-31。试运行中管理员需要用旧服务里的别名辨认迁移来的 Key；导入时主体名为不可读的 `legacy-p-<ref>`。主体名承担归属与轮换语义（[I12](../../specs/identity.md)），不能改名，因此新增独立的可编辑显示名，做法与账号显示名（[管理台第二轮](../admin-round2/proposal.md)）一致。

## 范围

### 后端

- Key 元数据新增可空 `displayName`：1—64 个 Unicode 标量，拒绝控制/格式/非法字符与换行分隔符，最多 256 UTF-8 字节；null 清除。保存在现有 Key 元数据 JSON 中，不改 schema、不参与认证/归属/治理/结算，轮换保留。
- `PUT /api/keys/{id}/display-name`：body `{revision, displayName}`，revision CAS，冲突 409；写 Key 审计（不记录名称原文以外的敏感数据，名称本身可记录）。认证/来源/CSRF/容量同其他 Key 修改接口。
- 所有返回 Key 主体的管理接口同时返回可空 `displayName`：Key 列表/详情、用量 options 的 `keyOptions`、用量明细、按 Key 今日摘要、进行中请求、`/api/attention` 的 Key 条目 subjectName（优先显示名）。按当前 Key 元数据连接，删除或未知为 null。

### 前端

- Key 列表、卡片、用量筛选与明细、首页进行中/最近请求、提醒区：有显示名时以显示名为主、主体名为次要灰字；无则保持现状。
- Key 编辑抽屉增加“显示名”输入（可清除），走 useManagedMutation（409 提示与刷新）；Key 搜索同时匹配显示名。

## 不做

主体名改名、批量改名接口（迁移时由主 Agent 用现有单条接口逐条设置）。

## 验收

- 后端：边界（64 标量、非法字符、空串、null 清除）、CAS 409、轮换保留、各接口字段出现与 null、名称不影响认证/归属；完整 `verify.sh --backend`。
- 前端：显示优先级、编辑与 409、搜索匹配；`verify.sh --web --chrome`；Linux verification。
