program BleScan;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  SyncObjs,
  CustApp,
  LazBleTypes,
  LazBleBackend,
  LazBleCentralManager,
  LazBleSimpleBleBackend;

type
  TScanDevice = record
    DeviceId: string;
    DeviceName: string;
    Rssi: SmallInt;
  end;
  TScanDevices = array of TScanDevice;

  TBleScanApplication = class(TCustomApplication)
  private
    FManager: TBleCentralManager;
    FDevicesLock: TRTLCriticalSection;
    FDevices: TScanDevices;
    FScanCompletedEvent: TEvent;
    FScanSucceeded: Boolean;
    FScanErrorMessage: string;
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject; const ASucceeded: Boolean;
      const AErrorCode: Integer; const AErrorMessage: string);
    function ParseTimeout(out ATimeoutMs: Cardinal): Boolean;
    function GetSortedDevices: TScanDevices;
    procedure PrintDevices;
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
  InitCriticalSection(FDevicesLock);
  FScanCompletedEvent := TEvent.Create(nil, True, False, '');
end;

destructor TBleScanApplication.Destroy;
begin
  ShutdownBle;
  FScanCompletedEvent.Free;
  DoneCriticalSection(FDevicesLock);
  inherited Destroy;
end;

procedure TBleScanApplication.ScanResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
var
  Index: Integer;
begin
  EnterCriticalSection(FDevicesLock);
  try
    for Index := 0 to High(FDevices) do
      if SameText(FDevices[Index].DeviceId, ADeviceId) then
      begin
        FDevices[Index].DeviceName := ADeviceName;
        FDevices[Index].Rssi := ARssi;
        Exit;
      end;
    Index := Length(FDevices);
    SetLength(FDevices, Index + 1);
    FDevices[Index].DeviceId := ADeviceId;
    FDevices[Index].DeviceName := ADeviceName;
    FDevices[Index].Rssi := ARssi;
  finally
    LeaveCriticalSection(FDevicesLock);
  end;
end;

procedure TBleScanApplication.ScanCompleted(Sender: TObject;
  const ASucceeded: Boolean; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  FScanSucceeded := ASucceeded;
  FScanErrorMessage := AErrorMessage;
  FScanCompletedEvent.SetEvent;
end;

function TBleScanApplication.ParseTimeout(
  out ATimeoutMs: Cardinal): Boolean;
var
  ParsedValue: QWord;
  TimeoutText: string;
begin
  TimeoutText := GetOptionValue('t', 'timeout');
  if TimeoutText = '' then
  begin
    ATimeoutMs := 5000;
    Exit(True);
  end;
  Result := TryStrToQWord(TimeoutText, ParsedValue) and
    (ParsedValue > 0) and (ParsedValue <= High(Cardinal));
  if Result then
    ATimeoutMs := ParsedValue;
end;

function TBleScanApplication.GetSortedDevices: TScanDevices;
var
  Current: TScanDevice;
  Index: Integer;
  InsertAt: Integer;
begin
  EnterCriticalSection(FDevicesLock);
  try
    Result := Copy(FDevices);
  finally
    LeaveCriticalSection(FDevicesLock);
  end;

  for Index := 1 to High(Result) do
  begin
    Current := Result[Index];
    InsertAt := Index;
    while (InsertAt > 0) and (Result[InsertAt - 1].Rssi < Current.Rssi) do
    begin
      Result[InsertAt] := Result[InsertAt - 1];
      Dec(InsertAt);
    end;
    Result[InsertAt] := Current;
  end;
end;

procedure TBleScanApplication.PrintDevices;
var
  Devices: TScanDevices;
  Index: Integer;
begin
  Devices := GetSortedDevices;
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
  Deadline: QWord;
begin
  if not Assigned(FManager) then
    Exit;
  FManager.OnScanResult := nil;
  FManager.OnScanCompleted := nil;
  FManager.BeginShutdown;
  Deadline := GetTickCount64 + 5000;
  while (FManager.State <> lbcsShutdown) and
    (GetTickCount64 < Deadline) do
    Sleep(10);
  FreeAndNil(FManager);
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
  Backend: ILazBleBackend;
  ErrorMessage: string;
  ScanTimeoutMs: Cardinal;
begin
  ErrorMessage := CheckOptions('ha:t:', [
    'help',
    'adapter:',
    'timeout:'
  ]);
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
  if not ParseTimeout(ScanTimeoutMs) then
  begin
    Fail('Invalid scan timeout.');
    Exit;
  end;

  AdapterId := GetOptionValue('a', 'adapter');
  Backend := TLazBleSimpleBleBackend.Create;
  FManager := TBleCentralManager.Create(Backend);
  Backend := nil;
  FManager.OnScanResult := @ScanResult;
  FManager.OnScanCompleted := @ScanCompleted;

  WriteLn('Scanning for BLE devices...');
  if FManager.StartScan(AdapterId, ScanTimeoutMs) = InvalidBleOperationId then
  begin
    Fail('Could not start BLE scan.');
    Exit;
  end;
  if FScanCompletedEvent.WaitFor(ScanTimeoutMs + 10000) <> wrSignaled then
  begin
    Fail('BLE scan timed out.');
    Exit;
  end;
  if not FScanSucceeded then
  begin
    if FScanErrorMessage = '' then
      FScanErrorMessage := 'BLE scan failed.';
    Fail(FScanErrorMessage);
    Exit;
  end;

  PrintDevices;
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
