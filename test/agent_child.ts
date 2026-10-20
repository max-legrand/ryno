// Helper for multi.ts: a mock agent process hosting the real extension.
import * as fs from "node:fs";
import * as path from "node:path";
import ryno from "../extension/ryno.ts";

const [cwd, file, delayMs] = [process.env.CHILD_CWD!, process.env.CHILD_FILE!, Number(process.env.CHILD_DELAY ?? 0)];
const handlers: Record<string, Function> = {};
ryno({ on: (n: string, h: Function) => (handlers[n] = h) } as any);
const ctx = { cwd, ui: {}, sessionManager: { getSessionId: () => "s" }, signal: undefined };
await handlers.session_start({}, ctx);
await Bun.sleep(delayMs);
const r = await handlers.tool_call(
  { toolName: "edit", toolCallId: "c-" + process.pid, input: { path: file, edits: [{ oldText: "beta", newText: "BETA" }] } },
  ctx,
);
console.log(JSON.stringify({ blocked: !!r?.block, reason: r?.reason?.slice(0, 40) ?? null, file: fs.readFileSync(path.join(cwd, file), "utf8") }));
await handlers.session_shutdown({ reason: "quit" });
process.exit(0);
