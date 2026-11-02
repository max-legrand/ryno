-- Play a sound for Ryno's terminal bell, but only when its tab is active.
-- Run with: rex do -s "$REX_SESSION" /path/to/ryno/rex/ryno-bell.lua
rex.on("terminal.bell", function(ctx)
  local view = rex.session.view{}
  if not view then return end

  for _, window in ipairs(view.windows or {}) do
    if window.window_id == view.active_window_id then
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if block.block_id == ctx.block_id then
            rex.exec { "afplay", "/System/Library/Sounds/Glass.aiff" }
            return
          end
        end
      end
      return
    end
  end
end)
