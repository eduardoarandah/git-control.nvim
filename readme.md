# 🎱 Balls.nvim

Add bouncing balls to destroy your vibe-coded spaghetti.

Press `<space>` to add more balls!

## Installation

### lazy.nvim

```lua
{
  "eduardoarandah/balls.nvim",
  config = function()
    require("balls").setup()
  end,
}
```

### vim.pack

```lua
vim.pack.add({ "https://github.com/eduardoarandah/balls.nvim" })
require("balls").setup()
```
