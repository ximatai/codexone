const messages: Record<string, string> = {
  provider_rejected: "提供者拒绝了设备码授权请求，请稍后重新发起。",
  exchange_failed: "授权码兑换失败，请核对账号列表后重新发起授权。",
  identity_mismatch:
    "登录的 ChatGPT 账号与要重新授权的账号不一致，或该账号已添加。请核对账号列表。",
  verification_failed: "授权安全校验失败，请关闭后重新发起授权。",
  revision_conflict: "账号版本或状态已变化，请重新读取账号后重新授权。",
  device_code_unavailable:
    "设备码登录暂不可用，可改用浏览器回调方式。也可能需要在 ChatGPT 安全设置中开启设备码登录。",
  authorization_failed: "授权未能完成，请核对账号列表后重新发起。",
};
export function knownAuthorizationFailureMessage(
  code?: string,
): string | undefined {
  return code && Object.hasOwn(messages, code) ? messages[code] : undefined;
}
export function authorizationFailureMessage(code?: string): string {
  return (
    knownAuthorizationFailureMessage(code) ?? messages.authorization_failed
  );
}
