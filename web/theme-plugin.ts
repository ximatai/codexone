import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { Plugin } from "vite";
import { themeCss } from "./src/app/theme";
export function staticTheme(): Plugin {
  const generate = () => {
    const directory = fileURLToPath(
      new URL("./src/app/generated/", import.meta.url),
    );
    mkdirSync(directory, { recursive: true });
    writeFileSync(directory + "theme.css", themeCss());
  };
  generate();
  return { name: "static-management-theme", buildStart: generate };
}
