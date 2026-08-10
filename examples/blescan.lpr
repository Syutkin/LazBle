program BleScan;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  CustApp,
  LazBleTypes,
  LazBleSync,
  BleExampleUtils;

type
  TBleScanApplication = class(TCustomApplication)
  private
    FBleSync: TLazBleSync;
    procedure PrintDevices(const ADevices: TBleDeviceInfos);
    procedure ShutdownBle;
    procedure Fail(const AMessage: string);
  protected
    procedure DoRun; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteHelp; virtual;
  end;

constructor TBleScanApplication.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  StopOnException := True;
end;

destructor TBleScanApplication.Destroy;
begin
  ShutdownBle;
  inherited Destroy;
end;

procedure TBleScanApplication.PrintDevices(const ADevices: TBleDeviceInfos);
var
  Current: TBleDeviceInfo;
  Devices: TBleDeviceInfos;
  Index: Integer;
  InsertAt: Integer;
begin
  Devices := Copy(ADevices);
  for Index := 1 to High(Devices) do
  begin
    Current := Devices[Index];
    InsertAt := Index;
    while (InsertAt > 0) and
      (Devices[InsertAt - 1].Rssi < Current.Rssi) do
    begin
      Devices[InsertAt] := Devices[InsertAt - 1];
      Dec(InsertAt);
    end;
    Devices[InsertAt] := Current;
  end;

  if Length(Devices) = 0 then
  begin
    WriteLn('No BLE devices were found.');
    Exit;
  end;
  WriteLn('The following devices were found:');
  for Index := 0 to High(Devices) do
    WriteLn('[', Index, '] ', Devices[Index].DeviceName, ' [',
      Devices[Index].DeviceId, '] ', Devices[Index].Rssi, ' dBm');
end;

procedure TBleScanApplication.ShutdownBle;
var
  ErrorMessage: string;
begin
  if Assigned(FBleSync) then
    FBleSync.Shutdown(5000, ErrorMessage);
  FreeAndNil(FBleSync);
end;

procedure TBleScanApplication.Fail(const AMessage: string);
begin
  WriteLn(StdErr, AMessage);
  ExitCode := 1;
  Terminate;
end;

procedure TBleScanApplication.DoRun;
var
  AdapterId: string;
  Devices: TBleDeviceInfos;
  ErrorMessage: string;
  ScanTimeoutMs: Cardinal;
begin
  ErrorMessage := CheckOptions('ha:t:', ['help', 'adapter:', 'timeout:']);
  if ErrorMessage <> '' then
  begin
    Fail(ErrorMessage);
    Exit;
  end;
  if HasOption('h', 'help') then
  begin
    WriteHelp;
    Terminate;
    Exit;
  end;
  if not TryParseBleTimeout(GetOptionValue('t', 'timeout'), 5000,
    ScanTimeoutMs) then
  begin
    Fail('Invalid scan timeout.');
    Exit;
  end;

  AdapterId := GetOptionValue('a', 'adapter');
  FBleSync := TLazBleSync.Create;
  WriteLn('Scanning for BLE devices...');
  if not FBleSync.Scan(AdapterId, ScanTimeoutMs, Devices,
    ErrorMessage) then
  begin
    if ErrorMessage = '' then
      ErrorMessage := 'BLE scan failed.';
    Fail(ErrorMessage);
    Exit;
  end;

  PrintDevices(Devices);
  ShutdownBle;
  Terminate;
end;

procedure TBleScanApplication.WriteHelp;
begin
  WriteLn('Usage: ', ExeName,
    ' [--adapter ID] [--timeout MILLISECONDS]');
  WriteLn;
  WriteLn('Scans for BLE devices and prints them ordered by strongest RSSI.');
  WriteLn('Set SIMPLECBLE_LIBRARY_DIR if native libraries are elsewhere.');
end;

var
  Application: TBleScanApplication;
begin
  Application := TBleScanApplication.Create(nil);
  Application.Title := 'BleScan';
  try
    Application.Run;
  finally
    Application.Free;
  end;
end.
