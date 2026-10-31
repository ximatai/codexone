import { useEffect, useState } from "react";
export function useOverviewRefresh() {
  const [automatic, setAutomatic] = useState(true);
  const [visible, setVisible] = useState(() => !document.hidden);
  useEffect(() => {
    const visibility = () => setVisible(!document.hidden);
    document.addEventListener("visibilitychange", visibility);
    return () => document.removeEventListener("visibilitychange", visibility);
  }, []);
  return {
    automatic,
    setAutomatic,
    interval: automatic && visible ? (15000 as const) : (false as const),
  };
}
