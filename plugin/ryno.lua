if vim.g.loaded_ryno then
  return
end
vim.g.loaded_ryno = 1

local function r()
  return require("ryno")
end

local function cmd(name, fn, desc, opts)
  vim.api.nvim_create_user_command(name, fn, vim.tbl_extend("force", { desc = desc }, opts or {}))
end

cmd("RynoConnect", function(a)
  local ok = r().connect(a.bang)
  if not ok then
    vim.notify("ryno: no agent found for " .. vim.fn.getcwd(), vim.log.levels.WARN)
  end
end, "Connect to a pi/prime-agent instance (! = choose)", { bang = true })
cmd("RynoLink", function(a)
  r().link(tonumber(a.args))
end, "Link this nvim to a pi/prime-agent session (optional arg: pid)", { nargs = "?" })
cmd("RynoUnlink", function() r().unlink() end, "Remove the manual link; auto-connect by cwd again")
cmd("RynoDisconnect", function() r().disconnect() end, "Disconnect from the agent")
cmd("RynoStatus", function() r().info() end, "Show connection status")
cmd("RynoFindings", function() require("ryno.findings").list() end, "List research/review comments")
cmd("RynoOpenFinding", function() require("ryno.findings").open() end, "Open review comment in a scrollable popup")
cmd("RynoClearFindings", function() require("ryno.findings").dismiss_all() end, "Dismiss all review comments (restorable with hide/show)")
cmd("RynoNextFinding", function() require("ryno.findings").next() end, "Jump to next review comment")
cmd("RynoPrevFinding", function() require("ryno.findings").prev() end, "Jump to previous review comment")
cmd("RynoToggleFindings", function() require("ryno.findings").toggle() end, "Hide/show review comments")
cmd("RynoHideFindings", function() require("ryno.findings").hide() end, "Hide all review comments")
cmd("RynoShowFindings", function() require("ryno.findings").show_all() end, "Show all review comments, including dismissed ones")
cmd("RynoDismissFinding", function() require("ryno.findings").dismiss() end, "Dismiss review comment at cursor")
cmd("RynoAuto", function() r().toggle_auto() end, "Toggle auto-accept (skip review)")
cmd("RynoAccept", function() r().review.accept_hunk() end, "Accept hunk under cursor")
cmd("RynoReject", function() r().review.reject_hunk() end, "Reject hunk under cursor")
cmd("RynoAcceptAll", function() r().review.accept_all() end, "Accept all pending hunks")
cmd("RynoRejectAll", function() r().review.reject_all() end, "Reject all pending hunks")
cmd("RynoNext", function() r().review.next_hunk() end, "Jump to next hunk")
cmd("RynoPrev", function() r().review.prev_hunk() end, "Jump to previous hunk")
cmd("RynoSend", function() r().review.send_review() end, "Send the review decision (all hunks decided)")
