program BatteryMonitor;

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
  LazBleGattSession,
  LazBleClientSync,
  LazBleBattery,
  BleExampleUtils;

type
  TBatteryMonitorApplication = class(TCustomApplication)
  private
    FClientSync: TBleClientSync;
    FSession: TBleGattSession;
    FProfile: TBleBatteryProfile;
    FBatteryLevelEvent: TEvent;
    procedure BatteryLevelChanged(Sender: TObject; const ADeviceId: string;
      const ALevelPercent: Integer);
    function WaitForInitialBatteryLevel(const ATimeoutMs: Cardinal): Boolean;
    function WaitForBatteryReady(const ATimeoutMs: Cardinal): Boolean;
    procedure ShutdownBle;
    procedure Fail(const AMessage: string);
  protected
    procedure DoRun; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteHelp; virtual;
  end;

constructor TBatteryMonitorApplication.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  StopOnException := True;
  FBatteryLevelEvent := TEvent.Create(nil, True, False, '');
end;

destructor TBatteryMonitorApplication.Destroy;
begin
  ShutdownBle;
  FBatteryLevelEvent.Free;
  inherited Destroy;
end;

procedure TBatteryMonitorApplication.BatteryLevelChanged(Sender: TObject;
  const ADeviceId: string; const ALevelPercent: Integer);
begin
  WriteLn(ADeviceId, ': battery ', ALevelPercent, '%');
  FBatteryLevelEvent.SetEvent;
end;

function TBatteryMonitorApplication.WaitForBatteryReady(
  const ATimeoutMs: Cardinal): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if FProfile.Ready then
      Exit(True);
    if FProfile.State = lbbsError then
      Exit(False);
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(10);
  until False;
end;

function TBatteryMonitorApplication.WaitForInitialBatteryLevel(
  const ATimeoutMs: Cardinal): Boolean;
var
  Deadline: QWord;
  RemainingMs: QWord;
begin
  Deadline := GetTickCount64 + ATimeoutMs;
  repeat
    if FProfile.LevelPercent <> UnknownBatteryLevel then
      Exit(True);
    if FProfile.State = lbbsError then
      Exit(False);
    if GetTickCount64 >= Deadline then
      Exit(False);
    RemainingMs := Deadline - GetTickCount64;
    if RemainingMs > 100 then
      RemainingMs := 100;
    FBatteryLevelEvent.WaitFor(RemainingMs);
    FBatteryLevelEvent.ResetEvent;
  until False;
end;

procedure TBatteryMonitorApplication.ShutdownBle;
var
  ErrorMessage: string;
begin
  if Assigned(FProfile) then
  begin
    FProfile.OnLevelChanged := nil;
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

procedure TBatteryMonitorApplication.Fail(const AMessage: string);
begin
  WriteLn(StdErr, AMessage);
  ExitCode := 1;
  Terminate;
end;

procedure TBatteryMonitorApplication.DoRun;
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

  FProfile := TBleBatteryProfile.Create(FSession);
  FProfile.OnLevelChanged := @BatteryLevelChanged;
  FProfile.Attach;
  if not WaitForInitialBatteryLevel(10000) then
  begin
    if FProfile.ErrorMessage <> '' then
      Fail(FProfile.ErrorMessage)
    else
      Fail('Could not read Battery Level.');
    Exit;
  end;
  if not WaitForBatteryReady(5000) then
  begin
    if FProfile.ErrorMessage <> '' then
      Fail(FProfile.ErrorMessage)
    else
      Fail('Could not subscribe to Battery Level notifications.');
    Exit;
  end;

  WriteLn('Monitoring Battery Service notifications. Press Enter to stop.');
  ReadLn;
  ShutdownBle;
  Terminate;
end;

procedure TBatteryMonitorApplication.WriteHelp;
begin
  WriteLn('Usage: ', ExeName,
    ' [--adapter ID] [--device ADDRESS] [--timeout MILLISECONDS]');
  WriteLn;
  WriteLn('Scans for a BLE device, reads Battery Level (0x2A19), and');
  WriteLn('prints subsequent Battery Service notifications.');
  WriteLn('Set SIMPLECBLE_LIBRARY_DIR if native libraries are elsewhere.');
end;

var
  Application: TBatteryMonitorApplication;
begin
  Application := TBatteryMonitorApplication.Create(nil);
  Application.Title := 'BatteryMonitor';
  try
    Application.Run;
  finally
    Application.Free;
  end;
end.
