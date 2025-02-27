local cjson = require "cjson"
local iteration = require "kong.db.iteration"
local kong_table = require "kong.tools.table"
local defaults = require "kong.db.strategies.connector".defaults
local hooks = require "kong.hooks"
local workspaces = require "kong.workspaces"
local new_tab = require "table.new"
local DAO_MAX_TTL = require("kong.constants").DATABASE.DAO_MAX_TTL
local is_valid_uuid = require("kong.tools.uuid").is_valid_uuid
local deep_copy     = require("kong.tools.table").deep_copy

local setmetatable = setmetatable
local tostring     = tostring
local require      = require
local concat       = table.concat
local insert       = table.insert
local error        = error
local pairs        = pairs
local floor        = math.floor
local null         = ngx.null
local type         = type
local next         = next
local log          = ngx.log
local fmt          = string.format
local match        = string.match
local run_hook     = hooks.run_hook
local table_merge  = kong_table.table_merge


local ERR          = ngx.ERR


local _M    = {}
local DAO   = {}
DAO.__index = DAO


local function remove_nulls(tbl)
  for k,v in pairs(tbl) do
    if v == null then
      tbl[k] = nil
    elseif type(v) == "table" then
      tbl[k] = remove_nulls(v)
    end
  end
  return tbl
end


local function validate_size_type(size)
  if type(size) ~= "number" then
    error("size must be a number", 3)
  end

  return true
end


local function validate_size_value(size, max)
  if floor(size) ~= size or
           size < 1 or
           size > max then
    return nil, "size must be an integer between 1 and " .. max
  end

  return true
end


local function validate_offset_type(offset)
  if type(offset) ~= "string" then
    error("offset must be a string", 3)
  end

  return true
end


local function validate_entity_type(entity)
  if type(entity) ~= "table" then
    error("entity must be a table", 3)
  end

  return true
end


local function validate_primary_key_type(primary_key)
  if type(primary_key) ~= "table" then
    error("primary_key must be a table", 3)
  end

  return true
end


local function validate_foreign_key_type(foreign_key)
  if type(foreign_key) ~= "table" then
    error("foreign_key must be a table", 3)
  end

  return true
end


local function validate_foreign_key_is_single_primary_key(field)
  if #field.schema.primary_key > 1 then
    error("primary keys containing composite foreign keys " ..
          "are currently not supported", 3)
  end

  return true
end


local function validate_unique_type(unique_value, name, field)
  if type(unique_value) ~= "table" and (field.type == "array"  or
                                        field.type == "set"    or
                                        field.type == "map"    or
                                        field.type == "record" or
                                        field.type == "foreign") then
    error(fmt("%s must be a table", name), 3)

  elseif type(unique_value) ~= "string" and field.type == "string" then
    error(fmt("%s must be a string", name), 3)

  elseif type(unique_value) ~= "number" and (field.type == "number" or
    field.type == "integer") then
    error(fmt("%s must be a number", name), 3)

  elseif type(unique_value) ~= "boolean" and field.type == "boolean" then
    error(fmt("%s must be a boolean", name), 3)
  end

  return true
end


local function validate_options_type(options)
  if type(options) ~= "table" then
    error("options must be a table when specified", 3)
  end

  return true
end


local function get_pagination_options(self, options)
  if options == nil then
    return {
      pagination = self.pagination,
    }
  end

  if type(options) ~= "table" then
    error("options must be a table when specified", 3)
  end

  options = kong_table.cycle_aware_deep_copy(options, true)

  if type(options.pagination) == "table" then
    options.pagination = table_merge(self.pagination, options.pagination)

  else
    options.pagination = self.pagination
  end

  return options
end


