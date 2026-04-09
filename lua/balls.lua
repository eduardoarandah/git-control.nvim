local M = {}
local api = vim.api
local uv = vim.uv

local interval_ms = 33
local BALL_CHAR = "●"

-- ---------------------------------------------------------------------------
-- Global module state
-- ---------------------------------------------------------------------------
-- All state lives at module level to avoid passing it around on every call.
-- There is ONE active session at a time, so there is no need to encapsulate
-- this in a table: keymap handlers (<Space>) and the timer tick read and
-- write directly here.

local float_win = nil -- floating window handle
local float_buf = nil -- floating window buffer
local timer = nil -- uv timer for the animation loop

local balls = {} -- list of active balls (multi-ball)
local chars = {} -- sparse map chars[y][x] = character
local max_w = 0 -- playing field width (longest line)
local field_h = 0 -- playing field height (number of visible lines)
local win_w = 0 -- floating window width (for the render grid)
local win_h = 0 -- floating window height

-- ---------------------------------------------------------------------------
-- Buffer content capture
-- ---------------------------------------------------------------------------

-- Reads the currently visible lines of the active buffer (same as explode.lua).
local function capture_visible_lines()
	local start_line = vim.fn.line("w0") - 1
	local end_line = vim.fn.line("w$")
	return api.nvim_buf_get_lines(0, start_line, end_line, false)
end

-- Converts buffer lines into the sparse `chars` map and calculates `max_w`.
-- Uses `strdisplaywidth` to handle tabs and multi-column characters correctly.
-- Writes directly into the globals.
local function build_char_map(lines)
	chars = {}
	max_w = 0
	for y, line in ipairs(lines) do
		chars[y] = {}
		local col = 1
		for _, ch in ipairs(vim.fn.split(line, "\\zs")) do
			local w = vim.fn.strdisplaywidth(ch)
			-- Only non-space characters are "targets" for the ball
			if ch:match("%S") then
				chars[y][col] = ch
			end
			col = col + w
		end
		if col - 1 > max_w then
			max_w = col - 1
		end
	end
end

-- ---------------------------------------------------------------------------
-- Floating window
-- ---------------------------------------------------------------------------

-- Opens a floating window covering the entire current window (same strategy
-- as explode.lua). Writes float_buf/float_win/win_w/win_h into the globals.
-- Receives the filetype of the original buffer to preserve syntax highlighting
-- in the float.
local function open_window(filetype, src_win)
	win_w = api.nvim_win_get_width(src_win)
	win_h = api.nvim_win_get_height(src_win)

	-- Capture window options from the original buffer BEFORE opening the float
	local win_opts = {
		"number",
		"relativenumber",
		"signcolumn",
		"foldcolumn",
		"statuscolumn",
		"cursorline",
		"cursorcolumn",
		"wrap",
		"linebreak",
		"list",
	}
	local src_opts = {}
	for _, opt in ipairs(win_opts) do
		src_opts[opt] = api.nvim_get_option_value(opt, { win = src_win })
	end

	float_buf = api.nvim_create_buf(false, true)
	float_win = api.nvim_open_win(float_buf, true, {
		relative = "win",
		win = src_win,
		width = win_w,
		height = win_h,
		row = 0,
		col = 0,
		style = "minimal",
		zindex = 150,
	})
	api.nvim_set_option_value("winhl", "Normal:Normal", { win = float_win })

	-- Copy options from the original window so the text doesn't shift
	for _, opt in ipairs(win_opts) do
		api.nvim_set_option_value(opt, src_opts[opt], { win = float_win })
	end

	-- Applying the original filetype triggers syntax/treesitter on the
	-- floating buffer, preserving the colors of the original text.
	if filetype and filetype ~= "" then
		api.nvim_set_option_value("filetype", filetype, { buf = float_buf })
	end

	for _, key in ipairs({ "q", "<Esc>" }) do
		api.nvim_buf_set_keymap(float_buf, "n", key, "", {
			noremap = true,
			silent = true,
			nowait = true,
			callback = function()
				M.stop()
			end,
		})
	end

	-- <Space>: adds a ball at a random cell in the field.
	-- `nowait = true` is CRITICAL: without it, nvim waits `timeoutlen` ms
	-- to see if <Space> is a prefix of another mapping, causing a visible
	-- pause in the animation when pressed.
	api.nvim_buf_set_keymap(float_buf, "n", "<Space>", "", {
		noremap = true,
		silent = true,
		nowait = true,
		callback = function()
			M.spawn_random()
		end,
	})
