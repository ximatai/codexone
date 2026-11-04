import NumberFlow from "@number-flow/react";
import {
  createContext,
  memo,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useReducedMotion } from "@mantine/hooks";
import styles from "./ContinuousValue.module.css";
const MotionContext = createContext(false);
export function OverviewMotion({
  children,
  reset = 0,
}: {
  children: ReactNode;
  reset?: number;
}) {
  const [ready, setReady] = useState(false);
  const reduced = useReducedMotion();
  useEffect(() => {
    setReady(false);
    let timer = window.setTimeout(() => setReady(!document.hidden), 400);
    const visibility = () => {
      setReady(false);
      clearTimeout(timer);
      if (!document.hidden) timer = window.setTimeout(() => setReady(true), 400);
    };
    document.addEventListener("visibilitychange", visibility);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", visibility);
    };
  }, [reset]);
  return <MotionContext value={ready && !reduced}>{children}</MotionContext>;
}
export function useOverviewMotion() {
  return useContext(MotionContext);
}
/** Accept already formatted display text so BigInt/null/unit semantics remain with the feature. */
export const ContinuousValue = memo(function ContinuousValue({
  text,
}: {
  text: string;
}) {
  const motion = useOverviewMotion();
  const match = text.match(/^([^0-9]*)([0-9][0-9,]*(?:\.[0-9]+)?)([^0-9]*)$/);
  const value = match ? Number(match[2].replaceAll(",", "")) : NaN;
  const previous = useRef(value);
  const animate =
    motion &&
    Number.isFinite(previous.current) &&
    Math.abs(value - previous.current) <=
      Math.max(100, Math.abs(previous.current) * 10);
  useEffect(() => {
    previous.current = value;
  }, [value]);
  if (!match || !Number.isSafeInteger(Math.trunc(value)) || typeof HTMLElement.prototype.animate !== "function")
    return <>{text}</>;
  return (
    <span className={styles.value} aria-label={text}>
      <span aria-hidden="true">
        <NumberFlow
          value={value}
          prefix={match[1]}
          suffix={match[3]}
          locales="zh-CN"
          format={{
            useGrouping: match[2].includes(","),
            minimumFractionDigits: match[2].split(".")[1]?.length ?? 0,
            maximumFractionDigits: match[2].split(".")[1]?.length ?? 0,
          }}
          animated={animate}
          transformTiming={{ duration: 250, easing: "ease-out" }}
          opacityTiming={{ duration: 150 }}
        />
      </span>
    </span>
  );
});
