----------------------------------------------------------------------------------------------------
-- Git control
--
-- Browse commits with Diffview and a floating git status
--
-- REQUIREMENTS
--
-- https://github.com/sindrets/diffview.nvim
--
-- INSTALL
--   Save as ~/.config/nvim/lua/git_control.lua
--
-- MAPPINGS (add them to your init.lua, like any plugin)
--
--   require("git_control").setup()   -- default keys
--
--   require("git_control").setup({
--     mappings = { toggle = "<leader>gd", prev = "<leader>gp", next = "<leader>gn", report = "<leader>gr" },
--     modal_extra_mappings = { close = { "<esc>", "q" } },  -- optional, only inside the modal
--   })
--
--   Global mappings (defaults):
--   toggle  <F1>  open / close Diffview (working tree against the index)
--   prev    <F2>  show the previous (parent) commit; from the working tree it shows HEAD
--   next    <F3>  show the next commit; after HEAD it goes back to the working tree
--                 (the selected file is kept while moving between commits)
--   report  <F4>  open / close the Git report modal with the title and description of the commit
--                 shown by Diffview (or HEAD if Diffview is closed)
--
--   Inside the modal the SAME keys change behavior (whatever keys you configured):
--     next key    next commit (newer)
--     prev key    previous commit (older)
--     toggle key  close the modal and open Diffview on the commit shown
--     report key  close the modal
--   plus the extra keys: <up> newer, <down> older, <esc> / q close
--
-- COMMAND
--
--   :GitReport  open / close the modal on the current commit (HEAD if no Diffview)
----------------------------------------------------------------------------------------------------

local M = {}

----------------------------------------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------------------------------------

local defaults = {
  -- Global mappings (normal mode). Set one to false to skip it
  mappings = { toggle = "<F1>", prev = "<F2>", next = "<F3>", report = "<F4>" },
  -- Extra keys that only exist inside the modal. Action -> list of keys
  modal_extra_mappings = {
    newer = { "<up>" },
    older = { "<down>" },
    close = { "<esc>", "q" },
  },
}

-- What each global mapping does when pressed inside the modal
local modal_action_of_mapping = {
  toggle = "diffview",
  prev = "older",
  next = "newer",
  report = "close",
}

-- Active configuration (defaults merged with the user options in setup())
local config = defaults

----------------------------------------------------------------------------------------------------
-- Git helpers
----------------------------------------------------------------------------------------------------

-- Runs git and returns the first line of the output, or nil on failure
-- :h vim.system()
local function git_first_line(args)
  local result = vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()
  if result.code ~= 0 or result.stdout == "" then
    return nil
  end
  return vim.split(result.stdout, "\n")[1]
end

-- Full hash of a commit or reference (e.g. "HEAD"), or nil if it does not exist
local function resolve_commit(rev)
  return git_first_line({ "rev-parse", "--verify", "--quiet", rev .. "^{commit}" })
end

-- Previous commit (parent). In the working tree (commit = nil), the previous one is HEAD
local function get_prev_commit(commit)
  if not commit then
    return resolve_commit("HEAD")
  end
  return resolve_commit(commit .. "^")
end

-- Next commit (child towards HEAD)
-- Returns "LOCAL" if the commit is already HEAD (the next one is the working tree)
-- https://git-scm.com/docs/git-rev-list#Documentation/git-rev-list.txt---ancestry-path
local function get_next_commit(commit)
  if not commit then
    return nil
  end
  local child = git_first_line({ "rev-list", "--reverse", "--ancestry-path", commit .. "..HEAD" })
  return child or "LOCAL"
end

----------------------------------------------------------------------------------------------------
-- Diffview navigation
--
-- Diffview cannot change the commit of an open view, so the current view is closed
-- and a new one is opened in its place (tabs do not pile up).
-- The selected file is kept with --selected-file  (:h :DiffviewOpen)
----------------------------------------------------------------------------------------------------

-- Returns the Diffview view of the current tab, or nil if there is none
-- Only DiffView (not DiffviewFileHistory) has left/right
local function get_diffview()
  local view = require("diffview.lib").get_current_view()
  if view and view.class:name() == "DiffView" then
    return view
  end
  return nil
end

-- Hash of the commit shown by the view (right side)
-- Returns nil if the right side is the local files (working tree)
local function get_view_commit(view)
  local RevType = require("diffview.vcs.rev").RevType
  if view and view.right.type == RevType.COMMIT then
    return view.right.commit
  end
  return nil
end

-- Absolute path of the file selected in the view, to keep it when changing commit
local function get_selected_file(view)
  if view and view.panel.cur_file then
    return view.adapter.ctx.toplevel .. "/" .. view.panel.cur_file.path
  end
  return nil
end

