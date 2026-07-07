# Fizzy Ruby Client PRD

## Summary

Build a single vendorable Ruby file that provides a small Ruby client for the Fizzy API using `net/http`.

The client is for integration use cases. It must minimize dependencies and expose a stable `Client` / `Request` / `Response` structure.

Source of truth for behavior is the Fizzy application code and tests, not the published API docs.

## Goals

- Provide a single-file Ruby client suitable for vendoring into scripts or apps.
- Use `net/http` with minimal third-party dependencies.
- Separate concerns into:
  - `Client`: endpoint facade and generic request entrypoint
  - `Request`: request building, auth, encoding, and HTTP send logic
  - `Response`: response parsing and normalization for HTTP responses and client/network failures
- Return `Response` objects for all outcomes, including network failures.
- Support bearer-token authentication.
- Support core API surface:
  - identity
  - boards
  - columns
  - cards
  - comments
  - users
  - direct uploads / attachments
- Include convenience helpers for direct uploads and rich text attachments.
- Keep user code insulated from the details of `net/http`.

## Non-goals

- No gem packaging requirement.
- No magic-link or session-cookie auth.
- No automatic pagination.
- No exceptions for non-2xx HTTP responses.
- No retries/backoff in initial implementation unless explicitly added later.
- No attempt to expose the full Fizzy API.
- No user creation support, because the current API does not provide it.

## Primary use case

Provide a small vendorable Ruby client for interacting with the Fizzy API.

## Constraints from current Fizzy code

These requirements reflect current application behavior:

- Authentication is via bearer token in `Authorization: Bearer ...`.
- `GET /my/identity` is not account-scoped.
- Most resource endpoints are account-scoped by URL path.
- Direct uploads are account-scoped at `/:account_slug/rails/active_storage/direct_uploads`.
- JSON endpoints are on normal app routes, not a separate `/api` namespace.
- Write endpoints often support both nested JSON and flat JSON; the client may send nested JSON consistently.
- Pagination supports `page`; server-controlled page sizing is used.
- `per_page` should not be promised as part of the official client surface.
- Current card controller params allow:
  - `title`
  - `description`
  - `image`
  - `created_at`
  - `last_active_at`
- Current comment controller params allow:
  - `body`
  - `created_at`
- Current user API supports:
  - list
  - get
  - update
  - deactivate/delete
  - no create

## Deliverable

One vendorable Ruby file placed in `lib/` beside its tests.

Expected implementation path:

```ruby
lib/fizzy_client.rb
```

This PRD documents the intended behavior and public API surface for that file.

---

# Architecture

## Top-level structure

The single file should define:

- `Fizzy::Client`
- `Fizzy::Request`
- `Fizzy::Response`
- small internal helpers/modules as needed

## Client responsibilities

`Client` is the facade.

Responsibilities:
- hold configuration
- know base URL, default account slug, bearer token, default headers, timeout settings
- expose endpoint-specific methods with primitive arguments
- expose a low-level generic `request` method
- expose upload convenience helpers

### Client initialization

```ruby
Fizzy::Client.new(
  base_url:,
  bearer_token:,
  account_slug: nil,
  open_timeout: 10,
  read_timeout: 60,
  write_timeout: 60,
  user_agent: "fizzy-client/1.0"
)
```

Notes:
- `account_slug` is optional at initialization because `get_identity` is unscoped.
- For nearly all account-scoped operations, `account_slug` should be provided.
- Account-scoped facade methods should always use the client's configured `account_slug`.
- If an account-scoped facade method is called without a configured account slug, the client should return a synthetic error `Response`.

## Request responsibilities

`Request` encapsulates the logic needed to communicate with the service.

Responsibilities:
- build URLs
- merge path/query params
- attach auth headers
- set JSON request headers
- serialize request body
- perform the HTTP request
- contain the only `net/http`-dependent request code, plus any tiny private helpers needed by that code
- catch network-level failures and normalize them into `Response`

## Response responsibilities

`Response` wraps and normalizes all results from the HTTP layer.

Responsibilities:
- extract status, headers, and body from the underlying `net/http` response
- parse JSON bodies when response content type indicates JSON, or when parsing is otherwise appropriate
- preserve raw body, headers, status, and error metadata
- represent synthetic network failures without raising
- isolate HTTP response handling away from `Client`

