# TinkerSwift Agent Guide

This file is the working contract for agents in this repository.

## Scope

- Build and maintain TinkerSwift as a macOS Swift/SwiftUI app.
- Prioritize PHP and Laravel project workflows.
- Treat this file and `README.md` as live, canonical docs.

## Architecture Rules

1. Keep app lifecycle and global wiring in `TinkerSwift/App`.
2. Keep shared protocols/contracts in `TinkerSwift/Core/Contracts`.
3. Keep shared helpers in `TinkerSwift/Core/Utilities`.
4. Keep user-facing behavior inside `TinkerSwift/Features/<FeatureName>`.
5. Keep integrations and infrastructure in `TinkerSwift/Services/<Domain>`.
6. Prefer composition and protocol boundaries over large objects.

## Change Routing

- Workspace behavior: `TinkerSwift/Features/Workspace`
- Editor behavior/UI: `TinkerSwift/Features/Editor`
- Execution flow/results: `TinkerSwift/Features/Execution`
- Project navigation/sidebar: `TinkerSwift/Features/Projects`
- Settings UI/state: `TinkerSwift/Features/Settings`
- PHP completion/LSP services: `TinkerSwift/Services/LSP`
- Persistence implementations: `TinkerSwift/Services/Persistence`
- Process/environment utilities: `TinkerSwift/Services/Environment`

## Guardrails

- Do not reintroduce the removed custom debug console subsystem.
- Keep LSP optional and fail-soft; editor/execution should still work without it.
- Avoid cross-feature circular dependencies.
- Do not duplicate contracts in feature folders.

## Validation

Run when changing Swift source:

```bash
xcodegen generate
xcodebuild -project TinkerSwift.xcodeproj -scheme TinkerSwift -configuration Debug -derivedDataPath .build-xcode build
```

## Git Safety

- Do not reset or revert unrelated user changes.
- Keep diffs focused and small.
- Prefer root-cause fixes over tactical patches.

