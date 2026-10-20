-- Plays the user inside a headless nvim. Plan + log paths come from env.
vim.opt.rtp:prepend(vim.env.RYNO_ROOT)
vim.o.swapfile = false
local function load_plan()
  if vim.env.RYNO_PLAN_FILE then
    local f = io.open(vim.env.RYNO_PLAN_FILE)
    if f then local t = vim.json.decode(f:read("*a")); f:close(); return t end
  end
  return vim.json.decode(vim.env.RYNO_PLAN or "{}")
end
local logf = assert(io.open(vim.env.RYNO_LOG, "a"))
local function log(t) logf:write(vim.json.encode(t) .. "\n"); logf:flush() end

local ryno = require("ryno")
ryno.setup({ auto_connect = true, poll_ms = 100, focus = true })
local review = require("ryno.review")
local seen = {}
local orig_applied = review.on_applied
review.on_applied = function(id, p)
  orig_applied(id, p)
  local b = vim.fn.bufnr(vim.uv.fs_realpath(p))
  log({ ev = "applied", id = id, text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "|"), modifiable = vim.bo[b].modifiable, winbar = vim.wo.winbar })
end

local t = vim.uv.new_timer()
t:start(100, 50, vim.schedule_wrap(function()
  local r = review.active
  if not r or not r.hunks or seen[r.id] then return end
  seen[r.id] = true
  local marks = vim.api.nvim_buf_get_extmarks(r.buf, vim.api.nvim_create_namespace("ryno"), 0, -1, { details = true })
  local virt = 0
  for _, m in ipairs(marks) do if m[4].virt_lines then virt = virt + #m[4].virt_lines end end
  log({ ev = "review", id = r.id, scratch = r.scratch, hunks = #r.hunks, marks = #marks, virt_lines = virt,
        modifiable = vim.bo[r.buf].modifiable, winbar = vim.wo[r.win].winbar ~= "", buftext = table.concat(vim.api.nvim_buf_get_lines(r.buf, 0, -1, false), "|") })
  local plan = load_plan()
  local action = plan[r.id] or plan["*"]
  if plan.seq and #plan.seq > 0 then
    action = table.remove(plan.seq, 1)
    if vim.env.RYNO_PLAN_FILE then local f = io.open(vim.env.RYNO_PLAN_FILE, "w"); f:write(vim.json.encode(plan)); f:close() end
  end
  vim.defer_fn(function()
    log({ ev = "action_start", id = r.id, action = action })
    local ok, err = pcall(function()
      if action == "accept_all" then review.accept_all()
      elseif action == "reject_all" then review.reject_all()
      elseif action == "partial" then review.accept_hunk(); review.reject_all()
      elseif action == "each" then for _ = 1, #r.hunks do review.accept_hunk() end
      end
    end)
    log({ ev = "action_end", id = r.id, ok = ok, err = err, active = review.active and review.active.id })
  end, 50)
end))

vim.api.nvim_create_autocmd("VimLeavePre", { callback = function()
  local b = vim.api.nvim_get_current_buf()
  log({ ev = "final", name = vim.api.nvim_buf_get_name(b), text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "|"),
        modifiable = vim.bo[b].modifiable, winbar = vim.wo.winbar })
end })
