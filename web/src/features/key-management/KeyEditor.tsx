import styles from "./keys.module.css";
import { useRef, useState } from "react";
import {
  Accordion,
  NativeSelect,
  Alert,
  Button,
  Checkbox,
  Group,
  NumberInput,
  Stack,
  Text,
  TextInput,
} from "@mantine/core";
import { useForm } from "@mantine/form";
import { z } from "../../shared/schema";
import type { KeyDraft, KeyLimits, ManagedKey } from "./api";
const integer = z.number().int().min(1).max(1_000_000_000_000).nullable();
const schema = z
  .object({
    displayName: z
      .string()
      .refine(
        (value) =>
          value === "" ||
          ([...value].length <= 64 &&
            new TextEncoder().encode(value).length <= 256 &&
            !/[\p{Cc}\p{Cf}\p{Cs}\p{Zl}\p{Zp}]/u.test(value)),
        "显示名须为1–64个Unicode标量，且不含控制字符",
      ),
    principal: z
      .string()
      .regex(/^[A-Za-z0-9._-]{1,64}$/, "使用1–64位字母、数字或 . _ -"),
    models: z.array(z.string()),
    visionInput: z.boolean(),
    imageGeneration: z.boolean(),
    imageModels: z.array(z.string()),
    limits: z.object({
      requests: integer,
      active: integer,
      unresolved: integer,
      budgetMicros: integer,
      unresolvedMicros: integer,
    }),
  })
  .superRefine((value, context) => {
    if (!value.models.length && !value.imageGeneration)
      context.addIssue({
        code: "custom",
        path: ["models"],
        message: "请选择对话模型或图片生成权限",
      });
    if (value.imageGeneration && !value.imageModels.length)
      context.addIssue({
        code: "custom",
        path: ["imageModels"],
        message: "请选择图片模型",
      });
  });
