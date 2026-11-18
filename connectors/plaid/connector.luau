-- Plaid API (version 2020-09-14, https://plaid.com/docs/api/), read-only. Arguments and results keep Plaid's native field names.
type Options = {[string]: any}
type Check = (any, string) -> any
type Spec = {fields: {[string]: Check}, required: {string}}
type Endpoint = {path: string, spec: Spec, summary: string, example: Options}

local API = if config.environment == "sandbox" then "https://sandbox.plaid.com" else "https://production.plaid.com"
local VERSION = "2020-09-14"
local MAX_BYTES = 4 * 1024 * 1024
local MAX_ERROR = 4096

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < 2 ^ 53
end

local function text(maximum: number): Check
	return function(value: any, field: string): any
		assert(type(value) == "string" and string.find(value, "%S") and #value <= maximum,
			field .. " must be a string of at most " .. tostring(maximum) .. " bytes, not only spaces")
		assert(not string.find(value, "%c"), field .. " must not contain control characters")
		return value
	end
end

local function integer(minimum: number, maximum: number): Check
	return function(value: any, field: string): any
		assert(finite(value) and value % 1 == 0 and value >= minimum and value <= maximum,
			field .. " must be an integer from " .. tostring(minimum) .. " to " .. tostring(maximum))
		return value
	end
end

local function flag(value: any, field: string): any
	assert(type(value) == "boolean", field .. " must be true or false")
	return value
end

local function list(maximum: number, item: Check): Check
	return function(value: any, field: string): any
		assert(type(value) == "table", field .. " must be an array")
		local count = 0
		for index, entry in value do
			assert(type(index) == "number" and index >= 1 and index % 1 == 0, field .. " must be a dense array")
			item(entry, field .. "[" .. tostring(index) .. "]")
			count += 1
		end
		assert(count == #value and count >= 1 and count <= maximum,
			field .. " must be a dense array of 1 to " .. tostring(maximum) .. " entries")
		return value
	end
end

local DAYS = table.freeze({31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31})

-- A real calendar date written YYYY-MM-DD, as Plaid expects.
local function date(value: any, field: string): any
	local y, m, d = string.match(if type(value) == "string" then value else "", "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local year, month, day = tonumber(y), tonumber(m), tonumber(d)
	assert(year and month and day and month >= 1 and month <= 12, field .. " must be a date written YYYY-MM-DD")
	local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
	assert(day >= 1 and day <= (if month == 2 and not leap then 28 else DAYS[month]), field .. " must be a date written YYYY-MM-DD")
	return value
end

-- Plaid's ISO 8601 date-time, for example 2026-01-31T12:00:00Z.
local function dateTime(value: any, field: string): any
	assert(type(value) == "string" and #value <= 40
		and string.match(value, "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%.%d]*[Z+%-][%d:]*$"),
		field .. " must be an ISO 8601 date-time such as 2026-01-31T12:00:00Z")
	return value
end

local function country(value: any, field: string): any
	assert(type(value) == "string" and string.match(value, "^%u%u$"), field .. " must be a two-letter uppercase country code such as US")
	return value
end

local accessToken: Check = text(256)
local accountIds: Check = list(100, text(256))
local countryCodes: Check = list(20, country)

-- Copies the known fields of an options table, checked, so unknown fields and the caller's table never reach Plaid.
local function fields(value: any, spec: {[string]: Check}, name: string, prefix: string): Options
	assert(type(value) == "table", name .. " must be an options table")
	local out: Options = {}
	for key, item in value do
		local check = if type(key) == "string" then spec[key] else nil
		assert(check, name .. " received an unknown option " .. string.sub(tostring(key), 1, 64))
		out[key] = check(item, prefix .. key)
	end
	return out
end

local function object(spec: {[string]: Check}, name: string): Check
	return function(value: any, field: string): any
		return fields(value, spec, name, field .. ".")
	end
end

local ACCOUNT_OPTIONS = {options = object({account_ids = accountIds}, "options")}

local endpoints: {[string]: Endpoint} = {
	getAccounts = {
		path = "/accounts/get",
		summary = "List the accounts of one Item with cached balances.",
		spec = {fields = {access_token = accessToken, options = ACCOUNT_OPTIONS.options}, required = {"access_token"}},
		example = {access_token = "access-sandbox-123"},
	},
	getBalance = {
		path = "/accounts/balance/get",
		summary = "Fetch real-time balances from the institution. Plaid may bill each call; prefer getAccounts for cached balances.",
		spec = {fields = {access_token = accessToken, options = object({account_ids = accountIds, min_last_updated_datetime = dateTime}, "options")},
			required = {"access_token"}},
		example = {access_token = "access-sandbox-123", options = {account_ids = {"account-1"}}},
	},
	syncTransactions = {
		path = "/transactions/sync",
		summary = "Fetch one page of added, modified and removed transactions after a cursor. Omit cursor for the first page.",
		spec = {fields = {access_token = accessToken, cursor = text(256), count = integer(1, 500), options = object({
			include_original_description = flag, include_personal_finance_category = flag, days_requested = integer(1, 730),
			account_id = text(256), include_logo_and_counterparty_beta = flag}, "options")}, required = {"access_token"}},
		example = {access_token = "access-sandbox-123", count = 100},
	},
	getTransactions = {
		path = "/transactions/get",
		summary = "List transactions in a date range, one page at a time with options.count and options.offset.",
		spec = {fields = {access_token = accessToken, start_date = date, end_date = date, options = object({
			account_ids = accountIds, count = integer(1, 500), offset = integer(0, 1000000),
			include_original_description = flag, include_personal_finance_category = flag}, "options")},
			required = {"access_token", "start_date", "end_date"}},
		example = {access_token = "access-sandbox-123", start_date = "2026-01-01", end_date = "2026-01-31", options = {count = 100, offset = 0}},
	},
	getRecurringTransactions = {
		path = "/transactions/recurring/get",
		summary = "List recurring inflow and outflow streams detected for the given accounts.",
		spec = {fields = {access_token = accessToken, account_ids = accountIds, options = object({include_personal_finance_category = flag}, "options")},
			required = {"access_token", "account_ids"}},
		example = {access_token = "access-sandbox-123", account_ids = {"account-1"}},
	},
	getAuth = {
		path = "/auth/get",
		summary = "Fetch account and routing numbers. Sensitive: do not log or save the result.",
		spec = {fields = {access_token = accessToken, options = ACCOUNT_OPTIONS.options}, required = {"access_token"}},
		example = {access_token = "access-sandbox-123"},
	},
	getIdentity = {
		path = "/identity/get",
		summary = "Fetch account holder names, addresses, emails and phone numbers. Sensitive: do not log or save the result.",
		spec = {fields = {access_token = accessToken, options = ACCOUNT_OPTIONS.options}, required = {"access_token"}},
		example = {access_token = "access-sandbox-123"},
	},
	getHoldings = {
		path = "/investments/holdings/get",
		summary = "List investment holdings and securities.",
		spec = {fields = {access_token = accessToken, options = ACCOUNT_OPTIONS.options}, required = {"access_token"}},
		example = {access_token = "access-sandbox-123"},
	},
	getInvestmentTransactions = {
		path = "/investments/transactions/get",
		summary = "List investment transactions in a date range, one page at a time with options.count and options.offset.",
		spec = {fields = {access_token = accessToken, start_date = date, end_date = date, options = object({
			account_ids = accountIds, count = integer(1, 500), offset = integer(0, 1000000)}, "options")},
			required = {"access_token", "start_date", "end_date"}},
		example = {access_token = "access-sandbox-123", start_date = "2026-01-01", end_date = "2026-01-31"},
	},
	getLiabilities = {
		path = "/liabilities/get",
		summary = "Fetch credit card, student loan and mortgage liabilities.",
		spec = {fields = {access_token = accessToken, options = ACCOUNT_OPTIONS.options}, required = {"access_token"}},
		example = {access_token = "access-sandbox-123"},
	},
	getItem = {
		path = "/item/get",
		summary = "Fetch an Item's status, institution, products and consent expiration.",
		spec = {fields = {access_token = accessToken}, required = {"access_token"}},
		example = {access_token = "access-sandbox-123"},
	},
	getInstitution = {
		path = "/institutions/get_by_id",
		summary = "Fetch one institution by ID.",
		spec = {fields = {institution_id = text(64), country_codes = countryCodes, options = object({
			include_optional_metadata = flag, include_status = flag, include_auth_metadata = flag,
			include_payment_initiation_metadata = flag}, "options")}, required = {"institution_id", "country_codes"}},
		example = {institution_id = "ins_109508", country_codes = {"US"}},
	},
	searchInstitutions = {
		path = "/institutions/search",
		summary = "Search institutions by name for the given products.",
		spec = {fields = {query = text(256), products = list(20, text(64)), country_codes = countryCodes, options = object({
			oauth = flag, include_optional_metadata = flag, include_auth_metadata = flag,
			include_payment_initiation_metadata = flag}, "options")}, required = {"query", "products", "country_codes"}},
		example = {query = "First Platypus", products = {"transactions"}, country_codes = {"US"}},
	},
	getInstitutions = {
		path = "/institutions/get",
		summary = "List institutions one page at a time with count and offset.",
		spec = {fields = {count = integer(1, 500), offset = integer(0, 1000000), country_codes = countryCodes, options = object({
			products = list(20, text(64)), routing_numbers = list(100, text(32)), oauth = flag, include_optional_metadata = flag,
			include_auth_metadata = flag, include_payment_initiation_metadata = flag}, "options")},
			required = {"count", "offset", "country_codes"}},
		example = {count = 50, offset = 0, country_codes = {"US"}},
	},
}

-- Plaid error bodies carry error_type, error_code, error_message and request_id; the access token is never echoed back.
local function failure(name: string, response: HttpResponse, token: string?): never
	local status = response.statusCode
	local message = "Plaid HTTP " .. tostring(status)
	if status >= 300 and status < 400 then
		response.body:close()
		return houston.fail({operation = name, layer = "upstream", upstream_status = status, retryable = false,
			message = message .. ": unexpected redirect"})
	end
	local ok, raw = pcall(function() return await(response.body:readPrefix(MAX_ERROR)) end)
	local code: string? = nil
	if ok and type(raw) == "string" then
		local decoded, value = pcall(json.decode, raw)
		if decoded and type(value) == "table" then
			local kind, errorCode, detail, request = value.error_type, value.error_code, value.error_message, value.request_id
			if type(kind) == "string" and string.match(kind, "^[%u_]+$") and type(errorCode) == "string" and string.match(errorCode, "^[%u_]+$") then
				code = errorCode
				message ..= " " .. kind .. "/" .. errorCode
			end
			if type(detail) == "string" then
				local clean = string.sub(detail, 1, 600)
				if token then clean = string.gsub(clean, token:gsub("%p", "%%%0"), "[redacted]") end
				message ..= ": " .. clean
			end
			if type(request) == "string" and #request <= 64 and string.match(request, "^[%w_%-]+$") then message ..= " (request " .. request .. ")" end
		end
	end
	local retry = response.headers["retry-after"]
	if retry and retry[1] then message ..= "; retry after " .. string.sub(retry[1], 1, 64) .. "s" end
	return houston.fail({operation = name, layer = "upstream", upstream_status = status,
		retryable = status == 429 or status >= 500 or code == "PRODUCT_NOT_READY", message = message})
end

local function invalid(name: string, status: number): never
	return houston.fail({operation = name, layer = "upstream", upstream_status = status, retryable = false,
		message = "Plaid returned an unexpected answer"})
end

local function request(name: string, endpoint: Endpoint, input: any): any
	assert(type(input) == "table", name .. " must be called with an options table")
	for _, field in endpoint.spec.required do
		assert(input[field] ~= nil, name .. " requires " .. field)
	end
	local body = fields(input, endpoint.spec.fields, name, "")
	local token: string? = body.access_token
	local response = await(http.request({
		method = "POST",
		url = API .. endpoint.path,
		headers = {["Content-Type"] = {"application/json"}, Accept = {"application/json"}, ["Plaid-Version"] = {VERSION}},
		body = json.encode(body),
	}))
	if response.statusCode < 200 or response.statusCode >= 300 then failure(name, response, token) end
	local raw = await(response.body:readPrefix(MAX_BYTES + 1))
	if #raw > MAX_BYTES then
		return houston.fail({operation = name, layer = "upstream", upstream_status = response.statusCode, retryable = false,
			message = "Plaid returned more than 4 MiB; request fewer rows"})
	end
	local ok, value = pcall(json.decode, raw)
	if not ok or type(value) ~= "table" or not string.match(raw, "^%s*{") or value.error_code ~= nil then
		invalid(name, response.statusCode)
	end
	return value
end

local ACCESS_TOKEN_NOTE = "Plaid reads each Item through its access_token, which is a call argument here because Plaid accepts it only in the request body; "
	.. "Houston supplies the client ID and secret. Never log the token or put it in saved actions or memories."

local exports: {[string]: any} = {}
local functions: {[string]: any} = {}
for name, endpoint in endpoints do
	exports[name] = function(args: any): any return request(name, endpoint, args) end
	local properties: {[string]: any} = {}
	for field in endpoint.spec.fields do properties[field] = {} end
	functions[name] = {
		description = endpoint.summary .. " Required: " .. table.concat(endpoint.spec.required, ", ") .. ".",
		inputSchema = {type = "object", properties = properties, required = endpoint.spec.required, additionalProperties = false,
			examples = {endpoint.example}},
		annotations = {readOnlyHint = true},
	}
end

exports.help = {
	text = "Plaid API 2020-09-14, read-only (" .. config.environment .. "). Each function takes one options table with Plaid's native field names and returns Plaid's JSON unchanged. "
		.. ACCESS_TOKEN_NOTE
		.. " Connector calls return completed values: call plaid.getAccounts({...}) directly, without await. "
		.. "Pages: syncTransactions returns next_cursor and has_more; pass next_cursor as cursor until has_more is false. getTransactions and getInvestmentTransactions page with options.count (1 to 500) and options.offset against total_transactions. "
		.. "Dates are YYYY-MM-DD. getBalance asks the institution live and Plaid may bill it; getAccounts returns cached balances. "
		.. "A PRODUCT_NOT_READY error means Plaid is still loading the Item's data and is retryable. Errors carry Plaid's error_type, error_code and request_id; ITEM_LOGIN_REQUIRED means the Item's owner must reconnect it in your Plaid Link flow. "
		.. "Link tokens, token exchange, Item removal, payments, transfers and webhooks are not available. Calls make no automatic retries.",
	functions = functions,
}
return exports
