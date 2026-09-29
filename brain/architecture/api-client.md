# API client

`api.Client` wraps `std.http.Client` for one host: paths are relative to
`<scheme>://<host>/api/v1` unless absolute.

- **Auth**: `authorization: token <token>` (Forgejo takes access tokens and
  OAuth access tokens alike under that prefix) through the request's standard
  header override. Two std 0.16 behaviours shape this: `privileged_headers`
  are never sent at all, and the standard authorization header survives a
  redirect to any host. So std's redirect handling is off and `raw` follows
  301/302/307/308 itself, at most three times and only to the same scheme,
  host and port; a redirect elsewhere is refused.
- **Refresh**: `Client.init` renews a browser login's access token when it
  is within a minute of expiry (`oauth.refreshIfDue`) and saves the new pair.
- **Bodies**: JSON payloads are anonymous structs stringified with null
  optionals omitted. A method that carries a body always sends one, empty if
  need be (std asserts otherwise).
- **Errors**: `call` turns a non-2xx status into a message built from
  Forgejo's `{"message": ...}`; a 401 points at `smith auth login`. `raw`
  returns the status for callers that branch on it (merge's 405/409, auth's
  403).
- **Decoding**: responses are parsed into `std.json.Value` first; `--json`
  prints those as sent, and `api.decode` maps them onto the structs in
  `types.zig`, ignoring unknown fields.
- **Bodies read only when there is one**: HEAD, 204 and 304 answers carry
  none, and reading one anyway would wait on the kept-alive connection.
- **Pagination**: `listValues` requests `page`/`limit` (at most the host's
  `page_size`, 50 by default) until it has `limit` items or a page comes
  back short. A short first page on a host whose page size is unknown
  triggers one look at `/settings/api` before it is taken as the end.
  `field` unwraps endpoints that nest the array (`workflow_runs`).
  `/issues/{n}/comments` ignores paging and is read in one request.

## Sources

- `src/api.zig`
- `src/types.zig`