### Response interface

Minimum interface:

```ruby
response.status
response.headers
response.body
response.raw_body
response.success?
response.json?
response.error?
response.message
```

Behavior:
- `body` returns parsed JSON when possible, else raw string or `nil`
- `raw_body` returns original body string
- `headers` are normalized into a simple case-insensitive or consistently keyed hash
- `success?` means `200..299`
- `error?` means not `success?`
- `message` may summarize HTTP or network failure context

### Synthetic failure responses

Network failures must still return `Response` objects.

Suggested behavior:
- `status` = `0`
- `success?` = `false`
- `body` should use a simple machine-friendly shape:

```ruby
{
  "error" => "connection_failed",
  "message" => "Connection refused"
}
```

Examples of network failures:
- DNS errors
- refused connections
- SSL failures
- timeouts
- malformed URLs

## HTTP boundary

Keep HTTP concerns simple.

The HTTP layer in this design is `Request` plus `Response`.

- `Request` owns sending HTTP through `net/http`
- `Response` owns interpreting what `net/http` returned

There is no separate adapter hierarchy in this design.

The implementation should keep `Client` free of `net/http` specifics, and should expose headers in a normalized, conventional form such as `"Content-Type"`.

---

# Request/Response conventions

## Default headers

API requests should send:

- `Authorization: Bearer <token>`
- `Accept: application/json`
- `User-Agent` from configuration

When a request body is present:
- if `body` is a `Hash`, the client should JSON-encode it and send `Content-Type: application/json`
- if `body` is a `String`, the client should send it as-is
- callers are responsible for passing a valid JSON string when they choose to pass a string body to a JSON endpoint

## Body encoding

The low-level request API should be simple:
- if `body` is a `Hash`, call `to_json` before sending
- if `body` is a `String`, send it unchanged

Facade methods should still build nested request payloads for object writes, for example:

```json
{ "board": { "name": "Import board" } }
```

Even though Fizzy accepts flat JSON for many endpoints, the client should choose one consistent nested shape for facade-generated write payloads.

## Query params

The low-level request layer must support:
- scalars
- arrays, encoded in Rails-style form for query strings where needed
- `page`

No special pagination abstraction is required.

## Time values

Callers should pass ISO 8601 strings or `Time`/`DateTime` objects. If objects are passed, the client should serialize them to ISO 8601.

---

# Public API surface

## Low-level entrypoint

```ruby
client.request(
  method:,
  path:,
  params: nil,
  query: nil,
  headers: nil,
  body: nil
)
```

Purpose:
- escape hatch for endpoints not wrapped by facade methods
- used internally by facade methods

Rules:
- `path` should be an absolute API path such as `"/my/identity"`
- if `body` is a `Hash`, it is JSON-encoded before sending
- if `body` is a `String`, it is sent as-is
- `query` builds query string

---

# Facade methods

These methods should accept primitive Ruby values and return `Response`.

## Identity

### Get identity

```ruby
client.get_identity
```

Maps to:
- `GET /my/identity`

---

## Boards

### List boards

```ruby
client.list_boards(page: nil)
```

### Get board

```ruby
client.get_board(board_id:)
```

### Create board

```ruby
client.create_board(
  name:,
  all_access: nil,
  auto_postpone_period_in_days: nil,
  public_description: nil
)
```

### Update board

```ruby
client.update_board(
  board_id:,
  name: nil,
  all_access: nil,
  auto_postpone_period_in_days: nil,
  public_description: nil
)
```

### Delete board

```ruby
client.delete_board(board_id:)
```

---

## Columns

### List columns

```ruby
client.list_columns(board_id:)
```

### Get column

```ruby
client.get_column(board_id:, column_id:)
```

### Create column

```ruby
client.create_column(board_id:, name:, color: nil)
```

### Update column

```ruby
client.update_column(board_id:, column_id:, name: nil, color: nil)
```

### Delete column

```ruby
client.delete_column(board_id:, column_id:)
```

---

## Cards

### List cards

```ruby
client.list_cards(
  page: nil,
  board_ids: nil,
  tag_ids: nil,
  assignee_ids: nil,
  creator_ids: nil,
  closer_ids: nil,
  card_ids: nil,
  column_ids: nil,
  indexed_by: nil,
  sorted_by: nil,
  assignment_status: nil,
  creation: nil,
  closure: nil,
  terms: nil
)
```

