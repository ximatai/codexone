export function isUTCDateInput(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const epoch = Date.parse(value + "T00:00:00Z");
  return (
    Number.isFinite(epoch) &&
    new Date(epoch).toISOString().slice(0, 10) === value
  );
}
