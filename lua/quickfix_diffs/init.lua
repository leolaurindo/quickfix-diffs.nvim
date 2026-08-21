local M = {}
local uv = vim.uv or vim.loop

local config = {
	open = true,
}
local setup_done = false

local modes = {
	unstaged = {
		args = {},
		title = "Git unstaged changes",
	},
	all = {
		args = { "HEAD" },
		title = "Git changes vs HEAD",
	},
	staged = {
		args = { "--cached" },
		title = "Git staged changes",
	},
}

local function notify(message, level)
	vim.notify(message, level, { title = "QuickfixDiffs" })
end

local function run_git(root, args)
	local command = { "git" }
	vim.list_extend(command, args)
	local result = vim.system(command, { cwd = root, text = true }):wait()
	if result.code ~= 0 then
		return nil, vim.trim(result.stderr or "git command failed")
	end
	return result.stdout or ""
end

local function repository_root()
	local file = vim.api.nvim_buf_get_name(0)
	local cwd = file ~= "" and vim.fs.dirname(file) or uv.cwd()
	local output, err = run_git(cwd, { "rev-parse", "--show-toplevel" })
	if not output then
		return nil, err == "" and "not in a git repository" or err
	end
	return vim.trim(output)
end

local function diff_args(opts)
	if opts.mode then
		local mode = modes[opts.mode]
		if not mode then
			return nil, ("unknown mode: %s"):format(opts.mode)
		end
		return vim.deepcopy(mode.args), mode.title
	end

	if opts.spec then
		local args = type(opts.spec) == "table" and vim.deepcopy(opts.spec) or { opts.spec }
		return args, opts.title or ("Git diff: " .. table.concat(args, " "))
	end

	local base = opts.base
	local target = opts.target
	if not base or not target then
		return nil, "diff requires mode, spec, or both base and target"
	end
	if target == "worktree" then
		return base == "index" and {} or { base }, opts.title or ("Git diff: " .. base .. " -> worktree")
	end
	if target == "index" then
		if base == "HEAD" then
			return { "--cached" }, opts.title or "Git diff: HEAD -> index"
		end
		return { "--cached", base }, opts.title or ("Git diff: " .. base .. " -> index")
	end
	if opts.merge_base then
		return { base .. "..." .. target }, opts.title or ("Git diff: " .. base .. "..." .. target)
	end
	return { base, target }, opts.title or ("Git diff: " .. base .. " -> " .. target)
end

local function changed_files(root, args)
	local command_args = { "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z" }
	vim.list_extend(command_args, args)
	vim.list_extend(command_args, { "--" })
	local output, err = run_git(root, command_args)
	if not output then
		return nil, err
	end
	local names = {}
	for name in output:gmatch("([^%z]+)%z") do
		names[#names + 1] = name
	end
	return names
end

local function file_hunks(root, args, name)
	local command_args = { "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "-U0" }
	vim.list_extend(command_args, args)
	vim.list_extend(command_args, { "--", name })
	local output, err = run_git(root, command_args)
	if not output then
		return nil, err
	end
	local hunks = {}
	for line in output:gmatch("[^\r\n]+") do
		local start = line:match("^@@ %-%d+,?%d* %+(%d+),?%d* @@")
		if start then
			hunks[#hunks + 1] = {
				filename = root .. "/" .. name,
				lnum = tonumber(start),
				text = line:match("^@@.-@@") or line,
			}
		end
	end
	return hunks
end

local function metadata(opts)
	if opts.mode == "unstaged" then
		return { base = "index", target = "worktree" }
	end
	if opts.mode == "all" then
		return { base = "HEAD", target = "worktree" }
	end
	if opts.mode == "staged" then
		return { base = "HEAD", target = "index" }
	end
	if opts.spec then
		return { spec = type(opts.spec) == "table" and table.concat(opts.spec, " ") or opts.spec }
	end
	return {
		base = opts.base,
		target = opts.target,
		merge_base = opts.merge_base == true,
	}
end

function M.open(opts)
	opts = opts or {}
	local args, title_or_err = diff_args(opts)
	if not args then
		return nil, title_or_err
	end
	local title = title_or_err
	local comparison = metadata(opts)
	local root, root_err = repository_root()
	if not root then
		return nil, root_err
	end
	local names, names_err = changed_files(root, args)
	if not names then
		return nil, names_err
	end

	local items = {}
	for _, name in ipairs(names) do
		local hunks, hunk_err = file_hunks(root, args, name)
		if not hunks then
			return nil, hunk_err
		end
		for _, item in ipairs(hunks) do
			item.user_data = { quickfix_diffs = vim.deepcopy(comparison) }
		end
		vim.list_extend(items, hunks)
	end

	if #items == 0 then
		notify("no changes", vim.log.levels.INFO)
		return items
	end

	vim.fn.setqflist({}, "r", {
		title = title,
		items = items,
	})
	if config.open then
		vim.cmd("copen")
	end
	return items
end

local function report(callback)
	local result, err = callback()
	if not result and err then
		notify(tostring(err), vim.log.levels.WARN)
	end
	return result, err
end

local function install_commands()
	local function command(name, callback, opts)
		vim.api.nvim_create_user_command(name, callback, vim.tbl_extend("force", { force = true }, opts or {}))
	end

	command("QuickfixDiffs", function()
		report(function()
			return M.open({ mode = "unstaged" })
		end)
	end, { desc = "Quickfix: unstaged Git changes" })
	command("QuickfixDiffsAll", function()
		report(function()
			return M.open({ mode = "all" })
		end)
	end, { desc = "Quickfix: all Git changes vs HEAD" })
	command("QuickfixDiffsStaged", function()
		report(function()
			return M.open({ mode = "staged" })
		end)
	end, { desc = "Quickfix: staged Git changes" })
	command("QuickfixDiffsRef", function(opts)
		report(function()
			return M.open({ base = opts.args, target = "worktree" })
		end)
	end, { nargs = 1, desc = "Quickfix: Git changes from a ref to the worktree" })
	command("QuickfixDiffsRange", function(opts)
		local parts = vim.split(vim.trim(opts.args), "%s+", { trimempty = true })
		report(function()
			if #parts == 1 then
				return M.open({ spec = parts[1] })
			end
			if #parts == 2 then
				return M.open({ base = parts[1], target = parts[2] })
			end
			return nil, "usage: QuickfixDiffsRange <spec> or <base> <target>"
		end)
	end, { nargs = "+", desc = "Quickfix: Git changes between revisions" })
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
	if setup_done then
		return M
	end
	setup_done = true
	install_commands()
	return M
end

return M
