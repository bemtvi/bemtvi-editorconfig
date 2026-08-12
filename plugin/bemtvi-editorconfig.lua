-- Auto-loaded when the plugin is on the runtimepath (sourced from `plugin/` like a
-- neovim plugin). `.editorconfig` support needs no configuration — registering the
-- autocmds is the whole setup — so this turns it on out of the box.
--
-- `setup()` is a full reconfigure, so a user calling
-- `require("bemtvi-editorconfig").setup({...})` from their init.lua just re-applies
-- it. To switch it off at runtime use `vim.g.editorconfig = false` (global) or
-- `vim.b[bufnr].editorconfig = false` (one buffer). See `:help bemtvi-editorconfig`.
require("bemtvi-editorconfig").setup({})
