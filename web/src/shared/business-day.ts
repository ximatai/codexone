import { ManagementError } from "./management";
export interface BusinessDay {
  offsetMinutes: number;
}
export function timezone(offsetMinutes = 0) {
  return offsetMinutes === 0
    ? "UTC"
    : `UTC${offsetMinutes < 0 ? "-" : "+"}${String(Math.abs(offsetMinutes) / 60).padStart(2, "0")}:00`;
}
export function readBusinessDay(value: {
  businessDay?: unknown;
  timezone?: unknown;
}): BusinessDay {
  const day =
    value.businessDay === undefined
      ? { offsetMinutes: 0 }
      : (value.businessDay as BusinessDay);
  if (
    !day ||
    !Number.isInteger(day.offsetMinutes) ||
    day.offsetMinutes % 60 !== 0 ||
    day.offsetMinutes < -720 ||
    day.offsetMinutes > 840 ||
    value.timezone !== timezone(day.offsetMinutes)
  )
    throw new ManagementError(0, "invalid_response");
  return { offsetMinutes: day.offsetMinutes };
}
export function businessDate(epoch: number, offsetMinutes = 0) {
  return new Date((epoch + offsetMinutes * 60) * 1000)
    .toISOString()
    .slice(0, 10);
}
export function businessTime(epoch: number, offsetMinutes = 0) {
  return new Date((epoch + offsetMinutes * 60) * 1000)
    .toISOString()
    .replace("T", " ")
    .replace(".000Z", ` ${timezone(offsetMinutes)}`);
}
export function dayStart(epoch: number, offsetMinutes = 0) {
  const offset = offsetMinutes * 60;
  return Math.floor((epoch + offset) / 86400) * 86400 - offset;
}