Note:
- These filters come from current documented list behavior and should be passed through as query params.

### Get card

```ruby
client.get_card(card_number:)
```

### Create card

```ruby
client.create_card(
  board_id:,
  title:,
  description: nil,
  created_at: nil,
  last_active_at: nil
)
```

Code-truth note:
- do not expose `status` or `tag_ids` in the main facade unless confirmed in current controller params
- current code forces JSON-created cards to `published`

### Update card

```ruby
client.update_card(
  card_number:,
  title: nil,
  description: nil,
  created_at: nil,
  last_active_at: nil
)
```

### Delete card

```ruby
client.delete_card(card_number:)
```

### Move card to board

Useful for basic workflows.

```ruby
client.move_card_to_board(card_number:, board_id:)
```

### Move card to column

```ruby
client.triage_card(card_number:, column_id:)
```

### Return card to triage

```ruby
client.untriage_card(card_number:)
```

### Close card

```ruby
client.close_card(card_number:)
```

### Reopen card

```ruby
client.reopen_card(card_number:)
```

### Move card to not now

```ruby
client.move_card_to_not_now(card_number:)
```

Rationale:
- while not strict CRUD, these are basic state controls likely to matter in normal client usage.

---

## Comments

### List comments

```ruby
client.list_comments(card_number:, page: nil)
```

### Get comment

```ruby
client.get_comment(card_number:, comment_id:)
```

### Create comment

```ruby
client.create_comment(card_number:, body:, created_at: nil)
```

### Update comment

```ruby
client.update_comment(card_number:, comment_id:, body:, created_at: nil)
```

### Delete comment

```ruby
client.delete_comment(card_number:, comment_id:)
```

---

## Users

### List users

```ruby
client.list_users(page: nil)
```

### Get user

```ruby
client.get_user(user_id:)
```

### Update user

```ruby
client.update_user(user_id:, name: nil)
```

### Delete/deactivate user

```ruby
client.delete_user(user_id:)
```

Explicitly unsupported:
- `create_user`

Reason:
- current Fizzy API has no user create endpoint.

---

# Uploads and rich text attachments

## Goal

Support Fizzy direct uploads and rich text attachments as first-class client features.

## API methods

### Create direct upload

```ruby
client.create_direct_upload(
  filename:,
  byte_size:,
  checksum:,
  content_type:
)
```

Maps to:
- `POST /:account_slug/rails/active_storage/direct_uploads`

Expected payload:

```json
{
  "blob": {
    "filename": "example.png",
    "byte_size": 12345,
    "checksum": "BASE64_MD5",
    "content_type": "image/png"
  }
}
```

### Upload direct file bytes

```ruby
client.upload_direct_file(
  url:,
  headers:,
  io: nil,
  path: nil,
  bytes: nil
)
```

Behavior:
- uploads file bytes to the storage service URL returned by `create_direct_upload`
- uses the exact headers returned by Fizzy
- returns a normalized `Response`

Note:
- this request is to storage, not to the Fizzy JSON API
- `Request` and `Response` should still handle it cleanly
- response body may not be JSON

### Build rich text attachment tag

```ruby
client.build_rich_text_attachment(signed_id:)
```

Returns:

```html
<action-text-attachment sgid="..."></action-text-attachment>
```

### Upload attachment and build tag

```ruby
client.upload_attachment_and_build_tag(
  filename: nil,
  content_type: nil,
  io: nil,
  path: nil,
  bytes: nil
)
```

Behavior:
- determines byte size
- computes Base64-encoded MD5 checksum
- calls `create_direct_upload`
- uploads binary content
- returns a `Response` whose parsed body includes enough info to embed the uploaded file:

```ruby
{
  "signed_id" => "...",
  "attachment_html" => "<action-text-attachment sgid=\"...\"></action-text-attachment>",
  "filename" => "image.png",
  "content_type" => "image/png",
  "byte_size" => 12345
}
```

If any step fails:
- return a non-success `Response`
- include context showing which stage failed

### Append attachments to HTML

```ruby
client.append_attachments_to_html(html, attachments:)
```

Where `attachments:` may be an array of signed IDs, attachment HTML fragments, or hashes describing uploaded files.