-- Closes the current view (if any) and opens Diffview on the given commit
-- commit = "LOCAL" opens the working tree against the index (:DiffviewOpen without arguments)
local function show_commit_in_diffview(commit)
  local view = get_diffview()
  local selected_file = get_selected_file(view)

  local args = {}
  if commit ~= "LOCAL" then
    table.insert(args, commit .. "^!")
  end
  if selected_file then
    table.insert(args, "--selected-file=" .. selected_file)
  end

  if view then
    vim.cmd("DiffviewClose")
  end
  require("diffview").open(args)
end

-- Open/close Diffview
function M.toggle()
  if get_diffview() then
    vim.cmd("DiffviewClose")
  else
    vim.cmd("DiffviewOpen")
  end
end

-- Previous commit
function M.prev()
  local prev = get_prev_commit(get_view_commit(get_diffview()))
  if not prev then
    vim.notify("No previous commit", vim.log.levels.WARN)
    return
  end
  show_commit_in_diffview(prev)
end

-- Next commit
function M.next()
  local next_commit = get_next_commit(get_view_commit(get_diffview()))
  if not next_commit then
    vim.notify("No next commit", vim.log.levels.WARN)
    return
  end
  show_commit_in_diffview(next_commit)
end

----------------------------------------------------------------------------------------------------
-- Git report modal
-- Floating window with the title and description of a commit and its position in the git graph.
----------------------------------------------------------------------------------------------------

-- Modal buffer and hash of the commit it shows (nil if closed)
local modal_buf = nil
local current_commit = nil

local function is_open()
  return modal_buf ~= nil and vim.api.nvim_buf_is_valid(modal_buf)
end

-- Lines to show: "# hash title", an empty line and the message body
-- https://devhints.io/git-log-format
local function get_commit_lines(commit)
  local lines = vim.fn.systemlist({ "git", "show", "-s", "--format=# %h %s%n%n%b", commit })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return lines
end

-- Lines of `git log --graph --oneline --decorate` up to the given commit (plus 5 older ones), with a marker on it
-- Graph lines look like "| * abc1234 (HEAD -> master) message": the hash comes after the graph characters
-- https://git-scm.com/docs/git-log#_commit_graph_options
local function get_graph_lines(commit)
  -- Commits from HEAD down to the current one, plus a few older ones for context
  -- https://git-scm.com/docs/git-rev-list#Documentation/git-rev-list.txt---count
  local older_commits = 58
  local newer_commits = tonumber(vim.fn.systemlist({ "git", "rev-list", "--count", commit .. "..HEAD" })[1]) or 0
  local max_commits = newer_commits + 1 + older_commits

  local graph = vim.fn.systemlist({ "git", "log", "--graph", "--oneline", "--decorate", "--max-count=" .. max_commits })
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local short_hash = vim.fn.systemlist({ "git", "rev-parse", "--short", commit })[1]
  for i, line in ipairs(graph) do
    local hash = line:match("^[%s%*|/\\_.-]*(%x+)")
    if hash == short_hash then
      graph[i] = line .. "   👈 👀"
    end
  end
  return graph
end

-- The modal takes this fraction of the editor (:h vim.o.lines)
local size_percentage = 0.8

local function get_modal_height()
  return math.ceil(vim.o.lines * size_percentage)
end

-- Message of the commit, blank lines up to half of the modal height, then the position in the git graph
-- (so the graph always has at least half of the modal)
-- Returns the lines and the row (0-indexed) where the graph starts, or nil if the commit does not exist
local function get_modal_lines(commit)
  local lines = get_commit_lines(commit)
  if not lines then
    return nil
  end

  local half_height = math.floor(get_modal_height() / 2)
  while #lines < half_height do
    table.insert(lines, "")
  end

  local graph_start = #lines
  vim.list_extend(lines, get_graph_lines(commit))
  return lines, graph_start
end

-- There is no treesitter parser for `git` output, so the graph is colored by hand with extmarks
-- Each line looks like "| * abc1234 (HEAD -> master) message"
-- :h nvim_buf_set_extmark()  :h nvim_buf_clear_namespace()
local graph_ns = vim.api.nvim_create_namespace("git_control_graph")

local function highlight_graph_line(buf, row, line)
  local function paint(first, last, group)
    vim.api.nvim_buf_set_extmark(buf, graph_ns, row, first - 1, { end_col = last, hl_group = group })
  end

  local graph_end, hash_start, hash_end = line:match("^[%s%*|/\\_.-]*()()%x+()")
  if not graph_end then
    return
  end
  paint(1, graph_end - 1, "Special")
  paint(hash_start, hash_end - 1, "Identifier")

  local deco_start, deco_end = line:find("^ %b()", hash_end)
  if deco_start then
    paint(deco_start + 1, deco_end, "Type")
  end
end

