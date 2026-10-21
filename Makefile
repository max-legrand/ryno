.PHONY: test
# tests must not depend on the user's ~/.config/ryno/settings.json
export RYNO_SETTINGS := /nonexistent/ryno-settings.json
unexport RYNO_BASH
test:
	nvim -l test/diff_test.lua
	nvim -l test/json_test.lua
	bun test/core_test.ts
	bun test/e2e.ts | grep -E "FAIL|ALL OK|FAILED"
	bun test/prime_shim.ts 2>&1 | grep -E "FAIL|ALL OK|FAILED"
	bun test/prime_block.ts 2>&1 | grep -E "FAIL|ALL OK|FAILED"
	bun test/bash_e2e.ts 2>&1 | grep -E "FAIL|ALL OK|FAILED"
	bun test/block_e2e.ts 2>&1 | grep -E "FAIL|ALL OK|FAILED"
	bun test/multi.ts 2>&1 | grep -E "FAIL|ALL OK|FAILED"
	bun test/route.ts 2>&1 | grep -E "FAIL|ALL OK|FAILED"
	bun test/vis_e2e.ts 2>&1 | grep -E "FAIL|ALL OK|FAILED"
