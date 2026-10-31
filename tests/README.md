# LazBle tests

Use the dependencies and directory layout described in the
[main README](../README.md#dependencies-and-native-libraries).

## Core, profiles, and backend

The suite is in `lazbletests.lpr`. Its native backend tests use the real
SimpleDelphiBLE bindings with the upstream PLAIN implementation. Keep that
runtime separate from production libraries. Build PLAIN from the SimpleBLE
source revision identified in the binding release's description.
For example, on Linux:

```sh
cmake -S /path/to/simpleble/simplecble -B /path/to/plain-build \
  -DSIMPLEBLE_PLAIN=ON -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON -DCMAKE_INSTALL_LIBDIR=lib
cmake --build /path/to/plain-build --config Release --parallel 4
cmake --install /path/to/plain-build --config Release --prefix /path/to/plain-runtime
```

Run these commands from LazBle's `tests` directory to compile the suite and
place the PLAIN runtime beside its executable:

```sh
mkdir -p bin/plain lib/plain
fpc -Fu../src/core -Fu../src/backends -Fu../src/profiles \
  -Fubackend -Fubattery -Fucore -Funus -Fudeviceinformation -Fusupport \
  -Fu../../simpledelphible/source -Fi../../simpledelphible/source \
  -FUlib/plain -FEbin/plain lazbletests.lpr
cp /path/to/plain-runtime/lib/libsimplecble.so bin/plain/
bin/plain/lazbletests --all --format=plain
```

On Windows, use `plain-runtime/bin/simplecble.dll` and run `lazbletests.exe`.
On macOS, use `plain-runtime/lib/libsimplecble.dylib`.

## LCL

Register the package dependencies as described in the
[Lazarus setup instructions](../README.md#lazarus). Then build and run the
suite from the LazBle root directory:

```sh
lazbuild --ws=qt6 tests/lcl/lazblelcltests.lpi
tests/bin/lazblelcltests --all --format=plain
```

Use the `.exe` executable on Windows. The LCL suite uses a fake backend and
does not require native BLE libraries.
