import { Alert, Button, Stack, Text } from "@mantine/core";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { fetchHeadroom } from "../../shared/governance-api";
import { ManagementError } from "../../shared/management";
import { useManagementSession } from "../../shared/session";
import { ConfirmModal } from "../../shared/ui/ConfirmModal";
import { useManagedMutation } from "../../shared/useManagedMutation";
import { releaseUnknown } from "../system-status/attention-api";

const queryKey = ["usage", "release-capacity"] as const;

export function EarlyCapacityRelease() {
  const owner = useManagementSession();
  const client = useQueryClient();
  const [open, setOpen] = useState(false);
  const [snapshot, setSnapshot] = useState<{
    count: number;
    beforeUnixSeconds: number;
  } | null>(null);
  const locked = owner.locked("executions");
  const query = useQuery({
    queryKey,
    queryFn: ({ signal }) => fetchHeadroom(signal),
    enabled: !!owner.session && (open || locked),
  });
  useEffect(() => {
    if (query.error instanceof ManagementError && query.error.status === 401)
      owner.invalidate();
  }, [owner, query.error]);
  const mutation = useManagedMutation({
    scope: "executions",
    invalidate: [["usage"], ["overview"]],
    refresh: async (signal) => {
      try {
        client.setQueryData(queryKey, await fetchHeadroom(signal));
        return true;
      } catch {
        return false;
      }
    },
    onFailure: () => setSnapshot(null),
  });
  const candidate = query.data?.unknownReconciliation;
  return (
    <Stack gap="xs" mb="md" align="flex-start">
      {locked && !mutation.busy && (
        <Alert color="yellow" role="alert">
          上次释放结果尚未确认。
          <Button
            size="xs"
            variant="subtle"
            disabled={query.isFetching}
            onClick={() => {
              void query.refetch().then((result) => {
                if (result.isSuccess) owner.lock("executions", false);
              });
            }}
          >
            刷新并核对释放结果
          </Button>
        </Alert>
      )}
      <Button variant="subtle" size="xs" onClick={() => setOpen(!open)}>
        {open ? "收起未结执行" : "查看未结执行"}
      </Button>
      {open && (
        <>
          {query.isError ? (
            <Button
              variant="subtle"
              size="xs"
              onClick={() => void query.refetch()}
            >
              读取未结执行失败，点击重试
            </Button>
          ) : query.isFetching || !candidate ? (
            <Text size="sm">正在读取未结执行…</Text>
          ) : candidate.count === 0 ? (
            <Text size="sm">暂无占用容量的未知执行。</Text>
          ) : (
            <Button
              size="xs"
              variant="light"
              disabled={locked || mutation.busy}
              onClick={() => setSnapshot(candidate)}
            >
              提前释放容量 · {candidate.count} 条
            </Button>
          )}
        </>
      )}
      <ConfirmModal
        opened={!!snapshot}
        title="提前释放容量"
        busy={mutation.busy}
        disabled={locked || mutation.busy}
        close={() => setSnapshot(null)}
        label="确认释放"
        confirm={() => {
          if (!snapshot) return;
          void mutation
            .run(async (csrf, signal) => {
              await releaseUnknown(
                snapshot.beforeUnixSeconds,
                snapshot.count,
                csrf,
                signal,
              );
            }, "已释放容量占用，统计仍显示用量未知。")
            .then((success) => {
              if (success) setSnapshot(null);
            });
        }}
      >
        <Text>
          将提前释放 {snapshot?.count}{" "}
          条未知执行占用的本地容量。操作会保留审计记录，原请求的真实用量仍为未知。
        </Text>
      </ConfirmModal>
    </Stack>
  );
}
