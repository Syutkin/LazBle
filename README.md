# LazBle

LazBle is an asynchronous BLE and GATT client library for Free Pascal.
Lazarus is supported through `lazble.lpk`, but the source units do not depend on
LCL, LazUtils, or a widgetset.

## Usage

```pascal
uses
  LazBleClient,
  LazBleFacade,
  LazBleNus,
  LazBleReconnect;

Ble := TLazBle.Create;
Client := Ble.CreateClient(DeviceId);
Nus := TNusProfile.Create;
Client.AddProfile(Nus);
Operation := Client.ConnectAsync;
```

Reconnect after an unexpected loss is optional and disabled by default:

```pascal
Client.ReconnectOptions := TLazBleReconnectOptions.Create(1000, 30000, 5);
Client.AutoReconnect := True;
```

The delay doubles up to the configured maximum, and reconnect stops after the
configured number of attempts. An initial connection failure is not retried.
`DisconnectAsync`, `TLazBle.ShutdownAsync`, or setting `AutoReconnect` to
`False` cancels a pending retry. Registered profiles are detached on loss and
attached again after service discovery. `State`, `ReconnectAttempt`, and
`ReconnectDelayMs` expose the current progress.

`TLazBle` owns its clients, and each `TBleClient` owns its registered profiles.
Console applications can use `TLazBleSync` from `LazBleSync`; GUI applications
should use the asynchronous API.

Backend events and asynchronous completion callbacks run on the thread that
delivers the backend event; the SimpleBLE backend uses its worker thread.
Reconnect state changes can also be delivered by the reconnect timer thread.
LazBle does not marshal callbacks to the LCL main thread. Handlers must be short
and thread-safe, and GUI applications must marshal them before accessing LCL
controls or application state confined to the main thread.

## Build and test

```sh
fppkg build
lazbuild --ws=qt6 lazble.lpk
lazbuild --ws=qt6 tests/lazbletests.lpi
tests/bin/lazbletests --all --format=plain
```

## License

LazBle is released under the MIT License. Native BLE backends and their runtime
libraries retain their own licenses.
