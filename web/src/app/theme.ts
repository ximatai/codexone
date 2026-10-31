import {
  createTheme,
  DEFAULT_THEME,
  mergeMantineTheme,
  defaultCssVariablesResolver,
} from "@mantine/core";
export const theme = createTheme({
  primaryColor: "brand",
  primaryShade: { light: 7, dark: 4 },
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
    Anchor: { defaultProps: { c: "brand.7" } },
    Button: { defaultProps: { radius: "md" } },
    Paper: { defaultProps: { radius: "md", shadow: "none" } },
    Drawer: { defaultProps: { shadow: "none" } },
    Notification: { defaultProps: { withBorder: true, radius: "md" } },
    Table: { defaultProps: { verticalSpacing: "md", highlightOnHover: true } },
  },
  colors: {
    // Graphite blue keeps the primary apart from the status colors.
    brand: [
      "#eef2f8",
      "#dde5f1",
      "#b9c9e1",
      "#93aacf",
      "#6f8bbb",
      "#5373a8",
      "#3d5d92",
      "#2f4b7c",
      "#263e67",
      "#1d3050",
    ],
  },
  other: {
    surface: { light: "#f6f7f9", dark: "#161b22" },
    text: { light: "#1b2330", dark: "#e8edf4" },
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
