import {
  createTheme,
  DEFAULT_THEME,
  mergeMantineTheme,
  defaultCssVariablesResolver,
} from "@mantine/core";
export const theme = createTheme({
  primaryColor: "green",
  primaryShade: { light: 8, dark: 4 },
  defaultRadius: "md",
  fontFamily: "Inter, ui-sans-serif, system-ui, sans-serif",
  fontSizes: {
    xs: "0.75rem",
    sm: "0.875rem",
    md: "1rem",
    lg: "1.125rem",
    xl: "1.25rem",
  },
  spacing: {
    xs: "0.625rem",
    sm: "0.75rem",
    md: "1rem",
    lg: "1.25rem",
    xl: "2rem",
  },
  radius: {
    xs: "0.125rem",
    sm: "0.25rem",
    md: "0.5rem",
    lg: "1rem",
    xl: "2rem",
  },
  headings: { fontFamily: "inherit", fontWeight: "600" },
  components: {
    Anchor: { defaultProps: { c: "green.8" } },
    Button: { defaultProps: { radius: "md" } },
    Paper: { defaultProps: { radius: "md", shadow: "none" } },
    Drawer: { defaultProps: { shadow: "none" } },
    Notification: { defaultProps: { withBorder: true, radius: "md" } },
    Table: { defaultProps: { verticalSpacing: "md", highlightOnHover: true } },
  },
  colors: {
    green: [
      "#edf5f0",
      "#dcebe2",
      "#b8d5c5",
      "#91bca7",
      "#6ca48b",
      "#4f8e73",
      "#317257",
      "#245d46",
      "#204c3f",
      "#173d30",
    ],
  },
  other: {
    surface: { light: "#f6f8fa", dark: "#17221d" },
    text: { light: "#21302b", dark: "#edf5f0" },
  },
});
/** The provider and Vite share the exact same resolved theme, without runtime style tags. */
export function themeCss() {
  const resolved = mergeMantineTheme(DEFAULT_THEME, theme);
  const variables = defaultCssVariablesResolver(resolved);
  const block = (selector: string, values: Record<string, string>) =>
    `${selector} {\n${Object.entries(values)
      .map(([key, value]) => `  ${key}: ${value};`)
      .join("\n")}\n}\n`;
  return (
    block(":root", variables.variables) +
    ["light", "dark"]
      .map((scheme) =>
        block(`[data-mantine-color-scheme="${scheme}"]`, {
          ...variables[scheme as "light" | "dark"],
          "--app-surface": resolved.other.surface[scheme],
          "--app-text": resolved.other.text[scheme],
        }),
      )
      .join("")
  );
}
