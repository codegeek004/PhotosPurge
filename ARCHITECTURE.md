# PhotoPurge System Architecture

PhotoPurge is a two-service system: a standalone **SSO service** that owns identity, and the **PhotoPurge platform** that owns the actual Google-to-Google migration work. They communicate through signed tokens, not shared session state or a shared database.

## Components

### SSO Service
A Django app whose only job is proving who someone is. It owns the user table, passwords, MFA secrets, and login sessions. On successful login, it signs a JWT with a private key and hands it back to the user. It also publishes its public key at a JWKS endpoint, so other services can verify that signature without ever calling back to it.

### PhotoPurge web app (Django)
Handles incoming requests. Every request carries the JWT issued by the SSO service. A middleware checks the JWT's signature against the SSO service's public key, extracts the user ID, and moves on — this app never sees a password and never manages a login form. Once the user is identified, its job is simple: accept "start a migration" requests, create a job record, and hand the work off to Celery.

### Celery + three queues (photos, drive, gmail)
This is where the actual work happens, off the request/response cycle. Instead of one shared queue where a large photo migration can block a small gmail cleanup, each domain gets its own queue and its own worker pool. A worker:
- pulls a chunk of work (e.g. 50 items)
- rate-limits itself against Redis
- calls the relevant Google API
- writes progress
- succeeds, or logs a failure and moves to the next item

### Postgres
The durable record of everything: job status, per-item progress, failed items, and the Google OAuth tokens for each user's source and destination accounts. This is the database the app can't afford to lose.

### Redis
Three unrelated jobs sharing one instance:
- message broker — hands tasks from Django to Celery workers
- rate limiter backing — a token bucket so workers don't exceed Google's API quota
- live progress counters — flushed to Postgres periodically instead of hitting the DB on every item

### Google APIs
The external system being read from and written to — Photos Library API, Drive API, Gmail API. PhotoPurge holds two separate sets of OAuth tokens per user (source account, destination account) specifically to talk to these.

---

## Request flow, end to end

1. User logs into the SSO service, which checks credentials + MFA and returns a signed JWT.
2. The browser carries that JWT to PhotoPurge. Middleware verifies it locally — no network call back to SSO for this step.
3. User separately authorizes Google access for both source and destination accounts. These OAuth tokens are stored in Postgres, tied to the user ID from the JWT — a completely separate credential from the SSO token, with its own refresh cycle.
4. User clicks "migrate photos." PhotoPurge creates a job row in Postgres and pushes a task onto the **photos** queue.
5. A photos-queue worker paginates through the source account, rate-limits itself via Redis, downloads a batch, checks whether each item already exists at the destination (so retries don't duplicate), uploads it, and writes progress.
6. If an item fails, it's logged to a failures table and the worker moves on — one bad file doesn't kill the whole job.
7. Once all chunks finish, the job's final state (`Completed` / `PartiallyFailed`) is written back to Postgres — this is what the user sees when checking status.

---

## Why it's built this way

| Decision | Reasoning |
|---|---|
| Identity split into a separate SSO service | Meant to be reused across future projects, not just this one — for a single standalone app, one combined Django project would genuinely be simpler |
| Three Celery queues instead of one | Photos/drive/gmail have very different runtimes and failure profiles; a multi-hour photo migration shouldn't block a 10-second gmail cleanup |
| Redis-backed rate limiting instead of a hardcoded sleep | A fixed delay doesn't adapt to actual API quota; a token bucket lets throughput be tuned instead of guessed |
| Postgres over MySQL | JSONB support for storing raw API metadata without a rigid schema, plus better concurrent-write behavior under multiple workers hitting the same rows |
| Idempotency checks before upload | Celery tasks can and do get retried; without a check, a retried chunk would create duplicate files at the destination |
