import { SystemOverview } from "./features/system-status/SystemOverview";

export function App() {
  return (
    <main>
      <header>
        <span className="brand-mark" aria-hidden="true">C</span>
        <strong>CodexOne</strong>
        <span className="subtle">管理控制台</span>
      </header>
      <SystemOverview />
    </main>
  );
}
