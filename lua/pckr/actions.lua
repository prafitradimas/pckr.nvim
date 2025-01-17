local fn = vim.fn
local fmt = string.format

local a = require('pckr.async')
local config = require('pckr.config')
local log = require('pckr.log')
local util = require('pckr.util')
local fsstate = require('pckr.fsstate')

local display = require('pckr.display')

local pckr_plugins = require('pckr.plugin').plugins

local M = {}

--- @class Pckr.Result
--- @field err? string[]
--- Used for moves
--- @field from string
--- @field to string

--- @return Pckr.Display
local function open_display()
  return display.open({
    diff = function(plugin, commit, callback)
      local plugin_type = require('pckr.plugin_types')[plugin.type]
      plugin_type.diff(plugin, commit, callback)
    end,
    revert_last = function(plugin)
      local plugin_type = require('pckr.plugin_types')[plugin.type]
      plugin_type.revert_last(plugin)
    end,
  })
end

--- @param tasks (fun(function))[]
--- @param disp Pckr.Display
--- @param kind string
local function run_tasks(tasks, disp, kind)
  if #tasks == 0 then
    log.info('Nothing to do!')
    return
  end

  local function check()
    if disp then
      return disp:check()
    end
  end

  local limit = config.max_jobs and config.max_jobs or #tasks

  log.fmt_debug('Running tasks: %s', kind)
  if disp then
    disp:update_headline_message(string.format('%s %d / %d plugins', kind, #tasks, #tasks))
  end

  a.join(limit, check, tasks)
end

--- @param dir string
--- @return boolean
local function helptags_stale(dir)
  local glob = fn.glob

  -- Adapted directly from minpac.vim
  local txts = glob(util.join_paths(dir, '*.txt'), true, true)
  vim.list_extend(txts, glob(util.join_paths(dir, '*.[a-z][a-z]x'), true, true))

  if #txts == 0 then
    return false
  end

  local tags = glob(util.join_paths(dir, 'tags'), true, true)
  vim.list_extend(tags, glob(util.join_paths(dir, 'tags-[a-z][a-z]'), true, true))

  if #tags == 0 then
    return true
  end

  ---@type integer
  local txt_newest = math.max(unpack(vim.tbl_map(fn.getftime, txts)))

  ---@type integer
  local tag_oldest = math.min(unpack(vim.tbl_map(fn.getftime, tags)))

  return txt_newest > tag_oldest
end

--- @param results table<string,Pckr.Result>
local function update_helptags(results)
  local paths = {} --- @type string[]
  for plugin_name, r in pairs(results) do
    if not r.err then
      paths[#paths + 1] = pckr_plugins[plugin_name].install_path
    end
  end

  for _, dir in ipairs(paths) do
    local doc_dir = util.join_paths(dir, 'doc')
    if helptags_stale(doc_dir) then
      log.fmt_debug('Updating helptags for %s', doc_dir)
      vim.cmd('silent! helptags ' .. fn.fnameescape(doc_dir))
    end
  end
end

--- @param plugin Pckr.Plugin
--- @param disp Pckr.Display
--- @return string[]?
local post_update_hook = a.sync(function(plugin, disp)
  if plugin.run or plugin.start then
    a.main()
    local loader = require('pckr.loader')
    loader.load_plugin(plugin)
  end

  if not plugin.run then
    return
  end

  a.main()

  local run_task = plugin.run

  if type(run_task) == 'function' then
    disp:task_update(plugin.name, 'running post update hook...')
    local ok, err = pcall(run_task, plugin, disp)
    if not ok then
      return { 'Error running post update hook: ' .. vim.inspect(err) }
    end
  elseif type(run_task) == 'string' then
    disp:task_update(plugin.name, string.format('running post update hook...("%s")', run_task))
    if vim.startswith(run_task, ':') then
      -- Run a vim command
      vim.cmd(run_task:sub(2))
    else
      local jobs = require('pckr.jobs')
      local jr = jobs.run(run_task, { cwd = plugin.install_path })

      if jr.code ~= 0 then
        return { string.format('Error running post update hook: %s', jr.stderr) }
      end
    end
  end
end, 2)

--- @param plugin Pckr.Plugin
--- @param disp Pckr.Display
--- @param installs table<string,Pckr.Result>
--- @return string, string[]?
local install_task = a.sync(function(plugin, disp, installs)
  disp:task_start(plugin.name, 'installing...')

  local plugin_type = require('pckr.plugin_types')[plugin.type]

  local err = plugin_type.installer(plugin, disp)

  plugin.installed = vim.fn.isdirectory(plugin.install_path) ~= 0

  if not err then
    err = post_update_hook(plugin, disp)
  end

  if not disp.items then
    disp.items = {}
  end

  if not err then
    disp:task_succeeded(plugin.name, 'installed')
    log.fmt_debug('Installed %s', plugin.name)
  else
    disp:task_failed(plugin.name, 'failed to install', err)
    log.fmt_debug('Failed to install %s: %s', plugin.name, vim.inspect(err))
  end

  installs[plugin.name] = { err = err }
  return plugin.name, err
end, 3)

--- @param missing_plugins string[]
--- @param disp? Pckr.Display
--- @param installs table<string,Pckr.Result>
--- @return (fun(function))[]
local function get_install_tasks(missing_plugins, disp, installs)
  if #missing_plugins == 0 then
    return {}
  end

  local tasks = {} --- @type (fun(function))[]
  for _, v in ipairs(missing_plugins) do
    tasks[#tasks + 1] = a.curry(install_task, pckr_plugins[v], disp, installs)
  end

  return tasks
end

--- @param plugin Pckr.Plugin
--- @param moves table<string,Pckr.Result>
--- @param fs_state Pckr.FSState
local function move_plugin(plugin, moves, fs_state)
  local from --- @type string
  local to --- @type string
  if not plugin.start then
    from = util.join_paths(config.start_dir, plugin.name)
    to = util.join_paths(config.opt_dir, plugin.name)
  else
    from = util.join_paths(config.opt_dir, plugin.name)
    to = util.join_paths(config.start_dir, plugin.name)
  end

  fs_state.start[to] = plugin.name
  fs_state.opt[from] = nil
  fs_state.dirty[from] = nil

  moves[plugin.name] = { from = from, to = to }

  -- NOTE: If we stored all plugins somewhere off-package-path and used symlinks to put them in the
  -- right directories, this could be lighter-weight
  local success, msg = os.rename(from, to)
  if not success then
    log.fmt_error('Failed to move %s to %s: %s', from, to, msg)
    moves[plugin.name] = { err = { msg } }
  else
    log.fmt_debug('Moved %s from %s to %s', plugin.name, from, to)
  end
end

--- @param plugin Pckr.Plugin
--- @param disp Pckr.Display
--- @param updates table<string,Pckr.Result>
--- @return string?, string[]?
local update_task = a.sync(function(plugin, disp, updates)
  disp:task_start(plugin.name, 'updating...')

  if plugin.lock then
    disp:task_succeeded(plugin.name, 'locked')
    return
  end

  local plugin_type = require('pckr.plugin_types')[plugin.type]
  local actual_update = false

  plugin.err = plugin_type.updater(plugin, disp)
  if not plugin.err and plugin.type == 'git' then
    local revs = plugin.revs
    actual_update = revs[1] ~= revs[2]
    if actual_update then
      log.fmt_debug('Updated %s', plugin.name)
      plugin.err = post_update_hook(plugin, disp)
    end
  end

  if plugin.err then
    disp:task_failed(plugin.name, 'failed to update', plugin.err)
    log.fmt_debug('Failed to update %s: %s', plugin.name, table.concat(plugin.err, '\n'))
  elseif actual_update then
    local info = {}
    local ncommits = 0
    if plugin.messages and #plugin.messages > 0 then
      table.insert(info, 'Commits:')
      for _, m in ipairs(plugin.messages) do
        for _, line in ipairs(vim.split(m, '\n')) do
          table.insert(info, '    ' .. line)
          ncommits = ncommits + 1
        end
      end

      table.insert(info, '')
    end
    -- msg = fmt('updated: %s...%s', revs[1], revs[2])
    local msg = fmt('updated: %d new commits', ncommits)
    disp:task_succeeded(plugin.name, msg, info)
  else
    disp:task_done(plugin.name, 'already up to date')
  end

  updates[plugin.name] = { err = plugin.err }
  return plugin.name, plugin.err
end, 3)

--- @param update_plugins string[]
--- @param disp Pckr.Display
--- @param updates table<string,Pckr.Result>
--- @return (fun(function))[]
local function get_update_tasks(update_plugins, disp, updates)
  local tasks = {} --- @type (fun(function))[]
  for _, v in ipairs(update_plugins) do
    local plugin = pckr_plugins[v]
    if not plugin then
      log.fmt_error('Unknown plugin: %s', v)
    end
    if plugin and not plugin.lock then
      tasks[#tasks + 1] = a.curry(update_task, plugin, disp, updates)
    end
  end

  if #tasks == 0 then
    log.info('Nothing to update!')
  end

  return tasks
end

--- @param plugins table<string,Pckr.Plugin>
--- @param extra_plugins string[]
--- @param moves table<string,Pckr.Result>
--- @param fs_state Pckr.FSState
local function fix_plugin_types(plugins, extra_plugins, moves, fs_state)
  log.debug('Fixing plugin types')
  -- NOTE: This function can only be run on plugins already installed
  for _, v in ipairs(extra_plugins) do
    local plugin = plugins[v]
    local wrong_install_dir =
      util.join_paths(plugin.start and config.opt_dir or config.start_dir, plugin.name)
    if vim.loop.fs_stat(wrong_install_dir) then
      move_plugin(plugin, moves, fs_state)
    end
  end
  log.debug('Done fixing plugin types')
end

-- Find and remove any plugins not currently configured for use
--- @param plugins table<string,Pckr.Plugin>
--- @param fs_state? Pckr.FSState
--- @param removals? string[]
local do_clean = a.sync(function(plugins, fs_state, removals)
  fs_state = fs_state or fsstate.get_fs_state(plugins)

  log.debug('Starting clean')
  --- @type table<string,string>
  local plugins_to_remove = vim.tbl_extend('force', fs_state.extra, fs_state.dirty)

  log.debug('extra plugins', fs_state.extra)
  log.debug('dirty plugins', fs_state.dirty)

  if not next(plugins_to_remove) then
    log.info('Already clean!')
    return
  end

  a.main()

  local lines = {}
  for path, _ in pairs(plugins_to_remove) do
    table.insert(lines, '  - ' .. path)
  end

  if
    config.autoremove or display.ask_user('Removing the following directories. OK? (y/N)', lines)
  then
    if removals then
      for r, _ in pairs(plugins_to_remove) do
        removals[#removals + 1] = r
      end
    end
    local removed = vim.deepcopy(plugins_to_remove)
    for path, _ in pairs(plugins_to_remove) do
      local result = vim.fn.delete(path, 'rf')
      if result == -1 then
        log.fmt_warn('Could not remove %s', path)
      end
      plugins_to_remove[path] = nil
    end
    log.debug('Removed', removed)
  else
    log.warn('Cleaning cancelled!')
  end
end, 4)

--- Install operation:
--- Installs missing plugins, then updates helptags
--- @param install_plugins string[]
--- @param _opts? table
--- @param __cb fun()
M.install = a.sync(function(install_plugins, _opts, __cb)
  if not install_plugins then
    local fs_state = fsstate.get_fs_state(pckr_plugins)
    install_plugins = vim.tbl_values(fs_state.missing)
  end

  if #install_plugins == 0 then
    log.info('All configured plugins are installed')
    return
  end

  a.main()

  log.debug('Gathering install tasks')

  local disp = open_display()
  local installs = {} --- @type table<string,Pckr.Result>

  local delta = util.measure(function()
    local install_tasks = get_install_tasks(install_plugins, disp, installs)
    run_tasks(install_tasks, disp, 'installing')

    a.main()
    update_helptags(installs)
  end)

  disp:finish(delta)
end, 2)

--- Update operation:
--- Takes an optional list of plugin names as an argument. If no list is given,
--- operates on all managed plugin then updates installed plugins and updates
--- helptags. - Options can be specified in the first argument as either a table -
--- @param update_plugins string[]
M.update = a.void(function(update_plugins)
  if #update_plugins == 0 then
    update_plugins = vim.tbl_keys(pckr_plugins)
  end
  local fs_state = fsstate.get_fs_state(pckr_plugins)
  local _, installed_plugins = util.partition(vim.tbl_values(fs_state.missing), update_plugins)

  local updates = {}

  a.main()

  local disp = open_display()

  local delta = util.measure(function()
    a.main()

    log.debug('Gathering update tasks')
    local tasks = get_update_tasks(installed_plugins, disp, updates)
    run_tasks(tasks, disp, 'updating')

    a.main()
    update_helptags(updates)
  end)

  disp:finish(delta)
end)

--- Sync operation:
--- Takes an optional list of plugin names as an argument. If no list is given,
--- operates on all managed plugins. Fixes plugin types, installs missing
--- plugins, then updates installed plugins and updates helptags and rplugins
--- Options can be specified in the first argument as either a table
--- @param update_plugins string[]
M.sync = a.void(function(update_plugins)
  if #update_plugins == 0 then
    update_plugins = vim.tbl_keys(pckr_plugins)
  end
  local fs_state = fsstate.get_fs_state(pckr_plugins)

  local extra_plugins = util.partition(vim.tbl_values(fs_state.extra), update_plugins)

  local results = {
    moves = {}, --- @type table<string,Pckr.Result>
    removals = {}, --- @type string[]
    installs = {}, --- @type table<string,Pckr.Result>
    updates = {}, --- @type table<string,Pckr.Result>
  }

  fix_plugin_types(pckr_plugins, extra_plugins, results.moves, fs_state)

  -- Even though we may have moved some dirty plugins, they may still be dirty
  -- for a different reason so recalculate fs_state
  fs_state = fsstate.get_fs_state(pckr_plugins)

  do_clean(pckr_plugins, fs_state, results.removals)

  local missing_plugins, installed_plugins =
    util.partition(vim.tbl_values(fs_state.missing), update_plugins)

  a.main()

  local disp = open_display()

  local delta = util.measure(function()
    local tasks = {}

    log.debug('Gathering install tasks')
    vim.list_extend(tasks, get_install_tasks(missing_plugins, disp, results.installs))

    a.main()

    log.debug('Gathering update tasks')
    vim.list_extend(tasks, get_update_tasks(installed_plugins, disp, results.updates))

    run_tasks(tasks, disp, 'syncing')

    a.main()
    update_helptags(vim.tbl_extend('error', results.installs, results.updates))
  end)

  disp:finish(delta)
end)

M.status = a.sync(function(_, _)
  require('pckr.status').run()
end, 2)

--- Clean operation:
-- Finds plugins present in the `pckr` package but not in the managed set
M.clean = a.void(function(_, _)
  do_clean(pckr_plugins)
end)

M.lock = a.sync(function(_, _)
  require('pckr.lockfile').lock()
end, 2)

M.restore = a.sync(function(_, _)
  require('pckr.lockfile').restore()
end, 2)

M.log = function(_, _)
  local messages = require('pckr.log').messages
  for _, m in ipairs(messages) do
    vim.api.nvim_echo({m}, false, {})
  end
end

return M
