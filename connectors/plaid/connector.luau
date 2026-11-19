-- Plaid API (version 2020-09-14, https://plaid.com/docs/api/), read-only. Arguments and results keep Plaid's native field names.
type Options = {[string]: any}
type Check = (any, string) -> any
type Spec = {fields: {[string]: Check}, required: {string}}

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

local function request(name: string, path: string, spec: Spec, input: any): any
	assert(type(input) == "table", name .. " must be called with an options table")
	for _, field in spec.required do
		assert(input[field] ~= nil, name .. " requires " .. field)
	end
	local body = fields(input, spec.fields, name, "")
	local token: string? = body.access_token
	local response = await(http.request({
		method = "POST",
		url = API .. path,
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

-- JSON Schema pieces shared by the help records below.
local TOKEN = {type = "string", minLength = 1, maxLength = 256, description = "The Item's Plaid access token."}
local ACCOUNT_IDS = {type = "array", items = {type = "string", minLength = 1}, minItems = 1, maxItems = 100, description = "Limit the result to these account IDs."}
local DATE = {type = "string", pattern = "^\\d{4}-\\d{2}-\\d{2}$", description = "A date written YYYY-MM-DD."}
local COUNTRIES = {type = "array", items = {type = "string", pattern = "^[A-Z]{2}$"}, minItems = 1, maxItems = 20, description = "Two-letter country codes such as US."}
local FLAG = {type = "boolean"}
local PAGE_SIZE = {type = "integer", minimum = 1, maximum = 500}
local OFFSET = {type = "integer", minimum = 0, maximum = 1000000}
local ACCOUNT_OPTIONS_SCHEMA = {type = "object", additionalProperties = false, properties = {account_ids = ACCOUNT_IDS}}
local ACCOUNT_OPTIONS = {account_ids = accountIds}

local exports: {[string]: any} = {}
exports.help = {
	text = "Plaid API 2020-09-14, read-only (" .. config.environment .. "). Each function takes one options table with Plaid's native field names and returns Plaid's JSON unchanged. "
		.. "Plaid reads each Item through its access_token, which is a call argument here because Plaid accepts it only in the request body; Houston supplies the client ID and secret. Never log the token or put it in saved actions or memories. "
		.. "Connector calls return completed values: call plaid.getAccounts({...}) directly, without await. "
		.. "Pages: syncTransactions returns next_cursor and has_more; pass next_cursor as cursor until has_more is false. getTransactions and getInvestmentTransactions page with options.count (1 to 500) and options.offset against total_transactions. "
		.. "Dates are YYYY-MM-DD. getBalance asks the institution live and Plaid may bill it; getAccounts returns cached balances. "
		.. "A PRODUCT_NOT_READY error means Plaid is still loading the Item's data and is retryable. Errors carry Plaid's error_type, error_code and request_id; ITEM_LOGIN_REQUIRED means the Item's owner must reconnect it in your Plaid Link flow. "
		.. "Link tokens, token exchange, Item removal, payments, transfers and webhooks are not available. Calls make no automatic retries.",
	functions = {},
}

exports.help.functions.getAccounts = {
	description = "List the accounts of one Item with cached balances.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token"},
		properties = {access_token = TOKEN, options = ACCOUNT_OPTIONS_SCHEMA},
		examples = {{access_token = "access-sandbox-123", options = {account_ids = {"account-1"}}}}},
	annotations = {readOnlyHint = true},
}
function exports.getAccounts(args: any): any
	return request("getAccounts", "/accounts/get", {fields = {access_token = accessToken, options = object(ACCOUNT_OPTIONS, "options")}, required = {"access_token"}}, args)
end

exports.help.functions.getBalance = {
	description = "Fetch real-time balances from the institution. Plaid may bill each call; prefer getAccounts for cached balances.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token"},
		properties = {access_token = TOKEN, options = {type = "object", additionalProperties = false,
			properties = {account_ids = ACCOUNT_IDS, min_last_updated_datetime = {type = "string", description = "ISO 8601 date-time such as 2026-01-31T12:00:00Z."}}}},
		examples = {{access_token = "access-sandbox-123", options = {account_ids = {"account-1"}}}}},
	annotations = {readOnlyHint = true},
}
function exports.getBalance(args: any): any
	return request("getBalance", "/accounts/balance/get", {fields = {access_token = accessToken,
		options = object({account_ids = accountIds, min_last_updated_datetime = dateTime}, "options")}, required = {"access_token"}}, args)
end