import {
  limitLabels,
  dollarsToMicros,
  microsToDollars,
  money,
  estimateNote,
} from "../../shared/presentation";
const fields = Object.entries(limitLabels) as [keyof KeyLimits, string][];
export function KeyEditor({
  entry,
  models,
  imageModels,
  disabled,
  submit,
  close,
}: {
  entry?: ManagedKey;
  models: string[];
  imageModels: string[];
  disabled: boolean;
  submit: (draft: KeyDraft, expires?: number | null) => Promise<boolean>;
  close: () => void;
}) {
  const retainedLimits = useRef<Partial<Record<keyof KeyLimits, number>>>({});
  const [amounts, setAmounts] = useState<Record<string, string | number>>({
    budgetMicros: microsToDollars(entry?.limits.budgetMicros ?? 1_000_000),
    unresolvedMicros: microsToDollars(
      entry?.limits.unresolvedMicros ?? 1_000_000,
    ),
  });
  const [advanced, setAdvanced] = useState<string | null>(null);
  const [expiration, setExpiration] = useState("never");
  const [expirationDate, setExpirationDate] = useState("");
  const form = useForm({
    initialValues: {
      displayName: entry?.displayName ?? "",
      principal: entry?.principal ?? "",
      models: entry?.models ?? [],
      visionInput: entry?.visionInput ?? false,
      imageGeneration: entry?.imageGeneration ?? false,
      imageModels: entry?.imageModels ?? [],
      limits: entry?.limits ?? {
        requests: 1000,
        active: 4,
        unresolved: 8,
        budgetMicros: 1_000_000,
        unresolvedMicros: 1_000_000,
      },
    },
  });
  function choices(
    available: string[],
    retained: string[],
    selected: string[],
    name: "models" | "imageModels",
    blocked = false,
  ) {
    return [...new Set([...available, ...retained])].map((model) => (
      <Checkbox
        key={model}
        label={model}
        checked={selected.includes(model)}
        disabled={
          disabled ||
          blocked ||
          (!available.includes(model) && !selected.includes(model))
        }
        onChange={(event) =>
          form.setFieldValue(
            name,
            event.currentTarget.checked
              ? [...selected, model]
              : selected.filter((value) => value !== model),
          )
        }
      />
    ));
  }
  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        const result = schema.safeParse(form.values);
        if (!result.success) {
          if (result.error.issues.some((issue) => issue.path[0] === "limits"))
            setAdvanced("limits");
          form.setErrors(
            Object.fromEntries(
              result.error.issues.map((issue) => [
                issue.path.join("."),
                issue.message,
              ]),
            ),
          );
          return;
        }
        form.clearErrors();
        const expires =
          expiration === "never"
            ? null
            : Date.parse(expirationDate + "T00:00:00Z") / 1000;
        if (
          !entry &&
          expires !== null &&
          (!Number.isSafeInteger(expires) || expires <= 0)
        ) {
          form.setFieldError("principal", "请选择有效到期日期");
          return;
        }
        const { displayName, ...draft } = result.data;
        void submit(
          entry ? { ...draft, displayName: displayName || null } : draft,
          expires,
        );
      }}
    >
      <Stack gap="lg">
        <TextInput
          label="主体标识"
          aria-label="主体标识"
          withAsterisk
          placeholder="例如 team-a"
          required
          disabled={disabled || !!entry}
          maxLength={64}
          {...form.getInputProps("principal")}
        />
        {entry && (
          <TextInput
            label="显示名"
            description="留空恢复主体标识"
            disabled={disabled}
            {...form.getInputProps("displayName")}
          />
        )}
        {!entry && (
          <Text size="xs" c="dimmed">
            主体隔离会话，创建后不可修改。
          </Text>
        )}
        <fieldset className={styles.fieldset}>
          <legend>对话模型</legend>
          <Stack gap="xs">
            <Checkbox
              label="全部模型"
              description="选择当前目录的全部对话模型，新增模型仍需手动授权。"
              checked={
                models.length > 0 &&
                models.every((model) => form.values.models.includes(model))
              }
              disabled={disabled || !models.length}
              onChange={(e) =>
                form.setFieldValue(
                  "models",
                  e.currentTarget.checked
                    ? [...new Set([...models, ...(entry?.models ?? [])])]
                    : [],
                )
              }
            />
            {choices(models, entry?.models ?? [], form.values.models, "models")}
          </Stack>
          {form.errors.models && (
            <Text c="red" size="sm" role="alert">
              {form.errors.models}
            </Text>
          )}
        </fieldset>
        <fieldset className={styles.fieldset}>
          <legend>图片能力</legend>
          <Stack gap="sm">
            <Checkbox
              label="视觉输入"
              description="ⓘ 让对话模型理解上传的图片，不授予图片生成权限。"
              disabled={disabled}
              {...form.getInputProps("visionInput", { type: "checkbox" })}
            />
            {(imageModels.length > 0 || entry?.imageGeneration) && (
              <>
                <Checkbox
                  label="图片生成与参考图编辑"
                  description="ⓘ 调用图片模型生成或编辑图片，与视觉输入分别授权。"
                  disabled={disabled}
                  {...form.getInputProps("imageGeneration", {
                    type: "checkbox",
                  })}
                />
                {form.values.imageGeneration &&
                  choices(
                    imageModels,
                    entry?.imageModels ?? [],
                    form.values.imageModels,
                    "imageModels",
                  )}
              </>
            )}
            {form.errors.imageModels && (
              <Text c="red" size="sm" role="alert">
                {form.errors.imageModels}
              </Text>
            )}
          </Stack>
        </fieldset>
        <Accordion value={advanced} onChange={setAdvanced}>
          <Accordion.Item value="limits">
            <Accordion.Control>
              <span>本地治理限额</span>
              <Text size="xs" c="dimmed">
                每日请求 {form.values.limits.requests ?? "不限"} · 并发{" "}
                {form.values.limits.active ?? "不限"} · 待核对{" "}
                {form.values.limits.unresolved ?? "不限"}
                <br />
                每日 {money(form.values.limits.budgetMicros, true)} · 待核对占用{" "}
                {money(form.values.limits.unresolvedMicros, true)}
              </Text>
            </Accordion.Control>
            <Accordion.Panel>
              <Stack gap="md" mt="md">
                {fields.map(([name, label]) => (
                  <Stack key={name} gap="xs">
                    <Checkbox
                      label="不限"
                      aria-label={`${label}不限`}
                      disabled={disabled}
                      checked={form.values.limits[name] === null}
                      onChange={(event) => {
                        const value = form.values.limits[name];
                        if (event.currentTarget.checked && value !== null)
                          retainedLimits.current[name] = value;
                        if (
                          !event.currentTarget.checked &&
                          name.endsWith("Micros")
                        )
                          setAmounts((previous) => ({
                            ...previous,
                            [name]: microsToDollars(
                              retainedLimits.current[name] ?? 1,
                            ),
                          }));
                        form.setFieldValue(
                          `limits.${name}`,
                          event.currentTarget.checked
                            ? null
                            : (retainedLimits.current[name] ?? 1),
                        );
                      }}
                    />
                    <NumberInput
                      label={label}
                      aria-label={label}
                      withAsterisk={form.values.limits[name] !== null}
                      min={name.endsWith("Micros") ? 0.000001 : 1}
                      max={
                        name.endsWith("Micros") ? 1_000_000 : 1_000_000_000_000
                      }
                      allowDecimal={name.endsWith("Micros")}
                      decimalScale={name.endsWith("Micros") ? 6 : 0}
                      {...form.getInputProps(`limits.${name}`)}
                      value={
                        form.values.limits[name] === null
                          ? ""
                          : name.endsWith("Micros")
                            ? amounts[name]
                            : form.values.limits[name]!
                      }
                      onChange={(value) => {
                        if (name.endsWith("Micros"))
                          setAmounts((previous) => ({
                            ...previous,
                            [name]: value,
                          }));
                        try {
                          form.setFieldValue(
                            `limits.${name}`,
                            name.endsWith("Micros")
                              ? dollarsToMicros(value)
                              : Number(value),
                          );
                        } catch {
                          form.setFieldValue(`limits.${name}`, 0);
                        }
                      }}
                      disabled={disabled || form.values.limits[name] === null}
                      placeholder={
                        form.values.limits[name] === null ? "不限" : undefined
                      }
                    />
                  </Stack>
                ))}
                <Alert color="gray">
                  {estimateNote}
                  。这些是本地阈值，不是订阅余额。预热和压缩计入请求，待核对请求保留占用。
                </Alert>
              </Stack>
            </Accordion.Panel>
          </Accordion.Item>
        </Accordion>
        {!entry && (
          <Stack gap="xs">
            <NativeSelect
              label="到期时间"
              value={expiration}
              disabled={disabled}
              onChange={(e) => {
                const value = e.currentTarget.value;
                setExpiration(value);
                if (["7", "30", "90"].includes(value))
                  setExpirationDate(
                    new Date(Date.now() + (Number(value) + 1) * 86400000)
                      .toISOString()
                      .slice(0, 10),
                  );
              }}
              data={[
                { value: "never", label: "永不过期" },
                { value: "7", label: "7 天" },
                { value: "30", label: "30 天" },
                { value: "90", label: "90 天" },
                { value: "custom", label: "自定义日期" },
              ]}
            />
            {expiration !== "never" && (
              <TextInput
                label="到期日期（UTC）"
                aria-label="到期日期（UTC）"
                type="date"
                required
                disabled={disabled}
                value={expirationDate}
                onChange={(e) => {
                  setExpiration("custom");
                  setExpirationDate(e.currentTarget.value);
                }}
              />
            )}
            <Text size="xs" c="dimmed">
              所选日期 UTC 00:00 起失效（快捷项至少保留整 N
              天）；到期后拒绝新请求，已派发请求继续。
            </Text>
          </Stack>
        )}
        <Group justify="flex-end">
          <Button
            variant="default"
            type="button"
            disabled={disabled}
            onClick={close}
          >
            取消
          </Button>
          <Button
            type="submit"
            disabled={
              disabled || (!entry && !models.length && !imageModels.length)
            }
          >
            {entry ? "保存修改" : "创建密钥"}
          </Button>
        </Group>
      </Stack>
    </form>
  );
}
