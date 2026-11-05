import { act, cleanup, render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ContinuousValue, OverviewMotion } from "./ContinuousValue";

const preference = vi.hoisted(() => ({ reduced: false }));
vi.mock("@mantine/hooks", () => ({
  useReducedMotion: () => preference.reduced,
}));

describe("confirmed overview values", () => {
  const running: { playState: string; cancel: ReturnType<typeof vi.fn> }[] = [];
  const animate = vi.fn(() => {
    const animation = {
      playState: "running",
      cancel: vi.fn(() => {
        animation.playState = "idle";
      }),
    };
    running.push(animation);
    return animation as unknown as Animation;
  });
  const view = (text: string, reset = 0) => (
    <OverviewMotion reset={reset}>
      <ContinuousValue text={text} />
    </OverviewMotion>
  );
  beforeEach(() => {
    vi.useFakeTimers();
    preference.reduced = false;
    running.length = 0;
    animate.mockClear();
    vi.spyOn(document, "hidden", "get").mockReturnValue(false);
    Object.defineProperty(HTMLElement.prototype, "animate", {
      configurable: true,
      writable: true,
      value: animate,
    });
  });
  afterEach(() => {
    cleanup();
    vi.useRealTimers();
    delete (HTMLElement.prototype as Partial<HTMLElement>).animate;
  });

  it("keeps exact current text and snaps interrupted or differently formatted values", () => {
    const screen = render(view("19"));
    act(() => {
      vi.advanceTimersByTime(401);
    });
    expect(animate).not.toHaveBeenCalled();
    screen.rerender(view("20"));
    expect(animate).toHaveBeenCalledTimes(2);
    expect(screen.container.textContent).toBe("20");
    expect(screen.container.querySelector("[style]")).toBeNull();
    screen.rerender(view("21"));
    expect(animate).toHaveBeenCalledTimes(2);
    expect(
      running.every((animation) => animation.cancel.mock.calls.length > 0),
    ).toBe(true);
    expect(screen.container.textContent).toBe("21");
    screen.rerender(view("1万"));
    screen.rerender(view("—"));
    expect(screen.container.textContent).toBe("—");
    expect(animate).toHaveBeenCalledTimes(2);
  });

  it("cancels motion when hidden, resetting, reduced or unmounted", () => {
    const screen = render(view("10"));
    act(() => {
      vi.advanceTimersByTime(401);
    });
    screen.rerender(view("11"));
    expect(animate).toHaveBeenCalledTimes(1);
    vi.spyOn(document, "hidden", "get").mockReturnValue(true);
    act(() => {
      document.dispatchEvent(new Event("visibilitychange"));
    });
    expect(running[0].cancel).toHaveBeenCalled();
    screen.rerender(view("12"));
    expect(animate).toHaveBeenCalledTimes(1);
    vi.spyOn(document, "hidden", "get").mockReturnValue(false);
    screen.rerender(view("13", 1));
    expect(animate).toHaveBeenCalledTimes(1);
    act(() => {
      vi.advanceTimersByTime(401);
    });
    preference.reduced = true;
    screen.rerender(view("14", 1));
    expect(animate).toHaveBeenCalledTimes(1);
    preference.reduced = false;
    screen.rerender(view("15", 1));
    expect(animate).toHaveBeenCalledTimes(2);
    screen.unmount();
    expect(running[1].cancel).toHaveBeenCalled();
  });
});
