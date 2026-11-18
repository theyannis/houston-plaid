return {
	contract = function(m)
		for _, environment in { "production", "sandbox" } do
			m.authentication({
				{
					auth = { client_id = "client-fixture", secret = "synthetic-method-secret" },
					config = { environment = environment },
					endpoint = { "POST", "https://" .. environment .. ".plaid.com/accounts/get" },
					expected = "synthetic-method-secret",
					header = "PLAID-SECRET",
					method = "keys",
					publisher = {},
				},
				{
					auth = { client_id = "client-fixture", secret = "synthetic-method-secret" },
					config = { environment = environment },
					endpoint = { "POST", "https://" .. environment .. ".plaid.com/accounts/get" },
					expected = "client-fixture",
					header = "PLAID-CLIENT-ID",
					method = "keys",
					publisher = {},
				},
			})
		end
	end,
}
