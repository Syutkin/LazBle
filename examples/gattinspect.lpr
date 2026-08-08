program GattInspect;

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
  LazBleGattSession,
  LazBleCentralManager,
  LazBleSimpleBleBackend;

type
  TInspectDevice = record
    DeviceId: string;
    DeviceName: string;
    Rssi: SmallInt;
  end;
  TInspectDevices = array of TInspectDevice;

  TGattInspectApplication = class(TCustomApplication)
  private
    FManager: TBleCentralManager;
    FSession: TBleGattSession;
    FDevicesLock: TRTLCriticalSection;
    FDevices: TInspectDevices;
    FScanCompletedEvent: TEvent;
    FSessionStateEvent: TEvent;
    FScanSucceeded: Boolean;
    FScanErrorMessage: string;
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject; const ASucceeded: Boolean;
      const AErrorCode: Integer; const AErrorMessage: string);
    procedure SessionStateChanged(Sender: TObject;
      const AState: TLazBleSessionState);
    function ParseTimeout(out ATimeoutMs: Cardinal): Boolean;
    function SelectDevice(const ARequestedDeviceId: string;
      out ADeviceId: string): Boolean;
    function WaitForSessionConnected(const ATimeoutMs: Cardinal): Boolean;
    procedure PrintGattSnapshot;
    procedure ShutdownBle;
    procedure Fail(const AMessage: string);
  protected
    procedure DoRun; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteHelp; virtual;
  end;

function BytesToHex(const AValue: TBytes): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(AValue) do
  begin
    if Index > 0 then
      Result := Result + ' ';
    Result := Result + IntToHex(AValue[Index], 2);
  end;
end;

procedure AppendProperty(var AText: string; const APropertyName: string);
begin
  if AText <> '' then
    AText := AText + ', ';
  AText := AText + APropertyName;
end;

function PropertiesToText(
  const AProperties: TLazBleGattCharacteristicProperties): string;
begin
  Result := '';
  if lbgcpRead in AProperties then
    AppendProperty(Result, 'read');
  if lbgcpWriteRequest in AProperties then
    AppendProperty(Result, 'write-request');
  if lbgcpWriteCommand in AProperties then
    AppendProperty(Result, 'write-command');
  if lbgcpNotify in AProperties then
    AppendProperty(Result, 'notify');
  if lbgcpIndicate in AProperties then
    AppendProperty(Result, 'indicate');
  if Result = '' then
    Result := 'none';
end;

constructor TGattInspectApplication.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  StopOnException := True;
  InitCriticalSection(FDevicesLock);
  FScanCompletedEvent := TEvent.Create(nil, True, False, '');
  FSessionStateEvent := TEvent.Create(nil, True, False, '');
end;

destructor TGattInspectApplication.Destroy;
begin
  ShutdownBle;
  FSessionStateEvent.Free;
  FScanCompletedEvent.Free;
  DoneCriticalSection(FDevicesLock);
  inherited Destroy;
end;

