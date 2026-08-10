program GattInspect;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  CustApp,
  LazBleTypes,
  LazBleClient,
  LazBleSync,
  BleExampleUtils;

type
  TGattInspectApplication = class(TCustomApplication)
  private
    FBleSync: TLazBleSync;
    FClient: TBleClient;
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
end;

destructor TGattInspectApplication.Destroy;
begin
  ShutdownBle;
  inherited Destroy;
end;

procedure TGattInspectApplication.PrintGattSnapshot;
var
  CharacteristicIndex: Integer;
  DescriptorIndex: Integer;
  ServiceIndex: Integer;
  Services: TLazBleGattServices;
begin
  Services := FClient.Services;
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
  ErrorMessage: string;
begin
  if Assigned(FBleSync) and Assigned(FClient) then
    FBleSync.Disconnect(FClient, 5000, ErrorMessage);
  FClient := nil;
  if Assigned(FBleSync) then
    FBleSync.Shutdown(5000, ErrorMessage);
  FreeAndNil(FBleSync);
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

  WriteLn('Connecting to ', DeviceId, '...');
  FClient := FBleSync.CreateClient(DeviceId);
  if not FBleSync.Connect(FClient, 15000, ErrorMessage) then
  begin
    if ErrorMessage = '' then
      ErrorMessage := 'Could not connect and discover GATT services.';
    Fail(ErrorMessage);
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