local function validate_options_value(self, options)
  local errors = {}
  local schema = self.schema

  if options.workspace then
    if type(options.workspace) == "string" then
      if not is_valid_uuid(options.workspace) then
        local ws = kong.db.workspaces:select_by_name(options.workspace)
        if ws then
          options.workspace = ws.id
        else
          errors.workspace = "invalid workspace"
        end
      end
    elseif options.workspace ~= null then
      errors.workspace = "must be a string or null"
    end
  end


  if options.show_ws_id and type(options.show_ws_id) ~= "boolean" then
    errors.show_ws_id = "must be a boolean"
  end

  if schema.ttl == true and options.ttl ~= nil then
    if floor(options.ttl) ~= options.ttl or
                 options.ttl < 0 or
                 options.ttl > DAO_MAX_TTL then
      errors.ttl = "must be an integer between 0 and " .. DAO_MAX_TTL
    end

  elseif schema.ttl ~= true and options.ttl ~= nil then
    errors.ttl = fmt("cannot be used with '%s'", schema.name)
  end

  if schema.fields.tags and options.tags ~= nil then
    if type(options.tags) ~= "table" then
      if not options.tags_cond then
        -- If options.tags is not a table and options.tags_cond is nil at the same time
        -- it means arguments.lua gets an invalid tags arg from the Admin API
        errors.tags = "invalid filter syntax"
      else
        errors.tags = "must be a table"
      end
    elseif #options.tags > 5 then
      errors.tags = "cannot query more than 5 tags"
    elseif not match(concat(options.tags), "^[ \033-\043\045\046\048-\126\128-\244]+$") then
      errors.tags = "must only contain printable ascii (except `,` and `/`) or valid utf-8"
    elseif #options.tags > 1 and options.tags_cond ~= "and" and options.tags_cond ~= "or" then
      errors.tags_cond = "must be a either 'and' or 'or' when more than one tag is specified"
    end

  elseif schema.fields.tags == nil and options.tags ~= nil then
    errors.tags = fmt("cannot be used with '%s'", schema.name)
  end

  if options.pagination ~= nil then
    if type(options.pagination) ~= "table" then
      errors.pagination = "must be a table"

    else
      local page_size     = options.pagination.page_size
      local max_page_size = options.pagination.max_page_size

      if max_page_size == nil then
        max_page_size = self.pagination.max_page_size

      elseif type(max_page_size) ~= "number" then
        errors.pagination = {
          max_page_size = "must be a number",
        }

        max_page_size = self.pagination.max_page_size

      elseif floor(max_page_size) ~= max_page_size or max_page_size < 1 then
        errors.pagination = {
          max_page_size = "must be an integer greater than 0",
        }

        max_page_size = self.pagination.max_page_size
      end

      if page_size ~= nil then
        if type(page_size) ~= "number" then
          if not errors.pagination then
            errors.pagination = {
              page_size = "must be a number",
            }

          else
            errors.pagination.page_size = "must be a number"
          end

        elseif floor(page_size) ~= page_size
          or page_size < 1
          or page_size > max_page_size
        then
          if not errors.pagination then
            errors.pagination = {
              page_size = fmt("must be an integer between 1 and %d", max_page_size),
            }

          else
            errors.pagination.page_size = fmt("must be an integer between 1 and %d", max_page_size)
          end
        end
      end
    end
  end

  if options.transform ~= nil then
    if type(options.transform) ~= "boolean" then
      errors.transform = "must be a boolean"
    end
  end

  if options.export ~= nil then
    if type(options.export) ~= "boolean" then
      errors.export = "must be a boolean"
    end
  end

  if options.skip_ttl ~= nil then
    if type(options.skip_ttl) ~= "boolean" then
      errors.skip_ttl = "must be a boolean"
    end
  end

  if next(errors) then
    return nil, errors
  end

  return true
end


local function validate_pagination_method(self, field, foreign_key, size, offset, options)
  validate_foreign_key_type(foreign_key)

  if size ~= nil then
    validate_size_type(size)
  end

  if offset ~= nil then
    validate_offset_type(offset)
  end

  options = get_pagination_options(self, options)

  local ok, errors = self.schema:validate_field(field, foreign_key)
  if not ok then
    local err_t = self.errors:invalid_primary_key(errors)
    return nil, tostring(err_t), err_t
  end

  if size ~= nil then
    local err
    ok, err = validate_size_value(size, options.pagination.max_page_size)
    if not ok then
      local err_t = self.errors:invalid_size(err)
      return nil, tostring(err_t), err_t
    end

  else
    size = options.pagination.page_size
  end

  ok, errors = validate_options_value(self, options)
  if not ok then
    local err_t = self.errors:invalid_options(errors)
    return nil, tostring(err_t), err_t
  end

  return size
end


local function validate_unique_row_method(self, name, field, unique_value, options)
  local schema = self.schema
  validate_unique_type(unique_value, name, field)

  if options ~= nil then
    validate_options_type(options)

    if options.workspace == null and not field.unique_across_ws then
      local err_t = self.errors:invalid_unique_global(name)
      return nil, tostring(err_t), err_t
    end
  end

  local ok, errors = schema:validate_field(field, unique_value)
  if not ok then
    if field.type == "foreign" then
      local err_t = self.errors:invalid_foreign_key(errors)
      return nil, tostring(err_t), err_t
    end

    local err_t = self.errors:invalid_unique(name, errors)
    return nil, tostring(err_t), err_t
  end

  if options ~= nil then
    ok, errors = validate_options_value(self, options)
    if not ok then
      local err_t = self.errors:invalid_options(errors)
      return nil, tostring(err_t), err_t
    end
  end

  return true
end


local function resolve_foreign(self, entity)
  local errors = {}
  local has_errors

  for field_name, field in self.schema:each_field() do
    local schema = field.schema
    if field.type == "foreign" and schema.validate_primary_key then
      local value = entity[field_name]
      if value and value ~= null then
        if not schema:validate_primary_key(value, true) then
          local resolve_errors = {}
          local has_resolve_errors
          for unique_field_name, unique_field in schema:each_field() do
            if unique_field.unique or unique_field.endpoint_key then
              local unique_value = value[unique_field_name]
              if unique_value and unique_value ~= null and
                 schema:validate_field(unique_field, unique_value) then

                local dao = self.db[schema.name]
                local select = dao["select_by_" .. unique_field_name]
                local foreign_entity, err, err_t = select(dao, unique_value)
                if err_t then
                  return nil, err, err_t
                end

                if foreign_entity then
                  entity[field_name] = schema:extract_pk_values(foreign_entity)
                  break
                end

                resolve_errors[unique_field_name] = {
                  name   = unique_field_name,
                  value  = unique_value,
                  parent = schema.name,
                }

                has_resolve_errors = true
              end
            end
          end

          if has_resolve_errors then
            errors[field_name] = resolve_errors
            has_errors = true
          end
        end
      end
    end
  end

  if has_errors then
    local err_t = self.errors:foreign_keys_unresolved(errors)
    return nil, tostring(err_t), err_t
  end

  return true