procedure TGattInspectApplication.ScanResult(Sender: TObject;
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

procedure TGattInspectApplication.ScanCompleted(Sender: TObject;
  const ASucceeded: Boolean; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  FScanSucceeded := ASucceeded;
  FScanErrorMessage := AErrorMessage;
  FScanCompletedEvent.SetEvent;
end;

procedure TGattInspectApplication.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
begin
  FSessionStateEvent.SetEvent;
end;

function TGattInspectApplication.ParseTimeout(
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

function TGattInspectApplication.SelectDevice(
  const ARequestedDeviceId: string; out ADeviceId: string): Boolean;
var
  Devices: TInspectDevices;
  Index: Integer;
  Selection: Integer;
  SelectionText: string;
begin
  EnterCriticalSection(FDevicesLock);
  try
    Devices := Copy(FDevices);
  finally
    LeaveCriticalSection(FDevicesLock);
  end;

  if ARequestedDeviceId <> '' then
  begin
    for Index := 0 to High(Devices) do
      if SameText(Devices[Index].DeviceId, ARequestedDeviceId) then
      begin
        ADeviceId := Devices[Index].DeviceId;
        Exit(True);
      end;
    WriteLn('Device was not found during scan: ', ARequestedDeviceId);
    Exit(False);
  end;

  if Length(Devices) = 0 then
  begin
    WriteLn('No BLE devices were found.');
    Exit(False);
  end;
  WriteLn('The following devices were found:');
  for Index := 0 to High(Devices) do
    WriteLn('[', Index, '] ', Devices[Index].DeviceName, ' [',
      Devices[Index].DeviceId, '] ', Devices[Index].Rssi, ' dBm');
  Write('Please select a device: ');
  ReadLn(SelectionText);
  Result := TryStrToInt(Trim(SelectionText), Selection) and
    (Selection >= 0) and (Selection < Length(Devices));
  if Result then
    ADeviceId := Devices[Selection].DeviceId
  else
    WriteLn('Invalid device selection.');
end;

function TGattInspectApplication.WaitForSessionConnected(
  const ATimeoutMs: Cardinal): Boolean;
var
  Deadline: QWord;
  RemainingMs: QWord;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if FSession.State = lbssConnected then
      Exit(True);
    if FSession.State in [lbssDisconnected, lbssError] then
      Exit(False);
    if GetTickCount64 >= Deadline then
      Exit(False);
    RemainingMs := Deadline - GetTickCount64;
    if RemainingMs > 100 then
      RemainingMs := 100;
    FSessionStateEvent.WaitFor(RemainingMs);
    FSessionStateEvent.ResetEvent;
  until False;
end;

procedure TGattInspectApplication.PrintGattSnapshot;
var
  CharacteristicIndex: Integer;
  DescriptorIndex: Integer;
  ServiceIndex: Integer;
  Services: TLazBleGattServices;
begin
  Services := FSession.Services;
  WriteLn('GATT services: ', Length(Services));
  for ServiceIndex := 0 to High(Services) do
  begin
    WriteLn('[', ServiceIndex, '] Service ', Services[ServiceIndex].Uuid);
    if Length(Services[ServiceIndex].Data) > 0 then
      WriteLn('    Data: ', BytesToHex(Services[ServiceIndex].Data));
    for CharacteristicIndex := 0 to
      High(Services[ServiceIndex].Characteristics) do
    begin
      WriteLn('    Characteristic ',
        Services[ServiceIndex].Characteristics[CharacteristicIndex].Uuid,
        ' [', PropertiesToText(Services[ServiceIndex].Characteristics[
          CharacteristicIndex].Properties), ']');
      for DescriptorIndex := 0 to High(Services[ServiceIndex].Characteristics[
        CharacteristicIndex].Descriptors) do
        WriteLn('        Descriptor ', Services[ServiceIndex].Characteristics[
          CharacteristicIndex].Descriptors[DescriptorIndex].Uuid);
    end;
  end;
end;

procedure TGattInspectApplication.ShutdownBle;
var
  Deadline: QWord;
begin
  if Assigned(FSession) and
    (FSession.State in [lbssConnecting, lbssDiscovering, lbssConnected,
      lbssError]) then
  begin
    FSession.Disconnect;
    Deadline := GetTickCount64 + 5000;
    while (FSession.State <> lbssDisconnected) and
      (GetTickCount64 < Deadline) do
    begin
      FSessionStateEvent.WaitFor(100);
      FSessionStateEvent.ResetEvent;
    end;
  end;
  if Assigned(FSession) then
    FSession.OnStateChanged := nil;
  FSession := nil;
  if Assigned(FManager) then
  begin
    FManager.OnScanResult := nil;
    FManager.OnScanCompleted := nil;
    FManager.BeginShutdown;
    Deadline := GetTickCount64 + 5000;
    while (FManager.State <> lbcsShutdown) and
      (GetTickCount64 < Deadline) do
      Sleep(10);
    FreeAndNil(FManager);
  end;
end;

procedure TGattInspectApplication.Fail(const AMessage: string);
begin
  WriteLn(StdErr, AMessage);
  ExitCode := 1;
  Terminate;
end;

procedure TGattInspectApplication.DoRun;
var
  AdapterId: string;
  Backend: ILazBleBackend;
  DeviceId: string;
  ErrorMessage: string;
  RequestedDeviceId: string;
  ScanTimeoutMs: Cardinal;
begin
  ErrorMessage := CheckOptions('ha:d:t:', [
    'help',
    'adapter:',
    'device:',
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
  RequestedDeviceId := GetOptionValue('d', 'device');
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
  if not SelectDevice(RequestedDeviceId, DeviceId) then
  begin
    Fail('No device was selected.');
    Exit;
  end;

  FSession := FManager.CreateSession(DeviceId);
  FSession.OnStateChanged := @SessionStateChanged;
  WriteLn('Connecting to ', DeviceId, '...');
  if FSession.Connect = InvalidBleOperationId then
  begin
    Fail('Could not start BLE connection.');
    Exit;
  end;
  if not WaitForSessionConnected(15000) then
  begin
    Fail('Could not connect and discover GATT services.');
    Exit;
  end;

  PrintGattSnapshot;
  ShutdownBle;
  Terminate;
end;

procedure TGattInspectApplication.WriteHelp;
begin
  WriteLn('Usage: ', ExeName,
    ' [--adapter ID] [--device ADDRESS] [--timeout MILLISECONDS]');
  WriteLn;
  WriteLn('Scans for a BLE device and prints its GATT services,');
  WriteLn('characteristics, properties, and descriptors.');
  WriteLn('Set SIMPLECBLE_LIBRARY_DIR if native libraries are elsewhere.');
end;

var
  Application: TGattInspectApplication;
begin
  Application := TGattInspectApplication.Create(nil);
  Application.Title := 'GattInspect';
  try
    Application.Run;
  finally
    Application.Free;
  end;
end.
