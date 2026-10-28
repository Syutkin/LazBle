# LazBle

LazBle is an asynchronous BLE and GATT client library for Free Pascal.
Lazarus can use the FPC-only core through `lazble.lpk`. The optional
`lazblelcl.lpk` package provides main-thread LCL components without adding LCL
dependencies to the core units. `lazblelcldesign.lpk` is an IDE-only package
that places the components on the Lazarus component palette; applications do
not depend on it.

Current source version: **1.2.0**.

The default backend now uses the public API of
[SimpleDelphiBLE 1.3.0](https://github.com/simpleble/simpledelphible/releases/tag/v1.3.0).
The matching native libraries are required at link time and before program
startup. The former SimpleBlePascal driver and lazy loader have been removed.

Migration is in progress: stages 1–3 are implemented. Core/profiles now use
the main-thread contract and upstream GATT records. Reconnect and `TLazBleSync`
work with the new backend. LCL/Entime dispatch, lifecycle, deployment, and release
work remain for stages 4–5. This unreleased migration contains breaking API changes.

## Architecture

- `TLazBle` is the facade, the entry point for creating clients, and their
  lifetime owner.
- `TBleClient` represents one remote BLE device and one physical connection.
- `TBleGattSession` provides the shared GATT context used by a client and its
  custom profiles.
- `TBleGattProfile` is the base class for typed GATT profiles.
- `TBleByteChannel` provides a reusable Write/Notify byte channel.
- `TNusProfile` configures a byte channel for Nordic UART Service.
- `TBleBatteryProfile` implements an independent typed Battery Service profile.
- `TLazBleSync` is the blocking facade intended for console applications and
  tests.
- `ILazBleBackend` is the asynchronous boundary used by SimpleBLE and future
  backend implementations.
- `TLazBleComponent` is the LCL facade owner and scan component.
- `TLazBleLclClient` is the persistent LCL component for one selected device;
  it keeps form event handlers while its core client is created lazily.
- `TBleDeviceSelectForm` is a reusable modal device picker over the existing
  LCL scan controller; it does not create or connect a BLE client.
- `TLazBleDeviceControl` is an optional visual selector and connection-status
  control bound to an existing `TLazBleLclClient`.

## Usage

The default facade creates the bundled SimpleBLE backend. A client represents
one remote device, while profiles add the GATT behavior required by the
application.

```pascal
uses
  LazBleTypes,
  LazBleOperation,
  LazBleClient,
  LazBleFacade,
  LazBleNus;

var
  Ble: TLazBle;
  Client: TBleClient;
  Nus: TNusProfile;
  Operation: IBleOperation;
begin
  Ble := TLazBle.Create;
  try
    Client := Ble.CreateClient(DeviceId);
    Nus := TNusProfile.Create;
    Client.AddProfile(Nus);
    Operation := Client.ConnectAsync;
    { Observe Operation.OnCompleted or Operation.State. }

    { Before releasing Ble, finish application work and await this operation. }
    Operation := Ble.ShutdownAsync;
  finally
    Ble.Free;
  end;
end;
```

All asynchronous methods return a non-null reference-counted operation. If a
request cannot be started, the returned operation is already in
`lbopFailed`; callers do not need a separate `nil` branch. Keep the interface
for as long as its terminal state or result is needed. Completed operations,
scan snapshots, and inactive subscription tokens remain valid after their
client or session is released. Do not call `Free` on operation or subscription
interfaces.

Bluetooth availability is checked explicitly and asynchronously; creating a
facade or loading an LCL component does not enumerate adapters or start BLE
work. The native shared libraries are already linked at process startup:

```pascal
AvailabilityOperation := Ble.CheckAvailabilityAsync(AdapterId);
```

On success, `IBleAvailabilityOperation.Availability` is either
`lbaAvailable` or `lbaUnavailable`. A failed operation carries a backend or
native error instead of treating it as an ordinary unavailable result. A missing
shared library prevents startup and is not an asynchronous availability result.

`IBleScanOperation.OnResult` reports every new or updated discovery while a
scan is running. Its `Results` property remains a deduplicated snapshot in
discovery order. Installing a handler does not replay results already present
in the snapshot.

`TLazBle` owns clients created by `CreateClient`. After successful
`AddProfile`, a client owns the profile. `CreateClient` raises an exception for
a duplicate device or after shutdown has started. Applications should call
`ShutdownAsync` and await its completion before freeing the facade.

Reconnect after an unexpected loss is optional and disabled by default:

```pascal
Client.ReconnectOptions := TLazBleReconnectOptions.Create(1000, 30000, 5);
Client.AutoReconnect := True;
```

The delay doubles up to the configured maximum, and reconnect stops after the
configured number of attempts. An initial connection failure is not retried.
`DisconnectAsync`, `TLazBle.ShutdownAsync`, or setting `AutoReconnect` to
`False` cancels a pending retry. Registered profiles are detached on loss and
attached again after service discovery.

`TLazBleLclClient` exposes the same policy through published `AutoReconnect`
and nested `ReconnectOptions` properties. Loading them from an `.lfm` does not
create a core client or start a BLE operation.

Call `TLazBleComponent.Shutdown` when the LCL BLE subsystem is no longer
needed. It is non-blocking, idempotent, cancels scan and client operations,
stops pending reconnect, and suppresses queued LCL callbacks. Shutdown is
terminal: new scans, clients, connections, and profile operations are rejected.
The component destructor starts the same shutdown automatically.

`TLazBleComponent.RefreshAvailability` starts the explicit check. Its
read-only `Availability` property transitions through `lbaChecking`, and the
published `OnAvailabilityChanged` event is delivered on the LCL main thread.
No check is started while an `.lfm` is loaded.

Use `TBleDeviceSelectForm` when a user needs to select a discovered device.
Creating the dialog does not start BLE work; `Execute` starts a scan when one
is not already active and returns the selected snapshot entry:

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

The list remains in discovery order. Advertising updates replace the matching
row by stable device id without re-sorting the list. The dialog temporarily
chains the scan controller events and restores existing handlers when released.

`TLazBleDeviceControl` can be placed on a form and linked through its published
`Client` property. It uses the same client for selection, status, connect, and
disconnect, while leaving the client's published event handlers untouched.
`ShowSelectButton` and `ShowConnectionButton` control which built-in actions
are visible; their captions are also published and configurable.
`OnSelectButtonClick` and `OnConnectionButtonClick` replace the corresponding
built-in action when assigned. A custom handler can invoke `SelectDevice` or
`ToggleConnection` explicitly when it also needs the default action. Binding
or streaming the control does not start BLE work. The control and the provided
selection dialog are optional; applications can build their own UI over
`TLazBleComponent`, `TLazBleLclScan`, and `TLazBleLclClient`.

LazBleLCL translations are stored in `languages` as separate catalogues for
`LazBleDeviceSelectForm` and `LazBleDeviceControl`. Load them after selecting
the application language and before creating the controls:

```pascal
TranslateLazBleLclResourceStrings('languages', Language, FallbackLanguage);
```

The host application must deploy the LazBleLCL `.po` files alongside its own
language files. Building `lazblelcl.lpk` updates the `.pot` templates through
the Lazarus package i18n support; no custom string extractor is required.

To add the components to the Lazarus palette, open
`lazblelcldesign.lpk` and choose **Use > Install**. Lazarus normally rebuilds
and restarts its IDE executable once because design-time packages are linked
into the IDE. This does not rebuild FPC or the complete Lazarus/LCL source
tree. Merely building the package does not modify or rebuild the IDE.

Console callers can use `TLazBleSync`: it pumps `CheckSynchronize` while waiting.
A wait deadline returns False with an explanation that the operation may still
be running. It neither cancels nor changes the operation's eventual result.
GUI applications and callbacks must use the asynchronous API.

## Threads and callbacks

The LazBle API, including core/profile state reads, handler registration,
submission, cancellation, and lifetime management, runs on the main thread.
Custom backends and reconnect timers must deliver on that thread too. One command
worker performs blocking BLE operations. SimpleDelphiBLE delivers native events
through `edMainThread`; command setup and completion use RTL `Synchronize`.
Console asynchronous applications must pump `CheckSynchronize`; LCL does this
through its main loop. Never wait for another BLE operation or destroy the
owner inside a callback; defer destruction with `TThread.ForceQueue`.

Only one LazBle default backend may own the process-wide native objects at a
time. Await `BeginShutdown` / `ShutdownAsync` before creating the next active
backend. Shutdown detaches handlers, drains commands, unsubscribes, disconnects,
and joins the worker before completion. The destructor has a blocking fallback
for legacy/idle owners; explicit asynchronous shutdown is required for GUI use.
Do not independently replace the same upstream handlers or change the global
`EventDelivery` while LazBle owns them.

Queued cancellation skips the native call. Scan cancellation wakes its wait and
stops scanning. A Connect/GATT call that has begun returns its actual outcome;
there is no rollback of connection or write effects. Notifications become active
only after subscription completion; early values are dropped. Duplicate active
subscriptions to a characteristic are rejected. Unsubscribe retires local value
delivery even on a native error. Queued upstream events carry no session token,
so absolute attribution across reconnects is not guaranteed.

Reconnect waits on a timer thread, then queues the client action once on the
main thread. Cancel also removes an elapsed action waiting in the queue. The
existing backoff/attempt policy, disabled default, and no retry of an initial
failure are preserved.

`CancelRequested` records a request and does not select the terminal state.
There is no public `IBleOperation.Timeout` or `lbopTimedOut` state. Cancelling
profile attachment after connection/discovery does not undo the connection;
attachment completes normally. If queued discovery is cancelled after connecting,
the client enters Error and an explicit Disconnect remains available. Connection
loss requests cancellation of queued GATT work while retaining real outcomes of
in-flight calls, including their own generation after reconnect.

Unsubscribe closes local delivery immediately. When Notify is pending, it waits
for the actual outcome: cancelled/failed Notify needs no native unsubscribe;
successful Notify is followed by Unsubscribe. The returned cleanup operation
cannot be cancelled once delivery is retired (`CancelRequested` can still be
recorded). Explicit client Disconnect likewise continues after profiles/reconnect
intent have been retired; Cancel does not rebuild a partly attached connection.
Failure preserves its native code/text, leaves the token inactive
with error (`lbsubFailed`), and disconnects the affected session; the configured
reconnect policy may then run. Shutdown can interrupt pending logical cleanup.

GATT names in `LazBleTypes` are aliases of upstream `TBleService` and
`TBleCharacteristic`. Use `CanRead`, `CanWriteRequest`, `CanWriteCommand`,
`CanNotify`, and `CanIndicate` booleans; descriptors are UnicodeString UUIDs.
Services, nested arrays, read values, and notification payloads are read-only
managed snapshots. Explicitly copy each array you intend to mutate. Write buffers
are copied once, at backend Submit.

An accepted command's data and outcome survive orderly shutdown. Pending
connect/profile pipelines finish when shutdown closes the session, without
starting new discovery or notification delivery. Custom backends must set
`ShutdownFailed` on a failed `lbekShutdownCompleted`; neither code 0 nor empty
text can distinguish failure from success. The facade preserves that failure.
Destruction before awaited shutdown is a blocking fallback that abandons pending
logical operations and detaches callbacks; it does not promise their native
outcomes.

LCL still contains its older dispatch/clone layer pending stage 4. Interactive
console examples that block in ReadLn also need a main-loop update in that stage.

## Custom profiles

Custom typed GATT profiles inherit from `TBleGattProfile`. The protected
`Session` provides the common `ReadAsync`, `WriteAsync`, and `SubscribeAsync`
API. Start the profile in `DoAttach`, release subscriptions in `DoDetach`, and
report the result with `MarkReady` or `MarkError`.

```pascal
type
  TMyProfile = class(TBleGattProfile)
  private
    FRead: IBleGattOperation;
    procedure ReadCompleted(Sender: TObject);
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  end;

procedure TMyProfile.DoAttach;
begin
  FRead := Session.ReadAsync(MyServiceUuid, MyCharacteristicUuid);
  FRead.OnCompleted := @ReadCompleted;
end;

procedure TMyProfile.ReadCompleted(Sender: TObject);
begin
  if FRead.State = lbopSucceeded then
    MarkReady
  else
    MarkError(FRead.ErrorMessage);
end;

procedure TMyProfile.DoDetach;
begin
  if Assigned(FRead) then
    FRead.OnCompleted := nil;
  FRead := nil;
end;
```

## Backends

`TLazBle.Create` uses SimpleBLE by default. Backend replacement remains part of
the supported API: implement the asynchronous `ILazBleBackend` interface and
inject it when creating the facade.

```pascal
Backend := TMyBleBackend.Create;
Ble := TLazBle.Create(Backend);
```

Application-facing units are `LazBleTypes`, `LazBleBackend`,
`LazBleOperation`, `LazBleGattOperation`, `LazBleGattSubscription`,
`LazBleGattSession`, `LazBleGattProfile`, `LazBleByteChannel`, `LazBleClient`,
`LazBleFacade`, `LazBleSync`, `LazBleNus`, `LazBleBattery`, and
`LazBleSimpleBleBackend`. `LazBleCentralManager`, `LazBleClientInternal`,
`LazBleReconnect` are package implementation units and are not a compatibility surface.

## Build and test

The Lazarus package requires `SimpleDelphiBLEPackage` 1.3.0, the distribution's
thin Lazarus wrapper in this Entime workspace. Prepare the verified release with
`python3 scripts/setup-simpledelphible.py --archive /path/to/simpledelphible-1.3.0.zip`
from the Entime root. Register package links in your chosen Lazarus configuration:

```sh
lazbuild --ws=qt6 --add-package-link /path/to/simpledelphiblepackage.lpk
lazbuild --ws=qt6 --add-package-link /path/to/lazble.lpk
lazbuild --ws=qt6 --add-package-link /path/to/lazblelcl.lpk
lazbuild --ws=qt6 /path/to/lazble.lpk
```

A standalone FPC build can instead use `-Fu` and `-Fi` for the official source
and `-Fl` for the matching native libraries. Deploy the native pair according to
its platform loader requirements. The old `fpmake.pp` / `manifest.xml` packaging
has been removed: upstream does not supply a compatible fppkg package, and LazBle
does not maintain a second binding/package wrapper for it.

Run the reproducible stage-3 checks from the Entime root:

```sh
bash scripts/run-simpledelphible-stage3.sh /path/to/simpleble-v1.3.0
```

The script builds upstream PLAIN, runs core/profile regressions and native backend
integration against PLAIN (without Bluetooth hardware), and builds the Lazarus
runtime packages. The native tests intentionally reject a production backend.
The existing LCL suite can be built with `lazbuild --ws=qt6`; its executable now
also needs the matching production native pair next to it on Linux.

## License

LazBle is released under the MIT License. Native BLE backends and their runtime
libraries retain their own licenses.