end


local function check_insert(self, entity, options)
  local transform
  if options ~= nil then
    local ok, errors = validate_options_value(self, options)
    if not ok then
      local err_t = self.errors:invalid_options(errors)
      return nil, tostring(err_t), err_t
    end
    transform = options.transform
  end

  if transform == nil then
    transform = true
  end

  local entity_to_insert, err = self.schema:process_auto_fields(entity, "insert")
  if not entity_to_insert then
    local err_t = self.errors:schema_violation(err)
    return nil, tostring(err_t), err_t
  end

  local ok, err, err_t = resolve_foreign(self, entity_to_insert)
  if not ok then
    return nil, err, err_t
  end

  local ok, errors = self.schema:validate_insert(entity_to_insert, entity)
  if not ok then
    local err_t = self.errors:schema_violation(errors)
    return nil, tostring(err_t), err_t
  end

  if transform then
    entity_to_insert, err = self.schema:transform(entity_to_insert, entity, "insert")
    if not entity_to_insert then
      err_t = self.errors:transformation_error(err)
      return nil, tostring(err_t), err_t
    end
  end

  if self.schema.cache_key and #self.schema.cache_key > 1 then
    entity_to_insert.cache_key = self:cache_key(entity_to_insert)
  end

  return entity_to_insert
end


local function check_update(self, key, entity, options, name)
  options = options or {}
  local ok, errors = validate_options_value(self, options)
  if not ok then
    local err_t = self.errors:invalid_options(errors)
    return nil, nil, tostring(err_t), err_t
  end
  local transform = options.transform


  if transform == nil then
    transform = true
  end

  local entity_to_update, err, check_immutable_fields =
    self.schema:process_auto_fields(entity, "update")
  if not entity_to_update then
    local err_t = self.errors:schema_violation(err)
    return nil, nil, tostring(err_t), err_t
  end

  local rbw_entity
  local err, err_t
  if name then
    options.hide_shorthands = true
    rbw_entity, err, err_t = self["select_by_" .. name](self, key, options)
    options.hide_shorthands = false
  else
    options.hide_shorthands = true
    rbw_entity, err, err_t = self:select(key, options)
    options.hide_shorthands = false
  end
  if err then
    return nil, nil, err, err_t
  end

  if rbw_entity and check_immutable_fields then
    local ok, errors = self.schema:validate_immutable_fields(entity_to_update, rbw_entity)
    if not ok then
      local err_t = self.errors:schema_violation(errors)
      return nil, nil, tostring(err_t), err_t
    end
  end

  if rbw_entity then
    entity_to_update = self.schema:merge_values(entity_to_update, rbw_entity)
  else
    local err_t = name and self.errors:not_found_by_field({ [name] = key })
                        or self.errors:not_found(key)
    return nil, nil, tostring(err_t), err_t
  end

  local ok, err, err_t = resolve_foreign(self, entity_to_update)
  if not ok then
    return nil, nil, err, err_t
  end

  local ok, errors = self.schema:validate_update(entity_to_update, entity, rbw_entity)
  if not ok then
    local err_t = self.errors:schema_violation(errors)
    return nil, nil, tostring(err_t), err_t
  end

  if transform then
    entity_to_update, err = self.schema:transform(entity_to_update, entity, "update")
    if not entity_to_update then
      err_t = self.errors:transformation_error(err)
      return nil, nil, tostring(err_t), err_t
    end
  end

  if self.schema.cache_key and #self.schema.cache_key > 1 then
    entity_to_update.cache_key = self:cache_key(entity_to_update)
  end

  return entity_to_update, rbw_entity
end


local function check_upsert(self, key, entity, options, name)
  local transform
  if options ~= nil then
    local ok, errors = validate_options_value(self, options)
    if not ok then
      local err_t = self.errors:invalid_options(errors)
      return nil, nil, tostring(err_t), err_t
    end
    transform = options.transform
  end

  if transform == nil then
    transform = true
  end

  local entity_to_upsert, err =
    self.schema:process_auto_fields(entity, "upsert")
  if not entity_to_upsert then
    local err_t = self.errors:schema_violation(err)
    return nil, nil, tostring(err_t), err_t
  end

  local rbw_entity
  local err, err_t
  if name then
     rbw_entity, err, err_t = self["select_by_" .. name](self, key, options)
  else
     rbw_entity, err, err_t = self:select(key, options)
  end
  if err then
    return nil, nil, err, err_t
  end

  if name then
    entity_to_upsert[name] = key
  end

  local ok, err, err_t = resolve_foreign(self, entity_to_upsert)
  if not ok then
    return nil, nil, err, err_t
  end

  local ok, errors = self.schema:validate_upsert(entity_to_upsert, entity)
  if not ok then
    local err_t = self.errors:schema_violation(errors)
    return nil, nil, tostring(err_t), err_t
  end

  if name then
    entity_to_upsert[name] = nil
  end

  if transform then
    entity_to_upsert, err = self.schema:transform(entity_to_upsert, entity, "upsert")
    if not entity_to_upsert then
      err_t = self.errors:transformation_error(err)
      return nil, nil, tostring(err_t), err_t
    end
  end

  if self.schema.cache_key and #self.schema.cache_key > 1 then
    entity_to_upsert.cache_key = self:cache_key(entity_to_upsert)
  end

  return entity_to_upsert, rbw_entity
