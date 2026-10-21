import { useEffect, useState } from "react";
import { fetchSystemStatus } from "./api";
import type { SystemStatus } from "./api";

type State =
  | { kind: "loading" }
  | { kind: "failed" }
  | { kind: "loaded"; data: SystemStatus };

const labels: Record<string, string> = {
  execution_store: "执行与用量存储",
  upstream_accounts: "上游账号",
  authorization: "访问授权",
};

export function SystemOverview() {
  const [state, setState] = useState<State>({ kind: "loading" });
  const [revision, setRevision] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    fetchSystemStatus(controller.signal).then(
      (data) => {
        if (!controller.signal.aborted) setState({ kind: "loaded", data });
      },
      () => {
        if (!controller.signal.aborted) setState({ kind: "failed" });
      },
    );
    return () => controller.abort();
  }, [revision]);

  function reload() {
    setState({ kind: "loading" });
    setRevision((value) => value + 1);
  }

  return (
    <>
      <section className="intro">
        <p className="eyebrow">服务概览</p>
        <h1>连接与运行状态</h1>
        <p>查看网关连接与服务准备情况。</p>
      </section>
      <section className="panel" aria-label="服务状态">
        {state.kind === "loading" && <p role="status">正在连接服务…</p>}
        {state.kind === "failed" && (
          <>
            <h2>无法连接服务</h2>
            <p role="alert">请检查服务连接后重试。</p>
            <button onClick={reload}>重新连接</button>
          </>
        )}
        {state.kind === "loaded" && (
          <>
            <div className="panel-heading">
              <h2>网关{state.data.ready ? "已就绪" : "尚未就绪"}</h2>
              <span className="badge">连接正常</span>
            </div>
            <ul>
              {state.data.checks.map((check) => (
                <li key={check.name}>
                  <span>{labels[check.name] ?? check.name}</span>
                  <span className={check.ready ? "good" : "subtle"}>
                    {check.ready ? "已就绪" : "待就绪"}
                  </span>
                </li>
              ))}
            </ul>
            <button className="secondary" onClick={reload}>刷新状态</button>
          </>
        )}
      </section>
    </>
  );
}
