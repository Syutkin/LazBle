program LazBleLclTests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  CThreads,
  {$ENDIF}
  Interfaces,
  Forms,
  ConsoleTestRunner,
  LazBleLclScanTests,
  LazBleLclContractTests,
  LazBleComponentTests,
  LazBleLclClientTests,
  LazBleLclClientConnectionTests,
  LazBleComponentClientTests,
  LazBleLclClientReconnectTests,
  LazBleDeviceSelectFormTests,
  LazBleLclTranslationsTests;

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