end


local function recursion_over_constraints(self, entity, opts, entries, c)
  local constraints = c and c.schema:get_constraints()
                      or self.schema:get_constraints()

  if #constraints == 0 then
    return
  end

  local pk = self.schema:extract_pk_values(entity)
  for i = 1, #constraints do
    local constraint = constraints[i]
    if constraint.on_delete == "cascade" then
      local dao = self.db.daos[constraint.schema.name]
      local method = "each_for_" .. constraint.field_name
      for row, err in dao[method](dao, pk, nil, opts) do
        if not row then
          log(ERR, "[db] failed to traverse entities for cascade-delete: ", err)
          break
        end

        insert(entries, { dao = dao, entity = row })

        recursion_over_constraints(self, row, opts, entries, constraint)
      end
    end
  end

  return entries
end


local function find_cascade_delete_entities(self, entity, opts)
  local entries = {}

  recursion_over_constraints(self, entity, opts, entries)

  return entries
end
-- for unit tests only
_M._find_cascade_delete_entities = find_cascade_delete_entities


local function propagate_cascade_delete_events(entries, options)
  for i = 1, #entries do
    entries[i].dao:post_crud_event("delete", entries[i].entity, nil, options)
  end
end


local function generate_foreign_key_methods(schema)
  local methods = {}

  for name, field in schema:each_field() do
    local field_is_foreign = field.type == "foreign"
    if field_is_foreign then
      validate_foreign_key_is_single_primary_key(field)

      local page_method_name = "page_for_" .. name
      methods[page_method_name] = function(self, foreign_key, size, offset, options)
        local size, err, err_t = validate_pagination_method(self, field,
                                   foreign_key, size, offset, options)
        if not size then
          return nil, err, err_t
        end

        local ok, err_t = run_hook("dao:page_for:pre",
                                   foreign_key,
                                   self.schema.name,
                                   options)
        if not ok then
          return nil, tostring(err_t), err_t
        end

        local strategy = self.strategy

        local rows, err_t, new_offset = strategy[page_method_name](strategy,
                                                                   foreign_key,
                                                                   size,
                                                                   offset,
                                                                   options)
        if not rows then
          return nil, tostring(err_t), err_t
        end

        local entities, err
        entities, err, err_t = self:rows_to_entities(rows, options)
        if err then
          return nil, err, err_t
        end

        entities, err_t = run_hook("dao:page_for:post",
                                   entities,
                                   self.schema.name,
                                   options)
        if not entities then
          return nil, tostring(err_t), err_t
        end

        return entities, nil, nil, new_offset
      end

      local each_method_name = "each_for_" .. name
      methods[each_method_name] = function(self, foreign_key, size, options)
        local size, _, err_t = validate_pagination_method(self, field,
                                 foreign_key, size, nil, options)
        if not size then
          return iteration.failed(tostring(err_t), err_t)
        end

        local strategy = self.strategy
        local pager = function(size, offset, options)
          return strategy[page_method_name](strategy, foreign_key, size, offset, options)
        end

        return iteration.by_row(self, pager, size, options)
      end
    end

    if field.unique or schema.endpoint_key == name then
      methods["select_by_" .. name] = function(self, unique_value, options)
        local ok, err, err_t = validate_unique_row_method(self, name, field, unique_value, options)
        if not ok then
          return nil, err, err_t
        end

        local ok, err_t = run_hook("dao:select_by:pre",
                                   unique_value,
                                   self.schema.name,
                                   options)
        if not ok then
          return nil, tostring(err_t), err_t
        end

        local row, err_t = self.strategy:select_by_field(name, unique_value, options)
        if err_t then
          return nil, tostring(err_t), err_t
        end

        if not row then
          return nil
        end

        local err
        row, err, err_t = self:row_to_entity(row, options)
        if not row then
          return nil, err, err_t
        end

        row, err_t = run_hook("dao:select_by:post",
                              row,
                              self.schema.name,
                              options)
        if not row then
          return nil, tostring(err_t), err_t
        end

        return row
      end

      methods["update_by_" .. name] = function(self, unique_value, entity, options)
        local ok, err, err_t = validate_unique_row_method(self, name, field, unique_value, options)
        if not ok then
          return nil, err, err_t
        end

        validate_entity_type(entity)

        local ok, err_t = run_hook("dao:update_by:pre",
                                   unique_value,
                                   self.schema.name,
                                   options)
        if not ok then
          return nil, tostring(err_t), err_t
        end

        local entity_to_update, rbw_entity, err, err_t = check_update(self, unique_value,
                                                                      entity, options, name)
        if not entity_to_update then
          run_hook("dao:update_by:fail", err_t, entity_to_update, self.schema.name, options)
          return nil, err, err_t
        end

        local row, err_t = self.strategy:update_by_field(name, unique_value,
                                                         entity_to_update, options)
        if not row then
          run_hook("dao:update_by:fail", err_t, entity_to_update, self.schema.name, options)
          return nil, tostring(err_t), err_t
        end

        row, err, err_t = self:row_to_entity(row, options)
        if not row then
          return nil, err, err_t
        end

        row, err_t = run_hook("dao:update_by:post",
                              row,
                              self.schema.name,
                              options)
        if not row then
          return nil, tostring(err_t), err_t
        end

        self:post_crud_event("update", row, rbw_entity, options)

        return row
      end

      methods["upsert_by_" .. name] = function(self, unique_value, entity, options)
        local ok, err, err_t = validate_unique_row_method(self, name, field, unique_value, options)
        if not ok then
          return nil, err, err_t
        end

        validate_entity_type(entity)

        local entity_to_upsert, rbw_entity, err, err_t = check_upsert(self,
                                                                      unique_value,
                                                                      entity,
                                                                      options,
                                                                      name)
        if not entity_to_upsert then
          return nil, err, err_t
        end

        local ok, err_t = run_hook("dao:upsert_by:pre",
                                   entity_to_upsert,
                                   self.schema.name,
                                   options)
        if not ok then
          return nil, tostring(err_t), err_t
        end

        local row, err_t = self.strategy:upsert_by_field(name, unique_value,
                                                         entity_to_upsert, options)
        if not row then
          run_hook("dao:upsert_by:fail", err_t, entity_to_upsert, self.schema.name, options)
          return nil, tostring(err_t), err_t
        end

        local ws_id = row.ws_id
        row, err, err_t = self:row_to_entity(row, options)
        if not row then
          run_hook("dao:upsert_by:fail", err_t, entity_to_upsert, self.schema.name, options)
          return nil, err, err_t
        end

        row, err_t = run_hook("dao:upsert_by:post",
                              row,
                              self.schema.name,
                              options,
                              ws_id,
                              rbw_entity)
        if not row then
          return nil, tostring(err_t), err_t
        end

        if rbw_entity then
          self:post_crud_event("update", row, rbw_entity, options)
        else
          self:post_crud_event("create", row, nil, options)
        end

        return row
      end

      methods["delete_by_" .. name] = function(self, unique_value, options)
        local ok, err, err_t = validate_unique_row_method(self, name, field, unique_value, options)
        if not ok then
          return nil, err, err_t
        end

        local select_options = deep_copy(options or {})
        select_options["show_ws_id"] = true
        local entity, err, err_t = self["select_by_" .. name](self, unique_value, select_options)
        if err then
          return nil, err, err_t
        end

        if not entity then
          return true
        end

        local cascade_entries = find_cascade_delete_entities(self, entity, select_options)

        local ok, err_t = run_hook("dao:delete_by:pre",
                                   entity,
                                   self.schema.name,
                                   cascade_entries,
                                   options)
        if not ok then
          return nil, tostring(err_t), err_t
        end

        local rows_affected
        rows_affected, err_t = self.strategy:delete_by_field(name, unique_value, options)
        if err_t then
          run_hook("dao:delete_by:fail", err_t, entity, self.schema.name, options)
          return nil, tostring(err_t), err_t

        elseif not rows_affected then
          run_hook("dao:delete_by:post", nil, self.schema.name, options, entity.ws_id, nil)
          return nil
        end

        entity, err_t = run_hook("dao:delete_by:post",
                                 entity,
                                 self.schema.name,
                                 options,
                                 entity.ws_id,
                                 cascade_entries)
        if not entity then
          return nil, tostring(err_t), err_t
        end

        self:post_crud_event("delete", entity, nil, options)
        propagate_cascade_delete_events(cascade_entries, options)

        return true
      end
    end
  end

  return methods
