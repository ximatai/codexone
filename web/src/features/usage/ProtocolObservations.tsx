import { Anchor, Text } from "@mantine/core";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router";
import {
  attentionQueryKey,
  fetchAttention,
} from "../system-status/attention-api";
import { useManagementSession } from "../../shared/session";

export function ProtocolObservations() {
  const [open, setOpen] = useState(false);
  const owner = useManagementSession();
  const query = useQuery({
    queryKey: attentionQueryKey,
    queryFn: ({ signal }) => fetchAttention(signal),
    enabled: open && !!owner.session,
  });
  const count = query.data?.items.filter(
    (item) => item.kind === "client_protocol_extension",
  ).length;
  return (
    <details onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary>客户端协议观测</summary>
      {query.isError ? (
        <Text size="sm">暂无法读取协议观测。</Text>
      ) : count ? (
        <Anchor component={Link} to="/?protocol=details" size="sm">
          查看协议名称
        </Anchor>
      ) : (
        <Text size="sm">
          {query.isPending ? "正在读取…" : "暂无新协议名称。"}
        </Text>
      )}
    </details>
  );
}
