-- Only each environment's own host and the listed read endpoints are reachable, and credentials are injected over forged headers.
return {
	contract = function(m)
		local paths = { "/accounts/get", "/accounts/balance/get", "/transactions/sync", "/transactions/get", "/transactions/recurring/get",
			"/auth/get", "/identity/get", "/investments/holdings/get", "/investments/transactions/get", "/liabilities/get",
			"/item/get", "/institutions/get", "/institutions/get_by_id", "/institutions/search" }
		for _, environment in { "production", "sandbox" } do
			local other = if environment == "production" then "sandbox" else "production"
			local r, err = m.resolve(nil, { environment = environment }, { client_id = "client-fixture", secret = "secret-fixture" }, "keys")
			assert(not err, tostring(err))
			local api = "https://" .. environment .. ".plaid.com"
			for _, path in paths do
				local recipe, problem = m.recipe(r, "POST", api .. path, nil)
				assert(not problem, "POST " .. path .. " denied: " .. tostring(problem))
				m.rejectPreparedOverrides(recipe, r.Context, "POST " .. path)
				local headers, prepared = m.prepare(recipe, r.Context, { ["PLAID-SECRET"] = { "forged" }, ["PLAID-CLIENT-ID"] = { "forged" } })
				assert(not prepared and m.header(headers, "PLAID-SECRET") == "secret-fixture" and m.header(headers, "PLAID-CLIENT-ID") == "client-fixture",
					"credentials not injected on " .. path)
			end
			m.routes(r, "", false, {
				"GET " .. api .. "/accounts/get",
				"POST " .. api .. "/item/remove",
				"POST " .. api .. "/item/access_token/invalidate",
				"POST " .. api .. "/item/public_token/exchange",
				"POST " .. api .. "/link/token/create",
				"POST " .. api .. "/sandbox/public_token/create",
				"POST " .. api .. "/transfer/create",
				"POST " .. api .. "/payment_initiation/payment/create",
				"POST " .. api .. "/webhook_verification_key/get",
				"POST " .. api .. "/accounts/get/extra",
				"POST " .. api .. "/%2e%2e/item/remove",
				"POST https://" .. other .. ".plaid.com/accounts/get",
				"POST https://" .. environment .. ".plaid.com.example.com/accounts/get",
				"POST http://" .. environment .. ".plaid.com:8080/accounts/get",
				"POST https://development.plaid.com/accounts/get",
				"POST https://plaid.com/accounts/get",
				"POST https://api.plaid.com/accounts/get",
			})
		end
	end,
}