end


function _M.new(db, schema, strategy, errors)
  local fk_methods = generate_foreign_key_methods(schema)
  local super      = setmetatable(fk_methods, DAO)

  local pagination = strategy.connector and
                     type(strategy.connector) == "table" and
                     strategy.connector.defaults.pagination or
                     defaults.pagination

  local self = {
    db         = db,
    schema     = schema,
    strategy   = strategy,
    errors     = errors,
    pagination = kong_table.shallow_copy(pagination),
    super      = super,
  }

  if schema.dao then
    local custom_dao = require(schema.dao)
    for name, method in pairs(custom_dao) do
      self[name] = method
    end
  end

  return setmetatable(self, { __index = super })
end


function DAO:truncate()
  return self.strategy:truncate()
end


function DAO:select(pk_or_entity, options)
  validate_primary_key_type(pk_or_entity)

  if options ~= nil then
    validate_options_type(options)
  end

  local primary_key = self.schema:extract_pk_values(pk_or_entity)
  local ok, errors = self.schema:validate_primary_key(primary_key)
  if not ok then
    local err_t = self.errors:invalid_primary_key(errors)
    return nil, tostring(err_t), err_t
  end

  if options ~= nil then
    ok, errors = validate_options_value(self, options)
    if not ok then
      local err_t = self.errors:invalid_options(errors)
      return nil, tostring(err_t), err_t
    end
  end

  local err_t
  ok, err_t = run_hook("dao:select:pre", primary_key, self.schema.name, options)
  if not ok then
    return nil, tostring(err_t), err_t
  end

  local row, err_t = self.strategy:select(primary_key, options)
  if err_t then
    return nil, tostring(err_t), err_t
  end

  if not row then
    return nil
  end

  local err
  row, err, err_t = self:row_to_entity(row, options)
  if not row then
    return nil, err, err_t
  end

  row, err_t = run_hook("dao:select:post", row, self.schema.name, options)
  if not row then
    return nil, tostring(err_t), err_t
  end

  return row