Purpose:
- convenience helper for callers
- avoid requiring callers to handcraft ActionText markup

Expected behavior:
- preserve original HTML
- append one or more `<action-text-attachment>` tags
- optionally include filename labels if the caller asks for them

## Checksum requirements

The direct upload endpoint requires:
- Base64-encoded MD5 checksum of the file bytes

The client should include an internal helper for this.

## Binary source handling

Attachment helpers should support one of:
- `path:`
- `io:`
- `bytes:`

If insufficient input is provided, return a synthetic error `Response`.

---

---

# Error handling

## Principle

The client should not raise for ordinary API or network failures.

All outcomes should return a `Response`.

## HTTP failures

Examples:
- `401 Unauthorized`
- `403 Forbidden`
- `404 Not Found`
- `422 Unprocessable Entity`
- `500 Internal Server Error`

Behavior:
- return `Response`
- parse JSON error body when present
- preserve headers and raw body

## Network failures

Examples:
- timeout
- SSL error
- socket error
- invalid URI

Behavior:
- return synthetic `Response`
- no exception escapes normal request path

## Validation failures in convenience helpers

Examples:
- missing account slug
- missing bearer token
- no attachment bytes/path/io supplied
- unknown content type when required

Behavior:
- return synthetic `Response`
- `status` = `0`
- body should use the same simple shape:

```ruby
{
  "error" => "missing_account_slug",
  "message" => "This endpoint requires a configured account slug"
}
```

---

# Serialization rules

## Request body shape

Use nested payloads for object writes.

Examples:

### Create board

```json
{ "board": { "name": "Imported board" } }
```

### Create card

```json
{
  "card": {
    "title": "Imported issue",
    "description": "<p>Body</p>",
    "created_at": "2026-06-08T12:00:00Z"
  }
}
```

### Create comment

```json
{
  "comment": {
    "body": "<p>Imported comment</p>",
    "created_at": "2026-06-08T12:00:00Z"
  }
}
```

## Null handling

Facade methods should omit keys for `nil` optional values rather than sending explicit `null` unless required.

---

# Paths

## Unscoped

- `GET /my/identity`

## Account-scoped

- `/ :account_slug /boards`
- `/ :account_slug /boards/:board_id/columns`
- `/ :account_slug /cards`
- `/ :account_slug /cards/:card_number/comments`
- `/ :account_slug /users`
- `/ :account_slug /rails/active_storage/direct_uploads`

Implementation should generate these paths internally from client config and method arguments.

---

# Example usage

## Initialize client

```ruby
client = Fizzy::Client.new(
  base_url: "https://app.fizzy.do",
  bearer_token: ENV.fetch("FIZZY_TOKEN"),
  account_slug: "1234567"
)
```

## Create a card

```ruby
response = client.create_card(
  board_id: "03f...",
  title: "Client-generated issue",
  description: "<p>Original description</p>",
  created_at: "2026-06-08T12:00:00Z"
)

if response.success?
  card = response.body
else
  warn response.body.inspect
end
```

## Create a comment with preserved attachment

```ruby
upload = client.upload_attachment_and_build_tag(path: "/tmp/screenshot.png")

if upload.success?
  html = "<p>Attached file</p>#{upload.body.fetch("attachment_html")}"
  client.create_comment(card_number: 42, body: html)
end
```

---

# Design decisions

## Why a single vendorable file

- easy to audit
- easy to copy into small repos/scripts
- no packaging friction
- minimal dependency footprint

## Why Response objects instead of exceptions

- simpler batch operation control flow
- easier logging/reporting
- safer for long-running processes
- lets callers decide how to handle failures

## Why direct upload helpers belong in the client

- attachment support is a core client requirement
- direct upload flow is multi-step and easy to get wrong
- ActionText markup should not be hand-assembled repeatedly in caller code

## Why nested JSON despite flat JSON support

- predictable client implementation
- easier to reason about payload shapes
- still compatible with current server behavior

---

# Open implementation notes

These are not blockers for the PRD, but should be decided in implementation:

- small details of the internal `net/http` request code inside `Request`
- small details of header normalization in `Response`

---

# Testing strategy

## Approach

Testing should use real HTTP requests against a running local Fizzy development server.

Do not use VCR and do not fake server interactions.

