import Testing

/// The parent suite for every test that goes through `StubURLProtocol`.
///
/// ⚠️ `.serialized` set on a suite only serializes ITS OWN tests —
/// two distinct suites run in parallel. But network interception is
/// process-global state: `start()` clears the table, so a suite that
/// starts wipes out the responses armed by another. Observed symptom: the
/// first test of each suite passes, every following one fails.
///
/// Grouping network suites UNDER this parent fixes the problem by
/// construction — the trait propagates to the whole descendant hierarchy, and a
/// future contributor needs to know nothing: they just need to nest their suite here.
@Suite("Réseau", .serialized)
struct NetworkSeam {}
