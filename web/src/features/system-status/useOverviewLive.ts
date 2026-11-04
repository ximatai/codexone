import { useEffect, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { z } from "../../shared/schema";
import { useManagementSession } from "../../shared/session";
import { fetchSession, ManagementError } from "../../shared/management";
import { parseAccount } from "../account-management/api";
import { parseSystemStatus } from "./api";
import { parseStorage } from "./storage-api";
import { daily, flight, keySummary } from "./round2-api";
import { report } from "./attention-api";
import { headroomSchema } from "../../shared/governance-api";
const names = [
  "system",
  "inFlight",
  "daily",
  "keys",
  "accounts",
  "storage",
  "attention",
  "headroom",
] as const;
const section = z.object({
  version: z.number().int().nonnegative().safe(),
  sampledAtUnixSeconds: z.number().nonnegative(),
  lastSuccessAt: z.number().nonnegative().nullable(),
  freshness: z.enum(["fresh", "stale", "unavailable"]),
  code: z.string().nullable(),
  data: z.unknown(),
});
const envelope = z.object({
  protocol: z.literal(1),
  epoch: z.string().max(64),
  sequence: z.number().positive().int().safe(),
  kind: z.enum(["snapshot", "update"]),
  sections: z.partialRecord(z.enum(names), section),
});
const clientsSchema = z
  .array(
    z.object({
      keyID: z.string(),
      displayName: z.string().nullable(),
      count: z.number().int().positive(),
      connectedAtUnixSeconds: z.number(),
    }),
  )
  .max(1024);
export type LiveClients = z.infer<typeof clientsSchema>;
export type Freshness = z.infer<typeof section>;
function parse(name: string, value: unknown): unknown {
  switch (name) {
    case "daily":
      return daily.parse(value);
    case "keys":
      return keySummary.parse(value);
    case "inFlight":
      return flight.parse(value).rows;
    case "headroom":
      return headroomSchema.parse(value);
    case "attention":
      return report.parse(value);
    case "accounts":
      return z
        .object({
          accounts: z.array(z.unknown()).max(64),
          nextCursor: z.null(),
        })
        .parse(value)
        .accounts.map(parseAccount);
    case "storage":
      return parseStorage(z.record(z.string(), z.unknown()).parse(value));
    case "system":
      return parseSystemStatus(value);
  }
}
export function useOverviewLive(active: boolean) {
  const owner = useManagementSession();
  const client = useQueryClient();
  const [failure, setFailure] = useState("");
  const [mode, setMode] = useState<
    "connecting" | "live" | "polling" | "paused"
  >("connecting");
  const [sources, setSources] = useState<Record<string, Freshness>>({});
  const [clients, setClients] = useState<LiveClients>([]);
  const [recent, setRecent] = useState<z.infer<typeof flight>["rows"]>([]);
  const [overflow, setOverflow] = useState(0);
  const [reset, setReset] = useState(0);
  const [manualBusy, setManualBusy] = useState(false);
  const [clock, setClock] = useState(Date.now());
  const transportGeneration = useRef(0);
  const [transportRevision, setTransportRevision] = useState(0);
  const socketRef = useRef<WebSocket | null>(null);
  const ownerRef = useRef(owner);
  ownerRef.current = owner;
  const authenticated = !!owner.session;
  useEffect(() => {
    if (!active || !authenticated || manualBusy) {
      setMode("paused");
      setRecent([]);
      return;
    }
    const transport = ++transportGeneration.current;
    let pending = 0;
    let retired = false,
      attempt = 0,
      sequence = 0,
      epoch = "",
      snapshot = false;
    let socket: WebSocket | null = null;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    let probe: ReturnType<typeof setTimeout> | undefined;
    let stable: ReturnType<typeof setTimeout> | undefined;
    let merge = Promise.resolve();
    const controller = new AbortController();
    const generation = owner.generation;
    const current = () =>
      !retired &&
      transport === transportGeneration.current &&
      generation === ownerRef.current.generation;
    async function checkSession() {
      try {
        const session = await fetchSession(controller.signal);
        if (current()) ownerRef.current.adopt(session);
      } catch (error) {
        if (
          current() &&
          error instanceof ManagementError &&
          error.status === 401
        )
          ownerRef.current.invalidate();
      }
    }
    function connect() {
      if (!current()) return;
      snapshot = false;
      sequence = 0;
      epoch = "";
      setMode(attempt ? "polling" : "connecting");
      socket = new WebSocket(
        `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/api/overview/live`,
      );
      socketRef.current = socket;
      const connection = socket;
      timeout = setTimeout(() => connection.close(), 10000);
      connection.onmessage = (event) => {
        if (
          pending >= 2 ||
          typeof event.data !== "string" ||
          event.data.length > 1048576
        ) {
          connection.close();
          return;
        }
        pending += 1;
        merge = merge
          .then(async () => {
            if (!current() || connection !== socket) return;
            if (typeof event.data !== "string" || event.data.length > 1048576)
              throw new Error("invalid_message");
            const frame = envelope.parse(JSON.parse(event.data));
            if (
              frame.sequence !== sequence + 1 ||
              (sequence && frame.epoch !== epoch) ||
              (!snapshot && frame.kind !== "snapshot") ||
              (snapshot && frame.kind === "snapshot")
            )
              throw new Error("sequence_mismatch");
            if (!snapshot && names.some((name) => !(name in frame.sections)))
              throw new Error("incomplete_snapshot");
            const parsed = Object.entries(frame.sections)
              .filter(
                (entry): entry is [string, Freshness] => entry[1] !== undefined,
              )
              .map(([name, source]) => ({
                name,
                source,
                data:
                  source.data == null ? undefined : parse(name, source.data),
              }));
            await client.cancelQueries({ queryKey: ["overview"] });
            if (!current() || connection !== socket) return;
            for (const { name, source, data } of parsed) {
              if (data !== undefined)
                client.setQueryData(
                  ["overview", name === "inFlight" ? "in-flight" : name],
                  data,
                  { updatedAt: (source.lastSuccessAt ?? 0) * 1000 },
                );
              if (name === "inFlight" && source.data != null) {
                const activity = z
                  .object({
                    recentlyFinished: z
                      .array(
                        flight.shape.rows.element.extend({
                          outcome: z.string(),
                          finishedAtUnixSeconds: z.number(),
                        }),
                      )
                      .max(64),
                    clients: clientsSchema,
                    overflow: z.number().int().nonnegative(),
                  })
                  .parse(source.data);
                setClients(activity.clients);
                setRecent(activity.recentlyFinished);
                setOverflow(activity.overflow);
                client.setQueryData(
                  ["overview", "recent"],
                  activity.recentlyFinished,
                );
              }
            }
            setSources((previous) => ({ ...previous, ...frame.sections }));
            epoch = frame.epoch;
            sequence = frame.sequence;
            if (!snapshot) {
              snapshot = true;
              clearTimeout(timeout);
              setReset((value) => value + 1);
              setMode("live");
              stable = setTimeout(() => {
                attempt = 0;
              }, 60000);
            }
          })
          .catch((error: unknown) => {
            const code =
              error instanceof Error &&
              [
                "invalid_message",
                "sequence_mismatch",
                "incomplete_snapshot",
              ].includes(error.message)
                ? error.message
                : "invalid_section";
            setFailure(code);
            connection.close();
          })
          .finally(() => {
            pending -= 1;
          });
      };
      connection.onclose = () => {
        if (!current() || connection !== socket) return;
        clearTimeout(timeout);
        clearTimeout(stable);
        socket = null;
        socketRef.current = null;
        setMode("polling");
        setRecent([]);
        setClients([]);
        void checkSession();
        attempt += 1;
        probe = setTimeout(
          connect,
          attempt >= 3
            ? 60000
            : Math.random() * Math.min(30000, 1000 * 2 ** (attempt - 1)),
        );
      };
      connection.onerror = () => {
        connection.close();
      };
    }
    connect();
    const timer = setInterval(() => {
      if (!document.hidden) setClock(Date.now());
    }, 1000);
    return () => {
      retired = true;
      controller.abort();
      clearTimeout(timeout);
      clearTimeout(probe);
      clearTimeout(stable);
      clearInterval(timer);
      socket?.close();
      socketRef.current = null;
    };
  }, [
    active,
    authenticated,
    owner.generation,
    client,
    manualBusy,
    transportRevision,
  ]);
  async function manualRefresh() {
    ++transportGeneration.current;
    socketRef.current?.close();
    setManualBusy(true);
    await client.cancelQueries({ queryKey: ["overview"] });
    await client.refetchQueries({ queryKey: ["overview"], type: "active" });
    setManualBusy(false);
    setTransportRevision((value) => value + 1);
  }
  const stale = Object.entries(sources).filter(
    ([name, source]) =>
      source.freshness !== "fresh" ||
      source.lastSuccessAt == null ||
      clock / 1000 - source.lastSuccessAt >
        (name === "storage"
          ? 6
          : ["accounts", "attention"].includes(name)
            ? 45
            : 15),
  );
  return {
    failure,
    mode,
    sources,
    clients,
    recent,
    overflow,
    reset,
    stale,
    manualRefresh,
  };
}
