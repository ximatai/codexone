export function duration(value: number | null | undefined) {
  return value == null
    ? "不可用"
    : value >= 1000
      ? `${(value / 1000).toFixed(1)} s`
      : `${value.toLocaleString("zh-CN", { maximumFractionDigits: 1 })} ms`;
}
export function number(value: string | null | undefined, lower = false) {
  return value == null
    ? "不可用"
    : (lower ? "≥ " : "") + BigInt(value).toLocaleString("zh-CN");
}
export function utc(value: number) {
  return new Date(value * 1000)
    .toISOString()
    .replace("T", " ")
    .replace(".000Z", " UTC");
}

const rejectionLabels: Record<string, string> = {
  invalid_request: "请求结构无效",
  conversation_too_large: "会话或输入过大",
  invalid_turn_state: "会话状态无效",
  conflicting_turn_state: "会话状态冲突",
  invalid_client_metadata: "客户端元数据无效",
  model_not_allowed: "请求模型不可用",
  reasoning_effort_not_allowed: "推理档位未获允许",
  reasoning_effort_missing: "未提交推理档位",
  reasoning_effort_invalid: "推理档位值无效",
  reasoning_effort_legacy_field: "使用了旧的推理档位字段",
  account_cooldown: "账号冷却中",
  account_dispatch_unavailable: "没有可派发的账号",
  account_refresh_required: "凭证需要刷新",
  account_authorization_required: "账号需要重新授权",
  account_refresh_capacity: "刷新暂不可用",
  account_state_changed: "账号状态已变化",
  account_refresh_unavailable: "凭证刷新失败",
  continuation_owner_unavailable: "续接所属账号不可用",
};

export function rejectedReasoningEffort(effort: string | null | undefined) {
  if (effort === "missing") return "未提交";
  if (effort === "invalid") return "无效";
  return effort ?? "未记录";
}

export function rejectionReason(reason: string | null | undefined) {
  const prefix = "backend_parameter_";
  if (reason?.startsWith(prefix))
    return `上游不支持参数 ${reason.slice(prefix.length)}`;
  return (reason && rejectionLabels[reason]) || "子原因未记录";
}
