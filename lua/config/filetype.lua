
-- ~/.config/nvim/lua/config/filetype.lua

-- Make sure .md files are treated as markdown
vim.filetype.add({
  extension = {
    md = "markdown",
  },
  pattern = {
    ["*.md"] = "markdown",
  }
})

-- Override telekasten filetype to behave as markdown (for plugin compatibility)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "telekasten",
  callback = function()
    vim.bo.filetype = "markdown"
  end,
})
