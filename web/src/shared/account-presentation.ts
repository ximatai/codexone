export interface AccountName {
  id: string;
  displayName?: string | null;
}
export function accountName(
  id: string | null | undefined,
  accounts: readonly AccountName[] = [],
  displayName?: string | null,
): string {
  if (!id) return "账号未记录";
  return (
    displayName?.trim() ||
    accounts.find((account) => account.id === id)?.displayName?.trim() ||
    `未命名账号 · ${id.slice(0, 8)}`
  );
}
export function credentialExpiry(
  value: number | null | undefined,
  now = Date.now(),
): string {
  if (value == null) return "访问凭证到期时间不可用";
  const minutes = Math.ceil((value * 1000 - now) / 60000);
  if (minutes <= 0) return "访问凭证已到期";
  const amount =
    minutes < 60
      ? minutes
      : minutes < 1440
        ? Math.ceil(minutes / 60)
        : Math.ceil(minutes / 1440);
  return `访问凭证约 ${amount} ${minutes < 60 ? "分钟" : minutes < 1440 ? "小时" : "天"}后到期`;
}
