# recapi for Swift

The recapi client for Swift 6: iOS 15+, macOS 12+, tvOS, watchOS and Linux
servers (Vapor, Hummingbird). Foundation only (URLSession, JSONEncoder): it adds
no dependency to an app. It keeps each user's decayed history, attributes
clicks to the recommendation that showed the item, restores a user's stored
history from recapi, and falls back to popular items when recapi can't answer
in time. It passes the shared vectors in `spec/`, like the other libraries.

Tracked events go out in the background: within 2 s (`flushInterval:`), a
full batch of 1,000 at once, retried 3 times with backoff (Retry-After
honoured) and kept through an outage (the sender then waits up to a minute;
the oldest go once 10,000 wait). Call `await recapi.close()` when a server
shuts down, and `try await recapi.flush()` when an app goes to the background
(iOS may suspend it before the next send).

## Install

Add the package from its public git repository (production releases push
each version there, and the Swift Package Index lists it) to your
`Package.swift`:

```swift
dependencies: [.package(url: "https://github.com/Blushedface/recapi-swift.git", from: "0.1.5")],
targets: [.target(name: "App", dependencies: [.product(name: "Recapi", package: "recapi-swift")])]
```

In Xcode: File > Add Package Dependencies, and paste the same URL.

On a Linux server, the library imports FoundationNetworking, which needs
libcurl at run time even with `--static-swift-stdlib`: in Vapor's standard
Dockerfile, uncomment `libcurl4` in the run image, or the server won't start.

Without access to GitHub, recapi's API serves the same package as a zip (the
dashboard's quick start shows the URL with your address). Unzip it into your
project:

```sh
curl -fLo recapi-swift.zip https://api.<your-domain>/sdk/swift/recapi-swift-0.1.5.zip
unzip -o recapi-swift.zip -d Vendor/Recapi
```

then use `.package(path: "Vendor/Recapi")` and `package: "Recapi"` above (in
Xcode: Add Local). Neither copy has the tests: they run from this repository,
against the shared vectors in `spec/`.

## Use

```swift
import Recapi

let recapi = try RecapiClient(apiKey: "rk_sec_...", baseURL: "https://api.recapi.io")

// An interaction: Level.view, .cart, .purchase, .reject, or -10...10.
try recapi.track(itemID: "sku-42", level: Level.view, userID: "user-7")

// Recommendations; a fallback list (recapi down) has no id.
let list = try await recapi.recommend(RecommendRequest(userID: "user-7", count: 4))
for item in list.items { print(item.itemID, item.metadata?["name"] ?? .null, item.why ?? "") }

// At login: the visitor's history and shown items become the user's. The user's
// first restore from recapi then leaves that visitor's browsing out, so it doesn't count twice.
try recapi.identify(anonID: "visitor-1", userID: "user-7")

let popular = try await recapi.popular(count: 10, tagsAny: ["shoes"])
_ = try await recapi.upsertItems([CatalogItem(itemID: "sku-42", tags: ["shoes"], metadata: ["name": .string("Red shoe")])])
try await recapi.deleteUser("user-7")

// At exit: sends what is queued, one try.
await recapi.close()
```

Every failure is a `RecapiError` with the API's `code` (`invalid_request`,
`rate_limited`, `quota_exceeded`...) or a client one (`network`, `timeout`,
`invalid_response`, `http_error`, `invalid_argument`), `status`, `retryAfter`
and `isRetryable`. Events lost for good (a refused batch, rejected events, a
full queue) print one `recapi: ...` line on stderr, from the background sender
as well as `flush()` and `close()`; failures that can still succeed print
nothing. A secret key restores a user's stored history; an app on a
device uses a public key (`rk_pub_...`), sent in the URL on GETs only.

`store:` takes any `RecapiStore` (get, set, delete strings): the default keeps
10,000 users in memory; a server with several processes passes a shared one
(Redis...), which should expire entries about 30 days after their last write,
or a Redis keeps them for ever. The stored JSON is the other server libraries', so they can share it.

**In an app**, pass a `FileStore()`: iOS ends apps in the background, and an
app's public key can't restore a visitor's history from recapi, so with the
in-memory default every launch would start with popular lists and forget the
recommendations the visitor was shown. `FileStore` keeps each visitor's state
in a small file in Application Support/recapi (another folder:
`FileStore(directory:)`), written on a background queue; `flush()` and
`close()` wait for it. Plain files: no UserDefaults, nothing to declare in
the app's privacy manifest.

```swift
let recapi = try RecapiClient(apiKey: "rk_pub_...", baseURL: "https://api.recapi.io", store: FileStore())
```

## Development

`./test.sh [filter]` builds with warnings as errors and runs the XCTest suite
(the shared vectors, wire-format tests), ~3 s once built. `scripts/swift.sh`
uses a local Swift 6, else fetches swift.org's toolchain once into
`~/.cache/recapi`. `make test` runs it.
