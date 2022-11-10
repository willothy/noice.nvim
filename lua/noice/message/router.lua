local require = require("noice.util.lazy")

local Config = require("noice.config")
local Util = require("noice.util")
local View = require("noice.view")
local Manager = require("noice.message.manager")

---@class NoiceRoute
---@field view NoiceView
---@field filter NoiceFilter
---@field opts? NoiceRouteOptions|NoiceViewOptions

---@class NoiceRouteOptions
---@field stop boolean
---@field skip boolean

---@class NoiceRouteConfig
---@field view string
---@field filter NoiceFilter
---@field opts? NoiceRouteOptions|NoiceViewOptions

local M = {}
---@type NoiceRoute[]
M._routes = {}
M._tick = 0
M._need_redraw = false
---@type fun()|Interval?
M._updater = nil
M._updating = false

function M.enable()
  if not M._updater then
    M._updater = Util.interval(Config.options.throttle, Util.protect(M.update))
  end
  M._updater()
end

function M.disable()
  if M._updater then
    M._updater.stop()
    Manager.clear()
    M.update()
  end
end

---@param route NoiceRouteConfig
function M.add(route)
  local ret = {
    filter = route.filter,
    opts = route.opts or {},
    view = route.view and View.get_view(route.view, route.opts) or nil,
  }
  if ret.view == nil then
    ret.view = nil
    ret.opts.skip = true
  end
  table.insert(M._routes, ret)
end

function M.setup()
  for _, route in ipairs(Config.options.routes) do
    M.add(route)
  end
end

function M.check_redraw()
  if Util.is_blocking() and M._need_redraw then
    -- NOTE: set to false before actually calling redraw to prevent a loop with ui
    M._need_redraw = false
    Util.redraw()
  end
end

function M.view_stats()
  ---@type table<NoiceView, boolean>
  local views = {}
  for _, route in ipairs(M._routes) do
    if route.view then
      views[route.view] = true
    end
  end

  local ret = {}

  -- remove deleted messages and new messages from the views
  for view, _ in pairs(views) do
    if #view._messages > 0 then
      if not ret[view._opts.view] then
        ret[view._opts.view] = 0
      end
      ret[view._opts.view] = ret[view._opts.view] + #view._messages
    end
  end
  return ret
end

function M.update()
  if M._updating then
    return
  end

  -- only update on changes
  if M._tick == Manager.tick() then
    M.check_redraw()
    return
  end

  M._updating = true

  Util.stats.track("router.update")

  ---@type table<NoiceView,boolean>
  local updates = {}

  ---@type table<NoiceView, boolean>
  local views = {}
  for _, route in ipairs(M._routes) do
    if route.view then
      views[route.view] = true
    end
  end

  local messages = Manager.get(nil, { sort = true })

  -- remove deleted messages and new messages from the views
  for view, _ in pairs(views) do
    local count = #view._messages
    view._messages = Manager.get({
      -- remove any deleted messages
      has = true,
      -- remove messages that we are adding
      ["not"] = {
        message = messages,
      },
    }, { messages = view._messages })
    if #view._messages ~= count then
      updates[view] = true
    end
  end

  -- add messages
  for _, message in ipairs(messages) do
    for _, route in ipairs(M._routes) do
      if message:is(route.filter) then
        if not route.opts.skip then
          route.view:push(message)
          route.view._route_opts = vim.tbl_deep_extend("force", route.view._route_opts or {}, route.opts or {})
          updates[route.view] = true
        end
        if route.opts.stop ~= false then
          break
        end
      end
    end
  end

  Manager.clear()

  for view, _ in pairs(updates) do
    view:display()
  end

  M._tick = Manager.tick()

  if not vim.tbl_isempty(updates) then
    Util.stats.track("router.update.updated")
    M._need_redraw = true
  end

  M.check_redraw()
  M._updating = false
end

return M
