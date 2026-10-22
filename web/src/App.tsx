import { useState } from "react";
import { AccountManagement } from "./features/account-management/AccountManagement";
import { KeyManagement } from "./features/key-management/KeyManagement";
import { SystemOverview } from "./features/system-status/SystemOverview";

export function App() {
  const [section, setSection] = useState<"overview" | "keys" | "accounts">("overview");
  return (
    <main className={section === "accounts" ? "key-workspace account-workspace" : section !== "overview" ? "key-workspace" : undefined}>
      <header>
        <span className="brand-mark" aria-hidden="true">C</span>
        <strong>CodexOne</strong>
        <span className="subtle">管理控制台</span>
      </header>
      <nav aria-label="控制台导航">
        <button className="nav-button" aria-pressed={section === "overview"} onClick={() => setSection("overview")}>服务概览</button>
        <button className="nav-button" aria-pressed={section === "keys"} onClick={() => setSection("keys")}>访问密钥</button>
        <button className="nav-button" aria-pressed={section === "accounts"} onClick={() => setSection("accounts")}>订阅账号</button>
      </nav>
      {section === "overview" ? <SystemOverview /> : section === "keys" ? <KeyManagement /> : <AccountManagement />}
    </main>
  );
}