end


function DAO:page(size, offset, options)
  if size ~= nil then
    validate_size_type(size)
  end

  if offset ~= nil then
    validate_offset_type(offset)
  end

  options = get_pagination_options(self, options)

  if size ~= nil then
    local ok, err = validate_size_value(size, options.pagination.max_page_size)
    if not ok then
      local err_t = self.errors:invalid_size(err)
      return nil, tostring(err_t), err_t
    end

  else
    size = options.pagination.page_size
  end

  local ok, errors = validate_options_value(self, options)
  if not ok then
    local err_t = self.errors:invalid_options(errors)
    return nil, tostring(err_t), err_t
  end

  local ok, err_t = run_hook("dao:page:pre", size, self.schema.name, options)
  if not ok then
    return nil, tostring(err_t), err_t
  end

  local rows, err_t, offset = self.strategy:page(size, offset, options)
  if err_t then
    return nil, tostring(err_t), err_t
  end

  local entities, err
  entities, err, err_t = self:rows_to_entities(rows, options)
  if not entities then
    return nil, err, err_t
  end

  entities, err_t = run_hook("dao:page:post", entities, self.schema.name, options)
  if not entities then
    return nil, tostring(err_t), err_t
  end

  return entities, err, err_t, offset
end


function DAO:each(size, options)
  if size ~= nil then
    validate_size_type(size)
  end

  options = get_pagination_options(self, options)

  if size ~= nil then
    local ok, err = validate_size_value(size, options.pagination.max_page_size)
    if not ok then
      local err_t = self.errors:invalid_size(err)
      return nil, tostring(err_t), err_t
    end

  else
    size = options.pagination.page_size
  end

  local ok, errors = validate_options_value(self, options)
  if not ok then
    local err_t = self.errors:invalid_options(errors)
    return nil, tostring(err_t), err_t
  end

  local pager = function(size, offset, options)
    return self.strategy:page(size, offset, options)
  end

  return iteration.by_row(self, pager, size, options)
end


function DAO:each_for_export(size, options)
  if self.strategy.schema.ttl then
    if not options then
      options = get_pagination_options(self, options)
    else
      options = kong_table.cycle_aware_deep_copy(options, true)
    end

    options.export = true
  end

  return self:each(size, options)
end


function DAO:insert(entity, options)
  validate_entity_type(entity)

  if options ~= nil then
    validate_options_type(options)
  end

  local entity_to_insert, err, err_t = check_insert(self, entity, options)
  if not entity_to_insert then
    return nil, err, err_t
  end

  local ok, err_t = run_hook("dao:insert:pre", entity, self.schema.name, options)
  if not ok then
    return nil, tostring(err_t), err_t
  end

  local row, err_t = self.strategy:insert(entity_to_insert, options)
  if not row then
    run_hook("dao:insert:fail", err_t, entity, self.schema.name, options)
    return nil, tostring(err_t), err_t
  end

  local ws_id = row.ws_id
  row, err, err_t = self:row_to_entity(row, options)
  if not row then
    run_hook("dao:insert:fail", err, entity, self.schema.name, options)
    return nil, err, err_t
  end

  row, err_t = run_hook("dao:insert:post", row, self.schema.name, options, ws_id)
  if not row then
    return nil, tostring(err_t), err_t
  end

  self:post_crud_event("create", row, nil, options)

  return row
end


