# LazBle

LazBle is an asynchronous BLE Central and GATT client library for
Free Pascal and Lazarus. It provides device discovery, connections, GATT
and descriptor operations, notifications and indications, typed profiles,
optional reconnection, and LCL controls.

The default backend uses the public Async API of
[SimpleDelphiBLE](https://github.com/simpleble/simpledelphible).
API access and callbacks run on the main thread.

## Packages and components

| Package | Purpose |
| --- | --- |
| `lazble.lpk` | Core library, SimpleDelphiBLE backend, NUS and Battery profiles; no LCL dependency |
| `lazblelcl.lpk` | LCL components, device picker, connection control, and translations |
| `lazblelcldesign.lpk` | Design-time registration on the Lazarus component palette |

The main types are:

- `TLazBle`: facade and lifetime owner of device clients.
- `TBleClient`: one device, its connection, profiles, and reconnect policy.
- `TBleGattSession`: shared GATT context for a client's operations and profiles.
- `TBleGattProfile`: base class for typed profiles.
- `TBleByteChannel`: reusable Write/Notify byte channel.
- `TNusProfile`: Nordic UART Service, with RX writes and TX notifications.
- `TBleBatteryProfile`: Battery Service, with an initial read and notifications.
- `TLazBleSync`: blocking facade for console applications.
- `ILazBleBackend`: asynchronous backend interface for custom implementations.
- `TLazBleComponent`: LCL facade owner, availability checks, and scan controller.
- `TLazBleLclClient`: persistent LCL wrapper for a selected device.
- `TBleDeviceSelectForm`: modal device picker using an existing scan controller.
- `TLazBleDeviceControl`: visual device selector and connection-status control.

## Dependencies and native libraries

Use Free Pascal 3.2.2 or later and, for LCL components, Lazarus. The default
backend requires the SimpleDelphiBLE 1.3.1 API. Use the official
[1.3.1-dev.25 distribution](https://github.com/simpleble/simpledelphible/releases/tag/v1.3.1-dev.25)
in `simpledelphible/`. This entire directory is local and ignored by Git,
including the upstream package, sources, native library, and licenses.

Extract the distribution and place its contents in LazBle's `simpledelphible`
directory:

```text
lazble/
  lazble.lpk
  simpledelphible/           # official release contents; entirely ignored by Git
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

| Supported target | Distribution directory | Runtime file |
| --- | --- | --- |
| Linux x86_64 | `simpledelphible/lib/linux-x64` | `libsimplecble.so` |
| Windows x86_64 | `simpledelphible/lib/win64` | `simplecble.dll` |
| macOS 15.0+ Intel x86_64 | `simpledelphible/lib/macos-x64` | `libsimplecble.dylib` |
| macOS 15.0+ Apple Silicon (aarch64) | `simpledelphible/lib/macos-arm64` | `libsimplecble.dylib` |

Deploy the matching runtime file beside the executable. For a macOS app bundle,
use `MyApp.app/Contents/MacOS`. With no explicit path, SimpleDelphiBLE first
looks in the executable's directory, then uses the system library search.
On Linux, the runtime can instead be installed in a directory visible to the
system dynamic loader, or supplied through `LD_LIBRARY_PATH`.

To select a file or directory explicitly, set `TSimpleDelphiBLE.LibraryPath`
from the `SimpleDelphiBLE` unit before the first native call:

```pascal
TSimpleDelphiBLE.LibraryPath := '/path/to/native';
```

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
lazbuild --ws=qt6 --add-package-link simpledelphible/SimpleDelphiBLEPackage.lpk
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
`simpledelphible/source` directory to both `-Fu` and `-Fi`. Native linker paths
and rpath options are not required. Keep compiled units for different targets
in separate `-FU` directories. Unix console programs must include `cthreads`
first in their uses clause.

## Console usage

This program connects to a NUS device, waits for profile readiness, sends one
byte, and completes shutdown before releasing the facade. Pass the device ID
as its command-line argument.

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

`TLazBle` owns clients created by `CreateClient`. Device IDs must be unique
within a facade. After successful `AddProfile`, the client owns that profile.
Required profiles must be Ready before the client enters `lbcstReady`.
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
contracts. NUS and Battery profiles use Notify.

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
access. Custom backends deliver callbacks on the main thread as well.

The default backend uses SimpleDelphiBLE Async methods and `edMainThread`
delivery. Commands run sequentially; only metadata and scan calls without an
upstream Async method use a LazBle background executor. Console applications
service `CheckSynchronize`; LCL services it through the GUI event loop. Scan
and reconnect timers deliver their actions on the main thread.

Callbacks may start the next asynchronous operation. Do not run nested BLE waits
or free the owner inside its callback. Defer destruction with
`TThread.ForceQueue` or an owned LCL async call; `TThread.Queue` may execute
immediately when called from the main thread.

Complete `ShutdownAsync` before freeing an active facade or LCL owner. Shutdown
stops new work and application callbacks, drains accepted commands, removes
handlers/subscriptions, and disconnects. It completes after pending command and
cleanup callbacks return. Inspect its terminal result for cleanup failures.
A native call can delay shutdown until it returns; there is no guaranteed
cleanup deadline. Destruction before completed shutdown can block and abandons
pending logical results.

Only one default backend may actively own the process-wide upstream objects at
a time. After orderly cleanup and release, another backend can use them. Do not
replace the same upstream handlers or change `EventDelivery` while LazBle owns
them. Adapters, peripherals, and the loaded runtime are owned by SimpleDelphiBLE;
LazBle shutdown does not unload the native library.

### Cancellation and subscriptions

`CancelRequested` records a request, not an operation outcome. Queued work can
be skipped. A started native Connect/GATT call returns its actual success or
failure and retains its effects. Cancelling profile attachment does not undo
the connection. If discovery is cancelled after physical connection, the client
enters Error and explicit Disconnect remains available.

Notifications and indications are delivered only after successful subscription
readiness; early values are dropped. A characteristic can have one active
subscription per default backend. Upstream queued events have no original session token, so
absolute attribution of notifications across reconnects is not guaranteed.

Unsubscribe immediately closes local delivery. With a pending Notify or Indicate,
cleanup waits for its outcome and unsubscribes if registration succeeds. A failed
Unsubscribe preserves the error, leaves the token inactive, and disconnects the
affected session; configured reconnection may then run. Unsubscribe and explicit
Disconnect cleanup continue after a cancellation request.

Accepted GATT commands keep their actual results across connection loss and
orderly shutdown. Their results do not reactivate closed subscriptions or apply
an old unsubscribe failure to a new session.

### Data and errors

GATT types in `LazBleTypes` alias upstream `TBleService` and `TBleCharacteristic`.
Use `CanRead`, `CanWriteRequest`, `CanWriteCommand`, `CanNotify`, and `CanIndicate`;
descriptors are UnicodeString UUIDs.

Services, nested arrays, read values, and subscription payloads are managed
snapshots treated as read-only. Explicitly copy arrays you need to change.
The backend copies a write buffer when submitting its command.

Inspect operation State to determine success or failure. Native error code 0
and empty error text can represent a failure. Named negative error codes in
`LazBleTypes` identify LazBle errors. Custom backends set `ShutdownFailed` on
failed `lbekShutdownCompleted` events independently of their error code/message.

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

### Device selection and controls

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

The picker keeps discovery order and updates matching rows. It temporarily
chains scan handlers and restores them when released.

Bind `TLazBleDeviceControl.Client` to an existing LCL client to display its
device, status, and connection actions. `ShowSelectButton` and
`ShowConnectionButton` control visibility. Button captions are configurable;
`OnSelectButtonClick` and `OnConnectionButtonClick` override the built-in actions.
Custom handlers may call `SelectDevice` or `ToggleConnection` explicitly.
Binding or streaming a control does not start BLE work.

### Translations

The `languages` directory contains separate catalogues for
`LazBleDeviceSelectForm` and `LazBleDeviceControl`. Load them after choosing the
application language and before creating controls:

```pascal
TranslateLazBleLclResourceStrings('languages', Language, FallbackLanguage);
```

Deploy the `.po` files with the application. Building `lazblelcl.lpk` updates the
`.pot` templates through Lazarus package i18n support.

## Custom profiles and backends

Derive a profile from `TBleGattProfile`. Use its protected Session for GATT
operations; start work in `DoAttach`, report readiness with
`MarkReady` or failure with `MarkError`, and release callbacks/subscriptions in
`DoDetach`. Register profiles through `TBleClient.AddProfile` before connecting.

To provide a backend, implement `ILazBleBackend` and inject it into the facade:

```pascal
Backend := TMyBleBackend.Create;
Ble := TLazBle.Create(Backend);
```

Submit and BeginShutdown must return before delivering their corresponding
events. Each accepted command produces exactly one terminal event. BeginShutdown
drains pending work, reports cleanup failures with ShutdownFailed, and ends
backend event delivery. Custom backends also copy submitted write buffers and
honour the main-thread contract.

Descriptor commands use `lbckReadDescriptor` or `lbckWriteDescriptor` and the
`DescriptorUuid` field. Reuse `lbekReadResult` or `lbekWriteCompleted` before the
terminal event. For `lbckSubscribe`, honour `SubscriptionMode` (`lbsmNotify` or
`lbsmIndicate`) and use the same subscription and notification events for either
mode.

Application-facing units are `LazBleTypes`, `LazBleBackend`, `LazBleOperation`,
`LazBleGattOperation`, `LazBleGattSubscription`, `LazBleGattSession`,
`LazBleGattProfile`, `LazBleByteChannel`, `LazBleClient`, `LazBleFacade`,
`LazBleSync`, `LazBleNus`, `LazBleBattery`, and `LazBleSimpleBleBackend`.

## Examples and tests

| Example | Purpose |
| --- | --- |
| [blescan](examples/blescan.lpr) | Discover devices and display scan results |
| [gattinspect](examples/gattinspect.lpr) | Inspect services and characteristics |
| [nusterminal](examples/nusterminal.lpr) | Send and receive NUS bytes with interactive input |
| [batterymonitor](examples/batterymonitor.lpr) | Read and monitor Battery Level |
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

The core/profile/backend suite is in `tests/lazbletests.lpr`. Its native backend
tests use the real SimpleDelphiBLE bindings with the upstream PLAIN implementation.
Keep that runtime separate from production libraries. Build PLAIN from the
SimpleBLE source revision identified in the binding release's description.
For example, on Linux:

```sh
cmake -S /path/to/simpleble/simplecble -B /path/to/plain-build \
  -DSIMPLEBLE_PLAIN=ON -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON -DCMAKE_INSTALL_LIBDIR=lib
cmake --build /path/to/plain-build --config Release --parallel 4
cmake --install /path/to/plain-build --config Release --prefix /path/to/plain-runtime
```

Compile the suite from `tests` and place the PLAIN runtime beside its executable:

```sh
mkdir -p bin/plain lib/plain
fpc -Fu../src/core -Fu../src/backends -Fu../src/profiles \
  -Fubackend -Fubattery -Fucore -Funus -Fusupport \
  -Fu../simpledelphible/source -Fi../simpledelphible/source \
  -FUlib/plain -FEbin/plain lazbletests.lpr
cp /path/to/plain-runtime/lib/libsimplecble.so bin/plain/
bin/plain/lazbletests --all --format=plain
```

On Windows, use `plain-runtime/bin/simplecble.dll` and run `lazbletests.exe`.
On macOS, use `plain-runtime/lib/libsimplecble.dylib`.

Build the LCL suite with its package dependencies registered:

```sh
lazbuild --ws=qt6 tests/lcl/lazblelcltests.lpi
```

Run `tests/bin/lazblelcltests --all --format=plain` (`.exe` on Windows).
The LCL suite uses a fake backend and does not require native BLE libraries.

## License

LazBle uses the [MIT License](LICENSE). SimpleDelphiBLE and its native libraries
retain their own licenses; include the distribution's license with deployed
runtime files.
