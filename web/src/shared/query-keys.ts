export const queryKeys = {
  keys: {
    all: ["keys"] as const,
    list: () => ["keys", "list"] as const,
    options: () => ["keys", "options"] as const,
  },
  usage: { all: ["usage"] as const, keys: () => ["usage", "keys"] as const },
  overview: { all: ["overview"] as const },
};
