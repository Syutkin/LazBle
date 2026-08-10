program BatteryMonitor;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  CustApp,
  LazBleTypes,
  LazBleClientSync,
  LazBleBattery,
  BleExampleUtils;

type
  TBatteryMonitorApplication = class(TCustomApplication)
  private
    FClientSync: TBleClientSync;
    FConnection: TBleConnection;
    FProfile: TBleBatteryProfile;
    procedure BatteryLevelChanged(Sender: TObject; const ADeviceId: string;
      const ALevelPercent: Integer);
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
end;

destructor TBatteryMonitorApplication.Destroy;
begin
  ShutdownBle;
  inherited Destroy;
end;

procedure TBatteryMonitorApplication.BatteryLevelChanged(Sender: TObject;
  const ADeviceId: string; const ALevelPercent: Integer);
begin
  WriteLn(ADeviceId, ': battery ', ALevelPercent, '%');
end;

procedure TBatteryMonitorApplication.ShutdownBle;
var
  ErrorMessage: string;
begin
  if Assigned(FProfile) then
    FProfile.OnLevelChanged := nil;
  if Assigned(FClientSync) and Assigned(FConnection) then
    FClientSync.Disconnect(FConnection, 5000, ErrorMessage);
  FProfile := nil;
  FConnection := nil;
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

  FConnection := FClientSync.CreateConnection(DeviceId);
  FProfile := TBleBatteryProfile.Create(FConnection.Session);
  FProfile.OnLevelChanged := @BatteryLevelChanged;
  FConnection.AddProfile(FProfile, True);

  WriteLn('Connecting to ', DeviceId, '...');
  if not FClientSync.Connect(FConnection, 15000, ErrorMessage) then
  begin
    if ErrorMessage = '' then
      ErrorMessage := 'Could not connect and discover GATT services.';
    Fail(ErrorMessage);
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
