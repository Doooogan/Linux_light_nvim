
-- ~/.config/nvim/lua/config/render_markdown.lua

require("render-markdown").setup({
  enabled = true,
  file_types = { "markdown", "telekasten" }, -- include 'telekasten' if needed
  preset = "default", -- try "minimal", "clean", or "none" as well
  completions = {
    lsp = { enabled = true }
  }
})

-- Optional: map toggle
vim.keymap.set("n", "<leader>rm", function()
  require("render-markdown").toggle()
end, { desc = "Toggle rendered markdown", silent = true })


vim.treesitter.language.register("markdown", "telekasten")
