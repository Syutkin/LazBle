# Changelog

## [Unreleased]

Changes for LazBle **2.0.0**, including breaking API and dependency changes.

### Added

- `LazBleGetAbout` and `DiagnosticInfo` for package, binding, backend, native
  version, adapter, and availability information. Reading diagnostics does not
  start BLE operations. Custom backends provide identity through
  `ILazBleBackend.GetBackendName`.
- Named negative LazBle error codes, distinct from native error ordinals.
- `TLazBleBackendEvent.ShutdownFailed` so custom backends can report cleanup
  failure independently of the error code and message.
- `TLazBleComponent.ShutdownAsync` to observe asynchronous cleanup, and
  `TLazBleLclClient.OnUnconfigureClient` to release borrowed client/profile
  references before detachment or removal.

### Changed

- Use the public SimpleDelphiBLE **1.3.0** API and its matching native libraries.
  Upstream owns adapters and peripherals; its main-thread events drive the
  backend, while one command worker performs blocking BLE calls.
- Require main-thread access to the API, state, handler registration, and object
  lifetime, including for custom backends. Reconnect actions and LCL callbacks
  run on that thread; LCL no longer queues a second delivery of each event.
- Use upstream GATT records, boolean characteristic capabilities, and UUID
  strings for descriptors. Managed GATT/data snapshots are read-only by
  contract, without automatic deep copies; submitted write buffers are copied.
- Treat cancellation as a request. Queued work can be skipped, but started
  native calls retain their actual success/failure and effects. Cancelling
  connection or profile attachment does not trigger a rollback Disconnect.
- Deliver notifications only after subscription readiness. Unsubscribe closes
  local delivery immediately and waits for pending Notify cleanup; native
  failure leaves the token inactive and disconnects the affected session.
  Explicit Disconnect and Unsubscribe cleanup continue after cancellation.
- Require completed `ShutdownAsync` before freeing active facade/LCL owners.
  Shutdown drains accepted work and stops the worker before completion; cleanup
  failure is returned to the caller. A new default backend can be used after
  the previous owner has completed cleanup and been released.
- Make `TLazBleSync` pump `CheckSynchronize`. Its deadline limits waiting and
  does not cancel the operation or replace its eventual result.
- Keep console example callbacks running while waiting for input. The LCL demo
  defers form closure until asynchronous shutdown completes.
- Require native libraries at link time and process startup, including for
  executables using a fake/custom backend. Compile the official SimpleDelphiBLE
  sources directly from a locally downloaded distribution in `simpledelphible/`,
  which is entirely ignored by Git. Configure target-specific native link paths
  without an auxiliary binding package, including macOS Intel and Apple Silicon.
- Align core, LCL, and design package versions with unreleased LazBle 2.0.0.

### Removed

- Dependency on SimpleBlePascal, the internal C-driver abstraction, custom
  native loader and `SIMPLECBLE_LIBRARY_DIR` lookup, and separate event worker.
- `IBleOperation.Timeout`, `lbopTimedOut`, and `lblssTimedOut`. Scan duration
  remains supported and normally completes the scan successfully.
- Legacy loader diagnostics: `MinimumNativeVersion`, `LoadWarning`,
  `WarningMessage`, and `BackendWarning`. Use `BindingName`/`BindingVersion`
  and the native version reported by an availability check.
- `LazBleLclDispatch` and its cloned event messages.
- Obsolete fppkg metadata (`fpmake.pp` and `manifest.xml`).

### Fixed

- Preserve backend/native error codes and messages through session operations
  and shutdown, including failures with code 0 and empty text.
- Cancel pending session operations safely when cancellation removes entries
  from the operation list.
- Keep accepted GATT command results after connection loss/reconnect without
  applying an old unsubscribe failure to a new session.
- Handle reentrant async actions and client/handler removal during callbacks.
  A Disconnect or shutdown from the Connecting handler prevents a Connect
  that has not yet been submitted.

## [1.0.0] - 2026-08-12

### Added

- Asynchronous BLE Central and GATT client API.
- SimpleBLE backend.
- GATT operations, byte channels, NUS, and Battery profiles.
- Optional reconnect policy and synchronous facade.
- LCL components, device selection, localization, and examples.

### Changed

- Target SimpleBlePascal and SimpleCBLE 1.1.0.

[1.0.0]: https://github.com/Syutkin/LazBle/releases/tag/v1.0.0
