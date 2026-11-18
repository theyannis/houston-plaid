-- Each export posts one exact JSON body to Plaid with no credentials (the proxy adds them) and returns Plaid's answer unchanged.
return {
	scenario = {publisher = {}, config = {environment = "sandbox"}, auth_method = "keys", auth_config = {client_id = "client-fixture", secret = "synthetic-plaid-secret"}},
	configure = function()
		requests, responses = {}, {}
		http = {request = function(req)
			table.insert(requests, req)
			for name in req.headers do
				local lower = string.lower(name)
				assert(lower ~= "authorization" and lower ~= "plaid-secret" and lower ~= "plaid-client-id", "the proxy adds the credentials")
			end
			assert(req.method == "POST" and req.headers["Content-Type"][1] == "application/json" and req.headers["Plaid-Version"][1] == "2020-09-14")
			assert(#responses > 0, "unexpected request: " .. req.url)
			return fixture.operation({statusCode = 200, headers = {["content-type"] = {"application/json"}}, body = fixture.reader(table.remove(responses, 1))})
		end}
		function respond(body) table.insert(responses, body) end
	end,
	run = function(plaid)
		local expected = {"getAccounts", "getAuth", "getBalance", "getHoldings", "getIdentity", "getInstitution", "getInstitutions", "getInvestmentTransactions",
			"getItem", "getLiabilities", "getRecurringTransactions", "getTransactions", "searchInstitutions", "syncTransactions"}
		local names = {}
		for name in plaid do if name ~= "help" then table.insert(names, name) end end
		table.sort(names)
		assert(table.concat(names, ",") == table.concat(expected, ","), "wrong export set: " .. table.concat(names, ","))
		for _, name in {"itemRemove", "removeItem", "createLinkToken", "exchangePublicToken", "createTransfer"} do assert(plaid[name] == nil, "leaked " .. name) end

		local function posted(path, body)
			local req = requests[#requests]
			assert(req.url == "https://sandbox.plaid.com" .. path, req.url)
			local sent = json.decode(req.body)
			for key, value in body do assert(json.encode(sent[key]) == json.encode(value), key .. " differs: " .. req.body) end
			for key in sent do assert(body[key] ~= nil, "extra field " .. key) end
		end

		respond('{"accounts":[{"account_id":"a1","balances":{"available":100.5,"current":110.25,"iso_currency_code":"USD"}}],"item":{"item_id":"i1"},"request_id":"r1"}')
		local accounts = plaid.getAccounts({access_token = "access-sandbox-1", options = {account_ids = {"a1"}}})
		posted("/accounts/get", {access_token = "access-sandbox-1", options = {account_ids = {"a1"}}})
		assert(accounts.accounts[1].balances.available == 100.5 and accounts.request_id == "r1")

		respond('{"accounts":[],"request_id":"r2"}')
		assert(json.encode(plaid.getAccounts({access_token = "access-sandbox-1"}).accounts) == "[]", "empty array lost")
		posted("/accounts/get", {access_token = "access-sandbox-1"})

		respond('{"accounts":[],"request_id":"r3"}')
		plaid.getBalance({access_token = "t", options = {min_last_updated_datetime = "2026-01-31T12:00:00Z"}})
		posted("/accounts/balance/get", {access_token = "t", options = {min_last_updated_datetime = "2026-01-31T12:00:00Z"}})

		respond('{"added":[{"transaction_id":"t1","amount":12.34}],"modified":[],"removed":[],"next_cursor":"c2","has_more":true,"request_id":"r4"}')
		local page = plaid.syncTransactions({access_token = "t", count = 100, options = {include_personal_finance_category = true}})
		posted("/transactions/sync", {access_token = "t", count = 100, options = {include_personal_finance_category = true}})
		assert(page.next_cursor == "c2" and page.has_more == true and page.added[1].amount == 12.34 and json.encode(page.modified) == "[]")
		respond('{"added":[],"modified":[],"removed":[],"next_cursor":"c3","has_more":false}')
		plaid.syncTransactions({access_token = "t", cursor = page.next_cursor})
		posted("/transactions/sync", {access_token = "t", cursor = "c2"})

		respond('{"transactions":[],"total_transactions":0,"accounts":[]}')
		plaid.getTransactions({access_token = "t", start_date = "2026-02-01", end_date = "2026-02-28", options = {count = 25, offset = 50}})
		posted("/transactions/get", {access_token = "t", start_date = "2026-02-01", end_date = "2026-02-28", options = {count = 25, offset = 50}})

		respond('{"inflow_streams":[],"outflow_streams":[]}')
		plaid.getRecurringTransactions({access_token = "t", account_ids = {"a1"}})
		posted("/transactions/recurring/get", {access_token = "t", account_ids = {"a1"}})

		for name, path in {getAuth = "/auth/get", getIdentity = "/identity/get", getHoldings = "/investments/holdings/get",
			getLiabilities = "/liabilities/get", getItem = "/item/get"} do
			respond('{"request_id":"x"}')
			plaid[name]({access_token = "t"})
			posted(path, {access_token = "t"})
		end

		respond('{"transactions":[]}')
		plaid.getInvestmentTransactions({access_token = "t", start_date = "2024-02-29", end_date = "2026-02-28"})
		posted("/investments/transactions/get", {access_token = "t", start_date = "2024-02-29", end_date = "2026-02-28"})

		respond('{"institution":{"institution_id":"ins_1"}}')
		plaid.getInstitution({institution_id = "ins_1", country_codes = {"US"}, options = {include_status = true}})
		posted("/institutions/get_by_id", {institution_id = "ins_1", country_codes = {"US"}, options = {include_status = true}})
		respond('{"institutions":[]}')
		plaid.searchInstitutions({query = "Platypus", products = {"transactions"}, country_codes = {"US", "CA"}})
		posted("/institutions/search", {query = "Platypus", products = {"transactions"}, country_codes = {"US", "CA"}})
		respond('{"institutions":[],"total":0}')
		plaid.getInstitutions({count = 10, offset = 20, country_codes = {"US"}, options = {oauth = true}})
		posted("/institutions/get", {count = 10, offset = 20, country_codes = {"US"}, options = {oauth = true}})

		local calls = #requests
		local function rejected(fn, expected)
			local ok, err = pcall(fn)
			assert(not ok and string.find(tostring(err), expected, 1, true), "wrong validation error: " .. tostring(err))
			assert(#requests == calls, "invalid input reached Plaid")
		end
		rejected(function() plaid.getAccounts() end, "options table")
		rejected(function() plaid.getAccounts({}) end, "requires access_token")
		rejected(function() plaid.getAccounts({access_token = ""}) end, "access_token must be a string")
		rejected(function() plaid.getAccounts({access_token = 5}) end, "access_token must be a string")
		rejected(function() plaid.getAccounts({access_token = "t", client_id = "x"}) end, "unknown option client_id")
		rejected(function() plaid.getAccounts({access_token = "t", secret = "x"}) end, "unknown option secret")
		rejected(function() plaid.getAccounts({access_token = "t", options = {account_ids = {}}}) end, "1 to 100 entries")
		rejected(function() plaid.getAccounts({access_token = "t", options = {account_ids = "a1"}}) end, "must be an array")
		rejected(function() plaid.getAccounts({access_token = "t", options = {other = 1}}) end, "unknown option other")
		rejected(function() plaid.getBalance({access_token = "t", options = {min_last_updated_datetime = "yesterday"}}) end, "ISO 8601 date-time")
		rejected(function() plaid.syncTransactions({access_token = "t", count = 501}) end, "integer from 1 to 500")
		rejected(function() plaid.syncTransactions({access_token = "t", count = 1.5}) end, "integer from 1 to 500")
		rejected(function() plaid.getTransactions({access_token = "t", start_date = "2026-02-01"}) end, "requires end_date")
		for _, bad in {"2026-02-30", "2025-02-29", "2026-13-01", "02/01/2026", "2026-2-1", 20260201} do
			rejected(function() plaid.getTransactions({access_token = "t", start_date = bad, end_date = "2026-02-28"}) end, "YYYY-MM-DD")
		end
		rejected(function() plaid.getTransactions({access_token = "t", start_date = "2026-02-01", end_date = "2026-02-28", options = {count = 0}}) end, "integer from 1 to 500")
		rejected(function() plaid.getTransactions({access_token = "t", start_date = "2026-02-01", end_date = "2026-02-28", options = {offset = -1}}) end, "options.offset")
		rejected(function() plaid.getRecurringTransactions({access_token = "t"}) end, "requires account_ids")
		rejected(function() plaid.getInstitution({institution_id = "ins_1", country_codes = {"us"}}) end, "two-letter uppercase")
		rejected(function() plaid.getInstitution({institution_id = "ins_1"}) end, "requires country_codes")
		rejected(function() plaid.searchInstitutions({query = "x", country_codes = {"US"}}) end, "requires products")
		rejected(function() plaid.getInstitutions({count = 10, country_codes = {"US"}}) end, "requires offset")

		-- Fixtures do not receive help; the validator checks it. These checks make sure the names line up.
		assert(type(plaid.help) == "table" and plaid.help.text ~= "" and next(plaid.help.functions) ~= nil)
		for _, name in expected do assert(plaid.help.functions[name], "no help for " .. name) end
	end,
}
