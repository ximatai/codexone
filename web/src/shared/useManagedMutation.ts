import { useEffect, useRef } from "react";
import {
  useMutation,
  useQueryClient,
  type QueryKey,
} from "@tanstack/react-query";
import { notifications } from "@mantine/notifications";
import { ManagementError } from "./management";
import { useManagementSession } from "./session";

type Operation = (csrf: string, signal: AbortSignal) => Promise<void>;
interface Options {
  scope: "keys" | "accounts";
  invalidate: readonly QueryKey[];
  refresh: (signal: AbortSignal) => Promise<boolean>;
  onFailure?: () => void;
}
/** Results deliberately never pass through useMutation: one-time secrets stay in their feature owner. */
export function useManagedMutation(options: Options) {
  const owner = useManagementSession();
  const notificationID = `management-${options.scope}`;
  const client = useQueryClient();
  const lifetime = useRef<AbortController | null>(null);
  const inFlight = useRef(false);
  useEffect(() => {
    const controller = new AbortController();
    lifetime.current = controller;
    return () => {
      controller.abort();
      notifications.hide(notificationID);
    };
  }, [owner.generation, notificationID]);
  const mutation = useMutation<
    void,
    unknown,
    { work: Operation; success: string }
  >({
    retry: false,
    gcTime: 0,
    mutationFn: async ({ work, success }) => {
      const signal = lifetime.current!.signal;
      const current = () => !signal.aborted && !!owner.session;
      try {
        await work(owner.session!.csrf, signal);
        if (!current()) return;
        await Promise.all(
          options.invalidate.map((queryKey) =>
            client.invalidateQueries({ queryKey }),
          ),
        );
        if (!current()) return;
        owner.lock(options.scope, false);
        notifications.show({
          id: notificationID,
          message: success,
          role: "status",
          color: "green",
        });
      } catch (error) {
        if (!current()) return;
        if (
          !(error instanceof ManagementError) ||
          ![400, 413].includes(error.status)
        )
          options.onFailure?.();
        if (error instanceof ManagementError && error.status === 401) {
          owner.invalidate();
          return;
        }
        let message =
          "无法连接管理服务，请稍后重试。操作结果尚未确认，请先刷新列表核对，再继续操作。";
        if (error instanceof ManagementError && error.status === 409) {
          await Promise.all(
            options.invalidate.map((queryKey) =>
              client.invalidateQueries({ queryKey, refetchType: "none" }),
            ),
          );
          const refreshed = await options.refresh(signal);
          if (!current()) return;
          owner.lock(options.scope, !refreshed);
          message = refreshed
            ? "数据已被修改，请确认后重试"
            : "数据已被修改，刷新未完成。请重新连接并核对列表后再操作。";
        } else if (
          error instanceof ManagementError &&
          (error.status === 400 || error.status === 413)
        ) {
          owner.lock(options.scope, false);
          message = "提交内容不符合要求，请检查模型、限额与到期时间。";
        } else if (error instanceof ManagementError && error.status === 403) {
          // A 403 is a definite rejection, so the scope can be used again.
          owner.lock(options.scope, false);
          message =
            error.code === "invalid_csrf"
              ? "管理会话已更新，请刷新后重试。"
              : "当前页面来源或会话验证不通过，请使用正确的管理地址。";
        }
        notifications.show({
          id: notificationID,
          message,
          color: "red",
          autoClose: false,
          role: "alert",
        });
        throw error;
      }
    },
  });
  async function run(work: Operation, success: string): Promise<boolean> {
    if (
      !owner.session ||
      owner.locked(options.scope) ||
      inFlight.current ||
      lifetime.current?.signal.aborted
    )
      return false;
    notifications.hide(notificationID);
    inFlight.current = true;
    owner.lock(options.scope, true);
    // The operation only returns void; neither mutation data nor variables can contain a response secret.
    let completed = false;
    try {
      await mutation.mutateAsync({
        work: async (csrf, signal) => {
          await work(csrf, signal);
          completed = !signal.aborted;
        },
        success,
      });
      return completed && !lifetime.current?.signal.aborted;
    } catch {
      return false;
    } finally {
      inFlight.current = false;
    }
  }
  return { run, busy: mutation.isPending };
}
