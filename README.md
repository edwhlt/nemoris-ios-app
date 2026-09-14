# Nemoris

A personal finance app for iOS and macOS, written entirely in Swift and
SwiftUI. Everything runs on device: transactions live in a local SQLite file,
and nothing is sent to a server the user does not choose.

> The source is published as a reference — a complete, tested SwiftUI
> application rather than a product accepting contributions. Read it, borrow
> from it, fork it.

## What it does

- **Transactions** — accounts, payees, hierarchical categories, tags, free-form
  metadata, and reimbursement tracking.
- **Import** — CSV, XLSX, CAMT.053, OFX, PDF statements and screenshots. Bank
  labels are matched to merchants by an on-device engine; documents are read by
  a deterministic extractor, optionally assisted by an AI backend.
- **Budget** — envelopes per category, recurring pattern detection, forecasts.
- **Investments** — positions derived from orders, live sync with Binance and
  with Bitcoin, Ethereum-compatible and Solana wallets, market history charts.
- **AI coach** — two on-demand analyses (spending, investments) built from a
  structured briefing of the user's own numbers rather than a generic prompt,
  ranked and shown as cards, dismissible and re-editable.
- **Financial goals** — savings targets, debt payoff, free-form progress
  tracked against the current net worth.
- **Shared expenses** — split bills, per-member balances, settlements.
- **Net worth** — assets, real estate, loans, projections.
- **Tax report** — a French capital-gains and rental-income recap, pre-filled
  from transactions and investment orders.
- **Sync** — optional end-to-end encrypted CloudKit mirror across devices.

## Design decisions worth knowing

**No ORM.** SQLite is accessed through its C API. Schema changes go through a
numbered migration chain, replayed on launch.

**The device owns the data.** The local file is the source of truth. CloudKit
is a disposable mirror, rebuilt by turning sync off and on. Snapshots to iCloud
Drive are the safety net that survives an app deletion.

**AI is optional and per-feature.** Each feature that can use a model —
merchant identification, statement import, the coach — picks its own backend:
Apple Foundation Models, a local HTTP server (LM Studio, Ollama…), a model
downloaded once and run in-process (GGUF via llama.cpp, or MLX on Apple
Silicon), a cloud provider, or none. The app is fully usable with no AI at all.

**Pure engines.** The calculations that would be expensive to get wrong —
portfolio valuation, envelope spending, statement extraction, query planning,
the coach's briefing construction and response parsing — live in files that
import nothing but `Foundation`. They take their inputs as parameters instead
of reaching for a database or the network, which is what makes them testable.

## Building

Requires Xcode 16 or later. iOS 18 / macOS 14 minimum.

```bash
git clone https://github.com/edwhlt/nemoris-ios-app.git
cd nemoris-ios-app
open Nemoris.xcodeproj
```

The merchant identification engine (`../NemorisEngine`) is referenced as a
local Swift package and embeds an ONNX model, which makes the first build
slower than later ones. Two more remote packages (`swift-llama-cpp`,
`mlx-swift-lm`, plus `swift-transformers` for local tokenization) back the
optional in-process AI backend — they add to the first resolve but nothing
downloads a model until the user pastes a Hugging Face link in Settings.

A single target builds for both platforms — there is no separate macOS target.
Platform differences are absorbed by shims rather than by branching the code.

## Tests

```bash
# Unit and integration tests
xcodebuild test -scheme Nemoris -destination 'platform=iOS Simulator,name=iPhone 16'

# Import-boundary guard (a grep, not a compile — runs in well under a second)
./Tests/check_purity.sh

# Coverage, split by layer
./Tests/coverage.sh
```

**One test system, one lint.** Pure engines — the ones listed by
`check_purity.sh` — are tested directly inside the XCTest target (`NemorisTests/`,
mostly under `Engines/`), as `Testing` suites that `@testable import Nemoris`
and exercise the real production files. `check_purity.sh` doesn't run any of
that logic; it only greps each listed engine for a forbidden import
(`SwiftUI`, `PDFKit`, `CloudKit`…) so a pure file that starts reaching for the
UI, disk, or network breaks the check immediately, independently of whether
its tests still pass.

One harness sits outside the XCTest target on purpose:
`Tests/run_merchant_corpus_tests.sh` compiles the query-planning engines
standalone with `swiftc` and measures a *spectrum* — how many of 984 bank
labels the planner handles correctly — against a floor of 85 %. Its result
legitimately moves when extraction improves, so keeping it out of the
always-green suite preserves the signal instead of forcing a binary pass/fail
on a number that's meant to trend, not gate.

## Test data

`Tests/Fixtures/merchant_labels_corpus.json` holds 984 bank statement labels in
their real formats — that realism is the point, since the parser exists to cope
with them. The file is generated by `build_corpus.py`, which anonymises person
names, substitutes every numeric identifier, and replaces the place names and
organisations that would situate a particular person. Regenerating it from a
real statement cannot reintroduce any of that.

## Layout

```
Nemoris/
  App/            entry point, global state, root navigation
  Core/           database, sync, backup, shared models
  DesignSystem/   theme, reusable components, platform shims
  Features/<X>/
    Views/        SwiftUI — the only place that imports it
    Model/        domain types
    Service/      pure engines
    Data/         the feature's repository
NemorisTests/     XCTest suite (unit, integration, pure engines)
Tests/            purity lint, corpus spectrum harness, fixtures
```

`Views/` is the boundary: a file outside it that imports SwiftUI is a bug, and
CI checks for it.

## Language

Code comments are in English. The app's own interface is French-first (it
started as a personal tool before being open-sourced), so UI strings, prompts
sent to AI backends, and displayed error messages stay in French — comments
document the reasoning behind a decision for a reader of the source, and the
⚠️ marked ones record a trap already paid for: a regex that eats a newline, an
alignment that means something, an API whose parameter order is significant.

## License

MIT — see [LICENSE](LICENSE).
