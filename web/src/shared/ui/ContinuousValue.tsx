import {
  createContext,
  memo,
  useContext,
  useEffect,
  useLayoutEffect,
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
/** Animate confirmed digits only. Layout and the accessible text always contain the new value. */
export const ContinuousValue = memo(function ContinuousValue({
  text,
}: {
  text: string;
}) {
  const motion = useOverviewMotion();
  const shape = text.replace(/[0-9]/g, "#");
  const root = useRef<HTMLSpanElement>(null);
  const previous = useRef(text);
  const animations = useRef<Animation[]>([]);
  useLayoutEffect(() => {
    const before = previous.current;
    const beforeCharacters = Array.from(before);
    const characters = Array.from(text);
    previous.current = text;
    const interrupted = animations.current.some(
      (animation) => animation.playState === "running",
    );
    animations.current.forEach((animation) => animation.cancel());
    animations.current = [];
    // Changing units/precision/sign/length snaps; rapid changes never build an animation queue.
    if (!motion || interrupted || before.replace(/[0-9]/g, "#") !== shape)
      return;
    const oldDigits = BigInt(before.replace(/\D/g, "") || "0");
    const newDigits = BigInt(text.replace(/\D/g, "") || "0");
    const delta =
      newDigits > oldDigits ? newDigits - oldDigits : oldDigits - newDigits;
    if (delta > 20n && delta > oldDigits / 2n) return;
    const decreasing = text.trimStart().startsWith("-")
      ? newDigits > oldDigits
      : newDigits < oldDigits;
    root.current
      ?.querySelectorAll<HTMLSpanElement>("[data-digit]")
      .forEach((track) => {
        const index = Number(track.dataset.digit);
        if (
          beforeCharacters[index] === characters[index] ||
          typeof track.animate !== "function"
        )
          return;
        track.dataset.previous = beforeCharacters[index];
        track.classList.toggle(styles.reverse, decreasing);
        animations.current.push(
          track.animate(
            [
              { transform: `translateY(${decreasing ? "-100%" : "100%"})` },
              { transform: "translateY(0)" },
            ],
            { duration: 240, easing: "cubic-bezier(0.2, 0.7, 0.2, 1)" },
          ),
        );
      });
  }, [text, motion, shape]);
  useLayoutEffect(
    () => () => animations.current.forEach((animation) => animation.cancel()),
    [],
  );
  return (
    <span className={styles.value} ref={root} data-continuous-value="">
      <span className={styles.accessible}>{text}</span>
      <span key={shape} className={styles.visual} aria-hidden="true">
        {Array.from(text, (character, index) =>
          /[0-9]/.test(character) ? (
            <span className={styles.digit} key={index}>
              <span
                className={styles.track}
                data-digit={index}
                data-current={character}
              />
            </span>
          ) : (
            <span
              className={styles.symbol}
              data-current={character}
              key={index}
            />
          ),
        )}
      </span>
    </span>
  );
});
