# Architecture

## Flow

1. The iOS app signs the user in with Apple and sends the Apple identity token to the backend.
2. The backend verifies the Apple token, creates or updates a `users` row, and issues a JWT.
3. The user buys a consumable StoreKit credit pack.
4. The app purchases with `Product.PurchaseOption.appAccountToken`, using the backend user UUID.
5. The backend verifies the StoreKit signed transaction, checks the product, checks the bundle id, checks `appAccountToken`, and writes a credit ledger entry.
6. The app records audio and sends it to `/v1/transcriptions`.
7. The backend checks the user's balance, calls OpenAI, calculates the model cost, writes the transcription row, and writes a debit ledger entry.
8. The app stores the latest transcript in the App Group. The keyboard extension reads it and inserts it into the active text field.

## User Accounting

The backend can use one OpenAI provider account/API key for all users. That does not mean usage is mixed.

User separation is enforced by:

- `users.id` as the account boundary.
- `credit_ledger.user_id` on every credit and debit.
- StoreKit `appAccountToken` matching `users.id`.
- Idempotent `credit_ledger.source_id` values, such as `storekit:<transaction_id>` and `transcription:<transcription_id>`.
- Re-checking balance inside a database transaction before writing transcription debits.
- Row-level user locks in Postgres during purchase and debit writes.

`OPENAI_PROVIDER_ACCOUNT_ID` is stored on each transcription. If the business later moves to multiple OpenAI accounts or regional providers, historical cost attribution still has a provider account label.

## Credit Policy

Credits do not expire. The ledger model records balance as the sum of immutable entries rather than a mutable number on the user row, so audits and refunds are straightforward.

Recommended ledger entry types:

- `storekit_purchase`: consumable credit purchase.
- `transcription`: model usage debit.
- `dev_credit`: local development only.
- Future: `refund`, `manual_adjustment`, `promo_credit`.

## StoreKit Security

Production defaults are strict:

- `STOREKIT_VERIFICATION_MODE=strict`
- `ALLOW_UNVERIFIED_STOREKIT_JWS=false`
- `REQUIRE_STOREKIT_APP_ACCOUNT_TOKEN=true`

The backend uses Apple's App Store Server Library to verify transaction signatures. Local unverified decoding exists only for StoreKit/Xcode development when explicitly enabled.

## Scaling

The API is stateless apart from Postgres, so the first scale step is horizontal API workers behind a load balancer.

The design does not need to be rewritten for higher user volume:

- JWT auth avoids server-side session storage.
- Postgres holds users, transactions, transcriptions, and ledger entries.
- Transaction ids and ledger source ids are unique, making retries safe.
- Balance checks happen in database transactions.
- API workers can scale independently.
- Audio is streamed to OpenAI and not stored by default, reducing storage pressure and privacy exposure.

Scale-up path:

1. Run Postgres with automated backups and point-in-time recovery.
2. Run 2+ backend instances with `DATABASE_POOL_MAX_SIZE` sized to database capacity.
3. Put the backend behind HTTPS with request size limits matching `MAX_AUDIO_BYTES`.
4. Add metrics for auth errors, purchase grants, transcription costs, 402 insufficient-credit responses, OpenAI latency, and StoreKit verification failures.
5. Add a background queue only if uploads or OpenAI latency require async job handling. The current synchronous path is simpler for v1.
6. Add read replicas or ledger partitioning only after Postgres write volume proves it is needed.

## Keyboard Constraints

iOS custom keyboard extensions cannot use the microphone directly. VoiceType records in the containing app, then shares the completed transcript through the App Group. The keyboard asks the user to enable Full Access so it can read the shared container.
