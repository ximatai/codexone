import styles from "./session.module.css";
import {
  Button,
  Paper,
  PasswordInput,
  Stack,
  Title,
  Alert,
} from "@mantine/core";
import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import * as api from "./management";

type Status =
  | "checking"
  | "authenticated"
  | "anonymous"
  | "failed"
  | "unavailable"
  | "logout-unconfirmed";
type Scope = "keys" | "accounts" | "executions";
interface SessionOwner {
  session: api.AdminSession | null;
  generation: number;
  adopt: (value: api.AdminSession) => boolean;
  invalidate: () => void;
  locked: (scope: Scope) => boolean;
  lock: (scope: Scope, value: boolean) => void;
}
const Context = createContext<SessionOwner | null>(null);
export function useManagementSession() {
  const value = useContext(Context);
  if (!value) throw new Error("Management session owner missing");
  return value;
}
export function ManagementSession({
  children,
  publicView = false,
}: {
  children: ReactNode;
  publicView?: boolean;
}) {
  const [status, setStatus] = useState<Status>("checking");
  const [session, setSession] = useState<api.AdminSession | null>(null);
  const [generation, setGeneration] = useState(0);
  const [credential, setCredential] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [, updateLocks] = useState(0);
  const locks = useRef(new Set<Scope>());
  const proof = useRef<string | null>(null);
  const lifetime = useRef<AbortController | null>(null);
  const sequence = useRef(0);
  const currentStatus = useRef(status);
  currentStatus.current = status;
  function clear(next: Status) {
    ++sequence.current;
    api.retireManagementRequests();
    currentStatus.current = next;
    proof.current = null;
    locks.current.clear();
    setNotice("");
    setSession(null);
    setCredential("");
    setGeneration((value) => value + 1);
    setStatus(next);
  }
  function invalidate() {
    clear("anonymous");
    setBusy(false);
    setError("管理会话已结束，请重新登录。");
  }
  function adopt(value: api.AdminSession) {
    if (proof.current !== value.csrf) {
      if (proof.current)
        setNotice("管理会话已更新，请重新发起需要的授权流程。");
      ++sequence.current;
      api.retireManagementRequests();
      locks.current.clear();
      setGeneration((previous) => previous + 1);
    }
    proof.current = value.csrf;
    currentStatus.current = "authenticated";
    setSession(value);
    setStatus("authenticated");
  }
  async function connect(secret?: string) {
    const signal = lifetime.current?.signal;
    if (!signal || signal.aborted) return;
    const version = ++sequence.current;
    setBusy(true);
    setError("");
    try {
      const value =
        secret === undefined
          ? await api.fetchSession(signal)
          : await api.login(secret, signal);
      if (signal.aborted || version !== sequence.current) return;
      adopt(value);
    } catch (cause) {
      if (signal.aborted || version !== sequence.current) return;
      setSession(null);
      if (cause instanceof api.ManagementError && cause.status === 401) {
        setStatus("anonymous");
        if (secret !== undefined) setError("管理员凭证无效，请重新输入。");
      } else if (cause instanceof api.ManagementError && cause.status === 404)
        setStatus("unavailable");
      else {
        setStatus(secret === undefined ? "failed" : "anonymous");
        setError("无法连接管理服务，请重试。");
      }
    } finally {
      if (!signal.aborted) setBusy(false);
    }
  }
  async function logout() {
    const signal = lifetime.current?.signal;
    if (!signal || signal.aborted || busy) return;
    clear("logout-unconfirmed");
    const version = sequence.current;
    setBusy(true);
    setError("");
    try {
      const fresh = await api.fetchSession(signal);
      if (signal.aborted || version !== sequence.current) return;
      await api.logout(fresh.csrf, signal);
      if (!signal.aborted && version === sequence.current) clear("anonymous");
    } catch (cause) {
      if (signal.aborted || version !== sequence.current) return;
      if (cause instanceof api.ManagementError && cause.status === 401)
        clear("anonymous");
      else setError("服务端登出尚未确认。本页内容已清除，请重试登出。");
    } finally {
      if (!signal.aborted) setBusy(false);
    }
  }
  useEffect(() => {
    const controller = new AbortController();
    lifetime.current = controller;
    const unsubscribe = api.onUnauthorized(() => {
      if (currentStatus.current === "authenticated") invalidate();
    });
    void connect();
    return () => {
      // This numeric epoch retires asynchronous work; it is not a DOM ref.
      // eslint-disable-next-line react-hooks/exhaustive-deps
      ++sequence.current;
      controller.abort();
      api.retireManagementRequests();
      unsubscribe();
    };
  }, []);
  const renderEpoch = sequence.current;
  const owner: SessionOwner = {
    session,
    generation,
    adopt: (value) => {
      if (renderEpoch !== sequence.current) return false;
      const same = proof.current === value.csrf;
      adopt(value);
      return same;
    },
    invalidate: () => {
      if (renderEpoch === sequence.current) invalidate();
    },
    locked: (scope) =>
      renderEpoch !== sequence.current || locks.current.has(scope),
    lock: (scope, value) => {
      if (renderEpoch !== sequence.current) return;
      if (value) locks.current.add(scope);
      else locks.current.delete(scope);
      updateLocks((previous) => previous + 1);
    },
  };
  return (
    <Context.Provider value={owner}>
      <div className={styles.action}>
        {status === "authenticated" && (
          <Button
            variant="subtle"
            onClick={() => void logout()}
            disabled={busy}
          >
            退出登录
          </Button>
        )}
      </div>
      {status === "authenticated" && notice && (
        <Alert role="status" mb="md">
          {notice}
        </Alert>
      )}
      {status === "authenticated" || publicView ? (
        <div key={generation}>{children}</div>
      ) : (
        <Paper className={styles.login} withBorder p="xl" radius="md">
          <Stack>
            <Title order={1} size="h3">
              {status === "logout-unconfirmed"
                ? "登出状态待确认"
                : status === "unavailable"
                  ? "管理入口尚未启用"
                  : "管理员登录"}
            </Title>
            {error && (
              <Alert role="alert" color="red">
                {error}
              </Alert>
            )}
            {status === "checking" ? (
              <p role="status">正在验证管理会话…</p>
            ) : status === "logout-unconfirmed" ? (
              <Button disabled={busy} onClick={() => void logout()}>
                重试登出
              </Button>
            ) : status === "failed" || status === "unavailable" ? (
              <Button disabled={busy} onClick={() => void connect()}>
                重新连接
              </Button>
            ) : (
              <form
                onSubmit={(event) => {
                  event.preventDefault();
                  if (busy) return;
                  const value = credential;
                  setCredential("");
                  void connect(value);
                }}
              >
                <Stack>
                  <PasswordInput
                    visibilityToggleButtonProps={{
                      "aria-label": "显示或隐藏管理员凭证",
                    }}
                    label="管理员凭证"
                    withAsterisk={false}
                    autoComplete="off"
                    required
                    value={credential}
                    disabled={busy}
                    onChange={(event) =>
                      setCredential(event.currentTarget.value)
                    }
                  />
                  <Button type="submit" disabled={busy}>
                    登录管理台
                  </Button>
                </Stack>
              </form>
            )}
          </Stack>
        </Paper>
      )}
    </Context.Provider>
  );
}
