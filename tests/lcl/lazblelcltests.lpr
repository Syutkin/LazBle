program LazBleLclTests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  CThreads,
  {$ENDIF}
  Interfaces,
  Forms,
  ConsoleTestRunner,
  LazBleLclDispatchTests,
  LazBleLclScanTests,
  LazBleComponentTests,
  LazBleLclClientTests,
  LazBleLclClientConnectionTests,
  LazBleComponentClientTests,
  LazBleLclClientReconnectTests,
  LazBleDeviceSelectFormTests,
  LazBleDeviceControlTests;

var
  Runner: TTestRunner;
begin
  Application.Initialize;
  Runner := TTestRunner.Create(nil);
  try
    Runner.Initialize;
    Runner.Run;
  finally
    Runner.Free;
  end;
end.
