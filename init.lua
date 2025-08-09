
-- Load plugin manager + plugins
require("plugins")

-- Load core user config (colors, keymaps, LSP, etc.)
require("config.colorscheme")
require("config.keybinds")
require("config.keybinds_random_rolls")
require("config.filetype")
require("config.lsp")



math.randomseed(os.time())
-- Load plugin-specific configs (if not already loaded via `use { config = ... }`)
-- Only needed for things not lazy-loaded
-- require("config.telekasten_config")
-- require("config.treesitter")
-- etc.
