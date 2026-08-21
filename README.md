# quickfix-diffs.nvim

Create native Neovim quickfix lists from Git diff hunks.

```lua
require("quickfix_diffs").setup()
```

## Commands

| Command | Comparison |
| --- | --- |
| `:QuickfixDiffs` | index -> working tree (`git diff`) |
| `:QuickfixDiffsAll` | HEAD -> working tree (`git diff HEAD`) |
| `:QuickfixDiffsStaged` | HEAD -> index (`git diff --cached`) |
| `:QuickfixDiffsRef main` | main -> working tree (`git diff main`) |
| `:QuickfixDiffsRange main HEAD` | main -> HEAD |
| `:QuickfixDiffsRange main...HEAD` | merge-base(main, HEAD) -> HEAD |

There is one quickfix item per diff hunk. The item line is the new-side line
reported by Git. Untracked files are not included.

## Lua API

```lua
local diffs = require("quickfix_diffs")

diffs.open({ mode = "unstaged" })
diffs.open({ mode = "all" })
diffs.open({ mode = "staged" })
diffs.open({ base = "main", target = "worktree" })
diffs.open({ base = "main", target = "HEAD" })
diffs.open({ base = "main", target = "HEAD", merge_base = true })
```

The API returns `items` on success and `nil, error` on failure.

## Tests

```sh
nvim --headless -u NONE -l test/run.lua
```