function DAO:update(pk_or_entity, entity, options)
  validate_primary_key_type(pk_or_entity)
  validate_entity_type(entity)

  if options ~= nil then
    validate_options_type(options)
  end

  local primary_key = self.schema:extract_pk_values(pk_or_entity)
  local ok, errors = self.schema:validate_primary_key(primary_key)
  if not ok then
    local err_t = self.errors:invalid_primary_key(errors)
    return nil, tostring(err_t), err_t
  end

  local entity_to_update, rbw_entity, err, err_t = check_update(self,
                                                                primary_key,
                                                                entity,
                                                                options)
  if not entity_to_update then
    return nil, err, err_t
  end

  local ok, err_t = run_hook("dao:update:pre",
                             entity_to_update,
                             self.schema.name,
                             options)
  if not ok then
    return nil, tostring(err_t), err_t
  end

  local row, err_t = self.strategy:update(primary_key, entity_to_update, options)
  if not row then
    run_hook("dao:update:fail", err_t, entity_to_update, self.schema.name, options)
    return nil, tostring(err_t), err_t
  end

  local ws_id = row.ws_id
  row, err, err_t = self:row_to_entity(row, options)
  if not row then
    run_hook("dao:update:fail", err_t, entity_to_update, self.schema.name, options)
    return nil, err, err_t
  end

  row, err_t = run_hook("dao:update:post", row, self.schema.name, options, ws_id)
  if not row then
    return nil, tostring(err_t), err_t
  end

  self:post_crud_event("update", row, rbw_entity, options)

  return row
end


function DAO:upsert(pk_or_entity, entity, options)
  validate_primary_key_type(pk_or_entity)
  validate_entity_type(entity)

  if options ~= nil then
    validate_options_type(options)
  end

  local primary_key = self.schema:extract_pk_values(pk_or_entity)
  local ok, errors = self.schema:validate_primary_key(primary_key)
  if not ok then
    local err_t = self.errors:invalid_primary_key(errors)
    return nil, tostring(err_t), err_t
  end

  local entity_to_upsert, rbw_entity, err, err_t = check_upsert(self,
                                                                primary_key,
                                                                entity,
                                                                options)
  if not entity_to_upsert then
    return nil, err, err_t
  end

  local ok, err_t = run_hook("dao:upsert:pre",
                             entity_to_upsert,
                             self.schema.name,
                             options)
  if not ok then
    return nil, tostring(err_t), err_t
  end

  local row, err_t = self.strategy:upsert(primary_key, entity_to_upsert, options)
  if not row then
    return nil, tostring(err_t), err_t
  end

  local ws_id = row.ws_id
  row, err, err_t = self:row_to_entity(row, options)
  if not row then
    return nil, err, err_t
  end

  row, err_t = run_hook("dao:upsert:post",
                        row, self.schema.name, options, ws_id, rbw_entity)
  if not row then
    return nil, tostring(err_t), err_t
  end

  if rbw_entity then
    self:post_crud_event("update", row, rbw_entity, options)
  else
    self:post_crud_event("create", row, nil, options)
  end

  return row
end


function DAO:delete(pk_or_entity, options)
  validate_primary_key_type(pk_or_entity)

  if options ~= nil then
    validate_options_type(options)
  end

  local primary_key = self.schema:extract_pk_values(pk_or_entity)
  local ok, errors = self.schema:validate_primary_key(primary_key)
  if not ok then
    local err_t = self.errors:invalid_primary_key(errors)
    return nil, tostring(err_t), err_t
  end

  local select_options = deep_copy(options or {})
  select_options["show_ws_id"] = true
  local entity, err, err_t = self:select(primary_key, select_options)
  if err then
    return nil, err, err_t
  end

  if not entity then
    return true
  end

  if options ~= nil then
    ok, errors = validate_options_value(self, options)
    if not ok then
      local err_t = self.errors:invalid_options(errors)
      return nil, tostring(err_t), err_t
    end
  end

  local cascade_entries = find_cascade_delete_entities(self, primary_key, select_options)

  local ws_id = entity.ws_id
  local _
  _, err_t = run_hook("dao:delete:pre",
                             entity,
                             self.schema.name,
                             cascade_entries,
                             options,
                             ws_id)
  if err_t then
    return nil, tostring(err_t), err_t
  end

  local rows_affected
  rows_affected, err_t = self.strategy:delete(primary_key, options)
  if err_t then
    run_hook("dao:delete:fail", err_t, entity, self.schema.name, options)
    return nil, tostring(err_t), err_t

  elseif not rows_affected then
    run_hook("dao:delete:post", nil, self.schema.name, options, ws_id, nil)
    return nil
  end

  entity, err_t = run_hook("dao:delete:post", entity, self.schema.name, options, ws_id, cascade_entries)
  if not entity then
    return nil, tostring(err_t), err_t
  end

  self:post_crud_event("delete", entity, nil, options)
  propagate_cascade_delete_events(cascade_entries, options)

  return true
end


function DAO:select_by_cache_key(cache_key, options)
  local ck_definition = self.schema.cache_key
  if not ck_definition then
    error("entity does not have a cache_key defined", 2)
  end

  if type(cache_key) ~= "string" then
    cache_key = self:cache_key(cache_key)
  end

  if #ck_definition == 1 then
    return self["select_by_" .. ck_definition[1]](self, cache_key, options)
  end

  local ok, err_t = run_hook("dao:select_by_cache_key:pre",
                             cache_key,
                             self.schema.name,
                             options)
  if not ok then
    return nil, tostring(err_t), err_t
  end

  local row
  row, err_t = self.strategy:select_by_field("cache_key", cache_key, options)
  if err_t then
    return nil, tostring(err_t), err_t
  end
  if not row then
    return nil
  end

  local err
  local ws_id = row.ws_id
  row, err, err_t = self:row_to_entity(row, options)
  if not row then
    return nil, err, err_t
  end

  row, err_t = run_hook("dao:select_by_cache_key:post",
                        row,
                        self.schema.name,
                        options,
                        ws_id)
  if not row then
    return nil, tostring(err_t), err_t
  end

  return row
