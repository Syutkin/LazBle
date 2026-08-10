program LazBleLclTests;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  CThreads,
  {$ENDIF}
  ConsoleTestRunner,
  LazBleLclDispatchTests;

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
