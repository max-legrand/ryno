// bun test/hooks_unit.ts — Claude Code Edit/MultiEdit and Codex apply_patch semantics
import { applyClaudeEdit, applyClaudeEdits, applyChunks, parsePatch, patchChanges, shellPatch } from "../extension/hooks/edits.ts";
let f = 0;
const eq = (a: any, b: any, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) { f++; console.log("FAIL", m, JSON.stringify(a), "!=", JSON.stringify(b)); } };
const E = (o: string, n: string, all = false) => ({ old_string: o, new_string: n, replace_all: all });

// ── Claude Edit ──
eq(applyClaudeEdit("a\nb\nc\n", E("b", "B")), "a\nB\nc\n", "edit: exact");
eq(applyClaudeEdit("x\nx\n", E("x", "y")), null, "edit: ambiguous -> null");
eq(applyClaudeEdit("x\nx\n", E("x", "y", true)), "y\ny\n", "edit: replace_all");
eq(applyClaudeEdit("a\n", E("zzz", "y")), null, "edit: missing -> null");
eq(applyClaudeEdit("a\n", E("a", "a")), null, "edit: no-op -> null");
eq(applyClaudeEdit(null, E("", "new\n")), "new\n", "edit: create a missing file");
eq(applyClaudeEdit("full\n", E("", "x")), null, "edit: empty old_string on a non-empty file -> null");
eq(applyClaudeEdit("say \u201Chi\u201D\n", E('say "hi"', "say bye")), "say bye\n", "edit: curly quotes in file matched by straight quotes");
eq(applyClaudeEdit("a\nb\nc\n", E("b", "")), "a\nc\n", "edit: deleting a line removes its newline");
eq(applyClaudeEdit("$1 x\n", E("x", "$&$1")), "$1 $&$1\n", "edit: no regex replacement patterns");
eq(applyClaudeEdits("a b\n", [E("a", "c"), E("c b", "d")]), "d\n", "multiedit: sequential");
eq(applyClaudeEdits("a\n", [E("a", "b"), E("zzz", "c")]), null, "multiedit: one failing edit fails all");

// ── apply_patch ──
const P = (body: string) => `*** Begin Patch\n${body}\n*** End Patch`;
eq(parsePatch("nope"), null, "patch: not a patch");
eq(parsePatch(P("*** Add File: n.txt\n+one\n+two")), [{ type: "add", path: "n.txt", contents: "one\ntwo\n" }], "patch: add");
eq(parsePatch("<<'EOF'\n" + P("*** Delete File: d.txt") + "\nEOF"), [{ type: "delete", path: "d.txt" }], "patch: heredoc wrapper");
eq(applyChunks("a\nb\nc\n", parsePatch(P("*** Update File: f\n@@\n a\n-b\n+B\n c"))![0].chunks as any), "a\nB\nc\n", "patch: update with context");
eq(applyChunks("a\nb\nc\n", (parsePatch(P("*** Update File: f\n-b\n+B")) as any)[0].chunks), "a\nB\nc\n", "patch: first chunk without @@");
eq(applyChunks("def f():\n    x\ndef g():\n    x\n", (parsePatch(P("*** Update File: f\n@@ def g():\n-    x\n+    y")) as any)[0].chunks), "def f():\n    x\ndef g():\n    y\n", "patch: @@ context picks the later match");
eq(applyChunks("a  \nb\n", (parsePatch(P("*** Update File: f\n-a\n+A")) as any)[0].chunks), "A\nb\n", "patch: trailing whitespace tolerated");
eq(applyChunks("a\n", (parsePatch(P("*** Update File: f\n-zzz\n+A")) as any)[0].chunks), null, "patch: missing lines -> null");
eq(applyChunks("a\nb\n", (parsePatch(P("*** Update File: f\n@@\n+c\n*** End of File")) as any)[0].chunks), "a\nb\nc\n", "patch: pure addition appends");
eq(applyChunks("x\ny\nx\n", (parsePatch(P("*** Update File: f\n@@\n-x\n+z\n*** End of File")) as any)[0].chunks), "x\ny\nz\n", "patch: End of File anchors at the end");
eq(applyChunks("a\nb\nc\nd\n", (parsePatch(P("*** Update File: f\n@@\n-a\n+A\n@@\n-d\n+D")) as any)[0].chunks), "A\nb\nc\nD\n", "patch: two chunks");

const disk: Record<string, string> = { "/p/a.txt": "hello\n", "/p/b.txt": "keep\n", "/p/old.txt": "o\n" };
const read = (abs: string) => disk[abs] ?? null;
eq(
  patchChanges(P("*** Update File: a.txt\n@@\n-hello\n+world\n*** Add File: /p/n.txt\n+x\n*** Delete File: b.txt"), "/p", read),
  [
    { abs: "/p/a.txt", original: "hello\n", proposed: "world\n" },
    { abs: "/p/n.txt", original: null, proposed: "x\n" },
    { abs: "/p/b.txt", original: "keep\n", proposed: null },
  ],
  "patchChanges: update + add + delete, relative and absolute paths",
);
eq(
  patchChanges(P("*** Update File: old.txt\n*** Move to: sub/new.txt\n@@\n-o\n+n"), "/p", read),
  [{ abs: "/p/sub/new.txt", from: "/p/old.txt", original: "o\n", proposed: "n\n" }],
  "patchChanges: move reported once, at its destination",
);
eq(patchChanges(P("*** Update File: missing.txt\n@@\n-a\n+b"), "/p", read), null, "patchChanges: update of a missing file -> null");
eq(shellPatch("apply_patch <<'EOF'\n" + P("*** Delete File: x") + "\nEOF", "/p"), { patch: P("*** Delete File: x"), cwd: "/p" }, "shellPatch: heredoc");
eq(shellPatch("cd sub && apply_patch <<EOF\n" + P("*** Delete File: x") + "\nEOF\n", "/p")?.cwd, "/p/sub", "shellPatch: cd prefix");
eq(shellPatch("echo apply_patch", "/p"), null, "shellPatch: other commands");

console.log(f ? f + " FAILED" : "hooks unit tests OK");
process.exit(f ? 1 : 0);
