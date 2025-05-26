local keymap = vim.keymap.set
local telekasten = require("telekasten")

-- Wrap the original follow_link to add a jump mark before changing file
vim.keymap.set("n", "<CR>", function()
  vim.cmd("normal! m'")
  telekasten.follow_link()
end, { noremap = true, silent = true })

local opts = {silent = true}

vim.opt.wrap = true
vim.opt.linebreak = true

keymap("","<Space>", "<Nop>", opts)
vim.g.mapleader = " "

keymap("n", "<S-l>", ":bnext<CR>", opts)
keymap("n", "<S-h>", ":bprevious<CR>", opts)
keymap("n", "<backspace>", ":bprevious<CR>", opts)


keymap("n", "<S-q>", "<cmd>Bdelete<CR>", opts)

keymap("n", ";", ":", { noremap = true })



vim.keymap.set("n", "<leader>cfg", function()
  vim.cmd("cd ~/.config/nvim")
  print("PWD set to ~/.config/nvim")
end, { desc = "Set PWD to Neovim config folder" })



-- Telekasten Mapping
keymap("n", "<leader>zf",":Telekasten find_notes<CR>", opts)
keymap("n", "<leader>zn",":Telekasten new_note<CR>", opts)
keymap("n", "<leader>zi",":Telekasten insert_link<CR>", opts)
keymap("n", "<leader>zd",":Telekasten find_daily_notes<CR>", opts)
keymap("n", "<leader>zw",":Telekasten find_weekly_notes<CR>", opts)
keymap("n", "<leader>zg",":Telekasten search_notes<CR>", opts)
keymap("n", "<leader>z",":Telekasten panel<CR>", opts)
keymap("n", "<cr>",":Telekasten follow_link<CR>", opts)

vim.keymap.set("n", "<leader>td", function()
  local file = vim.fn.expand("%:p")
  vim.cmd("bdelete")
  vim.fn.delete(file)
end, { desc = "Delete current Telekasten note" })


vim.keymap.set("n", "<leader>zpw", function()
  local template_path = vim.fn.expand("~/zettelkasten/Weekly Value Template-202505251830.md")
  local lines = vim.fn.readfile(template_path)
  vim.api.nvim_put(lines, "l", true, true)
end, { desc = "Paste Weekly Value Template" })

-- Go to next wikilink
vim.keymap.set("n", "<Tab>", function()
  if not vim.fn.search("\\[\\[.*\\]\\]", "W") then
    vim.notify("No next link", vim.log.levels.INFO, { title = "WikiJump" })
  end
end, { silent = true, noremap = true })

-- Go to previous wikilink
vim.keymap.set("n", "<S-Tab>", function()
  if not vim.fn.search("\\[\\[.*\\]\\]", "bW") then
    vim.notify("No previous link", vim.log.levels.INFO, { title = "WikiJump" })
  end
end, { silent = true, noremap = true })


-- Wrap the original follow_link to add a jump mark before changing file
vim.keymap.set("n", "<CR>", function()
  vim.cmd("normal! m'")
  telekasten.follow_link()
end, { noremap = true, silent = true })

vim.keymap.set("n", "<BS>", "<C-o>", { noremap = true, silent = true })



-- Telescope Mapping
keymap("n", "<leader>ff",":Telescope find_files<CR>", opts)
keymap("n", "<leader>ft",":Telescope live_grep<CR>", opts)
keymap("n", "<leader>fp",":Telescope projects<CR>", opts)
keymap("n", "<leader>fb",":Telescope buffers<CR>", opts)


-- Markdown Preview Mapping
keymap("n", "<leader>mp", "<cmd>MarkdownPreview<CR>", { desc = "Markdown Preview" })
keymap("n", "<leader>ms", "<cmd>MarkdownPreviewStop<CR>", { desc = "Stop Preview" })



-- Save and Quit
keymap("n", "<leader>w",":w<CR>", opts)
keymap("n", "<leader>q",":q<CR>", opts)

-- Exit Insert mode
keymap("i", "jj","<ESC>", opts)
