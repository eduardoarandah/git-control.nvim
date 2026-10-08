# Git control

Inspect commits and diffs like a 10x meatproxy! 🧠

1. prev/next commit shown in diffview.nvim
2. Show a popup with commit message and `git log --graph`

https://github.com/user-attachments/assets/4b9a70b0-637d-42db-bc6e-509a14ecb3ac

## Requirements

https://github.com/sindrets/diffview.nvim

## Install

Like any other plugin or just copy `lua/git_control.lua` to your `~/.config/nvim` folder as I probably won't maintain this unless it's popular or something

vim.pack example:

```lua
vim.pack.add({ "https://github.com/eduardoarandah/git-control.nvim/issues/1" })
```

## Mappings

I like to dedicate F1 to F4 to diff and explore commits:

```lua
require("git_control").setup({
  mappings = { toggle = "<F1>", prev = "<F2>", next = "<F3>", report = "<F4>" },
})
```

## Command

this shows git status and `git log --graph`

```vim
:GitReport
```

## More awesome plugins by me

[🎱 Balls.nvim](https://github.com/eduardoarandah/explode.nvim)

Add bouncing balls to destroy your vibe-coded spaghetti.

[ Explode.nvim 💣 🧨💥 ](https://github.com/eduardoarandah/explode.nvim)

Some things just work better with explosions.
