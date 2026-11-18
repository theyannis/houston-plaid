---
description: Read Plaid account balances, transactions, investments, liabilities and institution details for the bank connections your app has linked.
---

# Plaid

Let agents read the financial data your Plaid account already has permission to
see: accounts and balances, transactions and recurring payments, account holder
details, investment holdings, liabilities, Item status and institution details.

Access is read-only. Creating Link tokens, exchanging tokens, removing Items,
payments, transfers and webhooks are not included.

> Plaid identifies each linked bank connection by its access token. Agents need
> that token for every account lookup, so give it to them only for connections
> you want them to read. Real-time balance checks may be billed by Plaid.

[Connect Plaid](SETUP.md).
