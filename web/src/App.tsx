import { useState } from "react";
import { KeyManagement } from "./features/key-management/KeyManagement";
import { SystemOverview } from "./features/system-status/SystemOverview";

export function App() {
  const [section, setSection] = useState<"overview" | "keys">("overview");
  return (
    <main className={section === "keys" ? "key-workspace" : undefined}>
      <header>
        <span className="brand-mark" aria-hidden="true">C</span>
        <strong>CodexOne</strong>
        <span className="subtle">管理控制台</span>
      </header>
      <nav aria-label="控制台导航">
        <button className="nav-button" aria-pressed={section === "overview"} onClick={() => setSection("overview")}>服务概览</button>
        <button className="nav-button" aria-pressed={section === "keys"} onClick={() => setSection("keys")}>访问密钥</button>
      </nav>
      {section === "overview" ? <SystemOverview /> : <KeyManagement />}
    </main>
  );
}
