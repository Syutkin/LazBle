program LazBleTests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  consoletestrunner,
  LazBleBackendTests,
  LazBleBackendConformanceTests,
  LazBleSimpleBleBackendTests,
  LazBleCentralManagerTests,
  LazBleClientTests,
  LazBleGattSessionTests,
  LazBleByteChannelTests,
  LazBleNusTests,
  LazBleBatteryTests;

var
  Runner: TTestRunner;
begin
  Runner := TTestRunner.Create(nil);
  try
    Runner.Initialize;
    Runner.Run;
  finally
    Runner.Free;
  end;
end.
