import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as net from "node:net";
import * as path from "node:path";
import { once } from "node:events";
import { createInterface } from "node:readline";
import ryno from "../extension/ryno.ts";

const tmp = fs.mkdtempSync("/tmp/ryno-sub-");
const childCwd = path.join(tmp, "child");
const file = path.join(childCwd, "note.txt");
fs.mkdirSync(childCwd);
fs.writeFileSync(file, "before\n");
process.env.RYNO_DIR = tmp;
process.env.RYNO_MODE = "edit";
process.env.RYNO_TIMEOUT_MS = "1000";
process.env.RYNO_SOUND = "off";

function instance(cwd: string, id: string, hasUI: boolean) {
  const handlers: Record<string, Function> = {};
  ryno({ on: (name: string, fn: Function) => { handlers[name] = fn; } } as any);
  const ctx = { cwd, hasUI, sessionManager: { getSessionId: () => id } };
  return {
    start: () => handlers.session_start({}, ctx),
    stop: () => handlers.session_shutdown({}, ctx),
    call: (event: unknown) => handlers.tool_call(event, ctx),
    result: (event: unknown) => handlers.tool_result(event, ctx),
  };
}

const main = instance(tmp, "main", true);
const desc = path.join(tmp, `${process.pid}.json`);
const socket = path.join(tmp, `${process.pid}.sock`);
let editor: net.Socket | undefined;
try {
  await main.start();
  for (let i = 0; i < 100 && !fs.existsSync(desc); i++) await Bun.sleep(10);
  editor = net.createConnection(socket);
  const lines = createInterface({ input: editor })[Symbol.asyncIterator]();
  await once(editor, "connect");
  const read = async () => {
    const next = await Promise.race([lines.next(), Bun.sleep(1500).then(() => { throw new Error("editor message timed out"); })]);
    assert.equal(next.done, false);
    return JSON.parse(next.value);
  };
  const decide = (id: string, action: string) => editor!.write(JSON.stringify({ type: "decision", id, action }) + "\n");
  assert.equal((await read()).sessionId, "main");

  // Resource discovery may run a factory for an extension that never starts.
  const unused = instance(childCwd, "unused", false);
  await unused.stop();
  const child = instance(childCwd, "child", false);
  await child.start();
  assert.equal(JSON.parse(fs.readFileSync(desc, "utf8")).sessionId, "main");

  const write = { toolName: "write", toolCallId: "shared", input: { path: "note.txt", content: "after\n" } };
  const edit = { toolName: "edit", toolCallId: "shared", input: { path: "child/note.txt", edits: [{ oldText: "before", newText: "parent" }] } };
  const childCall = child.call(write);
  const parentCall = main.call(edit);
  const childReview = await read();
  const parentReview = await read();
  assert.equal(childReview.type, "review");
  assert.equal(childReview.path, file);
  assert.equal(childReview.relpath, "note.txt");
  assert.equal(childReview.proposed, "after\n");
  assert.equal(parentReview.id, "shared");
  assert.notEqual(childReview.id, parentReview.id);
  decide(childReview.id, "accept");
  assert.equal(await childCall, undefined);
  assert.equal((await read()).type, "resolved");
  await child.result(write);
  const applied = await read();
  assert.equal(applied.type, "applied");
  assert.equal(applied.id, childReview.id);
  assert.equal(applied.path, file);

  const secondChildCall = child.call(write);
  const secondChildReview = await read();
  await child.stop();
  assert.match((await secondChildCall).reason, /session ended/);
  assert.equal((await read()).id, secondChildReview.id);
  decide(parentReview.id, "reject");
  assert.equal((await parentCall).block, true);
  assert.equal((await read()).id, parentReview.id);
  assert.ok(fs.existsSync(socket));
} finally {
  editor?.destroy();
  await main.stop();
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log("ALL OK: in-process subagents share the parent editor connection");
