-- Automatically install packer if it’s not already installed
local ensure_packer = function()
  local fn = vim.fn
  local install_path = fn.stdpath('data')..'/site/pack/packer/start/packer.nvim'
end

local packer_bootstrap = ensure_packer()

-- Use a protected call so we don't error out on first use
local status_ok, packer = pcall(require, "packer")
if not status_ok then
  return
end

-- Have packer use a popup window
packer.init {
  display = {
    open_fn = function()
      return require('packer.util').float { border = 'rounded' }
    end,
  },
}

packer.startup(function(use)
  -- Packer manages itself
  use 'wbthomason/packer.nvim'

  --use 'nvim-lua/plenary.nvim'
  use 'nvim-telescope/telescope.nvim'

  -- Colorscheme setup
  use {
    'folke/tokyonight.nvim',
    config = function()
      require('config.colorscheme')
    end
  }

  use 'lunarvim/darkplus.nvim'  -- Optional, in case you switch themes manually

  use {
    'renerocksai/telekasten.nvim',
    requires = {'nvim-telescope/telescope.nvim'},
    config = function()
      require('config.telekasten_config').setup()
    end
  }

  use {
    'iamcco/markdown-preview.nvim',
    run = "cd app && npm install",
    setup = function()
      vim.g.mkdp_filetypes = { "markdown" }
    end,
    ft = { "markdown" },
    config = function()
      require('config.mdpreview')  -- Assuming you have this
    end
  }

  use {
    'nvim-treesitter/nvim-treesitter',
    run = ':TSUpdate',
    config = function()
      require('config.treesitter')
    end
  }

  -- Your keymaps
  use {
    'nvim-lua/plenary.nvim',  -- Just a dummy anchor plugin
    config = function()
      require('config.keybinds')
    end
  }

  use {
    "gaoDean/autolist.nvim",
    config = function()
      require("config.autolist")
    end,
    ft = { "markdown", "text", "norg","telekasten"},
  }

  use {
    'neovim/nvim-lspconfig',
    config = function()
      require('config.lsp')
    end
  }

  use {
    "MeanderingProgrammer/render-markdown.nvim",
    after = "nvim-treesitter",
    requires = {
      "nvim-treesitter/nvim-treesitter",
      "nvim-tree/nvim-web-devicons", -- or 'echasnovski/mini.nvim' for mini.icons support
    },
    config = function()
      require("config.render_markdown")
    end,
  }



  -- Auto-sync Packer on first install
  if packer_bootstrap then
    require('packer').sync()
  end
end)


-- Auto-compile when plugins.lua is saved
vim.cmd([[
  augroup packer_user_config
    autocmd!
    autocmd BufWritePost plugins.lua source <afile> | PackerCompile
  augroup end
]])
