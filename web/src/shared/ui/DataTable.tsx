import { Table, UnstyledButton } from "@mantine/core";
import { useState, type ReactNode } from "react";
import { EmptyState, ErrorState, LoadingState } from "./States";
import styles from "./DataTable.module.css";
export interface DataColumn<T> {
  id: string;
  title: string;
  label?: string;
  width?: string;
  nowrap?: boolean;
  mobileTitle?: boolean;
  render: (row: T) => ReactNode;
  sortValue?: (row: T) => string | number;
}
export function DataTable<T>({
  rows,
  columns,
  rowKey,
  loading = false,
  error,
  retry,
  empty = "暂无数据。",
  loadingText = "正在读取…",
  onRowClick,
}: {
  rows: T[];
  columns: DataColumn<T>[];
  rowKey: (row: T) => string;
  loading?: boolean;
  error?: string;
  retry: () => void;
  empty?: string;
  loadingText?: string;
  onRowClick?: (row: T) => void;
}) {
  const [sort, setSort] = useState<{ id: string; descending: boolean } | null>(
    null,
  );
  if (loading) return <LoadingState>{loadingText}</LoadingState>;
  if (error) return <ErrorState retry={retry}>{error}</ErrorState>;
  if (!rows.length) return <EmptyState>{empty}</EmptyState>;
  const column = columns.find((item) => item.id === sort?.id);
  const ordered = column?.sortValue
    ? [...rows].sort((a, b) => {
        const left = column.sortValue!(a),
          right = column.sortValue!(b);
        return (
          (typeof left === "number" && typeof right === "number"
            ? left - right
            : String(left).localeCompare(String(right))) *
          (sort?.descending ? -1 : 1)
        );
      })
    : rows;
  return (
    <Table className={styles.table}>
      <Table.Thead>
        <Table.Tr>
          {columns.map((item) => (
            <Table.Th
              key={item.id}
              style={{ width: item.width }}
              aria-sort={
                sort?.id === item.id
                  ? sort.descending
                    ? "descending"
                    : "ascending"
                  : item.sortValue
                    ? "none"
                    : undefined
              }
            >
              {item.sortValue ? (
                <UnstyledButton
                  className={styles.sortButton}
                  onClick={() =>
                    setSort({
                      id: item.id,
                      descending: sort?.id === item.id && !sort.descending,
                    })
                  }
                >
                  {item.title}
                  <span
                    aria-hidden="true"
                    className={
                      sort?.id === item.id ? undefined : styles.unsorted
                    }
                  >
                    {sort?.id === item.id
                      ? sort.descending
                        ? " ↓"
                        : " ↑"
                      : " ↕"}
                  </span>
                </UnstyledButton>
              ) : (
                item.title
              )}
            </Table.Th>
          ))}
        </Table.Tr>
      </Table.Thead>
      <Table.Tbody>
        {ordered.map((row) => (
          <Table.Tr
            key={rowKey(row)}
            className={onRowClick ? styles.clickable : undefined}
            tabIndex={onRowClick ? 0 : undefined}
            onClick={onRowClick ? () => onRowClick(row) : undefined}
            onKeyDown={
              onRowClick
                ? (event) => {
                    if (
                      event.target === event.currentTarget &&
                      (event.key === "Enter" || event.key === " ")
                    ) {
                      event.preventDefault();
                      onRowClick(row);
                    }
                  }
                : undefined
            }
          >
            {columns.map((item) => (
              <Table.Td
                key={item.id}
                style={{ whiteSpace: item.nowrap ? "nowrap" : undefined }}
              >
                <span
                  className={
                    item.mobileTitle ? styles.hiddenLabel : styles.label
                  }
                >
                  {item.label ?? item.title}
                </span>
                {item.render(row)}
              </Table.Td>
            ))}
          </Table.Tr>
        ))}
      </Table.Tbody>
    </Table>
  );
}
