# Changelog

## [Unreleased]

### Added

- Add `LazBleGetAbout` and `DiagnosticInfo` for library versions and BLE
  diagnostics. Reading the snapshot does not start BLE operations.

### Changed

- Backends now provide their name through `ILazBleBackend.GetBackendName`.
- Replace the internal C driver with the public SimpleDelphiBLE 1.3.0 API.
  Adapters and peripherals are borrowed from upstream; native events use
  `edMainThread`, blocking commands run on one worker, and completion uses RTL
  synchronization. Remove the old loader, driver interface, and event worker.
- Explicit shutdown detaches handlers, unsubscribes and disconnects on the
  worker, then joins it before completion. Allow a new backend after shutdown.
- Preserve actual outcomes of started native Connect/GATT calls instead of
  compensating successful effects after cancellation.
- Require matching native libraries before startup, including for fake-backend
  test executables. Remove obsolete fppkg metadata; use the Lazarus wrapper or
  direct FPC source/library paths.
- Adopt upstream GATT records/capability booleans and UnicodeString descriptors;
  remove the conversion layer and automatic deep copies. Snapshots are read-only.
- Make core, profiles, and custom backend delivery main-thread-only; remove their
  redundant locks and marshal reconnect timer actions once through RTL Queue.
- Remove `IBleOperation.Timeout` / `lbopTimedOut`. Cancellation preserves real
  command outcomes, including native error 0/empty text and old-generation GATT
  results after connection loss. Remove cancellation rollback Disconnect calls.
- Retire Unsubscribe delivery immediately and chain pending Notify cleanup without
  early success. Cleanup is not cancellable; a failed unsubscribe disconnects
  its session and preserves reconnect policy.
- Preserve accepted command results during shutdown and propagate cleanup failure
  with an explicit ShutdownFailed flag. Support the next async request from a
  completion callback and detach pending-operation callbacks on owner teardown.
- Move the TLazBleSync main-loop/deadline update forward from stage 4 because
  removing Timeout requires updating its wait semantics now.
- Deliver LCL and timing transport callbacks directly on the main thread; remove
  LazBleLclDispatch, its message clones, and the obsolete scan TimedOut state.
- Add TLazBleComponent.ShutdownAsync and OnUnconfigureClient. Await cleanup before
  freeing GUI owners and release borrowed profiles before core-client removal.
  The LCL demo uses asynchronous CloseQuery; console input services callbacks.
- Remove legacy loader diagnostics; expose BindingName = SimpleDelphiBLE and
  BindingVersion = 1.3.0. Align package metadata with unreleased LazBle 2.0.0.
- Replace injected C-driver tests with upstream PLAIN integration. Hardware,
  Windows runtime, clean-system/IDE verification and release remain for stage 5.

### Fixed

- Cancel pending session operations safely during shutdown when cancellation
  removes entries from the operation list.

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
