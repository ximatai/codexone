import { z } from "zod";
// Management CSP forbids runtime code generation, including feature probes.
z.config({ jitless: true });
export { z };
