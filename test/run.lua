vim.opt.rtp:prepend(vim.fn.getcwd())

local diffs = require("quickfix_diffs")

local function check(value, message)
	assert(value, message)
	return value
end

local function run(dir, args)
	local command = { "git" }
	vim.list_extend(command, args)
	local result = vim.system(command, { cwd = dir, text = true }):wait()
	assert(result.code == 0, result.stderr)
	return result.stdout
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local file = root .. "/example.txt"
vim.fn.writefile({ "one", "two", "three" }, file)
run(root, { "init", "-q" })
run(root, { "config", "user.email", "test@example.com" })
run(root, { "config", "user.name", "Test" })
run(root, { "add", "example.txt" })
run(root, { "commit", "-qm", "initial" })
run(root, { "branch", "base" })

vim.fn.writefile({ "one", "TWO", "three" }, file)
run(root, { "add", "example.txt" })
run(root, { "commit", "-qm", "feature" })
vim.fn.writefile({ "one", "TWO", "THREE" }, file)
run(root, { "add", "example.txt" })
vim.fn.writefile({ "one", "TWO", "THREE", "four" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))

diffs.setup({ open = false })
check(vim.fn.exists(":QuickfixDiffs") == 2)
check(vim.fn.exists(":QuickfixDiffsStaged") == 2)
check(vim.fn.exists(":QuickfixDiffsRange") == 2)

local staged = check(diffs.open({ mode = "staged" }))
check(#staged == 1 and staged[1].lnum == 3, "staged hunk did not target index line")
check(staged[1].user_data.quickfix_diffs.target == "index", "staged metadata is missing")

local unstaged = check(diffs.open({ mode = "unstaged" }))
check(#unstaged == 1 and unstaged[1].lnum == 4, "unstaged hunk did not target worktree line")

local all = check(diffs.open({ mode = "all" }))
check(#all == 1 and all[1].lnum == 3, "all mode did not target final working-tree changes")

local range = check(diffs.open({ spec = "base...HEAD" }))
check(#range == 1 and range[1].lnum == 2, "merge-base range did not target branch changes")

print("quickfix_diffs tests passed")