end

local function window_is_valid()
	return float_win and api.nvim_win_is_valid(float_win)
end

local function close_window()
	if float_win ~= nil and window_is_valid() then
		api.nvim_win_close(float_win, true)
	end
	float_win = nil
	float_buf = nil
end

-- ---------------------------------------------------------------------------
-- Collisions / character map queries
-- ---------------------------------------------------------------------------

local function cell_has_char(x, y)
	return chars[y] ~= nil and chars[y][x] ~= nil
end

-- ---------------------------------------------------------------------------
-- Ball (state + physics)
-- ---------------------------------------------------------------------------

-- Finds a free cell within the field. Tries random positions first; falls
-- back to a deterministic scan if the text is nearly full, to guarantee
-- a result.
local function find_empty_spot()
	for _ = 1, 200 do
		local x = math.random(1, max_w)
		local y = math.random(1, field_h)
		if not cell_has_char(x, y) then
			return x, y
		end
	end
	for y = 1, field_h do
		for x = 1, max_w do
			if not cell_has_char(x, y) then
				return x, y
			end
		end
	end
	return 1, 1
end

-- Random velocity strictly ±1 on each axis (never 0).
-- `math.random(0, 1) * 2 - 1` maps {0,1} → {-1,1}.
local function random_velocity()
	return math.random(0, 1) * 2 - 1, math.random(0, 1) * 2 - 1
end

local function create_ball()
	local x, y = find_empty_spot()
	local vx, vy = random_velocity()
	return { x = x, y = y, vx = vx, vy = vy }
end

-- Advances the ball and bounces it against the field boundaries.
-- IMPORTANT: the field is NOT the floating window size — it is
-- max_w × field_h. Beyond that rectangle the float is empty space.
local function update_ball(ball)
	ball.x = ball.x + ball.vx
	ball.y = ball.y + ball.vy

	if ball.x <= 1 then
		ball.x = 1
		ball.vx = 1
	elseif ball.x >= max_w then
		ball.x = max_w
		ball.vx = -1
	end

	if ball.y <= 1 then
		ball.y = 1
		ball.vy = 1
	elseif ball.y >= field_h then
		ball.y = field_h
		ball.vy = -1
	end
end

-- If the ball landed on a cell with a character:
--   1. determine which axis(es) the impact actually occurred on,
--   2. erase that character from the map (it is "eaten"),
--   3. step back to the previous tick to avoid overlapping,
--   4. reverse direction only on the impact axis.
--
-- To know which axis to bounce, we look at neighbors from the previous
-- position: if moving only in X (ball.x, prev_y) had a character, the
-- collision came from the X axis. Same for Y. If both neighbors are
-- occupied it is a corner and both axes are reversed. If neither is
-- occupied (purely diagonal hit) both are also reversed — the natural
-- corner bounce.
local function handle_char_collision(ball)
	if not cell_has_char(ball.x, ball.y) then
		return
	end

	local prev_x = ball.x - ball.vx
	local prev_y = ball.y - ball.vy

	local hit_on_x = cell_has_char(ball.x, prev_y)
	local hit_on_y = cell_has_char(prev_x, ball.y)

	-- Consume the hit character
	chars[ball.y][ball.x] = nil

	-- Step back to the previous cell
	ball.x = prev_x
	ball.y = prev_y

	if hit_on_x and hit_on_y then
		-- Corner: bounce on both axes
		ball.vx = -ball.vx
		ball.vy = -ball.vy
	elseif hit_on_x then
		ball.vx = -ball.vx
	elseif hit_on_y then
		ball.vy = -ball.vy
	else
		-- Purely diagonal hit (no occupied neighbor): double bounce
		ball.vx = -ball.vx
		ball.vy = -ball.vy
	end
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function create_empty_grid()
	local grid = {}
	for i = 1, win_h do
		grid[i] = {}
		for j = 1, win_w do
			grid[i][j] = " "
		end
	end
	return grid
