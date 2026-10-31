# LazBle

LazBle is an asynchronous BLE Central and GATT client library for
Free Pascal and Lazarus. It provides device discovery, connections, GATT
and descriptor operations, notifications and indications, typed profiles,
optional reconnection, and LCL controls.

LazBle uses [SimpleDelphiBLE](https://github.com/simpleble/simpledelphible)
to communicate with Bluetooth devices.
API access and callbacks run on the main thread.

## Packages and components

| Package | Purpose |
| --- | --- |
| `lazble.lpk` | Core library, SimpleDelphiBLE backend, NUS and Battery profiles; no LCL dependency |
| `lazblelcl.lpk` | LCL components, device picker, and translations |
| `lazblelcldesign.lpk` | Design-time registration on the Lazarus component palette |

The main types are:

- `TLazBle`: device discovery, availability checks, client ownership, and shutdown.
- `TBleClient`: one device, its connection, profiles, and reconnect policy.
- `TBleGattSession`: shared GATT access for a client's operations and profiles.
- `TBleGattProfile`: base class for typed profiles.
- `TBleByteChannel`: reusable Write/Notify byte channel.
- `TNusProfile`: Nordic UART Service, with RX writes and TX notifications.
- `TBleBatteryProfile`: typed Battery Service 1.1 data, reads, and updates.
- `TLazBleSync`: blocking facade for console applications.
- `TLazBleComponent`: LCL facade owner, availability checks, and scan controller.
- `TLazBleLclClient`: persistent LCL wrapper for a selected device.
- `TBleDeviceSelectForm`: modal device picker using an existing scan controller.

## Dependencies and native libraries

Use Free Pascal 3.2.2 or later and, for LCL components, Lazarus. LazBle
requires the SimpleDelphiBLE 1.3.1 API. Use the official
[1.3.1-dev.25 distribution](https://github.com/simpleble/simpledelphible/releases/tag/v1.3.1-dev.25)
supplied separately from LazBle.

Extract it to a convenient directory. The commands below use this layout:

```text
workspace/
  lazble/
    lazble.lpk
  simpledelphible/           # official distribution
    SimpleDelphiBLEPackage.lpk
    LICENSE.md
    source/
    lib/
      linux-x64/
      win64/
      macos-x64/
      macos-arm64/
      ...
```

Run commands from `lazble/` unless another directory is specified.

| Supported target | Distribution directory | Runtime file |
| --- | --- | --- |
| Linux x86_64 | `lib/linux-x64` | `libsimplecble.so` |
| Windows x86_64 | `lib/win64` | `simplecble.dll` |
| macOS 15.0+ Intel x86_64 | `lib/macos-x64` | `libsimplecble.dylib` |
| macOS 15.0+ Apple Silicon (aarch64) | `lib/macos-arm64` | `libsimplecble.dylib` |

Deploy the matching runtime file beside the executable. For a macOS app bundle,
use `MyApp.app/Contents/MacOS`. With no explicit path, SimpleDelphiBLE first
looks in the executable's directory, then uses the system library search.
On Linux, the runtime can instead be installed in a directory visible to the
system dynamic loader, or supplied through `LD_LIBRARY_PATH`.

To select a runtime file or existing directory, set `TLazBle.LibraryPath`
from the `LazBleFacade` unit on the main thread, before starting BLE operations:

```pascal
TLazBle.LibraryPath := '/path/to/native';
```

The setting applies to the whole process. An empty string enables the
executable/system search. Reading or setting the property does not load the
runtime; changing it after loading does not switch the loaded library.

The runtime loads on the first native call. Building, starting the application,
creating the facade or LCL components, and reading package information or
diagnostics do not require it. A missing runtime fails the BLE operation with
`LazBleErrorBackendUnavailable`; an availability check also stores the reason in
`DiagnosticInfo.AvailabilityErrorMessage`. Checking availability includes adapter
selection and power status, not just library loading.

The application needs [Bluetooth permission](https://docs.simpleble.org/fundamentals/permissions).

### Lazarus

`LazBle` depends on the official `SimpleDelphiBLEPackage` runtime package.
Register that package before the LazBle packages:

```sh
lazbuild --ws=qt6 --add-package-link ../simpledelphible/SimpleDelphiBLEPackage.lpk
lazbuild --ws=qt6 --add-package-link lazble.lpk
lazbuild --ws=qt6 --add-package-link lazblelcl.lpk
lazbuild --ws=qt6 lazble.lpk
lazbuild --ws=qt6 lazblelcl.lpk
```

Add `LazBle` to your project's required packages, and `LazBleLCL` when using
components or controls. Deploy the matching runtime file to the executable's
output directory; `lazbuild` does not copy it.

To install the components on the Lazarus palette, open `lazblelcldesign.lpk`
and choose **Use > Install**. Lazarus rebuilds its IDE executable with the design
package. Opening the IDE and using the component palette do not require the
native runtime; it is needed when the IDE process itself performs BLE work.

### Direct FPC use

Add `src/core`, `src/backends`, and `src/profiles` to `-Fu`. Add the official
`../simpledelphible/source` directory to both `-Fu` and `-Fi`. Native linker paths
and rpath options are not required. Keep compiled units for different targets
in separate `-FU` directories. Unix console programs must include `cthreads`
first in their uses clause.

## Console usage

This program scans, connects to a NUS device, waits for profile readiness,
sends one byte, and completes shutdown before releasing the facade. Pass the
device ID as its command-line argument.

```pascal
program NusExample;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils,
  LazBleTypes, LazBleOperation, LazBleClient, LazBleFacade, LazBleNus;

procedure Await(const Operation: IBleOperation);
begin
  while Operation.State = lbopPending do
    CheckSynchronize(10);
  if Operation.State <> lbopSucceeded then
    raise Exception.CreateFmt('BLE operation failed (%d): %s',
      [Operation.ErrorCode, Operation.ErrorMessage]);
end;

var
  Ble: TLazBle;
  Client: TBleClient;
  Nus: TNusProfile;
  Operation: IBleOperation;
  Value: TBytes;
begin
  if ParamCount <> 1 then
    raise Exception.Create('Usage: NusExample DEVICE_ID');

  Ble := TLazBle.Create;
  try
    Await(Ble.ScanAsync('', 5000));
    Client := Ble.CreateClient(ParamStr(1));
    Nus := TNusProfile.Create;
    Client.AddProfile(Nus);
    Await(Client.ConnectAsync);

    SetLength(Value, 1);
    Value[0] := 1;
    Await(Nus.SendAsync(Value));
  finally
    Operation := Ble.ShutdownAsync;
    while Operation.State = lbopPending do
      CheckSynchronize(10);
    if Operation.State = lbopFailed then
      WriteLn(StdErr, 'BLE shutdown failed: ', Operation.ErrorMessage);
    Ble.Free;
  end;
end.
```

Use asynchronous operations in GUI applications and callbacks. `TLazBleSync`
provides console methods for Scan, Connect, Disconnect, and Shutdown. It pumps
`CheckSynchronize` while waiting. A wait deadline returns False with an error
message; the BLE operation can still be running and keeps its eventual result.

## Operations, discovery, and ownership

Asynchronous requests return reference-counted operation interfaces. A request
that cannot start returns an operation in `lbopFailed`. Keep the interface while
observing its state, result, or `OnCompleted` handler. Assigning `OnCompleted`
after completion invokes it immediately. Do not call `Free` on operation or
subscription interfaces.

Repeated `ScanAsync` or `CheckAvailabilityAsync` calls return the current
operation while it is pending. A scan and an availability check cannot run
at the same time; the competing request fails. GATT requests can still be
queued during a scan. Completion handlers see updated diagnostics and can
start the next scan or availability check.

`CheckAvailabilityAsync(AdapterId)` explicitly checks Bluetooth availability.
On success, `IBleAvailabilityOperation.Availability` is `lbaAvailable` or
`lbaUnavailable`; a failed check carries an error code and message. Creating a
facade or loading an LCL component does not enumerate adapters or start a scan.

`ScanAsync(AdapterId, DurationMs)` returns `IBleScanOperation`. `OnResult` reports
new and updated discoveries; `Results` contains deduplicated device snapshots
in discovery order. Installing a result handler does not replay earlier results.
Reaching the scan duration normally completes the scan successfully. Duration 0
keeps scanning until cancellation or shutdown. Use the scan operation's `Cancel`
method to stop it and await `lbopCancelled` before starting another scan.

`ConnectAsync` uses a device known from an earlier scan, an existing
connection, or the paired-device list. An unknown DeviceId fails with
`LazBleErrorDeviceNotKnown`; Connect does not start a scan. Creating a client
only creates its local state. Scan explicitly before connecting an unknown
device, including one whose ID was restored from settings.

Use `CheckAvailabilityAsync` for adapter and power checks. GATT requests do not
perform a separate availability check.

`TLazBle` owns clients created by `CreateClient`. Device IDs must be unique
within a facade. After successful `AddProfile`, the client owns that profile.
Required profiles must be Ready before the client enters `lbcstReady`.
`Client.ConnectAsync` completes successfully only after connection, service
discovery, and readiness of those profiles.

Use `RemoveClient` to release a client in Disconnected or Error state.
Accepted GATT requests retain their results even after client removal.
Completed operations, scan snapshots, and inactive subscription tokens remain
readable after their client/session is released.

### GATT operations

`TBleClient` and `TBleGattSession` expose the same UUID-based requests:

| Request | Result |
| --- | --- |
| `ReadAsync(Service, Characteristic)` | `IBleGattOperation`, with bytes in `Value` |
| `WriteAsync(Service, Characteristic, Value, WriteMode)` | `IBleGattOperation`; `lbwmRequest` or `lbwmCommand` |
| `ReadDescriptorAsync(Service, Characteristic, Descriptor)` | `IBleGattOperation`, with bytes in `Value` |
| `WriteDescriptorAsync(Service, Characteristic, Descriptor, Value)` | `IBleGattOperation` |
| `SubscribeAsync(Service, Characteristic)` | `IBleSubscription` using Notify |
| `SubscribeAsync(Service, Characteristic, lbsmIndicate)` | `IBleSubscription` using Indicate |

Descriptor requests require a connected session and a descriptor present in the
discovered service tree. Subscriptions require a connected session, a discovered
characteristic, and `CanNotify` or `CanIndicate` for the selected mode. Missing
targets fail with `LazBleErrorGattNotFound`; unsupported subscription modes fail
with `LazBleErrorGattPropertyNotSupported`. UUID lookup is case-insensitive.

Notify is the default `TLazBleSubscriptionMode` (`lbsmNotify`); Indicate uses
`lbsmIndicate`. Both modes use the same `OnData`, readiness, and Unsubscribe
contracts. NUS uses Notify; Battery selects Notify or Indicate for each characteristic.

### Reconnection

Automatic reconnection after unexpected connection loss is optional and disabled
by default:

```pascal
Client.ReconnectOptions := TLazBleReconnectOptions.Create(1000, 30000, 5);
Client.AutoReconnect := True;
```

The retry delay doubles up to the configured maximum, with a limit on attempts.
An initial connection failure is not retried. Manual Disconnect, Shutdown, or
setting `AutoReconnect` to False stops a pending retry. Profiles detach on loss
and attach again after service discovery.

`TLazBleLclClient` exposes this policy through `AutoReconnect` and the nested
`ReconnectOptions` properties. Loading these properties from an `.lfm` does not
create a core client or start a connection.

## Threads and lifecycle

Create, use, and destroy LazBle objects on the main thread. This includes state
reads, handler registration, operation submission, cancellation, and profile
access. Callbacks also run on the main thread.

Console applications must service `CheckSynchronize`; LCL does this through
the GUI event loop. BLE operations run asynchronously.

Callbacks may start the next asynchronous operation. Do not run nested BLE waits
or free the owner inside its callback. Defer destruction with
`TThread.ForceQueue` or an owned LCL async call; `TThread.Queue` may execute
immediately when called from the main thread.

Complete `ShutdownAsync` before freeing an active facade or LCL owner. Shutdown
stops new application work, reconnect attempts, and subscription data delivery
and detaches profiles. It cancels requests that have not started, waits for
started operations, and cleans up subscriptions and connections.

The shutdown operation remains pending until accepted requests and cleanup
finish and all client sessions are closed. Clients and sessions remain readable
until their owner is freed. Repeated `ShutdownAsync` calls return the same
operation, including after failure. Its terminal result preserves the first
cleanup failure. A native call can delay shutdown until it returns; there is
no guaranteed cleanup deadline. Destruction before completed shutdown can block and abandons
pending logical results.

Use one active `TLazBle` instance at a time. Complete its shutdown and release
it before starting BLE work through another instance. Shutdown does not unload
the native library.

### Cancellation and subscriptions

`CancelRequested` records a request, not an operation outcome. Requests that
have not started can be skipped. A started native Connect/GATT call returns its
actual success or failure and retains its effects. Cancelling profile attachment does not undo
the connection. If discovery is cancelled after physical connection, the client
enters Error and explicit Disconnect remains available.

Notifications and indications are delivered only after successful subscription
readiness; early values are dropped. A characteristic can have one active
subscription per facade. Notifications queued before a reconnect cannot always
be distinguished from values received after it.

Unsubscribe immediately closes local delivery. With a pending Notify or Indicate,
cleanup waits for its outcome and unsubscribes if registration succeeds. A failed
Unsubscribe preserves the error, leaves the token inactive, and disconnects the
affected session; configured reconnection may then run. Unsubscribe and explicit
Disconnect cleanup continue after a cancellation request.

Accepted GATT commands keep their actual results across connection loss and
orderly shutdown. Their results do not reactivate closed subscriptions or apply
an old unsubscribe failure to a new session.

### Data and errors

GATT data uses `TLazBleGattService` and `TLazBleGattCharacteristic` from
`LazBleTypes`. Use `CanRead`, `CanWriteRequest`, `CanWriteCommand`, `CanNotify`,
and `CanIndicate`; descriptors are UnicodeString UUIDs.

Services, nested arrays, read values, and subscription payloads are managed
snapshots treated as read-only. Explicitly copy arrays you need to change.
Write requests copy the supplied buffer when submitted.

Inspect operation State to determine success or failure. Native error code 0
and empty error text can represent a failure. Named negative error codes in
`LazBleTypes` identify LazBle errors.

`TLazBle.Info` provides static package Name, Version, and About text.
`DiagnosticInfo` reports the backend, native version, adapter, availability,
and latest availability-check error. Reading it starts no BLE work.

## LCL integration

Assign `LazBle` and `DeviceId` on `TLazBleLclClient`, then configure profiles in
`OnConfigureClient`. The underlying core client is created on demand.
`OnUnconfigureClient` runs while that client and its profiles are still alive,
before replacement, root shutdown, or detachment. Clear profile callbacks and
release borrowed references there; do not start BLE work or free the owner in
that handler.

`TLazBleComponent.RefreshAvailability` publishes availability changes through
`OnAvailabilityChanged`. Scanning uses the component's AdapterId and
ScanTimeoutMs, with state/result/completion events delivered directly on the
main thread.

`TLazBleComponent.ShutdownAsync` returns the same operation on repeated calls.
`Shutdown` starts that cleanup without returning its operation. In a form's
`OnCloseQuery`, start shutdown, retain the operation, and defer closure while
it is pending. Its completion handler schedules `Close` using
`Application.QueueAsyncCall`. Remove owned queued calls in the destructor.
See the [LCL demo](examples/lcl/lazblelcldemoform.pas) for the complete pattern.

### Device selection

`TBleDeviceSelectForm` uses an existing scan controller and returns a selected
device snapshot:

```pascal
Dialog := TBleDeviceSelectForm.Create(nil, LazBleComponent.ScanController);
try
  Dialog.AdapterId := LazBleComponent.AdapterId;
  Dialog.ScanTimeoutMs := LazBleComponent.ScanTimeoutMs;
  if Dialog.Execute(Device) then
    LazBleClient.SelectDevice(Device);
finally
  Dialog.Free;
end;
```

The picker keeps discovery order and updates matching rows.

The [LCL demo](examples/lcl/lazblelcldemoform.pas) shows how to build device
selection, connection actions, and status display using `TLazBleLclClient`.

### Translations

The `languages` directory contains catalogues for the device picker. Load them
after choosing the application language and before creating controls:

```pascal
TranslateLazBleLclResourceStrings('languages', Language, FallbackLanguage);
```

Deploy the `.po` files with the application. Building `lazblelcl.lpk` updates the
`.pot` templates through Lazarus package i18n support.

## Battery profile

`TBleBatteryProfile` supports one Battery Service instance, including the
additional characteristics in [BAS 1.1](https://www.bluetooth.com/specifications/specs/battery-service/).
Add it to a client before connecting:

```pascal
Battery := TBleBatteryProfile.Create;
Battery.OnLevelChanged := @BatteryLevelChanged;
Battery.OnUpdated := @BatteryUpdated;
Client.AddProfile(Battery, False);
```

`LevelPercent` is 0..100 or `UnknownBatteryLevel` before a reading, after detachment,
or when Battery Level Status reports removal. `OnLevelChanged` reports changed,
known percentages. `OnUpdated` reports every accepted read or update, including
repeated values; assigning a handler does not replay previous data.

`AvailableCharacteristics` lists the discovered characteristics. `Data` returns
a read-only snapshot:

| Property in `Data` | Contents |
| --- | --- |
| `LevelStatus` | Presence, external power, charging state, faults, and additional status |
| `CriticalStatus` | Critical power and immediate service requirements |
| `EnergyStatus` | Power in W, voltage in V, energy and capacity in kWh |
| `TimeStatus` | Discharge and recharge estimates in minutes |
| `HealthStatus` | Health percentage, cycles, temperature in °C, and deep discharges |
| `HealthInformation` | Designed cycle count and operating temperature limits |
| `Information` | Battery features, chemistry, dates, capacity, and nominal voltage |
| `ServiceDaysSince1970` | Estimated service date in UTC days since 1970-01-01 |
| `ManufacturerName`, `ModelNumber`, `SerialNumber` | UTF-8 battery identity strings |

Check `HasValue` and the applicable `Has...` flags before using record fields.
Numeric `TBleBatteryValue` fields use `State`: absent, finite, unknown,
greater/less than a bound, NaN, not at resolution, or positive/negative infinity.
`Value` is meaningful for finite values and bounds. Manufacture and expiration
dates also use UTC days since 1970-01-01.

```pascal
Snapshot := Battery.Data;
if Snapshot.EnergyStatus.PresentVoltageVolts.State = bbvsFinite then
  WriteLn(Snapshot.EnergyStatus.PresentVoltageVolts.Value:0:3, ' V');

RefreshOperation := Battery.RefreshAsync;
RefreshOperation.OnCompleted := @BatteryRefreshCompleted;
```

A Read-only Battery Level reaches `Ready` without a subscription. `RefreshAsync`
reads the available data again without resubscribing; retain its `IBleOperation`
to observe the result. A concurrent refresh fails as busy. Cancellation does not
undo values already read. There is no automatic polling.

Optional characteristics may be absent. Errors from discovered characteristics
are profile errors. `Ready` means initial setup completed; reads whose values have
no meaning while the battery is absent are skipped.
Partial updates retain previously received fields where applicable; removal
invalidates battery-specific data, and insertion starts a fresh read.
Recharge estimates become absent when charging no longer applies. Characteristics
arrive separately, so the snapshot is not a simultaneous measurement of all fields.

## Custom profiles

Derive a profile from `TBleGattProfile`. Use its protected Session for GATT
operations; start work in `DoAttach`, report readiness with
`MarkReady` or failure with `MarkError`, and release callbacks/subscriptions in
`DoDetach`. Register profiles through `TBleClient.AddProfile` before connecting.

## Examples

| Example | Purpose |
| --- | --- |
| [blescan](examples/blescan.lpr) | Discover devices and display scan results |
| [gattinspect](examples/gattinspect.lpr) | Inspect services and characteristics |
| [nusterminal](examples/nusterminal.lpr) | Send and receive NUS bytes with interactive input |
| [batterymonitor](examples/batterymonitor.lpr) | Read Battery Service 1.1 data, monitor updates, and refresh with `r` |
| [LCL demo](examples/lcl/lazblelcldemo.lpi) | Select a device, connect, and close asynchronously |

Build examples with their `.lpi` projects, for example:

```sh
lazbuild --ws=qt6 examples/nusterminal.lpi
lazbuild --ws=qt6 examples/lcl/lazblelcldemo.lpi
```

Console and LCL example executables are written to `examples/bin`; deploy the
native runtime there or use the loader search described above. Interactive
console input continues servicing callbacks while waiting for a line, including
partial input and EOF.

For test build and run instructions, see [tests/README.md](tests/README.md).

## License

LazBle uses the [MIT License](LICENSE). SimpleDelphiBLE and its native libraries
retain their own licenses; include the distribution's license with deployed
runtime files.
