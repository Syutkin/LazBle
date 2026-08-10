# LazBle

LazBle is an asynchronous BLE and GATT client library for Free Pascal.
Lazarus is supported through `lazble.lpk`, but the source units do not depend on
LCL, LazUtils, or a widgetset.

## Usage

```pascal
uses
  LazBleClient,
  LazBleFacade,
  LazBleNus;

Ble := TLazBle.Create;
Client := Ble.CreateClient(DeviceId);
Nus := TNusProfile.Create;
Client.AddProfile(Nus);
Operation := Client.ConnectAsync;
```

`TLazBle` owns its clients, and each `TBleClient` owns its registered profiles.
Console applications can use `TLazBleSync` from `LazBleSync`; GUI applications
should use the asynchronous API.

Backend events and asynchronous completion callbacks run on the thread that
delivers the backend event; the SimpleBLE backend uses its worker thread.
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
