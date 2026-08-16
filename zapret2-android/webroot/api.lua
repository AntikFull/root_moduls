local moddir = "/data/adb/modules/zapret2-android"
local control = moddir .. "/bin/zapret2-control"

ngx.header["Content-Type"] = "application/json; charset=utf-8"
ngx.header["Access-Control-Allow-Origin"] = "*"
ngx.header["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
ngx.header["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-Requested-With"

if ngx.req.get_method() == "OPTIONS" then
    ngx.exit(200)
end

local cmd = ngx.var.arg_cmd or ngx.var.arg_action or ngx.var.arg_c

-- Если GET не передал cmd, считываем POST тело
if not cmd or cmd == "" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body and body ~= "" then
        local json_cmd = string.match(body, '"cmd"%s*:%s*"([^"]+)"')
        local json_action = string.match(body, '"action"%s*:%s*"([^"]+)"')
        cmd = json_cmd or json_action or body
    end
end

if not cmd or cmd == "" then
    cmd = "json-status"
end

-- Очистка команды от zapret2-control префикса если передан полный путь
cmd = string.gsub(cmd, "^/data/adb/modules/zapret2%%-android/bin/zapret2%%-control%%s*", "")
cmd = string.gsub(cmd, "^zapret2%%-control%%s*", "")

-- Выполнение zapret2-control
local full_exec = "sh -c '" .. control .. " " .. cmd .. " 2>&1'"
local handle = io.popen(full_exec)
if handle then
    local result = handle:read("*a")
    handle:close()
    ngx.say(result or "{}")
else
    ngx.status = 500
    ngx.say('{"error":"Failed to execute zapret2-control"}')
end
