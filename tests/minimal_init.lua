local plenary_dir = os.getenv "PLENARY_DIR" or "/tmp/plenary.nvim"

-- The provisioning sync inside up.run defaults its sources to the base's
-- stdpath trees: without this, a fixture spec would push the developer's
-- real config - and their whole plugin cache - onto the container. Point
-- both at scratch directories that stay empty unless a spec injects roots.
local scratch = vim.fn.tempname()

vim.env.XDG_CONFIG_HOME = scratch .. "/config"
vim.env.XDG_DATA_HOME = scratch .. "/data"

-- stdpath() appends the appname: the sync sources are these "nvim" leaves
vim.fn.mkdir(vim.env.XDG_CONFIG_HOME .. "/nvim", "p")
vim.fn.mkdir(vim.env.XDG_DATA_HOME .. "/nvim", "p")

local is_installed = vim.fn.isdirectory(plenary_dir .. "/lua/plenary") == 1

if not is_installed then
    print("Cloning plenary.nvim to " .. plenary_dir)
    if vim.fn.isdirectory(plenary_dir) == 1 then
        vim.fn.delete(plenary_dir, "rf")
    end
    vim.fn.system { "git", "clone", "https://github.com/nvim-lua/plenary.nvim", plenary_dir }
end

vim.opt.rtp:append "."
vim.opt.rtp:append(plenary_dir)

vim.cmd "runtime plugin/plenary.vim"
require "plenary.busted"

-- Test helper modules under tests/outpost/ are requireable as
-- "outpost.<name>". Appended after the repo itself (rtp ".") so the
-- plugin's own lua/outpost/ tree always wins on module collisions.
package.path = package.path .. ";" .. vim.fn.getcwd() .. "/tests/?.lua"
