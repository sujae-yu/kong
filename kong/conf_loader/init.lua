local require = require


local kong_default_conf = require "kong.templates.kong_defaults"
local process_secrets = require "kong.cmd.utils.process_secrets"
local pl_stringio = require "pl.stringio"
local socket_url = require "socket.url"
local conf_constants = require "kong.conf_loader.constants"
local listeners = require "kong.conf_loader.listeners"
local conf_sys = require "kong.conf_loader.sys"
local conf_parse = require "kong.conf_loader.parse"
local nginx_signals = require "kong.cmd.utils.nginx_signals"
local pl_pretty = require "pl.pretty"
local pl_config = require "pl.config"
local pl_file = require "pl.file"
local pl_path = require "pl.path"
local tablex = require "pl.tablex"
local log = require "kong.cmd.utils.log"
local env = require "kong.cmd.utils.env"
local constants = require "kong.constants"


local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy
local strip = require("kong.tools.string").strip


local fmt = string.format
local sub = string.sub
local type = type
local sort = table.sort
local find = string.find
local gsub = string.gsub
local lower = string.lower
local upper = string.upper
local match = string.match
local pairs = pairs
local assert = assert
local unpack = unpack
local ipairs = ipairs
local insert = table.insert
local remove = table.remove
local exists = pl_path.exists
local abspath = pl_path.abspath
local tostring = tostring
local setmetatable = setmetatable


local getgrnam = conf_sys.getgrnam
local getpwnam = conf_sys.getpwnam
local getenv   = conf_sys.getenv
local unsetenv = conf_sys.unsetenv


local get_phase = conf_parse.get_phase
local is_predefined_dhgroup = conf_parse.is_predefined_dhgroup
local parse_value = conf_parse.parse_value
local check_and_parse = conf_parse.check_and_parse
local overrides = conf_parse.overrides
local parse_nginx_directives = conf_parse.parse_nginx_directives


local function aliased_properties(conf)
  for property_name, v_schema in pairs(conf_constants.CONF_PARSERS) do
    local alias = v_schema.alias

    if alias and conf[property_name] ~= nil and conf[alias.replacement] == nil then
      if alias.alias then
        conf[alias.replacement] = alias.alias(conf)
      else
        local value = conf[property_name]
        if type(value) == "boolean" then
          value = value and "on" or "off"
        end
        conf[alias.replacement] = tostring(value)
      end
    end
  end
end


local function deprecated_properties(conf, opts)
  for property_name, v_schema in pairs(conf_constants.CONF_PARSERS) do
    local deprecated = v_schema.deprecated

    if deprecated and conf[property_name] ~= nil then
      if not opts.from_kong_env then
        if deprecated.value then
            log.warn("the configuration value '%s' for configuration property '%s' is deprecated", deprecated.value, property_name)
        end
        if deprecated.replacement then
          log.warn("the '%s' configuration property is deprecated, use " ..
                     "'%s' instead", property_name, deprecated.replacement)
        else
          log.warn("the '%s' configuration property is deprecated",
                   property_name)
        end
      end

      if deprecated.alias then
        deprecated.alias(conf)
      end
    end
  end
end


local function dynamic_properties(conf)
  for property_name, v_schema in pairs(conf_constants.CONF_PARSERS) do
    local value = conf[property_name]
    if value ~= nil then
      local directives = v_schema.directives
      if directives then
        for _, directive in ipairs(directives) do
          if not conf[directive] then
            if type(value) == "boolean" then
              value = value and "on" or "off"
            end
            conf[directive] = value
          end
        end
      end
    end
  end
end


