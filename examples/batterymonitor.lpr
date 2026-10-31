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
  LazBleOperation,
  LazBleClient,
  LazBleSync,
  LazBleBattery,
  LazBleGattReader,
  BleExampleUtils;

type
  TBatteryMonitorApplication = class(TCustomApplication)
  private
    FBleSync: TLazBleSync;
    FClient: TBleClient;
    FProfile: TBleBatteryProfile;
    procedure BatteryLevelChanged(Sender: TObject; const ADeviceId: string;
      const ALevelPercent: Integer);
    procedure BatteryUpdated(Sender: TObject);
    procedure RefreshCompleted(Sender: TObject);
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

procedure PrintValue(const AName: string; const AValue: TBleGattValue);
const
  StateNames: array[TBleGattValueState] of string = (
    'absent', 'finite', 'unknown', 'greater than', 'less than',
    'NaN', 'not at resolution', '+infinity', '-infinity');
begin
  if AValue.State = lgvsAbsent then Exit;
  if AValue.State = lgvsFinite then WriteLn('  ', AName, ': ', AValue.Value:0:3)
  else if AValue.State in [lgvsGreaterThan, lgvsLessThan] then
    WriteLn('  ', AName, ': ', StateNames[AValue.State], ' ', AValue.Value:0:0)
  else WriteLn('  ', AName, ': ', StateNames[AValue.State]);
end;

procedure TBatteryMonitorApplication.BatteryUpdated(Sender: TObject);
var
  Snapshot: TBleBatteryData;
begin
  Snapshot := FProfile.Data;
  WriteLn('Battery data:');
  if Snapshot.LevelStatus.HasValue then
    WriteLn('  present=', Snapshot.LevelStatus.BatteryPresent,
      ' charge_state=', Ord(Snapshot.LevelStatus.ChargeState));
  if Snapshot.CriticalStatus.HasValue then
    WriteLn('  critical=', Snapshot.CriticalStatus.CriticalPowerState,
      ' immediate_service=', Snapshot.CriticalStatus.ImmediateServiceRequired);
  PrintValue('external source power (W)', Snapshot.EnergyStatus.ExternalSourcePowerWatts);
  PrintValue('present voltage (V)', Snapshot.EnergyStatus.PresentVoltageVolts);
  PrintValue('available energy (kWh)', Snapshot.EnergyStatus.AvailableEnergyKWh);
  PrintValue('available battery capacity (kWh)', Snapshot.EnergyStatus.AvailableBatteryCapacityKWh);
  PrintValue('charge rate (W)', Snapshot.EnergyStatus.ChargeRateWatts);
  PrintValue('available energy at last charge (kWh)', Snapshot.EnergyStatus.AvailableEnergyAtLastChargeKWh);
  PrintValue('time until discharged (min)', Snapshot.TimeStatus.TimeUntilDischargedMinutes);
  PrintValue('time until discharged on standby (min)', Snapshot.TimeStatus.TimeUntilDischargedOnStandbyMinutes);
  PrintValue('time until recharged (min)', Snapshot.TimeStatus.TimeUntilRechargedMinutes);
  PrintValue('battery health summary (%)', Snapshot.HealthStatus.HealthSummaryPercent);
  PrintValue('cycle count', Snapshot.HealthStatus.CycleCount);
  PrintValue('current temperature (C)', Snapshot.HealthStatus.CurrentTemperatureCelsius);
  PrintValue('deep discharge count', Snapshot.HealthStatus.DeepDischargeCount);
  PrintValue('cycle count designed lifetime', Snapshot.HealthInformation.CycleCountDesignedLifetime);
  PrintValue('min designed operating temperature (C)', Snapshot.HealthInformation.MinDesignedOperatingTemperatureCelsius);
  PrintValue('max designed operating temperature (C)', Snapshot.HealthInformation.MaxDesignedOperatingTemperatureCelsius);
  if Snapshot.Information.HasValue then
    WriteLn('  replaceable=', Snapshot.Information.Replaceable,
      ' rechargeable=', Snapshot.Information.Rechargeable);
  PrintValue('battery manufacture date (UTC days since 1970)', Snapshot.Information.ManufactureDateDaysSince1970);
  PrintValue('battery expiration date (UTC days since 1970)', Snapshot.Information.ExpirationDateDaysSince1970);
  PrintValue('battery designed capacity (kWh)', Snapshot.Information.DesignedCapacityKWh);
  PrintValue('low energy (kWh)', Snapshot.Information.LowEnergyKWh);
  PrintValue('critical energy (kWh)', Snapshot.Information.CriticalEnergyKWh);
  PrintValue('nominal voltage (V)', Snapshot.Information.NominalVoltageVolts);
  PrintValue('estimated service date (UTC days since 1970)', Snapshot.EstimatedServiceDateDaysSince1970);
  if Snapshot.Information.HasChemistry then
    WriteLn('  chemistry code: ', Ord(Snapshot.Information.Chemistry));
  if Snapshot.ManufacturerName.HasValue then WriteLn('  manufacturer: ', Snapshot.ManufacturerName.Value);
  if Snapshot.ModelNumber.HasValue then WriteLn('  model: ', Snapshot.ModelNumber.Value);
  if Snapshot.SerialNumber.HasValue then WriteLn('  serial: ', Snapshot.SerialNumber.Value);
