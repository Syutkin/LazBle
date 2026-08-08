# LazBle

LazBle is an asynchronous BLE Central and GATT Client library for Free Pascal.
Lazarus is supported through `lazble.lpk`, but the source units do not depend on
LCL, LazUtils, or a widgetset.

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
