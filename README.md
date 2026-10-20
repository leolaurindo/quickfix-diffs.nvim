# quickfix-diffs.nvim

Create native Neovim quickfix lists from Git diffs, with hunk ranges and
revision metadata for navigation and review. Requires Neovim 0.10+.

Part of the [quickfix-kit.nvim](https://github.com/leolaurindo/quickfix-kit.nvim)
package.

It also pairs great with `]q` and `[q` navigation plus inline diff renders, such as 
[inline-diff.nvim](https://github.com/leolaurindo/inline-diff.nvim), [mini.diff](https://github.com/nvim-mini/mini.diff) and others.

## Installation

With lazy.nvim:

```lua
{ "leolaurindo/quickfix-diffs.nvim", opts = {} }
```

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/leolaurindo/quickfix-diffs.nvim" }, { load = true })
require("quickfix_diffs").setup()
```

## Setup

```lua
require("quickfix_diffs").setup({
  open = true,
  full_diff = false,
})
```

The default is one item per changed hunk. `full_diff = true` creates one item
per changed file and stores the complete patch in `item.text`. Untracked files
are excluded from `:QuickfixDiffs`; use `:QuickfixDiffsWithUntracked` to include
non-ignored untracked files without changing the index. Each non-empty run appends
a new list to quickfix history.

## Commands

| Command | Comparison |
| --- | --- |
| `:QuickfixDiffs` | index → worktree hunks |
| `:QuickfixDiffsWithUntracked` | index → worktree, including non-ignored untracked files |
| `:QuickfixDiffsFull` | index → worktree, full patch per file |
| `:QuickfixDiffsHEAD` | HEAD → worktree |
| `:QuickfixDiffsStaged` | HEAD → index |
| `:QuickfixDiffsRef <ref>` | ref → worktree |
| `:QuickfixDiffsCompare <spec>` | Git revision or range |
| `:QuickfixDiffsCompare <base> <target>` | base → target |
| `:QuickfixDiffsFromDiffer` | current Differ comparison |

`QuickfixDiffsRange` is an alias for `QuickfixDiffsCompare`.

For example:

```vim
:QuickfixDiffsCompare index worktree
:QuickfixDiffsCompare main HEAD
:QuickfixDiffsCompare main...feature
```

A pull request can be reviewed when its Git ref is available locally:

```vim
:QuickfixDiffsCompare origin/main...refs/pull/123/head
```

The plugin does not fetch pull requests or contact a hosting service.

## Lua API

The canonical API describes the two endpoints directly:

```lua
local diffs = require("quickfix_diffs")

diffs.open({ base = "index", target = "worktree" })
diffs.open({ base = "HEAD", target = "worktree" })
diffs.open({ base = "HEAD", target = "index" })
diffs.open({ base = "main", target = "worktree" })
diffs.open({ base = "main", target = "HEAD" })
diffs.open({ base = "main", target = "HEAD", merge_base = true })

-- Optional differ.nvim integration:
local items, err, target = diffs.open_from_differ({ tab = true })
```

`mode` is a convenience wrapper: `unstaged`, `head`, or `staged`.
`open_from_differ()` reads the active local Git comparison from Differ. It
accepts the same options as `open()`; `tab = true` creates the list without
opening it first, then opens it with `:tab copen`. Differ PR views backed only by
remote blobs are not supported because quickfix-diffs operates on local Git
objects.
`full_diff = true`
creates one item per file and stores the complete patch in `item.text`.
`spec` accepts a revision, `A..B`, `A...B`, or a two-revision array; empty
endpoints mean `HEAD`. `base` and `target` also accept `worktree` and `index`.

Success returns `items, nil, target`, where `target` is
`{ kind = "quickfix", id = ... }`. No changes returns an empty array without
changing the current list.

Each item has versioned `item.user_data.quickfix_diffs` metadata with `root`,
`path`, comparison revisions, old/new ranges, blob IDs, fingerprints,
`deletion`, and `full_diff`. Full-file items also contain `hunks`; their native
line is navigation-only. Zero counts follow Git's unified-diff semantics.

## Quickfix Review integration

The plugins are independent. Review can add notes directly to these diff rows;
each note stays on the native diff item and is mirrored into Review's owned
notes quickfix list. Review uses this metadata for new-side, old-side, or
file-level note anchors and revision-aware exports. Diffs does not reattach
notes to later lists. Native navigation still uses working-tree files.

## Tests

```sh
nvim --headless -u NONE -l test/run.lua
```
