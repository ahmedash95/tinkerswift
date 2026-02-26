## 2024-05-22 - Memoization of ExecutionPresentation
**Learning:** Caching `ExecutionPresentation` prevents expensive re-parsing of `latestExecution` and re-creation of `AttributedString`s on every `ResultPaneView` update.
**Action:** When working with SwiftUI views that depend on expensive computations from `@Observable` state, memoize the computation in the state object if inputs are stable.
