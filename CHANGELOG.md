# Changelog

## [Unreleased]

### Changed

- Require SimpleBlePascal 1.2.0 for the SimpleCBLE 1.2.0 ABI.
- Read native error codes and messages from SimpleCBLE 1.2.0 `out_error`
  objects across adapter, scan, connection, and GATT operations.
- Copy native GATT services and read buffers into Pascal-owned data, release
  native allocations, and drain callbacks before shutdown frees their userdata.

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
