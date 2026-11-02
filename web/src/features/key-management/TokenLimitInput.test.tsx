import { useState } from "react";
import { fireEvent, screen } from "@testing-library/react";
import { expect, it } from "vitest";
import { render } from "../../../tests/render";
import { TokenLimitInput } from "./TokenLimitInput";
it("preserves the actual Token count across units and decimal edits", () => {
  function Harness() {
    const [value, setValue] = useState(1500000);
    return (
      <>
        <TokenLimitInput value={value} disabled={false} onChange={setValue} />
        <output aria-label="actual">{value}</output>
      </>
    );
  }
  render(<Harness />);
  const input = screen.getByRole("textbox");
  const unit = screen.getByRole("combobox");
  fireEvent.click(unit);
  fireEvent.click(screen.getByRole("option", { name: "百万 Token" }));
  expect(input).toHaveValue("1.5");
  for (let i = 0; i < 3; i++) {
    fireEvent.click(unit);
    fireEvent.click(screen.getByRole("option", { name: "万 Token" }));
    expect(input).toHaveValue("150");
    fireEvent.click(unit);
    fireEvent.click(screen.getByRole("option", { name: "Token" }));
    expect(input).toHaveValue("1500000");
  }
  fireEvent.click(unit);
  fireEvent.click(screen.getByRole("option", { name: "百万 Token" }));
  fireEvent.change(input, { target: { value: "2.5" } });
  expect(screen.getByLabelText("actual")).toHaveTextContent("2500000");
  fireEvent.click(unit);
  fireEvent.click(screen.getByRole("option", { name: "Token" }));
  fireEvent.change(input, { target: { value: "0.5" } });
  expect(screen.getByLabelText("actual")).toHaveTextContent("0.5");
});