local function load_config(thing)
  local s = pl_stringio.open(thing)
  local conf, err = pl_config.read(s, {
    smart = false,
    list_delim = "_blank_" -- mandatory but we want to ignore it
  })
  s:close()
  if not conf then
    return nil, err
  end

  local function strip_comments(value)
    -- remove trailing comment, if any
    -- and remove escape chars from octothorpes
    if value then
      value = ngx.re.sub(value, [[\s*(?<!\\)#.*$]], "", "jo")
      value = gsub(value, "\\#", "#")
    end
    return value
  end

  for key, value in pairs(conf) do
    conf[key] = strip_comments(value)
  end

  return conf
end


--- Load Kong configuration file
-- The loaded configuration will only contain properties read from the
-- passed configuration file (properties are not merged with defaults or
-- environment variables)
-- @param[type=string] Path to a configuration file.
local function load_config_file(path)
  assert(type(path) == "string")

  local f, err = pl_file.read(path)
  if not f then
    return nil, err
  end

  return load_config(f)
end

--- Get available Wasm filters list
---@param filters_path string # Path where Wasm filters are stored.
---@return kong.configuration.wasm_filter[]
local function get_wasm_filters(filters_path)
  local wasm_filters = {}

  if filters_path and pl_path.isdir(filters_path) then
    local filter_files = {}
    for entry in pl_path.dir(filters_path) do
      local pathname = pl_path.join(filters_path, entry)
      if not filter_files[pathname] and pl_path.isfile(pathname) then
        filter_files[pathname] = pathname

        local extension = pl_path.extension(entry)
        if lower(extension) == ".wasm" then
          insert(wasm_filters, {
            name = entry:sub(0, -#extension - 1),
            path = pathname,
          })

        else
          log.debug("ignoring file ", entry, " in ", filters_path, ": does not contain wasm suffix")
        end
      end
    end
  end

  return wasm_filters
end


--- Load Kong configuration
-- The loaded configuration will have all properties from the default config
-- merged with the (optionally) specified config file, environment variables
-- and values specified in the `custom_conf` argument.
-- Values will then be validated and additional values (such as `proxy_port` or
-- `plugins`) will be appended to the final configuration table.
-- @param[type=string] path (optional) Path to a configuration file.
-- @param[type=table] custom_conf A key/value table with the highest precedence.
-- @treturn table A table holding a valid configuration.
local function load(path, custom_conf, opts)
  opts = opts or {}

  ------------------------
  -- Default configuration
  ------------------------

  -- load defaults, they are our mandatory base
  local defaults, err = load_config(kong_default_conf)
  if not defaults then
    return nil, "could not load default conf: " .. err
  end

  ---------------------
  -- Configuration file
  ---------------------

  local from_file_conf = {}
  if path and not exists(path) then
    -- file conf has been specified and must exist
    return nil, "no file at: " .. path
  end

  if not path then
    -- try to look for a conf in default locations, but no big
    -- deal if none is found: we will use our defaults.
    for _, default_path in ipairs(conf_constants.DEFAULT_PATHS) do
      if exists(default_path) then
        path = default_path
        break
      end

      log.verbose("no config file found at %s", default_path)
    end
  end

  if not path then
    -- still no file in default locations
    log.verbose("no config file, skip loading")

  else
    log.verbose("reading config file at %s", path)

    from_file_conf, err = load_config_file(path)
    if not from_file_conf then
      return nil, "could not load config file: " .. err
    end
  end

  -----------------------
  -- Merging & validation
  -----------------------

  do
    -- find dynamic keys that need to be loaded
    local dynamic_keys = {}

    local function add_dynamic_keys(t)
      t = t or {}

      for property_name, v_schema in pairs(conf_constants.CONF_PARSERS) do
        local directives = v_schema.directives
        if directives then
          local v = t[property_name]
          if v then
            if type(v) == "boolean" then
              v = v and "on" or "off"
            end

            tostring(v)

            for _, directive in ipairs(directives) do
              dynamic_keys[directive] = true
              t[directive] = v
            end
          end
        end
      end
    end

    local function find_dynamic_keys(dyn_prefix, t)
      t = t or {}

      for k, v in pairs(t) do
        local directive = match(k, "^(" .. dyn_prefix .. ".+)")
        if directive then
          dynamic_keys[directive] = true

          if type(v) == "boolean" then
            v = v and "on" or "off"
          end

          t[k] = tostring(v)
        end
      end
    end

    local kong_env_vars = {}

    do
      -- get env vars prefixed with KONG_<dyn_key_prefix>
      local env_vars, err = env.read_all()
      if err then
        return nil, err
      end

      for k in pairs(env_vars) do
        local kong_var = match(lower(k), "^kong_(.+)")
        if kong_var then
          -- the value will be read in `overrides()`
          kong_env_vars[kong_var] = true
        end
      end
    end

    add_dynamic_keys(defaults)
    add_dynamic_keys(custom_conf)
    add_dynamic_keys(kong_env_vars)
    add_dynamic_keys(from_file_conf)

    for _, dyn_namespace in ipairs(conf_constants.DYNAMIC_KEY_NAMESPACES) do
      find_dynamic_keys(dyn_namespace.prefix, defaults) -- tostring() defaults
      find_dynamic_keys(dyn_namespace.prefix, custom_conf)
      find_dynamic_keys(dyn_namespace.prefix, kong_env_vars)
      find_dynamic_keys(dyn_namespace.prefix, from_file_conf)
    end

    -- union (add dynamic keys to `defaults` to prevent removal of the keys
    -- during the intersection that happens later)
    defaults = tablex.merge(dynamic_keys, defaults, true)
  end

  -- merge file conf, ENV variables, and arg conf (with precedence)
  local user_conf = tablex.pairmap(overrides, defaults,
                                   tablex.union(opts, { no_defaults = true, }),
                                   from_file_conf, custom_conf)

  if not opts.starting then
    log.disable()
  end

  aliased_properties(user_conf)
  dynamic_properties(user_conf)
  deprecated_properties(user_conf, opts)

  -- merge user_conf with defaults
  local conf = tablex.pairmap(overrides, defaults,
                              tablex.union(opts, { defaults_only = true, }),
                              user_conf)

  -- remove the unnecessary fields if we are still at the very early stage
  -- before executing the main `resty` cmd, i.e. still in `bin/kong`
  if opts.pre_cmd then
    for k in pairs(conf) do
      if not conf_constants.CONF_BASIC[k] then
        conf[k] = nil
      end
    end
  end

  ---------------------------------
  -- Dereference process references
  ---------------------------------

  local loaded_vaults
  local refs
  do
    -- validation
    local vaults_array = parse_value(conf.vaults, conf_constants.CONF_PARSERS["vaults"].typ)

    -- merge vaults
    local vaults = {}

    if #vaults_array > 0 and vaults_array[1] ~= "off" then
      for i = 1, #vaults_array do
        local vault_name = strip(vaults_array[i])
        if vault_name ~= "off" then
          if vault_name == "bundled" then
            vaults = tablex.merge(conf_constants.BUNDLED_VAULTS, vaults, true)

          else
            vaults[vault_name] = true
          end
        end
      end
    end

    loaded_vaults = setmetatable(vaults, conf_constants._NOP_TOSTRING_MT)

    -- collect references
    local is_reference = require "kong.pdk.vault".is_reference
    for k, v in pairs(conf) do
      local typ = (conf_constants.CONF_PARSERS[k] or {}).typ
      v = parse_value(v, typ == "array" and "array" or "string")
      if typ == "array" then
        local found

        for i, r in ipairs(v) do
          if is_reference(r) then
            found = true
            if not refs then
              refs = setmetatable({}, conf_constants._NOP_TOSTRING_MT)
            end
            if not refs[k] then
              refs[k] = {}
            end
            refs[k][i] = r
          end
        end

        if found then
          conf[k] = v
        end

      elseif is_reference(v) then
        if not refs then
          refs = setmetatable({}, conf_constants._NOP_TOSTRING_MT)
        end
        refs[k] = v
      end
    end

    local prefix = abspath(conf.prefix or ngx.config.prefix())
    local secret_env
    local secret_file
    local secrets_env_var_name = upper("KONG_PROCESS_SECRETS_" .. ngx.config.subsystem)
    local secrets = getenv(secrets_env_var_name)
    if secrets then
      secret_env = secrets_env_var_name

    else
      local secrets_path = pl_path.join(prefix, unpack(conf_constants.PREFIX_PATHS.kong_process_secrets)) .. "_" .. ngx.config.subsystem
      if exists(secrets_path) then
        secrets, err = pl_file.read(secrets_path, true)
        if not secrets then
          pl_file.delete(secrets_path)
          return nil, fmt("failed to read process secrets file: %s", err)
        end
        secret_file = secrets_path
      end
    end

    if secrets then
      local env_path = pl_path.join(prefix, unpack(conf_constants.PREFIX_PATHS.kong_env))
      secrets, err = process_secrets.deserialize(secrets, env_path)
      if not secrets then
        return nil, err
      end

      for k, deref in pairs(secrets) do
        conf[k] = deref
      end
    end

    if get_phase() == "init" then
      if secrets then
        if secret_env then
          unsetenv(secret_env)
        end
        if secret_file then
          pl_file.delete(secret_file)
        end
      end

    elseif refs then
      local vault_conf = { loaded_vaults = loaded_vaults }
      for k, v in pairs(conf) do
        if sub(k, 1, 6) == "vault_" then
          vault_conf[k] = parse_value(v, "string")
        end
      end
      local vault = require("kong.pdk.vault").new({ configuration = vault_conf })
      for k, v in pairs(refs) do
        if type(v) == "table" then
          for i, r in pairs(v) do
            local deref, deref_err = vault.get(r)
            if deref == nil or deref_err then
              if opts.starting then
                return nil, fmt("failed to dereference '%s': %s for config option '%s[%d]'", r, deref_err, k, i)
              end

              -- not that fatal if resolving fails during stopping (e.g. missing environment variables)
              if opts.stopping or opts.pre_cmd then
                conf[k][i] = "_INVALID_VAULT_KONG_REFERENCE"
              end

            else
              conf[k][i] = deref
            end
          end

        else
          local deref, deref_err = vault.get(v)
          if deref == nil or deref_err then
            if opts.starting then
              return nil, fmt("failed to dereference '%s': %s for config option '%s'", v, deref_err, k)
            end

            -- not that fatal if resolving fails during stopping (e.g. missing environment variables)
            if opts.stopping or opts.pre_cmd then
              conf[k] = ""
              break
            end

          else
            conf[k] = deref
          end
        end
      end

      -- remove invalid references and leave valid ones for
      -- pre_cmd or non-fatal stopping scenarios
      -- this adds some robustness if the vault reference is
      -- inside an array style config field and the config field
      -- is also needed by vault, for example the `lua_ssl_trusted_certificate`
      if opts.stopping or opts.pre_cmd then
        for k, v in pairs(refs) do
          if type(v) == "table" then
            conf[k] = setmetatable(tablex.filter(conf[k], function(v)
              return v ~= "_INVALID_VAULT_KONG_REFERENCE"
            end), nil)
          end
        end
      end
    end
  end

  -- validation
  local ok, err, errors = check_and_parse(conf, opts)
  if not opts.starting then
    log.enable()
  end

  if not ok then
    return nil, err, errors
  end

  conf = tablex.merge(conf, defaults) -- intersection (remove extraneous properties)

  conf.loaded_vaults = loaded_vaults
  conf["$refs"] = refs

  -- load absolute paths
  conf.prefix = abspath(conf.prefix)

  -- The socket path is where we store listening unix sockets for IPC and private APIs.
  -- It is derived from the prefix and is NOT intended to be user-configurable
  conf.socket_path = pl_path.join(conf.prefix, constants.SOCKET_DIRECTORY)
  conf.worker_events_sock = constants.SOCKETS.WORKER_EVENTS
  conf.stream_worker_events_sock = constants.SOCKETS.STREAM_WORKER_EVENTS
  conf.stream_rpc_sock = constants.SOCKETS.STREAM_RPC
  conf.stream_config_sock = constants.SOCKETS.STREAM_CONFIG
  conf.stream_tls_passthrough_sock = constants.SOCKETS.STREAM_TLS_PASSTHROUGH
  conf.stream_tls_terminate_sock = constants.SOCKETS.STREAM_TLS_TERMINATE
  conf.cluster_proxy_ssl_terminator_sock = constants.SOCKETS.CLUSTER_PROXY_SSL_TERMINATOR


  if conf.lua_ssl_trusted_certificate
     and #conf.lua_ssl_trusted_certificate > 0 then

    conf.lua_ssl_trusted_certificate = tablex.map(
      function(cert)
        if exists(cert) then
          return abspath(cert)
        end
        return cert
      end,
      conf.lua_ssl_trusted_certificate
    )

    conf.lua_ssl_trusted_certificate_combined =
      abspath(pl_path.join(conf.prefix, ".ca_combined"))
  end

  -- attach prefix files paths
  for property, t_path in pairs(conf_constants.PREFIX_PATHS) do
    conf[property] = pl_path.join(conf.prefix, unpack(t_path))
  end

  log.verbose("prefix in use: %s", conf.prefix)

  -- leave early if we're still at the very early stage before executing
  -- the main `resty` cmd. The rest confs below are unused.
  if opts.pre_cmd then
    return setmetatable(conf, nil) -- remove Map mt
  end

  local default_nginx_main_user = false
  local default_nginx_user = false

  do
    -- nginx 'user' directive
    local user = gsub(strip(conf.nginx_main_user), "%s+", " ")
    if user == "nobody" or user == "nobody nobody" then
      conf.nginx_main_user = nil

    elseif user == "kong" or user == "kong kong" then
      default_nginx_main_user = true
    end

    local user = gsub(strip(conf.nginx_user), "%s+", " ")
    if user == "nobody" or user == "nobody nobody" then
      conf.nginx_user = nil

    elseif user == "kong" or user == "kong kong" then
      default_nginx_user = true
    end
  end

  if getpwnam("kong") == nil or getgrnam("kong") == nil then
    if default_nginx_main_user == true and default_nginx_user == true then
      conf.nginx_user = nil
      conf.nginx_main_user = nil
    end
  end

  -- lmdb validation tag
  conf.lmdb_validation_tag = conf_constants.LMDB_VALIDATION_TAG

  -- Wasm module support
  if conf.wasm then
    ---@type table<string, boolean>
    local allowed_filter_names = {}
    local all_bundled_filters_enabled = false
    local all_user_filters_enabled = false
    local all_filters_disabled = false
    for _, filter in ipairs(conf.wasm_filters) do
      if filter == "bundled" then
        all_bundled_filters_enabled = true

      elseif filter == "user" then
        all_user_filters_enabled = true

      elseif filter == "off" then
        all_filters_disabled = true

      else
        allowed_filter_names[filter] = true
      end
    end

    if all_filters_disabled then
      allowed_filter_names = {}
      all_bundled_filters_enabled = false
      all_user_filters_enabled = false
    end

    ---@type table<string, kong.configuration.wasm_filter>
    local active_filters_by_name = {}

    local bundled_filter_path = conf_constants.WASM_BUNDLED_FILTERS_PATH
    if not pl_path.isdir(bundled_filter_path) then
      local alt_path

      local nginx_bin = nginx_signals.find_nginx_bin(conf)
      if nginx_bin then
        alt_path = pl_path.dirname(nginx_bin) .. "/../../../kong/wasm"
        alt_path = pl_path.normpath(alt_path) or alt_path
      end

      if alt_path and pl_path.isdir(alt_path) then
        log.debug("loading bundled proxy-wasm filters from alt path: %s",
                  alt_path)
        bundled_filter_path = alt_path

      else
        log.debug("Bundled proxy-wasm filters path (%s) does not exist " ..
                 "or is not a directory. Bundled filters may not be " ..
                 "available", bundled_filter_path)
      end
    end

    conf.wasm_bundled_filters_path = bundled_filter_path
    local bundled_filters = get_wasm_filters(bundled_filter_path)
    for _, filter in ipairs(bundled_filters) do
      if all_bundled_filters_enabled or allowed_filter_names[filter.name] then
        active_filters_by_name[filter.name] = filter
      end
    end

    local user_filters = get_wasm_filters(conf.wasm_filters_path)
    for _, filter in ipairs(user_filters) do
      if all_user_filters_enabled or allowed_filter_names[filter.name] then
        if active_filters_by_name[filter.name] then
          log.warn("Replacing bundled filter %s with a user-supplied " ..
                   "filter at %s", filter.name, filter.path)
        end
        active_filters_by_name[filter.name] = filter
      end
    end

    ---@type kong.configuration.wasm_filter[]
    local active_filters = {}
    for _, filter in pairs(active_filters_by_name) do
      insert(active_filters, filter)
    end
    sort(active_filters, function(lhs, rhs)
      return lhs.name < rhs.name
    end)

    conf.wasm_modules_parsed = setmetatable(active_filters, conf_constants._NOP_TOSTRING_MT)

    local function add_wasm_directive(directive, value, prefix)
      local directive_name = (prefix or "") .. directive
      if conf[directive_name] == nil then
        conf[directive_name] = value
      end
    end

    local wasm_main_prefix = "nginx_wasm_"

    -- proxy_wasm_lua_resolver is intended to be 'on' by default, but we can't
    -- set it as such in kong_defaults, because it can only be used if wasm is
    -- _also_ enabled. We inject it here if the user has not opted to set it
    -- themselves.
    add_wasm_directive("nginx_http_proxy_wasm_lua_resolver", "on")

    -- configure wasmtime module cache
    if conf.role == "traditional" or conf.role == "data_plane" then
      conf.wasmtime_cache_directory = pl_path.join(conf.prefix, ".wasmtime_cache")
      conf.wasmtime_cache_config_file = pl_path.join(conf.prefix, ".wasmtime_config.toml")
    end

    -- wasm vm properties are inherited from previously set directives
    if conf.lua_ssl_trusted_certificate and #conf.lua_ssl_trusted_certificate >= 1 then
      add_wasm_directive("tls_trusted_certificate", conf.lua_ssl_trusted_certificate[1], wasm_main_prefix)
    end

    if conf.lua_ssl_verify_depth and conf.lua_ssl_verify_depth > 0 then
      add_wasm_directive("tls_verify_cert", "on", wasm_main_prefix)
      add_wasm_directive("tls_verify_host", "on", wasm_main_prefix)
      add_wasm_directive("tls_no_verify_warn", "on", wasm_main_prefix)
    end

    local wasm_inherited_injections = {
      nginx_http_lua_socket_connect_timeout = "nginx_http_wasm_socket_connect_timeout",
      nginx_proxy_lua_socket_connect_timeout = "nginx_proxy_wasm_socket_connect_timeout",
      nginx_http_lua_socket_read_timeout = "nginx_http_wasm_socket_read_timeout",
      nginx_proxy_lua_socket_read_timeout = "nginx_proxy_wasm_socket_read_timeout",
      nginx_http_lua_socket_send_timeout = "nginx_http_wasm_socket_send_timeout",
      nginx_proxy_lua_socket_send_timeout = "nginx_proxy_wasm_socket_send_timeout",
      nginx_http_lua_socket_buffer_size = "nginx_http_wasm_socket_buffer_size",
      nginx_proxy_lua_socket_buffer_size = "nginx_proxy_wasm_socket_buffer_size",
    }

    for directive, wasm_directive in pairs(wasm_inherited_injections) do
      if conf[directive] then
        add_wasm_directive(wasm_directive, conf[directive])
      end
    end
  end

  do
    local injected_in_namespace = {}

    -- nginx directives from conf
    for _, dyn_namespace in ipairs(conf_constants.DYNAMIC_KEY_NAMESPACES) do
      if dyn_namespace.injected_conf_name then
        injected_in_namespace[dyn_namespace.injected_conf_name] = true

        local directives = parse_nginx_directives(dyn_namespace, conf,
          injected_in_namespace)
        conf[dyn_namespace.injected_conf_name] = setmetatable(directives,
          conf_constants._NOP_TOSTRING_MT)
      end
    end

    -- TODO: Deprecated, but kept for backward compatibility.
    for _, dyn_namespace in ipairs(conf_constants.DEPRECATED_DYNAMIC_KEY_NAMESPACES) do
      if conf[dyn_namespace.injected_conf_name] then
        conf[dyn_namespace.previous_conf_name] = conf[dyn_namespace.injected_conf_name]
      end
    end
  end

  do
    -- print alphabetically-sorted values
    local conf_arr = {}

    for k, v in pairs(conf) do
      if k ~= "$refs" then
        local to_print = v
        if conf_constants.CONF_SENSITIVE[k] then
          to_print = conf_constants.CONF_SENSITIVE_PLACEHOLDER
        end

        conf_arr[#conf_arr+1] = k .. " = " .. pl_pretty.write(to_print, "")
      end
    end

    sort(conf_arr)

    for i = 1, #conf_arr do
      log.debug(conf_arr[i])
    end
  end

  -----------------------------
  -- Additional injected values
  -----------------------------

  do
    -- merge plugins
    local plugins = {}

    if #conf.plugins > 0 and conf.plugins[1] ~= "off" then
      for i = 1, #conf.plugins do
        local plugin_name = strip(conf.plugins[i])
        if plugin_name ~= "off" then
          if plugin_name == "bundled" then
            plugins = tablex.merge(conf_constants.BUNDLED_PLUGINS, plugins, true)

          else
            plugins[plugin_name] = true
          end
        end
      end
    end

    if conf.wasm_modules_parsed then
      for _, filter in ipairs(conf.wasm_modules_parsed) do
        assert(plugins[filter.name] == nil,
               "duplicate plugin/wasm filter name: " .. filter.name)
        plugins[filter.name] = true
      end
    end

    conf.loaded_plugins = setmetatable(plugins, conf_constants._NOP_TOSTRING_MT)
  end

  -- temporary workaround: inject an shm for prometheus plugin if needed
  -- TODO: allow plugins to declare shm dependencies that are automatically
  -- injected
  if conf.loaded_plugins["prometheus"] then
    local http_directives = conf["nginx_http_directives"]
    local found = false

    for _, directive in pairs(http_directives) do
      if directive.name == "lua_shared_dict"
         and find(directive.value, "prometheus_metrics", nil, true)
      then
         found = true
         break
      end
    end

    if not found then
      insert(http_directives, {
        name  = "lua_shared_dict",
        value = "prometheus_metrics 5m",
      })
    end

    local stream_directives = conf["nginx_stream_directives"]
    local found = false

    for _, directive in pairs(stream_directives) do
      if directive.name == "lua_shared_dict"
        and find(directive.value, "stream_prometheus_metrics", nil, true)
      then
        found = true
        break
      end
    end

    if not found then
      insert(stream_directives, {
        name  = "lua_shared_dict",
        value = "stream_prometheus_metrics 5m",
      })
    end
  end

  for _, dyn_namespace in ipairs(conf_constants.DYNAMIC_KEY_NAMESPACES) do
    if dyn_namespace.injected_conf_name then
      sort(conf[dyn_namespace.injected_conf_name], function(a, b)
        return a.name < b.name
      end)
    end
  end

  ok, err = listeners.parse(conf, {
    { name = "proxy_listen",   subsystem = "http",   ssl_flag = "proxy_ssl_enabled" },
    { name = "stream_listen",  subsystem = "stream", ssl_flag = "stream_proxy_ssl_enabled" },
    { name = "admin_listen",   subsystem = "http",   ssl_flag = "admin_ssl_enabled" },
    { name = "admin_gui_listen", subsystem = "http", ssl_flag = "admin_gui_ssl_enabled" },
    { name = "status_listen",  subsystem = "http",   ssl_flag = "status_ssl_enabled" },
    { name = "cluster_listen", subsystem = "http" },
  })
  if not ok then
    return nil, err
  end

  do
    -- load headers configuration

    -- (downstream)
    local enabled_headers = {}
    for _, v in pairs(conf_constants.HEADER_KEY_TO_NAME) do
      enabled_headers[v] = false
    end

    if #conf.headers > 0 and conf.headers[1] ~= "off" then
      for _, token in ipairs(conf.headers) do
        if token ~= "off" then
          enabled_headers[conf_constants.HEADER_KEY_TO_NAME[lower(token)]] = true
        end
      end
    end

    if enabled_headers.server_tokens then
      enabled_headers[conf_constants.HEADERS.VIA] = true
      enabled_headers[conf_constants.HEADERS.SERVER] = true
    end

    if enabled_headers.latency_tokens then
      enabled_headers[conf_constants.HEADERS.PROXY_LATENCY] = true
      enabled_headers[conf_constants.HEADERS.RESPONSE_LATENCY] = true
      enabled_headers[conf_constants.HEADERS.ADMIN_LATENCY] = true
      enabled_headers[conf_constants.HEADERS.UPSTREAM_LATENCY] = true
    end

    conf.enabled_headers = setmetatable(enabled_headers, conf_constants._NOP_TOSTRING_MT)


    -- (upstream)
    local enabled_headers_upstream = {}
    for _, v in pairs(conf_constants.UPSTREAM_HEADER_KEY_TO_NAME) do
      enabled_headers_upstream[v] = false
    end

    if #conf.headers_upstream > 0 and conf.headers_upstream[1] ~= "off" then
      for _, token in ipairs(conf.headers_upstream) do
        if token ~= "off" then
          enabled_headers_upstream[conf_constants.UPSTREAM_HEADER_KEY_TO_NAME[lower(token)]] = true
        end
      end
    end

    conf.enabled_headers_upstream = setmetatable(enabled_headers_upstream, conf_constants._NOP_TOSTRING_MT)
  end

  for _, prefix in ipairs({ "ssl", "admin_ssl", "admin_gui_ssl", "status_ssl", "client_ssl", "cluster" }) do
    local ssl_cert = conf[prefix .. "_cert"]
    local ssl_cert_key = conf[prefix .. "_cert_key"]

    if ssl_cert and ssl_cert_key then
      if type(ssl_cert) == "table" then
        for i, cert in ipairs(ssl_cert) do
          if exists(ssl_cert[i]) then
            ssl_cert[i] = abspath(cert)
          end
        end

      elseif exists(ssl_cert) then
        conf[prefix .. "_cert"] = abspath(ssl_cert)
      end

      if type(ssl_cert_key) == "table" then
        for i, key in ipairs(ssl_cert_key) do
          if exists(ssl_cert_key[i]) then
            ssl_cert_key[i] = abspath(key)
          end
        end

      elseif exists(ssl_cert_key) then
        conf[prefix .. "_cert_key"] = abspath(ssl_cert_key)
      end
    end
  end

  if conf.cluster_ca_cert and exists(conf.cluster_ca_cert) then
    conf.cluster_ca_cert = abspath(conf.cluster_ca_cert)
  end

  local ssl_enabled = conf.proxy_ssl_enabled or
                      conf.stream_proxy_ssl_enabled or
                      conf.admin_ssl_enabled or
                      conf.status_ssl_enabled

  for _, name in ipairs({ "nginx_http_directives", "nginx_stream_directives" }) do
    for i, directive in ipairs(conf[name]) do
      if directive.name == "ssl_dhparam" then
        if is_predefined_dhgroup(directive.value) then
          if ssl_enabled then
            directive.value = abspath(pl_path.join(conf.prefix, "ssl", directive.value .. ".pem"))

          else
            remove(conf[name], i)
          end

        elseif exists(directive.value) then
          directive.value = abspath(directive.value)
        end

        break
      end
    end
  end

  -- admin_gui_origin is a parameter for internal use only
  -- it's not set directly by the user
  -- if admin_gui_path is set to a path other than /, admin_gui_url may
  -- contain a path component
  -- to make it suitable to be used as an origin in headers, we need to
  -- parse and reconstruct the admin_gui_url to ensure it only contains
  -- the scheme, host, and port
  if conf.admin_gui_url and #conf.admin_gui_url > 0 then
    local admin_gui_origin = {}
    for _, url in ipairs(conf.admin_gui_url) do
      local parsed_url = socket_url.parse(url)
      table.insert(admin_gui_origin, parsed_url.scheme .. "://" .. parsed_url.authority)
    end
    conf.admin_gui_origin = admin_gui_origin
  end

  -- hybrid mode HTTP tunneling (CONNECT) proxy inside HTTPS
  if conf.cluster_use_proxy then
    -- throw err, assume it's already handled in check_and_parse
    local parsed = assert(socket_url.parse(conf.proxy_server))
    if parsed.scheme == "https" then
      conf.cluster_ssl_tunnel = fmt("%s:%s", parsed.host, parsed.port or 443)
    end
  end

  if conf.cluster_rpc_sync and not conf.cluster_rpc then
    log.warn("Cluster rpc sync has been forcibly disabled, " ..
             "please enable cluster RPC.")
    conf.cluster_rpc_sync = false
  end

  -- parse and validate pluginserver directives
  if conf.pluginserver_names then
    local pluginservers = {}
    for i, name in ipairs(conf.pluginserver_names) do
      name = name:lower()
      local env_prefix = "pluginserver_" .. name:gsub("-", "_")
      local socket = conf[env_prefix .. "_socket"] or (conf.prefix .. "/" .. name .. ".socket")

      local start_command = conf[env_prefix .. "_start_cmd"]
      local query_command = conf[env_prefix .. "_query_cmd"]

      local default_path = exists(conf_constants.DEFAULT_PLUGINSERVER_PATH .. "/" .. name)

      if not start_command and default_path then
        start_command = default_path
      end

      if not query_command and default_path then
        query_command = default_path .. " -dump"
      end

      -- query_command is required
      if not query_command then
        return nil, "query_command undefined for pluginserver " .. name
      end

      -- if start_command is unset, we assume the pluginserver process is
      -- managed externally
      if not start_command then
        log.warn("start_command undefined for pluginserver " .. name .. "; assuming external process management")
      end

      pluginservers[i] = {
        name = name,
        socket = socket,
        start_command = start_command,
        query_command = query_command,
      }
    end

    conf.pluginservers = setmetatable(pluginservers, conf_constants._NOP_TOSTRING_MT)
  end

  -- initialize the dns client, so the globally patched tcp.connect method
  -- will work from here onwards.
  assert(require("kong.tools.dns")(conf))

  return setmetatable(conf, nil) -- remove Map mt
end


return setmetatable({
  load = load,

  load_config_file = load_config_file,

  add_default_path = function(path)
    table.insert(conf_constants.DEFAULT_PATHS, path)
  end,

  remove_sensitive = function(conf)
    local purged_conf = cycle_aware_deep_copy(conf)

    local refs = purged_conf["$refs"]
    if type(refs) == "table" then
      for k, v in pairs(refs) do
        if not conf_constants.CONF_SENSITIVE[k] then
          purged_conf[k] = v
        end
      end
      purged_conf["$refs"] = nil
    end

    for k in pairs(conf_constants.CONF_SENSITIVE) do
      if purged_conf[k] then
        purged_conf[k] = conf_constants.CONF_SENSITIVE_PLACEHOLDER
      end
    end

    return purged_conf
  end,
}, {
  __call = function(_, ...)
    return load(...)
  end,
})
