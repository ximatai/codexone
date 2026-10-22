import { useRef } from "react";
import {
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
const integer = z.number().int().min(1).max(1_000_000_000_000);
const schema = z
  .object({
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
const fields: [keyof KeyLimits, string][] = [
  ["requests", "每日请求（UTC）"],
  ["active", "同时执行"],
  ["unresolved", "未结执行数量"],
  ["budgetMicros", "每日估算阈值（微单位）"],
  ["unresolvedMicros", "未结暴露阈值（微单位）"],
];
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
  submit: (draft: KeyDraft) => Promise<boolean>;
  close: () => void;
}) {
  const advanced = useRef<HTMLDetailsElement>(null);
  const form = useForm({
    initialValues: {
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
          if (
            result.error.issues.some((issue) => issue.path[0] === "limits") &&
            advanced.current
          )
            advanced.current.open = true;
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
        void submit(result.data);
      }}
    >
      <Stack gap="lg">
        <TextInput
          label="主体标识"
          withAsterisk={false}
          placeholder="例如 team-a"
          required
          disabled={disabled || !!entry}
          maxLength={64}
          {...form.getInputProps("principal")}
        />
        {!entry && (
          <Text size="xs" c="dimmed">
            主体隔离会话，创建后不可修改。
          </Text>
        )}
        <fieldset className="editor-fieldset">
          <legend>对话模型</legend>
          <Stack gap="xs">
            {choices(models, entry?.models ?? [], form.values.models, "models")}
          </Stack>
          {form.errors.models && (
            <Text c="red" size="sm" role="alert">
              {form.errors.models}
            </Text>
          )}
        </fieldset>
        <fieldset className="editor-fieldset">
          <legend>图片能力</legend>
          <Stack gap="sm">
            <Checkbox
              label="视觉输入"
              disabled={disabled}
              {...form.getInputProps("visionInput", { type: "checkbox" })}
            />
            {(imageModels.length > 0 || entry?.imageGeneration) && (
              <>
                <Checkbox
                  label="图片生成与参考图编辑"
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
        <details ref={advanced}>
          <summary>本地治理限额</summary>
          <Stack gap="md" mt="md">
            {fields.map(([name, label]) => (
              <NumberInput
                key={name}
                label={label}
                min={1}
                max={1_000_000_000_000}
                allowDecimal={false}
                disabled={disabled}
                {...form.getInputProps(`limits.${name}`)}
              />
            ))}
            <Alert color="gray">
              这些是本地阈值，不是订阅余额。预热和压缩计入请求，未知用量保留预留。
            </Alert>
          </Stack>
        </details>
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
            {entry ? "保存修改" : "创建 API Key"}
          </Button>
        </Group>
      </Stack>
    </form>
  );
}
