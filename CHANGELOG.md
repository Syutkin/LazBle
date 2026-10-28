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
- Replace injected C-driver tests with upstream PLAIN integration. Core, sync,
  reconnect and LCL contracts remain under migration in stages 3–4.

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
