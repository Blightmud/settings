local old_settings = settings

---@type table<string, string>
local old_settings_map = {}
---@type table<string, string>
local old_settings_map_rev = {}

---Setting module. Extends the /set family of commands to work on arbitrary
---data types and allows plugins to register their own settings
---@class new_settings
settings = {}

---@type fun()[]
settings.init_callbacks = {}
---@type table<string, fun(name: string, value: any)[]>
settings.change_callbacks = {}

---@type table<string, settings.Setting>
settings.settings = {}



---@class settings.Setting
---@field name string[]
---@field type string
---@field default any
---@field current any
local Setting = {
    name = "",
    type = "nil",
    default = nil,
    current = nil
}
settings.Setting = Setting
Setting.__index = Setting

---@param name string[]
---@param typ string
---@param default any
---@param current any
---@return settings.Setting
function Setting.new(name, typ, default, current)
    local ret = setmetatable({}, Setting)

	ret.name = name
	ret.type = typ
	ret.default = default
	ret.current = current

    return ret
end



local function convert(value, typ)
    if typ == "number" then
        return tonumber(value)
    elseif typ == "boolean" then
        if value == "true" or value == "on" or value == "yes" then
            return true
        elseif value == "false" or value == "off" or value == "no" then
            return false
        end
        error(string.format("Could not convert to boolean: %s", value))
    elseif typ == "string" then
        return value
    end
    error(string.format("Unknown value type: %s", typ))
end

local function get_setting(name)
    local setting = settings.settings[name]
    if not setting and old_settings_map_rev[name] then
        setting = settings.settings[old_settings_map_rev[name]]
    end
    if not setting then
        error(string.format("Setting not found: %s", name))
    end
    return setting
end

local function save()
    local to_save = {}
    for k, v in pairs(settings.settings) do
        if not old_settings_map[k] then
            to_save[k] = v
        end
    end
    store.disk_write("settings.settings", json.encode(to_save))
end

local function load()
    local success, to_load = pcall(json.decode, store.disk_read("settings.settings"))
    if success then
        settings.settings = to_load
    end
end

---Add a new setting key
---
---If the key already exists, will only update default value
---@param name string
---@param typ string
---@param default any | nil
function settings.add(name, typ, default)
    if not settings.settings[name] then
        settings.settings[name] = Setting.new(name, typ, default, nil)
    else
        settings.settings[name].default = default
    end
end


---Get current setting value
---@param name string
---@return any | nil
function settings.get(name)
    local setting = get_setting(name)
    if setting.current == nil then
        return setting.default
    end
    return setting.current
end


---Get the type of a given setting
---@param name string
---@return string
function settings.type(name)
    local setting = get_setting(name)
    return setting.type
end


---Set a setting
---@param name string
---@param value any
function settings.set(name, value)
    local setting = get_setting(name)
    setting.current = value
    if old_settings_map[name] then
        old_settings.set(old_settings_map[name], value)
    end

    if not old_settings_map[name] then
        save()
    end

    if settings.change_callbacks[name] then
        for _, v in ipairs(settings.change_callbacks[name]) do
            v(name, value)
        end
    end
end


---List all settings
---@return table<string, any>
function settings.list(name)
    if name ~= nil then
        error("Not implemented yet") -- TODO
    end
    local ret = {}
    for _, setting in pairs(settings.settings) do
        ret[setting.name] = setting.current
    end
    return ret
end


---Called after initialisation of settings is complete
---@param callback fun()
function settings.on_init(callback)
    settings.init_callbacks[#settings.init_callbacks+1] = callback
end


---@param name string
---@param callback fun(name: string, value: string)
function settings.on_change(name, callback)
    settings.change_callbacks[name] = settings.change_callbacks[name] or {}
    local tbl = settings.change_callbacks[name]
    tbl[#tbl+1] = callback
end


load()
for setting, value in pairs(old_settings.list()) do
    local new_setting = string.format("blight.%s", setting)
    settings.add(new_setting, "boolean", nil)
    settings.settings[new_setting].current = value
    old_settings_map[new_setting] = setting
    old_settings_map_rev[setting] = new_setting
end


local function disable_alias(sample_incovation)
    ---@type alias.AliasGroup
    ---@diagnostic disable-next-line
    local system_alias_group = alias.system_alias_groups[1]
    for _, alias in ipairs(system_alias_group:get_aliases()) do
        if alias.regex:test(sample_incovation) then
            alias:disable()
            break
        end
    end
end

-- Disable default /settings alias
disable_alias("/settings")
disable_alias("/set asd")

alias.add("^/settings$", function()
    local keys = {}
    local list = settings.list()
    do
        local n = 1
        for key, _ in pairs(list) do
            keys[n] = key
            n = n + 1
        end
    end
    table.sort(keys)

	for _, key in ipairs(keys) do
        local value = list[key]
		local key_format = cformat("<yellow>%-40s<reset>", key)
		local value_format
		if value == true then
			value_format = cformat("<bgreen>on<reset>")
		elseif value == false then
			value_format = cformat("<bred>off<reset>")
        else
            value_format = cformat("<yellow>%s<reset>", tostring(value))
		end
		print(cformat("[**] %s => %s", key_format, value_format))
	end
end)

alias.add("^/set (.*)$", function(match)
    local args = {}
    do
        local n = 1
        for arg in string.gmatch(match[2], "([^%s]+)") do
            args[n] = arg
            n = n + 1
        end
    end

    if #args == 0 or #args > 2 then
        print("[**] Usage: /set key [value]")
        return
    end

    local key = args[1]
    local value = args[2]

    if not value then
        -- Print current value
        local success
        success, value = pcall(settings.get, key)
        if not success then
            print(cformat("[**] <red>Unknown setting: %s<reset>", key))
            return
        end
        local key_format = cformat("<yellow>%s<reset>", key)
        local value_format
        if value == true then
            value_format = cformat("<bgreen>on<reset>")
        elseif value == false then
            value_format = cformat("<bred>off<reset>")
        else
            value_format = cformat("<yellow>%s<reset>", value)
        end
        print(cformat("[**] %s => %s", key_format, value_format))
    else
        -- Set new value
        local typ = settings.type(key)
        local success, converted = pcall(convert, value, typ)
        if success then
            settings.set(key, converted)
        else
            print(cformat("[**] <red>Could not convert to %s: %s<reset>", typ, value))
        end
    end
end)
