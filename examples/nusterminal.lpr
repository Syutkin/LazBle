program NusTerminal;

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
  LazBleGattOperation,
  LazBleGattSession,
  LazBleCentralManager,
  LazBleByteChannel,
  LazBleNus,
  LazBleSimpleBleBackend;

type
  TTerminalDevice = record
    DeviceId: string;
    DeviceName: string;
    Rssi: SmallInt;
  end;
  TTerminalDevices = array of TTerminalDevice;

  TNusTerminalApplication = class(TCustomApplication)
  private
    FManager: TBleCentralManager;
    FSession: TBleGattSession;
    FProfile: TNusProfile;
    FDevicesLock: TRTLCriticalSection;
    FOutputLock: TRTLCriticalSection;
    FDevices: TTerminalDevices;
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
    procedure NusDataReceived(Sender: TObject; const ADeviceId: string;
      const AValue: TBytes);
    function ParseTimeout(out ATimeoutMs: Cardinal): Boolean;
    function SelectDevice(const ARequestedDeviceId: string;
      out ADeviceId: string): Boolean;
    function WaitForSessionConnected(const ATimeoutMs: Cardinal): Boolean;
    function WaitForProfileReady(const ATimeoutMs: Cardinal): Boolean;
    function SendText(const AText: string; const ATimeoutMs: Cardinal): Boolean;
    procedure RunTerminal;
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

function BytesToDisplayText(const AValue: TBytes): string;
var
  Index: Integer;
begin
  Result := '';
  SetLength(Result, Length(AValue));
  for Index := 0 to High(AValue) do
    if AValue[Index] in [32..126] then
      Result[Index + 1] := Chr(AValue[Index])
    else
      Result[Index + 1] := '.';
end;

function StringToBytes(const AValue: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AValue));
  if Length(AValue) > 0 then
    Move(AValue[1], Result[0], Length(AValue));
end;

constructor TNusTerminalApplication.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  StopOnException := True;
  InitCriticalSection(FDevicesLock);
  InitCriticalSection(FOutputLock);
  FScanCompletedEvent := TEvent.Create(nil, True, False, '');
  FSessionStateEvent := TEvent.Create(nil, True, False, '');
end;

destructor TNusTerminalApplication.Destroy;
begin
  ShutdownBle;
  FSessionStateEvent.Free;
  FScanCompletedEvent.Free;
  DoneCriticalSection(FOutputLock);
  DoneCriticalSection(FDevicesLock);
  inherited Destroy;
end;

procedure TNusTerminalApplication.ScanResult(Sender: TObject;
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

procedure TNusTerminalApplication.ScanCompleted(Sender: TObject;
  const ASucceeded: Boolean; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  FScanSucceeded := ASucceeded;
  FScanErrorMessage := AErrorMessage;
  FScanCompletedEvent.SetEvent;
end;

procedure TNusTerminalApplication.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
begin
  FSessionStateEvent.SetEvent;
end;

procedure TNusTerminalApplication.NusDataReceived(Sender: TObject;
  const ADeviceId: string; const AValue: TBytes);
begin
  EnterCriticalSection(FOutputLock);
  try
    WriteLn;
    WriteLn('RX[', Length(AValue), '] ', BytesToHex(AValue),
      ' |', BytesToDisplayText(AValue), '|');
    Write('> ');
  finally
    LeaveCriticalSection(FOutputLock);
  end;
end;

function TNusTerminalApplication.ParseTimeout(
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

function TNusTerminalApplication.SelectDevice(
  const ARequestedDeviceId: string; out ADeviceId: string): Boolean;
var
  Devices: TTerminalDevices;
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

function TNusTerminalApplication.WaitForSessionConnected(
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

function TNusTerminalApplication.WaitForProfileReady(
  const ATimeoutMs: Cardinal): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if FProfile.Ready then
      Exit(True);
    if FProfile.State = lbchsError then
      Exit(False);
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(10);
  until False;
end;

function TNusTerminalApplication.SendText(const AText: string;
  const ATimeoutMs: Cardinal): Boolean;
var
  Deadline: QWord;
  Operation: TBleGattOperation;
begin
  Operation := FProfile.SendAsync(StringToBytes(AText));
  if not Assigned(Operation) then
    Exit(False);

  Deadline := GetTickCount64 + ATimeoutMs;
  while (Operation.State = lbosPending) and
    (GetTickCount64 < Deadline) do
    Sleep(10);

  Result := Operation.State = lbosSucceeded;
  if not Result then
  begin
    if Operation.ErrorMessage <> '' then
      WriteLn(StdErr, Operation.ErrorMessage)
    else if Operation.State = lbosPending then
      WriteLn(StdErr, 'NUS write timed out.')
    else
      WriteLn(StdErr, 'NUS write failed.');
  end;
end;

procedure TNusTerminalApplication.RunTerminal;
var
  InputLine: string;
begin
  WriteLn('NUS terminal is ready.');
  WriteLn('Enter text to write its UTF-8 bytes to NUS RX, or /quit to stop.');
  repeat
    EnterCriticalSection(FOutputLock);
    try
      Write('> ');
    finally
      LeaveCriticalSection(FOutputLock);
    end;
    ReadLn(InputLine);
    if Eof(Input) and (InputLine = '') then
      Break;
    if SameText(Trim(InputLine), '/quit') then
      Break;
    if InputLine = '' then
      Continue;
    SendText(InputLine, 5000);
  until False;
end;

procedure TNusTerminalApplication.ShutdownBle;
var
  Deadline: QWord;
begin
  if Assigned(FProfile) then
  begin
    FProfile.OnData := nil;
    FProfile.Detach;
    FreeAndNil(FProfile);
  end;
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

procedure TNusTerminalApplication.Fail(const AMessage: string);
begin
  WriteLn(StdErr, AMessage);
  ExitCode := 1;
  Terminate;
end;

procedure TNusTerminalApplication.DoRun;
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

  FProfile := TNusProfile.Create(FSession);
  FProfile.OnData := @NusDataReceived;
  FProfile.Attach;
  if not WaitForProfileReady(10000) then
  begin
    Fail('Could not subscribe to NUS TX notifications.');
    Exit;
  end;

  RunTerminal;
  ShutdownBle;
  Terminate;
end;

procedure TNusTerminalApplication.WriteHelp;
begin
  WriteLn('Usage: ', ExeName,
    ' [--adapter ID] [--device ADDRESS] [--timeout MILLISECONDS]');
  WriteLn;
  WriteLn('Scans for a BLE device and opens a Nordic UART Service terminal.');
  WriteLn('Received notifications are printed as HEX and ASCII.');
  WriteLn('Input lines are sent as UTF-8 bytes without an added line ending.');
  WriteLn('Set SIMPLECBLE_LIBRARY_DIR if native libraries are elsewhere.');
end;

var
  Application: TNusTerminalApplication;
begin
  Application := TNusTerminalApplication.Create(nil);
  Application.Title := 'NusTerminal';
  try
    Application.Run;
  finally
    Application.Free;
  end;
end.
