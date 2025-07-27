
-- Load plugin manager + plugins
require("plugins")

-- Load core user config (colors, keymaps, LSP, etc.)
require("config.colorscheme")
require("config.keybinds")
<<<<<<< HEAD
require("config.filetype")
=======
require("config.lsp")
>>>>>>> 4e334bb9fd83fe389f375cd2d10e112367f55170
-- Load plugin-specific configs (if not already loaded via `use { config = ... }`)
-- Only needed for things not lazy-loaded
-- require("config.telekasten_config")
-- require("config.treesitter")
-- etc.
