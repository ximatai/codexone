import {
  createContext,
  memo,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { useReducedMotion } from "@mantine/hooks";
const MotionContext = createContext(false);
export function OverviewMotion({
  children,
  reset = 0,
}: {
  children: ReactNode;
  reset?: number;
}) {
  const [readyFor, setReadyFor] = useState<number | null>(null);
  const reduced = useReducedMotion();
  useEffect(() => {
    setReadyFor(null);
    let timer = window.setTimeout(
      () => setReadyFor(document.hidden ? null : reset),
      400,
    );
    const visibility = () => {
      setReadyFor(null);
      clearTimeout(timer);
      if (!document.hidden)
        timer = window.setTimeout(() => setReadyFor(reset), 400);
    };
    document.addEventListener("visibilitychange", visibility);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", visibility);
    };
  }, [reset]);
  return (
    <MotionContext value={readyFor === reset && !document.hidden && !reduced}>
      {children}
    </MotionContext>
  );
}
export function useOverviewMotion() {
  return useContext(MotionContext);
}
/** Keep the existing exact representation until a CSP-compatible numeric renderer is approved.
 * NumberFlow 0.6.2 injects shadow styles rejected by the production style-src policy.
 * Do not relax CSP or render the unstyled digit stack as a fallback.
 */
export const ContinuousValue = memo(function ContinuousValue({
  text,
}: {
  text: string;
}) {
  return <>{text}</>;
});
