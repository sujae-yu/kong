local helpers         = require "spec.helpers"
local uuid            = require "kong.tools.uuid"
local schema_def = require "kong.plugins.oauth2.schema"
local DAO_MAX_TTL = require("kong.constants").DATABASE.DAO_MAX_TTL
local v = require("spec.helpers").validate_plugin_config_schema

local fmt = string.format

for _, strategy in helpers.each_strategy() do

  describe(fmt("Plugin: oauth2 [#%s] (schema)", strategy), function()
    local bp, db
    local oauth2_authorization_codes_schema
    local oauth2_tokens_schema

    lazy_setup(function()
      bp, db = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "consumers",
        "plugins",
        "oauth2_tokens",
        "oauth2_authorization_codes",
        "oauth2_credentials",
      })

      oauth2_authorization_codes_schema = db.oauth2_authorization_codes.schema
      oauth2_tokens_schema = db.oauth2_tokens.schema
    end)

    it("does not require `scopes` when `mandatory_scope` is false", function()
      local ok, errors = v({enable_authorization_code = true, mandatory_scope = false}, schema_def)
      assert.is_truthy(ok)
      assert.is_falsy(errors)
    end)
    it("valid when both `scopes` when `mandatory_scope` are given", function()
      local ok, errors = v({enable_authorization_code = true, mandatory_scope = true, scopes = {"email", "info"}}, schema_def)
      assert.truthy(ok)
      assert.is_falsy(errors)
    end)
    it("autogenerates `provision_key` when not given", function()
      local t = {enable_authorization_code = true, mandatory_scope = true, scopes = {"email", "info"}}
      local t2, errors = v(t, schema_def)
      assert.is_falsy(errors)
      assert.truthy(t2.config.provision_key)
      assert.equal(32, t2.config.provision_key:len())
    end)
    it("does not autogenerate `provision_key` when it is given", function()
      local t = {enable_authorization_code = true, mandatory_scope = true, scopes = {"email", "info"}, provision_key = "hello"}
      local ok, errors = v(t, schema_def)
      assert.truthy(ok)
      assert.is_falsy(errors)
      assert.truthy(t.provision_key)
      assert.equal("hello", t.provision_key)
    end)
    it("sets default `auth_header_name` when not given", function()
      local t = {enable_authorization_code = true, mandatory_scope = true, scopes = {"email", "info"}}
      local t2, errors = v(t, schema_def)
      assert.truthy(t2)
      assert.is_falsy(errors)
      assert.truthy(t2.config.provision_key)
      assert.equal(32, t2.config.provision_key:len())
      assert.equal("authorization", t2.config.auth_header_name)
    end)
    it("does not set default value for `auth_header_name` when it is given", function()
      local t = {enable_authorization_code = true, mandatory_scope = true, scopes = {"email", "info"}, provision_key = "hello",
      auth_header_name="custom_header_name"}
      local t2, errors = v(t, schema_def)
      assert.truthy(t2)
      assert.is_falsy(errors)
      assert.truthy(t2.config.provision_key)
      assert.equal("hello", t2.config.provision_key)
      assert.equal("custom_header_name", t2.config.auth_header_name)
    end)
    it("sets refresh_token_ttl to default value if not set", function()
      local t = {enable_authorization_code = true, mandatory_scope = false}
      local t2, errors = v(t, schema_def)
      assert.truthy(t2)
      assert.is_falsy(errors)
      assert.equal(1209600, t2.config.refresh_token_ttl)
    end)
    it("sets refresh_token_ttl to too large a value", function()
      local t = {enable_authorization_code = true, mandatory_scope = false, refresh_token_ttl = 252979200, }
      local t2, errors = v(t, schema_def)
      assert.is_nil(t2)
      assert.same(errors, { config = {
        refresh_token_ttl = "value should be between 0 and " .. DAO_MAX_TTL,
      }})
    end)
    it("defaults to non-persistent refresh tokens", function()
      local t = {enable_authorization_code = true, mandatory_scope = false}
      local t2, errors = v(t, schema_def)
      assert.truthy(t2)
      assert.is_falsy(errors)
      assert.equal(false, t2.config.reuse_refresh_token)
    end)

    describe("errors", function()
      it("requires at least one flow", function()
        local ok, err = v({}, schema_def)
        assert.is_falsy(ok)

        assert.same("at least one of these fields must be true: enable_authorization_code, enable_implicit_grant, enable_client_credentials, enable_password_grant",
                     err.config)
      end)
      it("requires `scopes` when `mandatory_scope` is true", function()
        local ok, err = v({enable_authorization_code = true, mandatory_scope = true}, schema_def)
        assert.is_falsy(ok)
        assert.equal("required field missing",
                     err.config.scopes)
      end)
      it("errors when given an invalid service_id on oauth tokens", function()
        local ok, err_t = oauth2_tokens_schema:validate_insert({
          credential = { id = "foo" },
          service = { id = "bar" },
          expires_in = 1,
        })
        assert.falsy(ok)
        assert.same({
          credential = { id = 'expected a valid UUID' },
          service = { id = 'expected a valid UUID' },
          token_type = "required field missing",
        }, err_t)

        local ok, err_t = oauth2_tokens_schema:validate_insert({
          credential = { id = "foo" },
          service = { id = uuid.uuid() },
          expires_in = 1,
        })
        assert.falsy(ok)
        assert.same({
          credential = { id = 'expected a valid UUID' },
          token_type = "required field missing",
        }, err_t)


        local ok, err_t = oauth2_tokens_schema:validate_insert({
          credential = { id = uuid.uuid() },
          service = { id = uuid.uuid() },
          expires_in = 1,
          token_type = "bearer",
        })

        assert.is_truthy(ok)
        assert.is_nil(err_t)
      end)

      it("errors when given an invalid service_id on oauth authorization codes", function()
        local ok, err_t = oauth2_authorization_codes_schema:validate_insert({
          credential = { id = "foo" },
          service = { id = "bar" },
        })
        assert.falsy(ok)
        assert.same({
          credential = { id = 'expected a valid UUID' },
          service = { id = 'expected a valid UUID' },
        }, err_t)

        local ok, err_t = oauth2_authorization_codes_schema:validate_insert({
          credential = { id = "foo" },
          service = { id = uuid.uuid() },
        })
        assert.falsy(ok)
        assert.same({
          credential = { id = 'expected a valid UUID' },
        }, err_t)

        local ok, err_t = oauth2_authorization_codes_schema:validate_insert({
          credential = { id = uuid.uuid() },
          service = { id = uuid.uuid() },
        })

        assert.truthy(ok)
        assert.is_nil(err_t)
      end)
    end)

    describe("when deleting a service", function()
      it("deletes associated oauth2 entities", function()
        local service = bp.services:insert()
        local consumer = bp.consumers:insert()
        local credential = bp.oauth2_credentials:insert({
          redirect_uris = { "http://example.com" },
          consumer = { id = consumer.id },
        })

        local ok, err, err_t

        local token = bp.oauth2_tokens:insert({
          credential = { id = credential.id },
          service = { id = service.id },
        })
        local code = bp.oauth2_authorization_codes:insert({
          credential = { id = credential.id },
          service = { id = service.id },
        })

        token, err = db.oauth2_tokens:select(token)
        assert.falsy(err)
        assert.truthy(token)

        code, err = db.oauth2_authorization_codes:select(code)
        assert.falsy(err)
        assert.truthy(code)

        ok, err, err_t = db.services:delete(service)
        assert.truthy(ok)
        assert.is_falsy(err_t)
        assert.is_falsy(err)

        -- no more service
        service, err = db.services:select(service)
        assert.falsy(err)
        assert.falsy(service)

        -- no more token
        token, err = db.oauth2_tokens:select(token)
        assert.falsy(err)
        assert.falsy(token)

        -- no more code
        code, err = db.oauth2_authorization_codes:select(code)
        assert.falsy(err)
        assert.falsy(code)
      end)
    end)
  end)
end
