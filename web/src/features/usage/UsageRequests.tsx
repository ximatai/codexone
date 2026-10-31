import { KeyName } from "../../shared/KeyName";
import { Button, Text } from "@mantine/core";
import { DataTable } from "../../shared/ui/DataTable";
import {
  failures,
  outcomes,
  states,
  localTime,
  timeTitle,
} from "../../shared/presentation";
import type { UsageReport } from "./api";
import { duration } from "./format";
import styles from "./usage.module.css";
export function UsageRequests({
  rows,
  onDetail,
  retry,
  defaultReasoningEfforts = {},
}: {
  rows: UsageReport["rows"];
  onDetail: (row: UsageReport["rows"][number]) => void;
  retry: () => void;
  defaultReasoningEfforts?: Record<string, string>;
}) {
  return (
    <div className={`usage-table ${styles.table}`}>
      <DataTable
        rows={rows}
        rowKey={(row) => row.kind + row.id}
        onRowClick={onDetail}
        retry={retry}
        empty="此筛选下没有已记录请求。"
        columns={[
          {
            id: "time",
            title: "准入/记录时间",
            render: (row) => (
              <>
                <span title={timeTitle(row.atUnixSeconds)}>
                  {localTime(row.atUnixSeconds)}
                </span>
                <small title={row.requestID ?? row.id}>
                  {row.requestID ?? row.id}
                </small>
              </>
            ),
          },
          {
            id: "key",
            title: "Key / 模型",
            render: (row) => (
              <>
                <span title={row.keyID}>{<KeyName {...row} />}</span>
                <small>{row.model ?? "模型未记录"}</small>
              </>
            ),
          },
          {
            id: "reasoning",
            title: "推理",
            render: (row) =>
              !row.requestMetadataRecorded
                ? "—"
                : (row.reasoningEffort ?? (
                    <Text component="span" size="sm" c="dimmed">
                      默认
                      {row.model && defaultReasoningEfforts[row.model]
                        ? ` · ${defaultReasoningEfforts[row.model]}`
                        : ""}
                    </Text>
                  )),
          },
          {
            id: "outcome",
            title: "请求结果",
            render: (row) => (
              <>
                {row.kind === "rejected"
                  ? "准入前拒绝"
                  : row.outcome
                    ? outcomes[row.outcome]
                    : "结果未记录"}
                <small>
                  {row.failure ? (failures[row.failure] ?? "其他异常") : ""}
                </small>
                <small>{row.state ? states[row.state] : "无执行租约"}</small>
              </>
            ),
          },
          {
            id: "first",
            title: "首事件耗时",
            render: (row) => (
              <span title="首个上游事件耗时，并非下游首个 Token">
                {duration(row.firstEventMilliseconds)}
              </span>
            ),
          },
          {
            id: "total",
            title: "总耗时",
            render: (row) => duration(row.totalMilliseconds),
          },
          {
            id: "detail",
            title: "详情",
            render: (row) => (
              <Button
                variant="subtle"
                size="compact-sm"
                onClick={(event) => {
                  event.stopPropagation();
                  onDetail(row);
                }}
              >
                查看详情
              </Button>
            ),
          },
        ]}
      />
    </div>
  );
}
