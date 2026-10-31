/** Bounded navigation metadata, owned and cleared by the management session. */
export class ViewMemory extends Map<string, unknown> {
  override set(key: string, value: unknown): this {
    this.delete(key);
    if (this.size >= 32) this.delete(this.keys().next().value!);
    return super.set(key, value);
  }
}

export function readPage(value: string | null, maximum: number): number {
  const page = Number(value);
  return value !== null &&
    /^[1-9]\d*$/.test(value) &&
    Number.isSafeInteger(page)
    ? Math.min(maximum, page)
    : 1;
}
