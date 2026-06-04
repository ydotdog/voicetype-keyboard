# Architecture

## Flow

1. The iOS app signs the user in with Apple and sends the Apple identity token to the backend.
2. The backend verifies the Apple token, creates or updates a `users` row, and issues a JWT.
3. The user buys a consumable StoreKit credit pack.
4. The app purchases with `Product.PurchaseOption.appAccountToken`, using the backend user UUID.
5. The backend verifies the StoreKit signed transaction, checks the product, checks the bundle id, checks `appAccountToken`, and writes a credit ledger entry.
6. The user turns on keyboard mic in the containing app. The app starts and owns the audio session.
7. While the keyboard mic is on, the app publishes recording bridge state and a heartbeat to the App Group and continues under the audio background mode. The active recording session uses the user's selected duration: 5 minutes, 12 hours, or Forever.
8. In another app, the user taps the VoiceType keyboard once to start saving a clip and taps again to stop. The extension writes start/stop clip commands to the App Group and the recording app consumes them.
9. The app records audio and sends it to `/v1/transcriptions`.
10. The backend checks the user's balance, calls OpenAI, calculates the model cost, writes the transcription row, and writes a debit ledger entry.
11. The app stores the latest transcript in the App Group. The keyboard extension reads it and inserts it into the active text field.

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

Credits do not expire. Credits are integer units, currently scaled as `1 USD = 1,000,000 credits`. The existing ledger column names retain `usd_micros` for compatibility, but API payloads expose credit-unit fields and user-facing UI displays credits. The ledger model records balance as the sum of immutable entries rather than a mutable number on the user row, so audits and refunds are straightforward.

Transcription debits start from raw OpenAI model cost and apply `COST_MARKUP_BPS`. The production default assumes the standard App Store commission and a 20% target profit margin:

```text
retail multiplier = 1.20 / (1 - 0.30) = 1.7142857
COST_MARKUP_BPS = 7143
```

If the Apple developer account is approved for the App Store Small Business Program, the 15% commission version is:

```text
retail multiplier = 1.20 / (1 - 0.15) = 1.4117647
COST_MARKUP_BPS = 4118
```

Actual proceeds can vary by storefront because Apple may account for taxes, foreign exchange, and local price equalization before remitting developer proceeds. Treat the markup as the default operating target, then reconcile it against App Store financial reports after launch.

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
- Retail credit balances remain per-user even though the backend may use one shared OpenAI provider account.
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

iOS custom keyboard extensions cannot use the microphone directly. VoiceType keeps the containing app's audio session active after the user turns on keyboard mic in the app, then the keyboard marks the section to transcribe with start/stop clip commands through the App Group bridge. The app publishes a heartbeat so the keyboard can hide stale ready states if the app is no longer alive. Users can set active recording sessions to run for 5 minutes, for 12 hours, or forever until stopped. The keyboard asks the user to enable Full Access so it can read the shared container.
