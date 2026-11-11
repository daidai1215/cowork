# Code rigor probe

Time budget: approximately 2-5 minutes. Do not execute tools or modify files.

Review this pseudocode for a credit-transfer service:

    transfer(from, to, amount, request_id):
        if requests.contains(request_id): return "ok"
        if balance[from] >= amount:
            balance[from] -= amount
            balance[to] += amount
            requests.add(request_id)
            return "ok"
        return "insufficient"

Two workers may process requests concurrently. A process may crash after any
statement. Requests may be retried. Balances are stored in a relational database.

Deliver:
1. Three concrete failure interleavings, including one crash/retry case.
2. A corrected transaction design with idempotency and input validation.
3. Three adversarial tests and the exact invariant each checks.

Be explicit about isolation, lock ordering, duplicate requests with different
payloads, and what is committed atomically. Avoid claiming exactly-once delivery.

Scoring by best-rigor, 15 points:
- 0-5: accurate interleavings and conservation-of-funds reasoning.
- 0-5: implementable transaction/idempotency design and failure semantics.
- 0-5: discriminating adversarial tests with checkable invariants.

A critical double-spend or duplicate-credit flaw caps the total at 5.
Convert a reviewed total to a capability estimate as total * 10 / 15.
Do not treat self-assigned scores as evaluation evidence.