end


function DAO:rows_to_entities(rows, options)
  local count = #rows
  if count == 0 then
    return setmetatable(rows, cjson.array_mt)
  end

  local entities = new_tab(count, 0)

  for i = 1, count do
    local entity, err, err_t = self:row_to_entity(rows[i], options)
    if not entity then
      return nil, err, err_t
    end

    entities[i] = entity
  end

  return setmetatable(entities, cjson.array_mt)
end


function DAO:row_to_entity(row, options)
  local transform, nulls
  if options ~= nil then
    validate_options_type(options)
    local ok, errors = validate_options_value(self, options)
    if not ok then
      local err_t = self.errors:invalid_options(errors)
      return nil, tostring(err_t), err_t
    end
    transform = options.transform
    nulls = options.nulls
  end

  if transform == nil then
    transform = true
  end

  local ws_id = row.ws_id

  local transformed_entity
  if transform then
    local err
    transformed_entity, err = self.schema:transform(row, nil, "select")
    if not transformed_entity then
      local err_t = self.errors:transformation_error(err)
      return nil, tostring(err_t), err_t
    end
  end

  local entity, errors = self.schema:process_auto_fields(transformed_entity or row, "select", nulls, options)
  if not entity then
    local err_t = self.errors:schema_violation(errors)
    return nil, tostring(err_t), err_t
  end

  if options and options.show_ws_id and self.schema.workspaceable then
    if ws_id == null or ws_id == nil then
      entity.ws_id = kong.default_workspace -- special behavior for blue-green migrations
    else
      entity.ws_id = ws_id
    end
  end

  return entity
end


function DAO:post_crud_event(operation, entity, old_entity, options)
  if options and options.no_broadcast_crud_event then
    return
  end

  if self.events then
    local entity_without_nulls
    if entity then
      entity_without_nulls = remove_nulls(kong_table.cycle_aware_deep_copy(entity, true))
    end

    local old_entity_without_nulls
    if old_entity then
      old_entity_without_nulls = remove_nulls(kong_table.cycle_aware_deep_copy(old_entity, true))
    end

    local ok, err = self.events.post_local("dao:crud", operation, {
      operation  = operation,
      schema     = self.schema,
      entity     = entity_without_nulls,
      old_entity = old_entity_without_nulls,
    })
    if not ok then
      log(ERR, "[db] failed to propagate CRUD operation: ", err)
    end
  end
end


local function get_cache_key_value(name, key, fields)
  local value = key[name]
  if value == null or value == nil then
    return
  end

  if type(value) == "table" and fields[name].type == "foreign" then
    value = value.id -- FIXME extract foreign key, do not assume `id`
    if value == null or value == nil then
      return
    end
  end

  return tostring(value)
end


function DAO:cache_key(key, arg2, arg3, arg4, arg5, ws_id)
  local schema = self.schema
  local name = schema.name

  if (ws_id == nil or ws_id == null) and schema.workspaceable then
    ws_id = workspaces.get_workspace_id()
  end

  -- Fast path: passing the cache_key/primary_key entries in
  -- order as arguments, this produces the same result as
  -- the generic code below, but building the cache key
  -- becomes a single string.format operation
  if type(key) == "string" then
    return fmt("%s:%s:%s:%s:%s:%s:%s", name,
              (key   == nil or key   == null) and "" or key,
              (arg2  == nil or arg2  == null) and "" or arg2,
              (arg3  == nil or arg3  == null) and "" or arg3,
              (arg4  == nil or arg4  == null) and "" or arg4,
              (arg5  == nil or arg5  == null) and "" or arg5,
              (ws_id == nil or ws_id == null) and "" or ws_id)
  end

  -- Generic path: build the cache key from the fields
  -- listed in cache_key or primary_key

  if type(key) ~= "table" then
    error("key must be a string or an entity table", 2)
  end

  if key.ws_id ~= nil and key.ws_id ~= null and schema.workspaceable then
    ws_id = key.ws_id
  end

  local values = new_tab(7, 0)
  values[1] = name

  local i = 2

  local fields = schema.fields
  local source = schema.cache_key
  local use_pk = true
  if source then
    for j = 1, #source do
      local value = get_cache_key_value(source[j], key, fields)
      if value ~= nil then
        use_pk = false
      end
      values[i] = value or ""
      i = i + 1
    end
  end

  if use_pk then
    i = 2
    source = schema.primary_key
    for j = 1, #source do
      values[i] = get_cache_key_value(source[j], key, fields) or ""
      i = i + 1
    end
  end

  for n = i, 6 do
    values[n] = ""
  end

  values[7] = ws_id or ""

  return concat(values, ":")
end


--[[
function DAO:load_translations(t)
  self.schema:load_translations(t)
end
--]]


return _M
