# LazBle

LazBle **2.0.0** is an asynchronous BLE Central and GATT client library for
Free Pascal and Lazarus. It provides device discovery, connections, GATT
operations, notifications, typed profiles, optional reconnection, and LCL controls.

The default backend uses the public API of
[SimpleDelphiBLE 1.3.0](https://github.com/simpleble/simpledelphible/releases/tag/v1.3.0).
Blocking BLE calls run on a command worker. API access and callbacks run on the
main thread.

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
backend requires the official SimpleDelphiBLE 1.3.0 distribution in
`simpledelphible/`. This entire directory is local and ignored by Git, including
sources, native libraries, and licenses.

Download [simpledelphible-1.3.0.zip](https://github.com/simpleble/simpledelphible/releases/download/v1.3.0/simpledelphible-1.3.0.zip),
extract it, and place its contents in LazBle's `simpledelphible` directory
(renaming the extracted `simpledelphible-1.3.0` folder to `simpledelphible`):

Archive SHA-256: `6fce6451fec87c67914a8841ffc9945e5af6e852c734ab238d57f4b623bf46c2`.

```text
lazble/
  lazble.lpk
  simpledelphible/           # official release contents; entirely ignored by Git
    LICENSE.md
    source/
    lib/
      linux-x64/
      win64/
      macos-x64/
      macos-arm64/
      ...
```

| Supported target | Link-time directory | Runtime files |
| --- | --- | --- |
| Linux x86_64 | `simpledelphible/lib/linux-x64` | `libsimplecble.so` and `libsimpleble.so` |
| Windows x86_64 | `simpledelphible/lib/win64` | `simplecble.dll` and `simpleble.dll` |
| macOS 15.0+ Intel x86_64 | `simpledelphible/lib/macos-x64` | `libsimplecble.dylib` and `libsimpleble.dylib` |
| macOS 15.0+ Apple Silicon (aarch64) | `simpledelphible/lib/macos-arm64` | `libsimplecble.dylib` and `libsimpleble.dylib` |

The official Linux binary uses the SONAME `$ORIGIN/libsimplecble.so` and RUNPATH
`$ORIGIN`; deploy both libraries beside the executable. On Windows, place both
DLLs beside the executable. On macOS, place both `.dylib` files beside the
executable, or in `MyApp.app/Contents/MacOS` for an app bundle. The official
libraries resolve their dependencies from that location without an added rpath.
The application needs [Bluetooth permission](https://docs.simpleble.org/fundamentals/permissions).
Each test/example executable and a Lazarus IDE with the design package also need
their native dependencies.

Native libraries are required at link time and process startup, including for
executables using a fake or custom backend. An availability check reports adapter
and Bluetooth status; it cannot handle a library missing at process startup.

### Lazarus

The `LazBle` package compiles the locally supplied official sources directly. Its unit,
include, and target-specific library paths are already configured; native link
paths are passed to dependent projects. Only the LazBle packages need registering:

```sh
lazbuild --ws=qt6 --add-package-link lazble.lpk
lazbuild --ws=qt6 --add-package-link lazblelcl.lpk
lazbuild --ws=qt6 lazble.lpk
lazbuild --ws=qt6 lazblelcl.lpk
```

Add `LazBle` to your project's required packages, and `LazBleLCL` when using
components or controls. Copy the matching runtime libraries to the executable's
output directory; `lazbuild` does not copy them.

To install the components on the Lazarus palette, open `lazblelcldesign.lpk`
and choose **Use > Install**. Lazarus rebuilds its IDE executable with the design
package. Deploy the native libraries beside that executable before restarting it.

### Direct FPC use

Add `src/core`, `src/backends`, and `src/profiles` to `-Fu`. Add the official
`simpledelphible/source` directory to both `-Fu` and `-Fi`, and the matching
`simpledelphible/lib` target directory to `-Fl`.

On Linux, `-k-L/path/to/native` can set linker search precedence when other
library versions are present. Keep compiled units for different targets in
separate `-FU` directories. Unix console programs must include `cthreads` first
in their uses clause.

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
Reaching the scan duration normally completes the scan successfully.

`TLazBle` owns clients created by `CreateClient`. Device IDs must be unique
within a facade. After successful `AddProfile`, the client owns that profile.
Required profiles must be Ready before the client enters `lbcstReady`.
Completed operations, scan snapshots, and inactive subscription tokens remain
readable after their client/session is released.

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

The default backend uses SimpleDelphiBLE `edMainThread` delivery and one worker
for blocking commands. Console applications service `CheckSynchronize`; LCL
services it through the GUI event loop. Reconnect timers deliver their client
actions on the main thread.

Callbacks may start the next asynchronous operation. Do not run nested BLE waits
or free the owner inside its callback. Defer destruction with
`TThread.ForceQueue` or an owned LCL async call; `TThread.Queue` may execute
immediately when called from the main thread.

Complete `ShutdownAsync` before freeing an active facade or LCL owner. Shutdown
stops new work and application callbacks, drains accepted commands, removes
handlers/subscriptions, disconnects, and stops the worker. Inspect its terminal
result for cleanup failures. A native call can delay shutdown until it returns;
there is no guaranteed cleanup deadline. Destruction before completed shutdown
can block and abandons pending logical results.

Only one default backend may actively own the process-wide upstream objects at
a time. After orderly cleanup and release, another backend can use them. Do not
replace the same upstream handlers or change `EventDelivery` while LazBle owns
them. Adapters and peripherals are owned by SimpleDelphiBLE.

### Cancellation and subscriptions

`CancelRequested` records a request, not an operation outcome. Queued work can
be skipped. A started native Connect/GATT call returns its actual success or
failure and retains its effects. Cancelling profile attachment does not undo
the connection. If discovery is cancelled after physical connection, the client
enters Error and explicit Disconnect remains available.

Notifications are delivered only after successful subscription readiness; early
values are dropped. A characteristic can have one active subscription per
default backend. Upstream queued events have no original session token, so
absolute attribution of notifications across reconnects is not guaranteed.

Unsubscribe immediately closes local delivery. With a pending Notify, cleanup
waits for its outcome and unsubscribes if registration succeeds. A failed
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

Services, nested arrays, read values, and notification payloads are managed
snapshots treated as read-only. Explicitly copy arrays you need to change.
The backend copies a write buffer when submitting its command.

Inspect operation State to determine success or failure. Native error code 0
and empty error text can represent a failure. Named negative error codes in
`LazBleTypes` identify LazBle errors. Custom backends set `ShutdownFailed` on
failed `lbekShutdownCompleted` events independently of their error code/message.

`LazBleGetAbout` returns static package information. `DiagnosticInfo` contains
LazBleVersion, BindingName/BindingVersion, BackendName, NativeVersion, AdapterId,
Availability, and ErrorMessage. Reading it starts no BLE work. NativeVersion and
AdapterId are populated by an availability check; BindingName/BindingVersion
describe the compiled SimpleDelphiBLE dependency.

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

Derive a profile from `TBleGattProfile`. Use its protected Session for Read,
Write, and Subscribe operations; start work in `DoAttach`, report readiness with
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
native libraries there. Interactive console input continues servicing callbacks
while waiting for a line, including partial input and EOF.

The core/profile/backend suite is in `tests/lazbletests.lpr`. Its native backend
tests require SimpleDelphiBLE 1.3.0 with the upstream PLAIN implementation; keep
that runtime separate from the production libraries used by applications.
Build PLAIN from the matching SimpleBLE 1.3.0 source:

```sh
cmake -S /path/to/simpleble/simplecble -B /path/to/plain-build \
  -DSIMPLEBLE_PLAIN=ON -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build /path/to/plain-build
```

Compile the suite from `tests`, substituting the PLAIN library path:

```sh
mkdir -p bin/plain lib/plain
fpc -Fu../src/core -Fu../src/backends -Fu../src/profiles \
  -Fubackend -Fubattery -Fucore -Funus -Fusupport \
  -Fu../simpledelphible/source -Fi../simpledelphible/source \
  -Fl/path/to/plain-build/lib -k-L/path/to/plain-build/lib \
  -FUlib/plain -FEbin/plain lazbletests.lpr
LD_LIBRARY_PATH=/path/to/plain-build/lib bin/plain/lazbletests --all --format=plain
```

Build the LCL suite with its package dependencies registered:

```sh
lazbuild --ws=qt6 tests/lcl/lazblelcltests.lpi
```

Deploy the production native libraries to `tests/bin`, then run
`tests/bin/lazblelcltests --all --format=plain`.

## License

LazBle uses the [MIT License](LICENSE). SimpleDelphiBLE and its native libraries
retain their own licenses; include the distribution's license with deployed
runtime files.
