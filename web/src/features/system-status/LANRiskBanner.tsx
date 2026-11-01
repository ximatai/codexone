import { Alert, Anchor } from "@mantine/core";
import { useEffect, useState } from "react";
import { fetchSystemStatus } from "./api";

export function LANRiskBanner() {
  const [lan, setLAN] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    void fetchSystemStatus(controller.signal).then(
      (status) => {
        if (!controller.signal.aborted)
          setLAN(status.transportMode === "lan_http");
      },
      () => {},
    );
    return () => controller.abort();
  }, []);
  if (!lan) return null;
  return (
    <Alert color="yellow" mb="lg" aria-label="局域网明文风险">
      局域网 HTTP 模式：管理员秘密、Key 与请求内容在局域网中明文传输。{" "}
      <Anchor
        href="https://github.com/ximatai/codexone/blob/main/docs/operations/tls-proxy.md#局域网-http-风险"
        target="_blank"
        rel="noreferrer"
      >
        了解风险
      </Anchor>
    </Alert>
  );
}
