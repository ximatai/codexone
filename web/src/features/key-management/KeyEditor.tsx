import { usePrivacyMask } from "../../shared/privacy-mask";
import { DateInput } from "@mantine/dates";
import { isUTCDateInput } from "./date-input";
import { TokenLimitInput } from "./TokenLimitInput";
import styles from "./keys.module.css";
import { useRef, useState } from "react";
import {
  Alert,
  Select,
  Button,
  Checkbox,
  Group,
  NumberInput,
  Radio,
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
    models: z.array(z.string()).nullable(),
    visionInput: z.boolean(),
    imageGeneration: z.boolean(),
    imageModels: z.array(z.string()).nullable(),
    limits: z.object({
      tokens: integer,
      active: integer,
    }),
  })
  .superRefine((value, context) => {
    if (value.models !== null && !value.models.length && !value.imageGeneration)
      context.addIssue({
        code: "custom",
        path: ["models"],
        message: "请选择对话模型或图片生成权限",
      });
    if (
      value.imageGeneration &&
      value.imageModels !== null &&
      !value.imageModels.length
    )
      context.addIssue({
        code: "custom",
        path: ["imageModels"],
        message: "请选择图片模型",
      });
  });
import { limitLabels } from "../../shared/presentation";
const fields: [keyof KeyLimits, string][] = [
  ["active", limitLabels.active],
  ["tokens", "每日 Token 上限"],
];
export function KeyEditor({
  entry,
  models,
  imageModels,
  disabled,
  submit,
  close,
  hideCancel = false,
  hideSubmit = false,
  formId,
}: {
  entry?: ManagedKey;
  models: string[];
  imageModels: string[];
  disabled: boolean;
  submit: (draft: KeyDraft, expires?: number | null) => Promise<boolean>;
  close: () => void;
  hideCancel?: boolean;
  hideSubmit?: boolean;
  formId?: string;
}) {
  const masked = usePrivacyMask();
  const retainedScopes = useRef({
    models: entry?.models ?? [],
    imageModels: entry?.imageModels ?? [],
  });
  const retainedLimits = useRef<Partial<Record<keyof KeyLimits, number>>>({});
  const [expiration, setExpiration] = useState("never");
  const [expirationDate, setExpirationDate] = useState("");
  const [expirationInvalid, setExpirationInvalid] = useState(false);
  const [calendarOpen, setCalendarOpen] = useState(false);
  const form = useForm({
    initialValues: {
      displayName: entry?.displayName ?? "",
      principal: entry?.principal ?? "",
      models: entry ? entry.models : ([] as string[] | null),
      visionInput: entry?.visionInput ?? false,
      imageGeneration: entry?.imageGeneration ?? false,
      imageModels:
        entry?.imageModels === null
          ? null
          : (entry?.imageModels ?? ([] as string[] | null)),
      limits: {
        tokens: entry ? entry.limits.tokens : 1_000_000,
        active: entry ? entry.limits.active : 4,
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
      id={formId}
      className={entry ? styles.detailEditor : undefined}
      onSubmit={(event) => {
        event.preventDefault();
        const result = schema.safeParse(form.values);
        if (!result.success) {
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
          (expirationInvalid || !Number.isSafeInteger(expires) || expires <= 0)
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
      <Stack gap={entry ? "md" : "lg"}>
        {!entry && (
          <TextInput
            label="主体标识"
            type={masked ? "password" : "text"}
            aria-label="主体标识"
            withAsterisk
            placeholder="例如 team-a"
            required
            disabled={disabled || !!entry}
            maxLength={64}
            {...form.getInputProps("principal")}
          />
        )}
        {entry && (
          <TextInput
            label="显示名"
            type={masked ? "password" : "text"}
            title="留空恢复主体标识"
            disabled={disabled}
            {...form.getInputProps("displayName")}
          />
        )}
        {!entry && (
          <Text size="xs" c="dimmed">
            主体隔离会话，创建后不可修改。
          </Text>
        )}
        <div className={entry ? styles.permissionsCard : undefined}>
          {entry && (
            <Text fw={600} size="sm" mb="md">
              模型与能力权限
            </Text>
          )}
          <fieldset className={styles.fieldset}>
            <legend>对话模型</legend>
            <Stack gap="xs">
              <Radio.Group
                label="对话模型范围"
                styles={{ label: { display: "none" } }}
                value={form.values.models === null ? "all" : "selected"}
                onChange={(value) => {
                  if (form.values.models !== null)
                    retainedScopes.current.models = form.values.models;
                  form.setFieldValue(
                    "models",
                    value === "all" ? null : retainedScopes.current.models,
                  );
                }}
              >
                <Group gap="md">
                  <Radio
                    value="all"
                    label="全部模型（跟随配置）"
                    disabled={disabled}
                  />
                  <Radio
                    value="selected"
                    label="指定模型"
                    disabled={disabled}
                  />
                </Group>
              </Radio.Group>
              {form.values.models !== null &&
                choices(
                  models,
                  entry?.models ?? [],
                  form.values.models,
                  "models",
                )}
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
                title="允许对话模型理解上传的图片；图片生成单独授权。"
                disabled={disabled}
                {...form.getInputProps("visionInput", { type: "checkbox" })}
              />
              {(imageModels.length > 0 || entry?.imageGeneration) && (
                <>
                  <Checkbox
                    label="图片生成与参考图编辑"
                    title="允许调用图片模型生成或编辑图片。"
                    disabled={disabled}
                    {...form.getInputProps("imageGeneration", {
                      type: "checkbox",
                    })}
                  />
                  {form.values.imageGeneration && (
                    <>
                      <Radio.Group
                        label="图片模型范围"
                        value={
                          form.values.imageModels === null ? "all" : "selected"
                        }
                        onChange={(value) => {
                          if (form.values.imageModels !== null)
                            retainedScopes.current.imageModels =
                              form.values.imageModels;
                          form.setFieldValue(
                            "imageModels",
                            value === "all"
                              ? null
                              : retainedScopes.current.imageModels,
                          );
                        }}
                      >
                        <Group gap="md">
                          <Radio
                            value="all"
                            label="全部模型（跟随配置）"
                            disabled={disabled}
                          />
                          <Radio
                            value="selected"
                            label="指定模型"
                            disabled={disabled}
                          />
                        </Group>
                      </Radio.Group>
                      {form.values.imageModels !== null &&
                        choices(
                          imageModels,
                          entry?.imageModels ?? [],
                          form.values.imageModels,
                          "imageModels",
                        )}
                    </>
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
        </div>
        <fieldset
          className={`${styles.fieldset} ${entry ? styles.limitsCard : ""}`}
        >
          <legend>本地治理限额</legend>
          <Stack gap="md">
            <div className={styles.limitGrid}>
              {fields.map(([name, label]) => (
                <Stack key={name} gap={6}>
                  <Checkbox
                    label="不限"
                    aria-label={`${label}不限`}
                    disabled={disabled}
                    checked={form.values.limits[name] === null}
                    onChange={(event) => {
                      const value = form.values.limits[name];
                      if (event.currentTarget.checked && value !== null)
                        retainedLimits.current[name] = value;
                      form.setFieldValue(
                        `limits.${name}`,
                        event.currentTarget.checked
                          ? null
                          : (retainedLimits.current[name] ?? 1),
                      );
                    }}
                  />
                  {name === "tokens" ? (
                    <TokenLimitInput
                      value={form.values.limits.tokens}
                      disabled={disabled || form.values.limits.tokens === null}
                      onChange={(value) =>
                        form.setFieldValue("limits.tokens", value)
                      }
                      error={form.errors["limits.tokens"]}
                    />
                  ) : (
                    <NumberInput
                      style={{ order: -1 }}
                      label={label}
                      aria-label={label}
                      withAsterisk={form.values.limits[name] !== null}
                      min={1}
                      max={1_000_000_000_000}
                      allowDecimal={false}
                      {...form.getInputProps(`limits.${name}`)}
                      value={
                        form.values.limits[name] === null
                          ? ""
                          : form.values.limits[name]!
                      }
                      onChange={(value) =>
                        form.setFieldValue(
                          `limits.${name}`,
                          typeof value === "number" ? value : 0,
                        )
                      }
                      disabled={disabled || form.values.limits[name] === null}
                      placeholder={
                        form.values.limits[name] === null ? "不限" : undefined
                      }
                    />
                  )}
                </Stack>
              ))}
            </div>
            <Text size="xs" c="dimmed">
              UTC
              每日重置；输入（含缓存）＋输出。达到已观测上限后拒绝新请求，进行中的请求继续；缺失用量仍为未知。
            </Text>
          </Stack>
        </fieldset>
        {!entry && (
          <Stack gap="xs">
            <Select
              label="到期时间"
              value={expiration}
              disabled={disabled}
              allowDeselect={false}
              comboboxProps={{ withinPortal: true, zIndex: 350 }}
              onChange={(selection) => {
                const value = selection ?? "never";
                setExpiration(value);
                setExpirationInvalid(false);
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
              <DateInput
                label="到期日期（UTC）"
                aria-label="到期日期（UTC）"
                locale="zh-cn"
                valueFormat="YYYY-MM-DD"
                fixOnBlur={false}
                allowDeselect
                popoverProps={{
                  withinPortal: true,
                  zIndex: 350,
                  onOpen: () => setCalendarOpen(true),
                  onClose: () => setCalendarOpen(false),
                }}
                data-mantine-stop-propagation={
                  calendarOpen ? "true" : undefined
                }
                getDayProps={(day) => ({
                  "aria-label": day,
                  "data-mantine-stop-propagation": "true",
                })}
                onKeyDown={(event) => {
                  if (event.key === "Escape" && calendarOpen)
                    event.stopPropagation();
                }}
                dateParser={(value) => (isUTCDateInput(value) ? value : null)}
                onInputCapture={(event) =>
                  setExpirationInvalid(
                    !isUTCDateInput(event.currentTarget.value),
                  )
                }
                error={
                  expirationInvalid ? "请输入有效日期（YYYY-MM-DD）" : undefined
                }
                required
                disabled={disabled}
                value={expirationDate || null}
                onChange={(value) => {
                  setExpiration("custom");
                  setExpirationDate(value ?? "");
                  setExpirationInvalid(false);
                }}
              />
            )}
            <Text size="xs" c="dimmed">
              所选日期 UTC 00:00 起失效（快捷项至少保留整 N
              天）；到期后拒绝新请求，已派发请求继续。
            </Text>
            {expiration !== "never" &&
              Date.parse(expirationDate + "T00:00:00Z") <= Date.now() && (
                <Alert color="yellow">
                  所选时间已过去，保存后立即拒绝新请求。
                </Alert>
              )}
          </Stack>
        )}
        {!hideSubmit && (
          <Group justify="flex-end">
            {!hideCancel && (
              <Button
                variant="default"
                type="button"
                disabled={disabled}
                onClick={close}
              >
                取消
              </Button>
            )}
            <Button
              type="submit"
              disabled={
                disabled || (!entry && !models.length && !imageModels.length)
              }
            >
              {entry ? "保存修改" : "创建密钥"}
            </Button>
          </Group>
        )}
      </Stack>
    </form>
  );
}
