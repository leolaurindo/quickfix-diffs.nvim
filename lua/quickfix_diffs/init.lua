local M = {}
local uv = vim.uv or vim.loop

local config = {
	open = true,
	full_diff = false,
}
local setup_done = false

local head_mode = {
	args = { "HEAD" },
	title = "Git changes vs HEAD",
}

local modes = {
	unstaged = {
		args = {},
		title = "Git unstaged changes",
	},
	head = head_mode,
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

local function repository_root(path)
	local cwd = path
	if not cwd then
		local file = vim.api.nvim_buf_get_name(0)
		cwd = file ~= "" and vim.fs.dirname(file) or uv.cwd()
	end
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

local function file_hunks(root, args, name, full_diff, comparison)
	local command_args = { "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", "--full-index", "-U0" }
	vim.list_extend(command_args, args)
	vim.list_extend(command_args, { "--", name })
	local output, err = run_git(root, command_args)
	if not output then
		return nil, err
	end
	local data = vim.deepcopy(comparison)
	data.version, data.root, data.path = 1, root, name
	data.full_diff = full_diff
	data.old_blob, data.new_blob = output:match("\nindex (%x+)%.%.(%x+)")
	data.deleted = output:find("\ndeleted file mode ", 1, true) ~= nil
	data.deletion = data.deleted
	for _, side in ipairs({ "old", "new" }) do
		local blob = data[side .. "_blob"]
		if blob and not blob:match("^0+$") then
			data[side .. "_fingerprint"] = "git:" .. blob
		end
	end
	local hunks, ranges = {}, {}
	for line in output:gmatch("[^\r\n]+") do
		local old_start, old_count, new_start, new_count =
			line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
		if old_start then
			local range = {
				old = { start = tonumber(old_start), count = tonumber(old_count) or 1 },
				new = { start = tonumber(new_start), count = tonumber(new_count) or 1 },
			}
			ranges[#ranges + 1] = range
			local hunk_data = vim.tbl_extend("force", vim.deepcopy(data), range)
			hunk_data.deletion = range.new.count == 0 and range.old.count > 0
			hunks[#hunks + 1] = {
				filename = root .. "/" .. name,
				lnum = math.max(range.new.start, 1),
				end_lnum = range.new.count > 0 and range.new.start + range.new.count - 1 or nil,
				text = line:match("^@@.-@@") or line,
				user_data = { quickfix_diffs = hunk_data },
			}
		end
	end
	if full_diff then
		data.hunks = ranges
		return { {
			filename = root .. "/" .. name,
			lnum = hunks[1] and hunks[1].lnum or 1,
			text = output,
			user_data = { quickfix_diffs = data },
		} }
	end
	return hunks
end

local function metadata(opts)
	if opts.mode == "unstaged" then
		return { base = "index", target = "worktree" }
	end
	if opts.mode == "head" then
		return { base = "HEAD", target = "worktree" }
	end
	if opts.mode == "staged" then
		return { base = "HEAD", target = "index" }
	end
	if opts.spec then
		local parts = type(opts.spec) == "table" and opts.spec or { opts.spec }
		if #parts == 2 then
			if parts[1] == "--cached" then
				return { base = parts[2], target = "index" }
			end
			return { base = parts[1], target = parts[2] }
		end
		if #parts ~= 1 then
			return nil, "spec must contain one revision/range or two revisions"
		end
		local base, target = parts[1]:match("^(.-)%.%.%.(.-)$")
		local merge_base = base ~= nil
		if not base then
			base, target = parts[1]:match("^(.-)%.%.(.-)$")
		end
		if base then
			return { base = base ~= "" and base or "HEAD", target = target ~= "" and target or "HEAD",
				merge_base = merge_base }
		end
		if parts[1] == "--cached" then
			return { base = "HEAD", target = "index" }
		end
		return { base = parts[1], target = "worktree" }
	end
	return {
		base = opts.base,
		target = opts.target,
		merge_base = opts.merge_base == true,
	}
end

local function resolve_comparison(root, comparison)
	local refs = {}
	for _, side in ipairs({ "base", "target" }) do
		local ref = comparison[side]
		if ref == "index" or ref == "worktree" then
			refs[side] = ref
		else
			local revision, err = run_git(root, { "rev-parse", "--verify", "--end-of-options", ref .. "^{commit}" })
			if not revision then
				-- An unborn branch can still have staged additions.
				if side ~= "base" or ref ~= "HEAD" or comparison.target ~= "index" then
					return nil, err
				end
				refs[side] = ref
			else
				refs[side] = vim.trim(revision)
				comparison[side .. "_revision"] = refs[side]
			end
		end
	end
	if comparison.merge_base then
		local target = refs.target == "worktree" and "HEAD" or refs.target
		local base, err = run_git(root, { "merge-base", refs.base, target })
		if not base then
			return nil, err
		end
		refs.base = vim.trim(base)
		comparison.base_revision = refs.base
	end
	return diff_args(refs)
end

function M.open(opts)
	opts = opts or {}
	local full_diff = opts.full_diff
	if full_diff == nil then
		full_diff = config.full_diff
	end
	local should_open = opts.open
	if should_open == nil then
		should_open = config.open
	end
	local args, title_or_err = diff_args(opts)
	if not args then
		return nil, title_or_err
	end
	local title = title_or_err
	local comparison, metadata_err = metadata(opts)
	if not comparison then
		return nil, metadata_err
	end
	local root, root_err = repository_root(opts.root)
	if not root then
		return nil, root_err
	end
	local resolved, resolve_err = resolve_comparison(root, comparison)
	if not resolved then
		return nil, resolve_err
	end
	args = resolved
	local names, names_err = changed_files(root, args)
	if not names then
		return nil, names_err
	end

	local items = {}
	for _, name in ipairs(names) do
		local hunks, hunk_err = file_hunks(root, args, name, full_diff, comparison)
		if not hunks then
			return nil, hunk_err
		end
		vim.list_extend(items, hunks)
	end

	if #items == 0 then
		notify("no changes", vim.log.levels.INFO)
		return items
	end

	local result = vim.fn.setqflist({}, " ", {
		nr = "$",
		title = title,
		context = { quickfix_diffs = { version = 1, root = root, comparison = comparison } },
		items = items,
	})
	if result ~= 0 then
		return nil, "could not create diff list"
	end
	local target = { kind = "quickfix", id = vim.fn.getqflist({ id = 0 }).id }
	if should_open then
		vim.cmd("copen")
	end
	return items, nil, target
end

local function differ_endpoint(value)
	if value == "INDEX" then
		return "index"
	end
	if value == "WORKTREE" then
		return "worktree"
	end
	return value
end

local function differ_options(model, opts)
	if type(model) ~= "table" or type(model.old_rev) ~= "string" or type(model.new_rev) ~= "string" then
		return nil, "Differ view has no Git comparison"
	end
	local old, new = model.old_rev, model.new_rev
	local base, target, merge_base
	local branch, revision = old:match("^(.-)%.%.%.(.*)$")
	if branch and branch ~= "" then
		base = branch
		target = revision ~= "" and revision or "worktree"
		merge_base = true
	else
		base, target = differ_endpoint(old), differ_endpoint(new)
	end
	local open_opts = vim.tbl_extend("force", {}, opts or {})
	open_opts.base = base
	open_opts.target = target
	open_opts.merge_base = merge_base
	open_opts.root = model.root
	open_opts.title = open_opts.title or ("Differ: " .. old .. " -> " .. new)
	if open_opts.tab then
		open_opts.open = false
	end
	open_opts.tab = nil
	return open_opts
end

function M.open_from_differ(opts)
	opts = opts or {}
	local ok, differ = pcall(require, "differ")
	if not ok or type(differ.active_view) ~= "function" then
		return nil, "differ.nvim is not available"
	end
	local view_ok, view = pcall(differ.active_view)
	if not view_ok or type(view) ~= "table" then
		return nil, "no active Differ view"
	end
	local open_opts, options_err = differ_options(view.model, opts)
	if not open_opts then
		return nil, options_err
	end
	local items, err, target = M.open(open_opts)
	if not items or err or not target then
		return items, err, target
	end
	if opts.tab then
		vim.cmd("tab copen")
	end
	return items, nil, target
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
	command("QuickfixDiffsFull", function()
		report(function()
			return M.open({ mode = "unstaged", full_diff = true })
		end)
	end, { desc = "Quickfix: full unstaged Git diffs" })
	command("QuickfixDiffsHEAD", function()
		report(function()
			return M.open({ mode = "head" })
		end)
	end, { desc = "Quickfix: Git changes vs HEAD" })
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
	local function compare_command(opts)
		local parts = vim.split(vim.trim(opts.args), "%s+", { trimempty = true })
		if #parts == 1 then
			return M.open({ spec = parts[1] })
		end
		if #parts == 2 then
			return M.open({ base = parts[1], target = parts[2] })
		end
		return nil, "usage: QuickfixDiffsCompare <spec> or <base> <target>"
	end
	command("QuickfixDiffsCompare", function(opts)
		report(function()
			return compare_command(opts)
		end)
	end, { nargs = "+", desc = "Quickfix: compare Git revisions or endpoints" })
	command("QuickfixDiffsRange", function(opts)
		report(function()
			return compare_command(opts)
		end)
	end, { nargs = "+", desc = "Quickfix: alias for QuickfixDiffsCompare" })
	command("QuickfixDiffsFromDiffer", function()
		report(function()
			return M.open_from_differ()
		end)
	end, { desc = "Quickfix: current Differ comparison" })
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
