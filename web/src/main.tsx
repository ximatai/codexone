import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "@mantine/core/styles.css";
import "@mantine/dates/styles.css";
import "dayjs/locale/zh-cn";
import "@mantine/notifications/styles.css";
import "@mantine/charts/styles.css";
import "./styles.css";
import "./app/generated/theme.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
