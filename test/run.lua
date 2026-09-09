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
check(vim.fn.exists(":QuickfixDiffsFull") == 2)
check(vim.fn.exists(":QuickfixDiffsHEAD") == 2)
check(vim.fn.exists(":QuickfixDiffsAll") == 0)
check(vim.fn.exists(":QuickfixDiffsStaged") == 2)
check(vim.fn.exists(":QuickfixDiffsCompare") == 2)
check(vim.fn.exists(":QuickfixDiffsRange") == 2)
check(vim.fn.exists(":QuickfixDiffsFromDiffer") == 2)
local differ_model = { root = root, old_rev = "INDEX", new_rev = "WORKTREE" }
package.preload.differ = function()
	return {
		active_view = function()
			return { model = differ_model }
		end,
	}
end
local differ_items = check(diffs.open_from_differ({ open = false }))
check(#differ_items == 1, "Differ integration did not create a diff list")
local differ_list = vim.fn.getqflist({ all = 1 })
check(differ_list.title == "Differ: INDEX -> WORKTREE")
check(differ_list.context.quickfix_diffs.comparison.base == "index")
check(differ_list.context.quickfix_diffs.comparison.target == "worktree")
local tab_count = vim.fn.tabpagenr("$")
check(diffs.open_from_differ({ tab = true }))
check(vim.fn.tabpagenr("$") == tab_count + 1, "tab integration did not open a new tab")
vim.cmd("tabclose!")
differ_model = { root = root, old_rev = "base...", new_rev = "WORKTREE" }
check(diffs.open_from_differ({ open = false }))
local branch_comparison = vim.fn.getqflist({ context = 1 }).context.quickfix_diffs.comparison
check(branch_comparison.base == "base" and branch_comparison.target == "worktree" and branch_comparison.merge_base)
vim.cmd("QuickfixDiffsCompare index worktree")
local compared = vim.fn.getqflist({ context = 1 }).context.quickfix_diffs.comparison
check(compared.base == "index" and compared.target == "worktree", "compare command did not preserve endpoints")

vim.fn.setqflist({}, " ", {
	title = "another producer",
	context = { keep = true },
	items = { { filename = file, lnum = 1, text = "keep", user_data = { consumer = "note" } } },
})
local other = vim.fn.getqflist({ all = 1 })
local staged, staged_err, staged_target = diffs.open({ mode = "staged" })
check(staged and not staged_err and staged_target.kind == "quickfix")
check(staged_target.id ~= other.id)
check(vim.deep_equal(vim.fn.getqflist({ id = other.id, all = 1 }).items, other.items))
check(vim.fn.getqflist({ context = 1 }).context.quickfix_diffs.version == 1)
check(#staged == 1 and staged[1].lnum == 3, "staged hunk did not target index line")
check(staged[1].user_data.quickfix_diffs.target == "index", "staged metadata is missing")
local data = staged[1].user_data.quickfix_diffs
check(data.root == root and data.path == "example.txt")
check(data.base_revision == vim.trim(run(root, { "rev-parse", "HEAD" })))
check(data.new_blob == vim.trim(run(root, { "rev-parse", ":example.txt" })))
check(data.new_fingerprint == "git:" .. data.new_blob)
check(data.old_fingerprint == "git:" .. data.old_blob)
check(not data.deletion)
check(data.old.start == 3 and data.old.count == 1 and data.new.start == 3 and data.new.count == 1)
staged[1].user_data.consumer = { note = "preserve" }
vim.fn.setqflist({}, "r", { id = staged_target.id, items = staged })

local unstaged = check(diffs.open({ mode = "unstaged" }))
check(#unstaged == 1 and unstaged[1].lnum == 4, "unstaged hunk did not target worktree line")
check(vim.fn.getqflist({ id = staged_target.id, items = 1 }).items[1].user_data.consumer.note == "preserve")
check(unstaged[1].user_data.quickfix_diffs.old.count == 0)
check(unstaged[1].end_lnum == 4)

local full = check(diffs.open({ mode = "unstaged", full_diff = true }))
check(#full == 1 and full[1].text:find("+four", 1, true), "full diff was not stored in the item")
local exported = vim.fn.getqflist()
check(exported[1].text:find("+four", 1, true), "full diff was not retained by quickfix")

local all = check(diffs.open({ mode = "head" }))
check(#all == 1 and all[1].lnum == 3, "head mode did not target final working-tree changes")

local range = check(diffs.open({ spec = "base...HEAD" }))
check(#range == 1 and range[1].lnum == 2, "merge-base range did not target branch changes")

check(range[1].user_data.quickfix_diffs.base_revision == vim.trim(run(root, { "merge-base", "base", "HEAD" })))
check(range[1].user_data.quickfix_diffs.target_revision == vim.trim(run(root, { "rev-parse", "HEAD" })))
local pair = check(diffs.open({ spec = { "base", "HEAD" } }))
check(pair[1].user_data.quickfix_diffs.target_revision == range[1].user_data.quickfix_diffs.target_revision)
local dotted = check(diffs.open({ spec = "base..HEAD" }))
check(dotted[1].user_data.quickfix_diffs.base_revision == pair[1].user_data.quickfix_diffs.base_revision)
local previous_id = vim.fn.getqflist({ id = 0 }).id
vim.cmd("silent colder")
check(diffs.open({ base = "base", target = "HEAD", merge_base = true }))
check(vim.fn.getqflist({ id = previous_id }).id == previous_id)
local current = vim.fn.getqflist({ all = 1 })
check(#check(diffs.open({ base = "HEAD", target = "HEAD" })) == 0)
check(vim.deep_equal(vim.fn.getqflist({ all = 1 }), current))
local failed, err = diffs.open({ base = "missing-ref", target = "HEAD" })
check(not failed and err)
check(vim.deep_equal(vim.fn.getqflist({ all = 1 }), current))

run(root, { "config", "color.ui", "always" })
vim.fn.writefile({ "one", "TWO", "THREE", "four", "five" }, file)
local multiline = check(diffs.open({ mode = "unstaged" }))
check(multiline[1].lnum == 4 and multiline[1].end_lnum == 5)
check(multiline[1].user_data.quickfix_diffs.new.count == 2)

vim.fn.delete(file)
local deletion = check(diffs.open({ mode = "unstaged" }))
data = deletion[1].user_data.quickfix_diffs
check(data.deleted and data.old.start == 1 and data.old.count == 3)
check(data.new.start == 0 and data.new.count == 0)
check(data.deletion and data.new_fingerprint == nil)
check(data.old_fingerprint == "git:" .. data.old_blob)
check(deletion[1].lnum == 1 and deletion[1].end_lnum == nil)
local deleted_file = check(diffs.open({ mode = "unstaged", full_diff = true }))
data = deleted_file[1].user_data.quickfix_diffs
check(data.full_diff and data.deleted and #data.hunks == 1)
check(data.new_blob:match("^0+$"))
check(data.hunks[1].old.count == 3)

local unborn = vim.fn.tempname()
vim.fn.mkdir(unborn, "p")
run(unborn, { "init", "-q" })
vim.fn.writefile({ "new" }, unborn .. "/new.txt")
run(unborn, { "add", "new.txt" })
vim.cmd("edit " .. vim.fn.fnameescape(unborn .. "/new.txt"))
local additions = check(diffs.open({ mode = "staged" }))
check(additions[1].user_data.quickfix_diffs.new.count == 1)
check(additions[1].user_data.quickfix_diffs.old.count == 0)
print("quickfix_diffs tests passed")
