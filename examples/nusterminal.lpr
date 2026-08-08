program NusTerminal;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  CustApp,
  LazBleTypes,
  LazBleGattOperation,
  LazBleGattSession,
  LazBleClientSync,
  LazBleByteChannel,
  LazBleNus,
  BleExampleUtils;

type
  TNusTerminalApplication = class(TCustomApplication)
  private
    FClientSync: TBleClientSync;
    FSession: TBleGattSession;
    FProfile: TNusProfile;
    FOutputLock: TRTLCriticalSection;
    procedure NusDataReceived(Sender: TObject; const ADeviceId: string;
      const AValue: TBytes);
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
  InitCriticalSection(FOutputLock);
end;

destructor TNusTerminalApplication.Destroy;
begin
  ShutdownBle;
  DoneCriticalSection(FOutputLock);
  inherited Destroy;
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
  ErrorMessage: string;
begin
  if Assigned(FProfile) then
  begin
    FProfile.OnData := nil;
    FProfile.Detach;
    FreeAndNil(FProfile);
  end;
  if Assigned(FClientSync) and Assigned(FSession) then
    FClientSync.Disconnect(FSession, 5000, ErrorMessage);
  FSession := nil;
  if Assigned(FClientSync) then
    FClientSync.Shutdown(5000, ErrorMessage);
  FreeAndNil(FClientSync);
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
  DeviceId: string;
  Devices: TBleDeviceInfos;
  ErrorMessage: string;
  RequestedDeviceId: string;
  ScanTimeoutMs: Cardinal;
begin
  ErrorMessage := CheckOptions('ha:d:t:', [
    'help', 'adapter:', 'device:', 'timeout:']);
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
  RequestedDeviceId := GetOptionValue('d', 'device');
  FClientSync := TBleClientSync.Create;

  WriteLn('Scanning for BLE devices...');
  if not FClientSync.Scan(AdapterId, ScanTimeoutMs, Devices,
    ErrorMessage) then
  begin
    if ErrorMessage = '' then
      ErrorMessage := 'BLE scan failed.';
    Fail(ErrorMessage);
    Exit;
  end;
  if not SelectBleDevice(Devices, RequestedDeviceId, DeviceId) then
  begin
    Fail('No device was selected.');
    Exit;
  end;

  WriteLn('Connecting to ', DeviceId, '...');
  if not FClientSync.Connect(DeviceId, 15000, FSession,
    ErrorMessage) then
  begin
    if ErrorMessage = '' then
      ErrorMessage := 'Could not connect and discover GATT services.';
    Fail(ErrorMessage);
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
