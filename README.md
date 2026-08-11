# LazBle

LazBle is an asynchronous BLE and GATT client library for Free Pascal.
Lazarus can use the FPC-only core through `lazble.lpk`. The optional
`lazblelcl.lpk` package provides main-thread LCL components without adding LCL
dependencies to the core units. `lazblelcldesign.lpk` is an IDE-only package
that places the components on the Lazarus component palette; applications do
not depend on it.

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
facade or loading an LCL component does not load the native backend:

```pascal
AvailabilityOperation := Ble.CheckAvailabilityAsync(AdapterId);
```

On success, `IBleAvailabilityOperation.Availability` is either
`lbaAvailable` or `lbaUnavailable`. A failed operation carries a backend or
native-loader error instead of treating it as an ordinary unavailable result.

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

To add the components to the Lazarus palette, open
`lazblelcldesign.lpk` and choose **Use > Install**. Lazarus normally rebuilds
and restarts its IDE executable once because design-time packages are linked
into the IDE. This does not rebuild FPC or the complete Lazarus/LCL source
tree. Merely building the package does not modify or rebuild the IDE.

Console applications and tests can use the blocking `TLazBleSync` facade from
`LazBleSync`. GUI applications should use the asynchronous API.

## Threads and callbacks

Backend events and asynchronous completion callbacks run on the thread that
delivers the backend event; the SimpleBLE backend uses its worker thread.
Scan result and reconnect callbacks follow the same rule; reconnect events can
run on the timer thread. LazBle does not marshal callbacks to the LCL main
thread. Handlers must be short and thread-safe, and GUI applications must
marshal them before accessing LCL controls.

Public readonly async state and result properties are synchronized. Callback
properties can safely be installed or cleared concurrently with state changes;
a completion handler installed after an operation finishes is called once
immediately on the installing thread.

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
`LazBleReconnect`, and `LazBleSimpleBleDriverIntf` are package implementation
units and are not a compatibility surface.

## Build and test

Register or install the sibling `SimpleBlePascal` package before building
LazBle. `fppkg build` likewise expects `simpleblepascal` to be available in the
active FPC package repository.

```sh
fppkg build
lazbuild --ws=qt6 lazble.lpk
lazbuild --ws=qt6 tests/lazbletests.lpi
tests/bin/lazbletests --all --format=plain
lazbuild --ws=qt6 lazblelcl.lpk
lazbuild --ws=qt6 lazblelcldesign.lpk
lazbuild --ws=qt6 tests/lcl/lazblelcltests.lpi
tests/bin/lazblelcltests --all --format=plain
lazbuild --ws=qt6 examples/lcl/lazblelcldemo.lpi
```

## License

LazBle is released under the MIT License. Native BLE backends and their runtime
libraries retain their own licenses.
