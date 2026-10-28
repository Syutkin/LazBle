# Changelog

## [2.0.0] - 2026-10-28

LazBle **2.0.0** moves from SimpleBlePascal to SimpleDelphiBLE 1.3.0.
See the [release notes](docs/releases/2.0.0.md) for upgrading from 1.0.0.

### Added

- `TLazBle.Info` for static package information and `DiagnosticInfo` for
  backend identity, native version, adapter, availability, and check errors.
- `TLazBleComponent.ShutdownAsync` and `TLazBleLclClient.OnUnconfigureClient`
  for asynchronous cleanup and releasing borrowed client/profile references.
- Additional named LazBle error codes, `ILazBleBackend.GetBackendName`, and
  `TLazBleBackendEvent.ShutdownFailed` for custom backends.

### Changed

- Compile official SimpleDelphiBLE sources from the local `simpledelphible/`
  directory. Native libraries are required at link time and process startup.
  Package paths cover Linux x86_64, Windows x86_64, and macOS Intel/Apple Silicon.
- Run all API access and callbacks on the main thread, including custom
  backends and reconnection. Console applications must service `CheckSynchronize`.
- Use upstream GATT records, boolean characteristic capabilities, and UUID
  strings for descriptors. Managed snapshots are read-only; write buffers
  are copied on submission.
- Preserve the actual outcome and effects of started operations after a
  cancellation request. Synchronous wait deadlines only limit waiting.
- Deliver notifications after subscription readiness. Failed Unsubscribe
  leaves the token inactive and disconnects the affected session; cleanup
  continues after cancellation.
- Complete `ShutdownAsync` before releasing active core or LCL owners.
  Shutdown drains work and reports cleanup failures.

### Removed

- SimpleBlePascal dependency, custom native loader, and
  `SIMPLECBLE_LIBRARY_DIR` lookup.
- `IBleOperation.Timeout`, `lbopTimedOut`, and `lblssTimedOut`. Scan duration
  remains supported and normally completes the scan successfully.
- `BackendInfo` and `TLazBleBackendInfo`; use `DiagnosticInfo`.
- `LazBleCopyGattServices`, the characteristic property enum, and
  `LazBleLclDispatch`.
- fppkg metadata (`fpmake.pp` and `manifest.xml`).

### Fixed

- Preserve native errors, including failures with code 0 or empty text, and
  accepted GATT results across connection loss and shutdown.
- Handle cancellation, new asynchronous actions, and client removal safely
  from callbacks.

## [1.0.0] - 2026-08-12

### Added

- Asynchronous BLE Central and GATT client API.
- SimpleBLE backend.
- GATT operations, byte channels, NUS, and Battery profiles.
- Optional reconnect policy and synchronous facade.
- LCL components, device selection, localization, and examples.

### Changed

- Target SimpleBlePascal and SimpleCBLE 1.1.0.

[2.0.0]: https://github.com/Syutkin/LazBle/releases/tag/v2.0.0
[1.0.0]: https://github.com/Syutkin/LazBle/releases/tag/v1.0.0