local function highlight_graph(buf, lines, graph_start)
  vim.api.nvim_buf_clear_namespace(buf, graph_ns, 0, -1)
  for row = graph_start, #lines - 2 do
    highlight_graph_line(buf, row, lines[row + 1])
  end
end

local function close_modal()
  if is_open() then
    vim.api.nvim_buf_delete(modal_buf, { force = true })
  end
  modal_buf = nil
end

-- Shows the commit in the modal (opens it if closed); defined below, needed by the keymaps
local show_commit_in_modal

-- Older commit
local function modal_prev()
  local prev = get_prev_commit(current_commit)
  if prev then
    show_commit_in_modal(prev)
  end
end

-- Newer commit. At HEAD there is no next commit ("LOCAL")
local function modal_next()
  local next_commit = get_next_commit(current_commit)
  if next_commit and next_commit ~= "LOCAL" then
    show_commit_in_modal(next_commit)
  end
end

-- Close the modal and open Diffview on the commit shown
local function modal_open_in_diffview()
  local commit = current_commit
  close_modal()
  show_commit_in_diffview(commit)
end

local modal_actions = {
  newer = modal_next,
  older = modal_prev,
  diffview = modal_open_in_diffview,
  close = close_modal,
}

-- Keys of the modal by action: the global mappings translated + the extra ones
-- Example: { newer = { "<F3>", "<up>" }, older = { "<F2>", "<down>" }, ... }
local function get_modal_keys(cfg)
  local keys = {}
  for mapping, action in pairs(modal_action_of_mapping) do
    keys[action] = {}
    if cfg.mappings[mapping] then
      table.insert(keys[action], cfg.mappings[mapping])
    end
  end
  for action, extra_keys in pairs(cfg.modal_extra_mappings) do
    vim.list_extend(keys[action], extra_keys)
  end
  return keys
end

-- Local keymaps of the modal; buffer-local mappings take priority over the global ones
-- :h vim.keymap.set()  (buffer option)
local function set_modal_keymaps(buf, keys)
  local opts = { buffer = buf, nowait = true, silent = true }
  for action, action_keys in pairs(keys) do
    for _, lhs in ipairs(action_keys) do
      vim.keymap.set("n", lhs, modal_actions[action], opts)
    end
  end
end

-- Footer with the real keys, so it stays correct if the user changes the mappings
local function get_modal_footer(keys)
  local function join(action)
    return table.concat(keys[action], "/")
  end
  return string.format(
    " %s newer · %s older · %s diffview · %s close ",
    join("newer"),
    join("older"),
    join("diffview"),
    join("close")
  )
end

-- Creates the buffer and the floating window. Returns the buffer
-- https://dev.to/2nit/how-to-write-neovim-plugins-in-lua-5cca
-- :h nvim_open_win()
local function open_modal(keys)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  set_modal_keymaps(buf, keys)

  vim.api.nvim_open_win(buf, true, {
    style = "minimal",
    relative = "editor",
    width = math.ceil(vim.o.columns * size_percentage),
    height = get_modal_height(),
    row = math.ceil(vim.o.lines * (1 - size_percentage) / 2),
    col = math.ceil(vim.o.columns * (1 - size_percentage) / 2),
    border = "double",
    title = " Git Report ",
    title_pos = "center",
    footer = get_modal_footer(keys),
    footer_pos = "center",
  })

  return buf
end

show_commit_in_modal = function(commit)
  local lines, graph_start = get_modal_lines(commit)
  if not lines then
    return
  end

  if not is_open() then
    modal_buf = open_modal(get_modal_keys(config))
  end

  vim.api.nvim_buf_set_lines(modal_buf, 0, -1, false, lines)
  highlight_graph(modal_buf, lines, graph_start)
  current_commit = commit
end

-- Opens the modal on the Diffview commit (or HEAD if there is none), or closes it if open
function M.report()
  if is_open() then
    close_modal()
    return
  end
  local commit = get_view_commit(get_diffview()) or resolve_commit("HEAD")
  show_commit_in_modal(commit)
end

vim.api.nvim_create_user_command("GitReport", M.report, { desc = "Git report (toggle modal with the current commit)" })

----------------------------------------------------------------------------------------------------
-- Setup
----------------------------------------------------------------------------------------------------

local mapping_descriptions = {
  toggle = { fn = M.toggle, desc = "Diffview toggle" },
  prev = { fn = M.prev, desc = "Diffview previous commit" },
  next = { fn = M.next, desc = "Diffview next commit" },
  report = { fn = M.report, desc = "Git report of the current commit" },
}

-- Creates the global mappings from the configuration
-- :h vim.tbl_deep_extend()
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})
  for name, mapping in pairs(mapping_descriptions) do
    local lhs = config.mappings[name]
    if lhs then
      vim.keymap.set("n", lhs, mapping.fn, { desc = mapping.desc })
    end
  end
end

return M

