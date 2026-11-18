# Connect Plaid

1. Sign in to the [Plaid Dashboard](https://dashboard.plaid.com/) and open
   [Team Settings → Keys](https://dashboard.plaid.com/developers/keys).
2. Copy your **client_id** and the **secret** for the environment you want.
   Sandbox and Production have different secrets; the client ID is the same.
3. In Houston, choose the matching **Environment**, paste the **Client ID** and
   **Secret**, and save the connection.

> Production needs Plaid's approval for your account and for each product you
> read. Sandbox returns test data and is free.

## Advanced

### Access tokens

Plaid only accepts an Item's access token in the request body, so Houston cannot
store it. Agents must be given the access token of each linked bank connection
they should read, for example from your own Link integration. Use the Sandbox
environment to try the connection with test Items.

### Troubleshooting

An `INVALID_API_KEYS` error means the secret does not match the chosen
environment. `PRODUCT_NOT_READY` means Plaid is still loading data for that
connection; try again shortly. `ITEM_LOGIN_REQUIRED` means the person who linked
the account must sign in to their bank again through your Link flow.

[Plaid API keys](https://plaid.com/docs/quickstart/#api-keys).