exports.help.functions.syncTransactions = {
	description = "Fetch one page of added, modified and removed transactions after a cursor. Omit cursor for the first page; pass the returned next_cursor until has_more is false.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token"},
		properties = {access_token = TOKEN, cursor = {type = "string", minLength = 1, maxLength = 256}, count = PAGE_SIZE,
			options = {type = "object", additionalProperties = false, properties = {include_original_description = FLAG,
				include_personal_finance_category = FLAG, days_requested = {type = "integer", minimum = 1, maximum = 730},
				account_id = {type = "string", minLength = 1}, include_logo_and_counterparty_beta = FLAG}}},
		examples = {{access_token = "access-sandbox-123", count = 100}}},
	annotations = {readOnlyHint = true},
}
function exports.syncTransactions(args: any): any
	return request("syncTransactions", "/transactions/sync", {fields = {access_token = accessToken, cursor = text(256), count = integer(1, 500), options = object({
		include_original_description = flag, include_personal_finance_category = flag, days_requested = integer(1, 730),
		account_id = text(256), include_logo_and_counterparty_beta = flag}, "options")}, required = {"access_token"}}, args)
end

exports.help.functions.getTransactions = {
	description = "List transactions in a date range, one page at a time with options.count and options.offset against total_transactions.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token", "start_date", "end_date"},
		properties = {access_token = TOKEN, start_date = DATE, end_date = DATE,
			options = {type = "object", additionalProperties = false, properties = {account_ids = ACCOUNT_IDS, count = PAGE_SIZE, offset = OFFSET,
				include_original_description = FLAG, include_personal_finance_category = FLAG}}},
		examples = {{access_token = "access-sandbox-123", start_date = "2026-01-01", end_date = "2026-01-31", options = {count = 100, offset = 0}}}},
	annotations = {readOnlyHint = true},
}
function exports.getTransactions(args: any): any
	return request("getTransactions", "/transactions/get", {fields = {access_token = accessToken, start_date = date, end_date = date, options = object({
		account_ids = accountIds, count = integer(1, 500), offset = integer(0, 1000000),
		include_original_description = flag, include_personal_finance_category = flag}, "options")},
		required = {"access_token", "start_date", "end_date"}}, args)
end

exports.help.functions.getRecurringTransactions = {
	description = "List recurring inflow and outflow streams detected for the given accounts.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token", "account_ids"},
		properties = {access_token = TOKEN, account_ids = ACCOUNT_IDS,
			options = {type = "object", additionalProperties = false, properties = {include_personal_finance_category = FLAG}}},
		examples = {{access_token = "access-sandbox-123", account_ids = {"account-1"}}}},
	annotations = {readOnlyHint = true},
}
function exports.getRecurringTransactions(args: any): any
	return request("getRecurringTransactions", "/transactions/recurring/get", {fields = {access_token = accessToken, account_ids = accountIds,
		options = object({include_personal_finance_category = flag}, "options")}, required = {"access_token", "account_ids"}}, args)
end

exports.help.functions.getAuth = {
	description = "Fetch account and routing numbers. Sensitive: do not log or save the result.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token"},
		properties = {access_token = TOKEN, options = ACCOUNT_OPTIONS_SCHEMA}, examples = {{access_token = "access-sandbox-123"}}},
	annotations = {readOnlyHint = true},
}
function exports.getAuth(args: any): any
	return request("getAuth", "/auth/get", {fields = {access_token = accessToken, options = object(ACCOUNT_OPTIONS, "options")}, required = {"access_token"}}, args)
end

exports.help.functions.getIdentity = {
	description = "Fetch account holder names, addresses, emails and phone numbers. Sensitive: do not log or save the result.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token"},
		properties = {access_token = TOKEN, options = ACCOUNT_OPTIONS_SCHEMA}, examples = {{access_token = "access-sandbox-123"}}},
	annotations = {readOnlyHint = true},
}
function exports.getIdentity(args: any): any
	return request("getIdentity", "/identity/get", {fields = {access_token = accessToken, options = object(ACCOUNT_OPTIONS, "options")}, required = {"access_token"}}, args)
end

exports.help.functions.getHoldings = {
	description = "List investment holdings and securities.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token"},
		properties = {access_token = TOKEN, options = ACCOUNT_OPTIONS_SCHEMA}, examples = {{access_token = "access-sandbox-123"}}},
	annotations = {readOnlyHint = true},
}
function exports.getHoldings(args: any): any
	return request("getHoldings", "/investments/holdings/get", {fields = {access_token = accessToken, options = object(ACCOUNT_OPTIONS, "options")}, required = {"access_token"}}, args)
end

exports.help.functions.getInvestmentTransactions = {
	description = "List investment transactions in a date range, one page at a time with options.count and options.offset.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token", "start_date", "end_date"},
		properties = {access_token = TOKEN, start_date = DATE, end_date = DATE,
			options = {type = "object", additionalProperties = false, properties = {account_ids = ACCOUNT_IDS, count = PAGE_SIZE, offset = OFFSET}}},
		examples = {{access_token = "access-sandbox-123", start_date = "2026-01-01", end_date = "2026-01-31"}}},
	annotations = {readOnlyHint = true},
}
function exports.getInvestmentTransactions(args: any): any
	return request("getInvestmentTransactions", "/investments/transactions/get", {fields = {access_token = accessToken, start_date = date, end_date = date,
		options = object({account_ids = accountIds, count = integer(1, 500), offset = integer(0, 1000000)}, "options")},
		required = {"access_token", "start_date", "end_date"}}, args)
