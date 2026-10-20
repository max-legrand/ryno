// bun test/core_test.ts — edit-application semantics vs. the tools' (exact + fuzzy)
import { applyEdits, normalizeEdits } from "../extension/ryno.ts";
let f = 0;
const eq = (a: any, b: any, m: string) => { if (JSON.stringify(a) !== JSON.stringify(b)) { f++; console.log("FAIL", m, JSON.stringify(a), "!=", JSON.stringify(b)); } };
const E = (o: string, n: string) => ({ oldText: o, newText: n });

eq(applyEdits("a\nb\nc\n", [E("b", "B")]), "a\nB\nc\n", "exact");
eq(applyEdits("a\nb\nc\nd\n", [E("d", "D"), E("a", "A")]), "A\nb\nc\nD\n", "order independent");
eq(applyEdits("x\nx\n", [E("x", "y")]), null, "ambiguous -> null");
eq(applyEdits("a\n", [E("zzz", "y")]), null, "missing -> null");
eq(applyEdits("abc\n", [E("ab", "X"), E("bc", "Y")]), null, "overlap -> null");
eq(applyEdits("a\n", [E("a", "a")]), null, "no-op -> null");
eq(applyEdits("a\r\nb\n", [E("a\r\nb", "z")]), "z\n", "CRLF in oldText normalised");
// fuzzy: smart quotes in file, ASCII in oldText; trailing whitespace trimmed file-wide (tool behaviour)
eq(applyEdits("say \u201Chi\u201D  \nkeep   \n", [E('say "hi"', "say 'yo'")]), "say 'yo'\nkeep\n", "fuzzy fallback rewrites normalised file");
eq(normalizeEdits({ edits: '[{"oldText":"a","newText":"b"}]' }), [E("a", "b")], "edits as JSON string");
eq(normalizeEdits({ oldText: "a", newText: "b" }), [E("a", "b")], "legacy top-level");
eq(normalizeEdits({ edits: [E("a", "b")], oldText: "c", newText: "d" }), [E("a", "b"), E("c", "d")], "merged");
console.log(f ? f + " FAILED" : "core tests OK");
process.exit(f ? 1 : 0);