end

-- The grid matches the floating window size (win_w × win_h).
-- Remaining text is drawn first, then ALL balls on top.
local function render()
	if not float_buf then
		return
	end
	local grid = create_empty_grid()

	-- Remaining text (background layer)
	for y, row in pairs(chars) do
		if y >= 1 and y <= win_h then
			for x, ch in pairs(row) do
				if x >= 1 and x <= win_w then
					grid[y][x] = ch
				end
			end
		end
	end

	-- Balls on top (multi-ball): if two balls land on the same cell the
	-- last one overwrites the previous, which is visually acceptable.
	for _, ball in ipairs(balls) do
		if ball.y >= 1 and ball.y <= win_h and ball.x >= 1 and ball.x <= win_w then
			grid[ball.y][ball.x] = BALL_CHAR
		end
	end

	local lines = {}
	for i = 1, win_h do
		lines[i] = table.concat(grid[i])
	end
	api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)

	-- Permanent hint on the last row, centered over the field, with highlight
	local hint = "[ press space to add a ball ]"
	local hint_col = math.max(0, math.floor((max_w - #hint) / 2))
	local ns = api.nvim_create_namespace("balls_hint")
	api.nvim_buf_clear_namespace(float_buf, ns, 0, -1)
	api.nvim_buf_set_extmark(float_buf, ns, win_h - 1, hint_col, {
		virt_text = { { hint, "IncSearch" } },
		virt_text_pos = "overlay",
	})
end

-- ---------------------------------------------------------------------------
-- Timer / animation
-- ---------------------------------------------------------------------------

-- One tick: for each ball move → resolve collision → then draw all at once.
-- Balls share the same character map, so one ball eating a char affects
-- the physics of the others in the same tick (they cooperate to clear the
-- field).
local function tick()
	if not window_is_valid() then
		M.stop()
		return
	end
	for _, ball in ipairs(balls) do
		update_ball(ball)
		handle_char_collision(ball)
	end
	render()
end

local function start_timer()
	timer = uv.new_timer()
	if not timer then
		return
	end
	timer:start(0, interval_ms, vim.schedule_wrap(tick))
end

local function stop_timer()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.start()
	-- 1. Capture the text, filetype and original window BEFORE opening the
	--    float (once opened, the active buffer becomes the float).
	local src_win = api.nvim_get_current_win()
	local lines = capture_visible_lines()
	local filetype = api.nvim_get_option_value("filetype", { buf = 0 })
	build_char_map(lines)
	field_h = #lines

	-- Not enough playing area — bail out
	if max_w < 2 or field_h < 2 then
		return
	end

	-- 2. Open the float copying options from the original window so the
	--    text lands in exactly the same position.
	open_window(filetype, src_win)

	-- 3. Start with one initial ball
	balls = { create_ball() }

	-- 4. Animation loop
	start_timer()
end

function M.stop()
	stop_timer()
	close_window()
	balls = {}
	chars = {}
end

-- Adds a ball at a random free cell. Does nothing if there is no active
-- session (avoids crashes if called at the wrong time).
function M.spawn_random()
	if not window_is_valid() then
		return
	end
	table.insert(balls, create_ball())
end

-- Add Command Balls
function M.setup()
	vim.api.nvim_create_user_command("Balls", function()
		require("balls").start()
	end, {
		desc = "Add a destructive ball to the code",
	})
end

return M
