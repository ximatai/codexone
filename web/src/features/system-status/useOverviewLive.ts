import {
  useCallback,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
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
  data: z.unknown().optional(),
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
const hourlyRate = z.object({
  endUnixSeconds: z.number().int().nonnegative(),
  offsetMinutes: z.number().int().min(-720).max(840).multipleOf(60),
  points: z.record(
    z.string(),
    z.object({
      median: z.number().finite().nonnegative(),
      count: z.number().int().positive(),
    }),
  ),
});
export type HourlyOutputRate = z.infer<typeof hourlyRate>;
const liveActivity = flight.extend({
  clients: clientsSchema,
  recentRequestOutputRateMedian: z.number().finite().nonnegative().nullish(),
  requestOutputRateMediansByDay: z
    .record(z.string(), z.number().finite().nonnegative())
    .optional(),
  requestOutputRateByHour: hourlyRate.optional(),
  overflow: z.number().int().nonnegative(),
});
export type LiveClients = z.infer<typeof clientsSchema>;
export type Freshness = z.infer<typeof section>;
const queryKey = (name: string) => [
  "overview",
  name === "inFlight" ? "in-flight" : name,
];
function parse(name: string, value: unknown): unknown {
  switch (name) {
    case "daily":
      return daily.parse(value);
    case "keys":
      return keySummary.parse(value);
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
  const [requestOutputRateMedian, setRequestOutputRateMedian] = useState<
    number | null
  >();
  const [requestOutputRateByHour, setRequestOutputRateByHour] =
    useState<HourlyOutputRate>();
  const [clients, setClients] = useState<LiveClients>([]);
  const [overflow, setOverflow] = useState(0);
  const [reset, setReset] = useState(0);
  const [clock, setClock] = useState(Date.now());
  const [flightAtDisconnect, setFlightAtDisconnect] = useState<number>();
  const retryConnection = useRef<() => void>(() => {});
  const transportGeneration = useRef(0);
  const ownerRef = useRef(owner);
  ownerRef.current = owner;
  const authenticated = !!owner.session;
  useEffect(() => {
    if (!active || !authenticated) {
      setMode("paused");
      return;
    }
    const transport = ++transportGeneration.current;
    let pending = 0;
    let versions: Record<string, number> = {};
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
      versions = {};
      setMode(attempt ? "polling" : "connecting");
      socket = new WebSocket(
        `${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/api/overview/live`,
      );
      const connection = socket;
      let manualRetry = false;
      retryConnection.current = () => {
        if (connection.readyState !== WebSocket.OPEN) return;
        manualRetry = true;
        connection.close();
      };
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
            if (
              !snapshot &&
              Object.values(frame.sections).some(
                (source) => !source || !("data" in source),
              )
            )
              throw new Error("incomplete_snapshot");
            const parsed = Object.entries(frame.sections)
              .filter(
                (entry): entry is [string, Freshness] => entry[1] !== undefined,
              )
              .map(([name, source]) => {
                const activity =
                  name === "inFlight" && source.data != null
                    ? liveActivity.parse(source.data)
                    : undefined;
                return {
                  name,
                  source,
                  activity,
                  data:
                    source.data == null
                      ? undefined
                      : (activity?.rows ?? parse(name, source.data)),
                };
              });
            if (
              parsed.some(
                ({ name, source }) => source.version < (versions[name] ?? 0),
              )
            )
              throw new Error("sequence_mismatch");
            await Promise.all(
              parsed.map(({ name }) =>
                client.cancelQueries({ queryKey: queryKey(name), exact: true }),
              ),
            );
            if (!current() || connection !== socket) return;
            for (const { name, source, data, activity } of parsed) {
              versions[name] = source.version;
              const key = queryKey(name);
              const replacement =
                data ??
                (!("data" in source) ? client.getQueryData(key) : undefined);
              if (replacement !== undefined)
                client.setQueryData(key, replacement, {
                  updatedAt: (source.lastSuccessAt ?? 0) * 1000,
                });
              if (activity) {
                setRequestOutputRateMedian(
                  activity.recentRequestOutputRateMedian,
                );
                setRequestOutputRateByHour(activity.requestOutputRateByHour);
                setClients(activity.clients);
                setOverflow(activity.overflow);
              } else if (name === "inFlight" && source.data === null) {
                setRequestOutputRateMedian(undefined);
                setRequestOutputRateByHour(undefined);
              }
            }
            setSources((previous) => {
              const next = { ...previous };
              for (const { name, source } of parsed)
                next[name] =
                  "data" in source
                    ? source
                    : { ...source, data: previous[name]?.data };
              return next;
            });
            epoch = frame.epoch;
            sequence = frame.sequence;
            if (!snapshot) {
              snapshot = true;
              clearTimeout(timeout);
              setReset((value) => value + 1);
              setFlightAtDisconnect(undefined);
              setMode("live");
              stable = setTimeout(() => {
                attempt = 0;
              }, 60000);
            }
          })
          .catch((error: unknown) => {
            if (!current() || connection !== socket) return;
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
        setMode("polling");
        setClients([]);
        setOverflow(0);
        if (snapshot) {
          const key = queryKey("inFlight");
          setFlightAtDisconnect(
            client.getQueryState(key)?.dataUpdateCount ?? 0,
          );
          void client.refetchQueries({
            queryKey: key,
            exact: true,
            type: "active",
          });
        }
        void checkSession();
        attempt += 1;
        probe = setTimeout(
          connect,
          manualRetry
            ? 0
            : attempt >= 3
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
      retryConnection.current = () => {};
      controller.abort();
      clearTimeout(timeout);
      clearTimeout(probe);
      clearTimeout(stable);
      clearInterval(timer);
      socket?.close();
    };
  }, [active, authenticated, owner.generation, client]);
  const cache = client.getQueryCache();
  const subscribe = useCallback(
    (notify: () => void) => cache.subscribe(notify),
    [cache],
  );
  const readHTTP = useCallback(
    () =>
      JSON.stringify(
        names.map((name) => {
          const state = client.getQueryState(queryKey(name));
          return [
            name,
            state?.dataUpdatedAt ?? 0,
            state?.status ?? "pending",
            state?.dataUpdateCount ?? 0,
          ];
        }),
      ),
    [client],
  );
  const httpState = useSyncExternalStore(subscribe, readHTTP);
  const httpSources = JSON.parse(httpState) as [
    string,
    number,
    string,
    number,
  ][];
  const flightUnconfirmed =
    mode !== "live" &&
    flightAtDisconnect !== undefined &&
    httpSources.find(([name]) => name === "inFlight")?.[3] ===
      flightAtDisconnect;
  const observed: Record<string, Freshness> =
    mode === "live"
      ? sources
      : Object.fromEntries(
          httpSources
            .filter(([, updated, status]) => updated > 0 || status === "error")
            .map(([name, updated, status]) => [
              name,
              {
                version: 0,
                sampledAtUnixSeconds: updated / 1000,
                lastSuccessAt: updated ? updated / 1000 : null,
                freshness:
                  status === "error"
                    ? updated
                      ? "stale"
                      : "unavailable"
                    : "fresh",
                code: status === "error" ? "source_unavailable" : null,
              },
            ]),
        );
  const displayed = Object.fromEntries(
    Object.entries(observed).map(([name, source]) => {
      const limit =
        mode !== "live"
          ? 45
          : name === "storage"
            ? 6
            : ["accounts", "attention"].includes(name)
              ? 45
              : 15;
      return [
        name,
        source.freshness === "fresh" &&
        source.lastSuccessAt != null &&
        clock / 1000 - source.lastSuccessAt > limit
          ? { ...source, freshness: "stale" as const }
          : source,
      ];
    }),
  );
  const stale = Object.entries(displayed).filter(
    ([, source]) =>
      source.freshness !== "fresh" || source.lastSuccessAt == null,
  );
  const requestRateFresh =
    mode === "live" &&
    displayed.inFlight?.freshness === "fresh" &&
    displayed.inFlight.lastSuccessAt != null;
  return {
    failure,
    retry: () => retryConnection.current(),
    flightUnconfirmed,
    mode,
    sources: displayed,
    clients,
    requestOutputRateMedian: requestRateFresh
      ? requestOutputRateMedian
      : undefined,
    requestOutputRateByHour: requestRateFresh
      ? requestOutputRateByHour
      : undefined,
    overflow,
    reset,
    stale,
  };
}
