-- grove-rex: Grove workspace popup for Rex.
-- Loaded from init.lua with dofile(); install.sh adds the dofile and the key.

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = source:match("^(.*)/rex/[^/]+$")
  or ((os.getenv("HOME") or "") .. "/.local/share/grove-rex")
local create = root .. "/hooks/create.sh"

local function layout(ctx)
  return rex.layout.block{
    flavor  = "com.superlogical.terminal.shell",
    options = {
      -- Runs through the login shell, so gw, fzf, and jq are on PATH.
      command = { create, ctx.client_id or "" },
      cwd     = os.getenv("HOME"),
    },
  }
end

rex.action{
  name        = "grove_create",
  title       = "Create Grove Workspace",
  description = "Name a workspace, pick a preset or repos, then open it as a Rex session.",
  keywords    = "gw grove worktree workspace",
  args        = { placement = "string?" },
  run         = function(ctx, args)
    local _, err
    if args.placement == "below" then
      _, err = rex.session.new_split{
        anchor_id = ctx.block_id,
        direction = "vertical",
        side      = "after",
        ratio     = 0.6,
        focus     = true,
        layout    = layout(ctx),
      }
    else
      _, err = rex.session.new_layer{
        bounds = { 0.25, 0.32, 0.5, 0.36 },
        focus  = true,
        layout = layout(ctx),
      }
    end
    if err ~= nil then error(err, 0) end
  end,
}

rex.action{
  name     = "grove_create_below",
  title    = "Create Grove Workspace (Split Below)",
  keywords = "gw grove worktree workspace split",
  run      = function(ctx, args)
    local _, err = rex.invoke("grove_create", { placement = "below" })
    if err ~= nil then error(err, 0) end
  end,
}
