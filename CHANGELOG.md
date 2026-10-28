# Changelog

## [2.0.0] - 2026-10-28

See the [release notes](docs/releases/2.0.0.md) for upgrading from 1.0.0.

### Added

- Static package information through `TLazBle.Info`.
- Backend and availability diagnostics through `DiagnosticInfo`.
- `TLazBleComponent.ShutdownAsync` to await LCL cleanup.
- `TLazBleLclClient.OnUnconfigureClient` to release borrowed references.
- Error codes for adapter, backend, native data, and profile failures.
- Backend identity through `ILazBleBackend.GetBackendName`.
- Explicit cleanup failure reporting through `TLazBleBackendEvent.ShutdownFailed`.

### Changed

- Migrated from SimpleBlePascal to the official SimpleDelphiBLE 1.3.0 sources.
- API CHANGE: Native libraries are required at link time and process startup.
- API CHANGE: All API access and callbacks require the main thread.
- API CHANGE: GATT types use upstream records, capability booleans, and descriptor UUID strings.
- API CHANGE: Managed GATT and data snapshots are read-only.
- API CHANGE: Cancellation preserves the actual outcome and effects of started operations.
- API CHANGE: Active LCL owners require completed `ShutdownAsync` before destruction.
- `TLazBleSync` services `CheckSynchronize` and preserves operations after wait deadlines.
- Notification delivery starts after subscription readiness.
- Failed Unsubscribe cleanup leaves the token inactive and disconnects the session.

### Fixed

- Lost native failures when the error code is 0 or the message is empty.
- Lost accepted GATT results across connection loss and shutdown.
- Reentrant operations and client removal from callbacks.

### Removed

- Custom native loader and `SIMPLECBLE_LIBRARY_DIR` lookup.
- API CHANGE: `IBleOperation.Timeout`, `lbopTimedOut`, and `lblssTimedOut`.
- API CHANGE: Replaced `BackendInfo` and `TLazBleBackendInfo` with `DiagnosticInfo`.
- API CHANGE: Custom GATT property flags and `LazBleCopyGattServices`.
- `LazBleLclDispatch`.
- fppkg metadata.

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
