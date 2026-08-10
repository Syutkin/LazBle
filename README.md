# LazBle

LazBle is an asynchronous BLE and GATT client library for Free Pascal.
Lazarus is supported through `lazble.lpk`, but the source units do not depend on
LCL, LazUtils, or a widgetset.

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
```

## License

LazBle is released under the MIT License. Native BLE backends and their runtime
libraries retain their own licenses.
