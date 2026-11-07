import { useEffect, useState } from "react";
export function useOverviewRefresh() {
  const [visible, setVisible] = useState(() => !document.hidden);
  useEffect(() => {
    const visibility = () => setVisible(!document.hidden);
    document.addEventListener("visibilitychange", visibility);
    return () => document.removeEventListener("visibilitychange", visibility);
  }, []);
  return {
    active: visible,
    interval: visible ? (15000 as const) : (false as const),
  };
}