Recommended default server target:
- `http://app.fizzy.localhost:3006`

This matches the repository's documented development setup.

## Test types

### Unit tests

Unit tests should cover logic that does not require a running server:
- `Response` parsing behavior
- JSON vs non-JSON body handling
- header normalization
- `success?`, `error?`, and `message`
- synthetic error responses for client-side validation failures
- synthetic error responses for network failures
- helper behavior such as rich text attachment tag generation
- helper behavior such as HTML attachment appending

These tests should not perform network calls.

### Live integration tests

Integration tests should run against the real local server and exercise the actual API over HTTP.

Coverage should include:
- bearer token authentication
- `get_identity`
- boards CRUD
- columns CRUD
- cards CRUD
- comments CRUD
- users list/get/update/delete
- direct upload creation
- direct upload binary PUT
- attachment helper flow that produces embeddable ActionText HTML
- low-level `client.request(...)` escape hatch

## Test environment requirements

The integration test suite should assume:
- the local Fizzy dev server is already running
- the local database and fixtures are in a usable state
- a valid bearer token is available for a test-capable user
- a valid account slug is available

Tests should derive stable auth/account values from repository helpers or hardcoded test constants rather than relying on external environment variables.

Suggested default base URL constant:
- `http://app.fizzy.localhost:3006`

If the server is unavailable, integration tests should fail fast with a clear message.

## Test framework

Recommended framework:
- Minitest, to match the repository's existing test style

Suggested test layout:
- unit tests for pure client logic in a focused client test file
- integration tests for live HTTP behavior in a separate file or section

Example paths:
- `test/lib/fizzy_client_test.rb`
- `test/integration/fizzy_client_integration_test.rb`

The implementation file should live at:
- `lib/fizzy_client.rb`

Exact file placement may vary, but the split between unit and live integration coverage should remain clear.

## Test data strategy

Integration tests may create, update, and delete real development data.

Guidelines:
- prefer creating dedicated test records during setup or inside each test
- use obvious names such as `Fizzy Client Test Board` to make cleanup easy
- clean up records when practical
- avoid depending on fragile incidental dev data
- fixture-backed users/accounts/tokens are acceptable if stable and easy to reference

For destructive operations:
- create the record first within the test
- then delete it as part of the scenario
- do not delete shared baseline data unless the test suite is designed to restore it

## Authentication test strategy

Use bearer-token authentication only.

Recommended coverage:
- successful request with valid bearer token
- failed request with invalid bearer token
- failed write with insufficient permissions if a read-only token is available

## Upload and attachment test strategy

Attachment preservation is a core requirement and must be tested live.

Recommended live test flow:
1. create a direct upload with file metadata
2. upload fixture bytes to the returned storage URL
3. generate `<action-text-attachment sgid="..."></action-text-attachment>`
4. create or update a card/comment using that HTML
5. verify the resulting response indicates attachments are present or the rich text contains the expected embedded structure

Test fixtures should include at least one small file under a normal fixtures directory.

Recommended fixture types:
- one small image
- optionally one small non-image file

## Failure-mode coverage

The test suite should explicitly verify that failures still return `Response` objects.

Required cases:
- HTTP `401`
- HTTP `404`
- HTTP `422` where practical
- connection failure to an invalid host or port
- missing account slug for account-scoped methods
- invalid attachment helper inputs such as missing `path`, `io`, and `bytes`

## Acceptance criteria for tests

The testing strategy is acceptable when:
- unit tests cover response normalization and helper logic
- integration tests exercise the real local API over HTTP
- no VCR or HTTP stubbing is required for primary API coverage
- attachment flow is tested end-to-end against the local server
- failures are verified to return `Response` objects instead of raising during normal request handling

# Acceptance criteria

The single-file client is acceptable when:

- it can authenticate with bearer token
- it can fetch `/my/identity`
- it can CRUD boards
- it can CRUD columns
- it can CRUD cards within current code-supported params
- it can CRUD comments
- it can list/get/update/delete users
- it can make a direct upload, upload file bytes, and produce embeddable attachment HTML
- all API and network failures return `Response` objects rather than raising
- `Client` remains cleanly separated from the internal `net/http` request/response code in `Request` and `Response`
- the API surface is suitable for callers that need direct uploads, rich text attachments, and the core supported endpoints