end;

procedure TBatteryMonitorApplication.RefreshCompleted(Sender: TObject);
var
  Operation: TBleOperation;
begin
  Operation := TBleOperation(Sender);
  if Operation.State = lbopSucceeded then WriteLn('Battery refresh complete.')
  else if Operation.State = lbopCancelled then WriteLn('Battery refresh cancelled.')
  else WriteLn(StdErr, 'Battery refresh: ', Operation.ErrorMessage);
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
  begin
    FProfile.OnLevelChanged := nil;
    FProfile.OnUpdated := nil;
  end;
  if Assigned(FBleSync) and Assigned(FClient) then
    FBleSync.Disconnect(FClient, 5000, ErrorMessage);
  FProfile := nil;
  FClient := nil;
  if Assigned(FBleSync) then
    FBleSync.Shutdown(5000, ErrorMessage);
  FreeAndNil(FBleSync);
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
  InputLine: string;
  Refresh: IBleOperation;
begin
  Refresh := nil;
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
  if not SelectBleDevice(Devices, RequestedDeviceId, DeviceId) then
  begin
    Fail('No device was selected.');
    Exit;
  end;

  FClient := FBleSync.CreateClient(DeviceId);
  FProfile := TBleBatteryProfile.Create;
  FProfile.OnLevelChanged := @BatteryLevelChanged;
  FProfile.OnUpdated := @BatteryUpdated;
  FClient.AddProfile(FProfile, True);

  WriteLn('Connecting to ', DeviceId, '...');
  if not FBleSync.Connect(FClient, 15000, ErrorMessage) then
  begin
    if ErrorMessage = '' then
      ErrorMessage := 'Could not connect and discover GATT services.';
    Fail(ErrorMessage);
    Exit;
  end;

  WriteLn('Monitoring Battery Service. Enter r to refresh, or an empty line to stop.');
  while ReadBleConsoleLine(InputLine) do
  begin
    if Trim(InputLine) = '' then Break;
    if SameText(Trim(InputLine), 'r') then
    begin
      if Assigned(Refresh) and (Refresh.State = lbopPending) then
      begin
        WriteLn('A battery refresh is already pending.');
        Continue;
      end;
      if Assigned(Refresh) then Refresh.OnCompleted := nil;
      Refresh := FProfile.RefreshAsync;
      Refresh.OnCompleted := @RefreshCompleted;
    end;
  end;
  if Assigned(Refresh) then Refresh.OnCompleted := nil;
  ShutdownBle;
  Terminate;
end;

procedure TBatteryMonitorApplication.WriteHelp;
begin
  WriteLn('Usage: ', ExeName,
    ' [--adapter ID] [--device ADDRESS] [--timeout MILLISECONDS]');
  WriteLn;
  WriteLn('Reads Battery Level and available Battery Service 1.1 data.');
  WriteLn('Prints updates; enter r to refresh a read-only device.');
  WriteLn('Deploy the matching SimpleCBLE runtime beside the executable or in the system library path.');
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