end

exports.help.functions.getLiabilities = {
	description = "Fetch credit card, student loan and mortgage liabilities.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token"},
		properties = {access_token = TOKEN, options = ACCOUNT_OPTIONS_SCHEMA}, examples = {{access_token = "access-sandbox-123"}}},
	annotations = {readOnlyHint = true},
}
function exports.getLiabilities(args: any): any
	return request("getLiabilities", "/liabilities/get", {fields = {access_token = accessToken, options = object(ACCOUNT_OPTIONS, "options")}, required = {"access_token"}}, args)
end

exports.help.functions.getItem = {
	description = "Fetch an Item's status, institution, products and consent expiration.",
	inputSchema = {type = "object", additionalProperties = false, required = {"access_token"},
		properties = {access_token = TOKEN}, examples = {{access_token = "access-sandbox-123"}}},
	annotations = {readOnlyHint = true},
}
function exports.getItem(args: any): any
	return request("getItem", "/item/get", {fields = {access_token = accessToken}, required = {"access_token"}}, args)
end

exports.help.functions.getInstitution = {
	description = "Fetch one institution by ID.",
	inputSchema = {type = "object", additionalProperties = false, required = {"institution_id", "country_codes"},
		properties = {institution_id = {type = "string", minLength = 1, maxLength = 64}, country_codes = COUNTRIES,
			options = {type = "object", additionalProperties = false, properties = {include_optional_metadata = FLAG, include_status = FLAG,
				include_auth_metadata = FLAG, include_payment_initiation_metadata = FLAG}}},
		examples = {{institution_id = "ins_109508", country_codes = {"US"}}}},
	annotations = {readOnlyHint = true},
}
function exports.getInstitution(args: any): any
	return request("getInstitution", "/institutions/get_by_id", {fields = {institution_id = text(64), country_codes = countryCodes, options = object({
		include_optional_metadata = flag, include_status = flag, include_auth_metadata = flag,
		include_payment_initiation_metadata = flag}, "options")}, required = {"institution_id", "country_codes"}}, args)
end

exports.help.functions.searchInstitutions = {
	description = "Search institutions by name for the given products.",
	inputSchema = {type = "object", additionalProperties = false, required = {"query", "products", "country_codes"},
		properties = {query = {type = "string", minLength = 1, maxLength = 256},
			products = {type = "array", items = {type = "string", minLength = 1}, minItems = 1, maxItems = 20, description = "Plaid products such as transactions."},
			country_codes = COUNTRIES,
			options = {type = "object", additionalProperties = false, properties = {oauth = FLAG, include_optional_metadata = FLAG,
				include_auth_metadata = FLAG, include_payment_initiation_metadata = FLAG}}},
		examples = {{query = "First Platypus", products = {"transactions"}, country_codes = {"US"}}}},
	annotations = {readOnlyHint = true},
}
function exports.searchInstitutions(args: any): any
	return request("searchInstitutions", "/institutions/search", {fields = {query = text(256), products = list(20, text(64)), country_codes = countryCodes, options = object({
		oauth = flag, include_optional_metadata = flag, include_auth_metadata = flag,
		include_payment_initiation_metadata = flag}, "options")}, required = {"query", "products", "country_codes"}}, args)
end

exports.help.functions.getInstitutions = {
	description = "List institutions one page at a time with count and offset.",
	inputSchema = {type = "object", additionalProperties = false, required = {"count", "offset", "country_codes"},
		properties = {count = PAGE_SIZE, offset = OFFSET, country_codes = COUNTRIES,
			options = {type = "object", additionalProperties = false, properties = {
				products = {type = "array", items = {type = "string", minLength = 1}, minItems = 1, maxItems = 20},
				routing_numbers = {type = "array", items = {type = "string", minLength = 1}, minItems = 1, maxItems = 100},
				oauth = FLAG, include_optional_metadata = FLAG, include_auth_metadata = FLAG, include_payment_initiation_metadata = FLAG}}},
		examples = {{count = 50, offset = 0, country_codes = {"US"}}}},
	annotations = {readOnlyHint = true},
}
function exports.getInstitutions(args: any): any
	return request("getInstitutions", "/institutions/get", {fields = {count = integer(1, 500), offset = integer(0, 1000000), country_codes = countryCodes, options = object({
		products = list(20, text(64)), routing_numbers = list(100, text(32)), oauth = flag, include_optional_metadata = flag,
		include_auth_metadata = flag, include_payment_initiation_metadata = flag}, "options")},
		required = {"count", "offset", "country_codes"}}, args)
end

return exports
