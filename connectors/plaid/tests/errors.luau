-- Plaid's errors, slow answers and bad bodies map to clear failures that never include the access token.
return {
	scenario = {publisher = {}, config = {environment = "production"}, auth_method = "keys", auth_config = {client_id = "client-fixture", secret = "synthetic-plaid-secret"}},
	configure = function()
		calls = 0
		status, payload, responseHeaders = 200, "{}", {}
		http = {request = function(req)
			calls += 1
			assert(string.sub(req.url, 1, 28) == "https://production.plaid.com", req.url)
			return fixture.operation({statusCode = status, headers = responseHeaders, body = fixture.reader(payload)})
		end}
	end,
	run = function(plaid)
		local function upstream(code, body, headers, expected, absent)
			status, payload, responseHeaders = code, body, headers
			local before = calls
			local ok, err = pcall(function() plaid.getAccounts({access_token = "access-production-secret-token"}) end)
			assert(not ok, "expected a failure")
			for _, text in expected do assert(string.find(tostring(err), text, 1, true), "missing " .. text .. " in " .. tostring(err)) end
			assert(not string.find(tostring(err), "access-production-secret-token", 1, true), "access token leaked")
			if absent then assert(not string.find(tostring(err), absent, 1, true), "unexpected " .. absent .. " in " .. tostring(err)) end
			assert(calls == before + 1, "a failed request was repeated")
		end
		local function envelope(kind, code, message) return '{"error_type":"' .. kind .. '","error_code":"' .. code .. '","error_message":"' .. message .. '","request_id":"req-1"}' end

		upstream(400, envelope("INVALID_INPUT", "INVALID_ACCESS_TOKEN", "provided access token is invalid"), {},
			{"Plaid HTTP 400 INVALID_INPUT/INVALID_ACCESS_TOKEN: provided access token is invalid (request req-1)", '"retryable":false', '"upstream_status":400'})
		upstream(400, envelope("ITEM_ERROR", "ITEM_LOGIN_REQUIRED", "the login details of this item have changed"), {},
			{"ITEM_ERROR/ITEM_LOGIN_REQUIRED", '"retryable":false'})
		upstream(400, envelope("ITEM_ERROR", "PRODUCT_NOT_READY", "the requested product is not yet ready"), {},
			{"ITEM_ERROR/PRODUCT_NOT_READY", '"retryable":true'})
		upstream(400, envelope("INVALID_INPUT", "INVALID_API_KEYS", "invalid client_id or secret provided"), {}, {"INVALID_API_KEYS", '"retryable":false'})
		upstream(429, envelope("RATE_LIMIT_EXCEEDED", "RATE_LIMIT", "rate limit exceeded"), {["retry-after"] = {"2"}},
			{"Plaid HTTP 429 RATE_LIMIT_EXCEEDED/RATE_LIMIT", "retry after 2s", '"retryable":true', '"upstream_status":429'})
		upstream(500, envelope("API_ERROR", "INTERNAL_SERVER_ERROR", "an unexpected error occurred"), {}, {"Plaid HTTP 500 API_ERROR/INTERNAL_SERVER_ERROR", '"retryable":true'})
		upstream(502, "<html>Bad Gateway</html>", {}, {"Plaid HTTP 502", '"retryable":true'}, "Gateway")
		upstream(500, "", {}, {"Plaid HTTP 500", '"retryable":true'})
		-- An echoed access token is redacted, and an oversized message is cut.
		upstream(400, envelope("INVALID_INPUT", "INVALID_FIELD", "bad token access-production-secret-token"), {}, {"bad token [redacted]"})
		upstream(400, '{"error_type":"X y","error_code":"bad code!","error_message":"' .. string.rep("y", 1000) .. '"}', {}, {"Plaid HTTP 400: " .. string.rep("y", 300)}, string.rep("y", 601))
		upstream(307, "", {location = {"https://elsewhere.example"}}, {"Plaid HTTP 307: unexpected redirect", '"retryable":false'}, "elsewhere")

		upstream(200, "<html>maintenance</html>", {}, {"Plaid returned an unexpected answer", '"retryable":false'}, "maintenance")
		upstream(200, "[]", {}, {"Plaid returned an unexpected answer"})
		upstream(200, '"text"', {}, {"Plaid returned an unexpected answer"})
		upstream(200, '{"error_code":"INVALID_REQUEST","request_id":"r"}', {}, {"Plaid returned an unexpected answer"})
		upstream(200, '{"accounts":[' .. string.rep('{"name":"' .. string.rep("z", 1024) .. '"},', 4 * 1024) .. '{}]}', {},
			{"Plaid returned more than 4 MiB", '"retryable":false'})
	end,
}
