unit LazBleDeviceInformation;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LazBleTypes, LazBleOperation, LazBleGattOperation,
  LazBleGattProfile, LazBleGattReader;

const
  DeviceInformationServiceUuid = '0000180A-0000-1000-8000-00805F9B34FB';
  DeviceInformationManufacturerNameUuid = '00002A29-0000-1000-8000-00805F9B34FB';
  DeviceInformationModelNumberUuid = '00002A24-0000-1000-8000-00805F9B34FB';
  DeviceInformationSerialNumberUuid = '00002A25-0000-1000-8000-00805F9B34FB';
  DeviceInformationHardwareRevisionUuid = '00002A27-0000-1000-8000-00805F9B34FB';
  DeviceInformationFirmwareRevisionUuid = '00002A26-0000-1000-8000-00805F9B34FB';
  DeviceInformationSoftwareRevisionUuid = '00002A28-0000-1000-8000-00805F9B34FB';
  DeviceInformationSystemIdUuid = '00002A23-0000-1000-8000-00805F9B34FB';
  DeviceInformationRegulatoryCertificationDataListUuid = '00002A2A-0000-1000-8000-00805F9B34FB';
  DeviceInformationPnpIdUuid = '00002A50-0000-1000-8000-00805F9B34FB';
  DeviceInformationUdiForMedicalDevicesUuid = '00002BFF-0000-1000-8000-00805F9B34FB';

type
  TBleDeviceInformationCharacteristic = (dicManufacturerName, dicModelNumber,
    dicSerialNumber, dicHardwareRevision, dicFirmwareRevision, dicSoftwareRevision,
    dicSystemId, dicRegulatoryCertificationDataList, dicPnpId, dicUdiForMedicalDevices);
  TBleDeviceInformationCharacteristics = set of TBleDeviceInformationCharacteristic;

  TBleSystemId = record
    ManufacturerIdentifier: QWord; { 40 bits }
    OrganizationallyUniqueIdentifier: Cardinal; { 24 bits }
  end;

  TBlePnpId = record
    VendorIdSource: Byte; { 1: Bluetooth SIG; 2: USB Implementer's Forum }
    VendorId, ProductId: Word;
    ProductVersion: Word; { BCD 0xJJMN, representing JJ.M.N }
  end;

  TBleUdiForMedicalDevices = record
    HasUdiLabel, HasUdiDeviceIdentifier, HasUdiIssuer, HasUdiAuthority: Boolean;
    UdiLabel, UdiDeviceIdentifier, UdiIssuer, UdiAuthority: UTF8String;
  end;

  { Read-only snapshot published after a complete successful read cycle.
    PresentFields distinguishes missing fields from empty strings and zeroes. }
  TBleDeviceInformationData = record
    PresentFields: TBleDeviceInformationCharacteristics;
    ManufacturerName, ModelNumber, SerialNumber: UTF8String;
    HardwareRevision, FirmwareRevision, SoftwareRevision: UTF8String;
    SystemId: TBleSystemId;
    PnpId: TBlePnpId;
    { Encoded IEEE 11073-20601 list; its internal format is not decoded here. }
    RegulatoryCertificationDataList: TBytes;
    UdiForMedicalDevices: TBleUdiForMedicalDevices;
  end;

  { Read-only DIS client. Reads all discovered fields on attach, without
    subscriptions. Only one unambiguously addressable service is supported. }
  TBleDeviceInformationProfile = class(TBleGattProfile)
  private
    FData, FPendingData: TBleDeviceInformationData;
    FAvailable: TBleDeviceInformationCharacteristics;
    FIndex: Integer;
    FReading: Boolean;
    FEpoch: QWord;
    FReadOperation: IBleGattOperation;
    FRefreshOperation: IBleOperation;
    FRefreshObject: TBleOperation;
    FOnUpdated: TNotifyEvent;
    function DiscoverCharacteristics: Boolean;
    procedure BeginRead;
    procedure StartNextRead;
    procedure ReadCompleted(Sender: TObject);
    procedure FinishRead(const AState: TLazBleOperationState;
      const ACode: Integer = 0; const AMessage: string = '');
    procedure RefreshCancelled(Sender: TObject);
    function GetData: TBleDeviceInformationData;
    function GetAvailable: TBleDeviceInformationCharacteristics;
    function GetOnUpdated: TNotifyEvent;
    procedure SetOnUpdated(const AHandler: TNotifyEvent);
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  public
    destructor Destroy; override;
    { Ready remains true during refresh; failure/cancellation keeps the previous
      snapshot. Only one read cycle can be pending. }
    function RefreshAsync: IBleOperation;
    property AvailableCharacteristics: TBleDeviceInformationCharacteristics read GetAvailable;
    property Data: TBleDeviceInformationData read GetData;
    { Once per successful complete snapshot, including unchanged values. No replay. }
    property OnUpdated: TNotifyEvent read GetOnUpdated write SetOnUpdated;
  end;

implementation

uses LazBleGattSession;

const
  CharacteristicUuids: array[TBleDeviceInformationCharacteristic] of string = (
    DeviceInformationManufacturerNameUuid, DeviceInformationModelNumberUuid,
    DeviceInformationSerialNumberUuid, DeviceInformationHardwareRevisionUuid,
    DeviceInformationFirmwareRevisionUuid, DeviceInformationSoftwareRevisionUuid,
    DeviceInformationSystemIdUuid, DeviceInformationRegulatoryCertificationDataListUuid,
    DeviceInformationPnpIdUuid, DeviceInformationUdiForMedicalDevicesUuid);
  CharacteristicNames: array[TBleDeviceInformationCharacteristic] of string = (
    'Manufacturer Name', 'Model Number', 'Serial Number', 'Hardware Revision',
    'Firmware Revision', 'Software Revision', 'System ID',
    'IEEE 11073-20601 Regulatory Certification Data List', 'PnP ID', 'UDI for Medical Devices');

type
  TDeviceInformationRefresh = class(TBleOperation)
  public
    constructor Create(const ACancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const ACode: Integer; const AMessage: string);
  end;

constructor TDeviceInformationRefresh.Create(const ACancel: TLazBleOperationCancelEvent);
begin inherited Create(ACancel); end;

procedure TDeviceInformationRefresh.Finish(const AState: TLazBleOperationState;
  const ACode: Integer; const AMessage: string);
begin Complete(AState, ACode, AMessage); end;

function ReadUdiText(var AReader: TBleGattReader; const AData: TBytes): UTF8String;
var Start: SizeInt; TextReader: TBleGattReader;
begin
  Result := '';
  Start := AReader.Position;
  while AReader.Valid do
    if AReader.UInt(1) = 0 then Break;
  if not AReader.Valid then Exit;
  TextReader := TBleGattReader.Create(Copy(AData, Start, AReader.Position - Start - 1));
  Result := TextReader.Utf8Text;
  if not TextReader.Finished then AReader.Invalidate;
end;

function DecodeValue(const AKind: TBleDeviceInformationCharacteristic;
  const AValue: TBytes; var AData: TBleDeviceInformationData): Boolean;
var Reader: TBleGattReader; Flags: Byte; I: Integer;
begin
  Reader := TBleGattReader.Create(AValue);
  case AKind of
    dicManufacturerName: AData.ManufacturerName := Reader.Utf8Text;
    dicModelNumber: AData.ModelNumber := Reader.Utf8Text;
    dicSerialNumber: AData.SerialNumber := Reader.Utf8Text;
    dicHardwareRevision: AData.HardwareRevision := Reader.Utf8Text;
    dicFirmwareRevision: AData.FirmwareRevision := Reader.Utf8Text;
    dicSoftwareRevision: AData.SoftwareRevision := Reader.Utf8Text;
    dicSystemId:
      begin
        AData.SystemId.ManufacturerIdentifier := Reader.UInt(5);
        AData.SystemId.OrganizationallyUniqueIdentifier := Reader.UInt(3);
      end;
    dicPnpId:
      begin
        AData.PnpId.VendorIdSource := Reader.UInt(1);
        AData.PnpId.VendorId := Reader.UInt(2);
        AData.PnpId.ProductId := Reader.UInt(2);
        AData.PnpId.ProductVersion := Reader.UInt(2);
        if not (AData.PnpId.VendorIdSource in [1, 2]) then Reader.Invalidate;
        for I := 0 to 3 do
          if ((AData.PnpId.ProductVersion shr (I * 4)) and $F) > 9 then Reader.Invalidate;
      end;
    dicRegulatoryCertificationDataList:
      begin
        AData.RegulatoryCertificationDataList := Copy(AValue);
        Include(AData.PresentFields, AKind);
        Exit(True);
      end;
    dicUdiForMedicalDevices:
      begin
        Flags := Reader.UInt(1);
        if (Flags and 3) = 0 then Reader.Invalidate;
        with AData.UdiForMedicalDevices do
        begin
          HasUdiLabel := (Flags and 1) <> 0;
          HasUdiDeviceIdentifier := (Flags and 2) <> 0;
          HasUdiIssuer := (Flags and 4) <> 0;
          HasUdiAuthority := (Flags and 8) <> 0;
          if HasUdiLabel then UdiLabel := ReadUdiText(Reader, AValue);
          if HasUdiDeviceIdentifier then UdiDeviceIdentifier := ReadUdiText(Reader, AValue);
          if HasUdiIssuer then UdiIssuer := ReadUdiText(Reader, AValue);
          if HasUdiAuthority then UdiAuthority := ReadUdiText(Reader, AValue);
        end;
      end;
  end;
  Result := Reader.Finished;
  if Result then Include(AData.PresentFields, AKind);
end;

destructor TBleDeviceInformationProfile.Destroy;
begin
  FOnUpdated := nil;
  Detach;
  inherited Destroy;
end;

function TBleDeviceInformationProfile.GetData: TBleDeviceInformationData;
begin LazBleRequireMainThread; Result := FData; end;

function TBleDeviceInformationProfile.GetAvailable: TBleDeviceInformationCharacteristics;
begin LazBleRequireMainThread; Result := FAvailable; end;

function TBleDeviceInformationProfile.GetOnUpdated: TNotifyEvent;
begin LazBleRequireMainThread; Result := FOnUpdated; end;

procedure TBleDeviceInformationProfile.SetOnUpdated(const AHandler: TNotifyEvent);
begin LazBleRequireMainThread; FOnUpdated := AHandler; end;

function TBleDeviceInformationProfile.DiscoverCharacteristics: Boolean;
var Kind: TBleDeviceInformationCharacteristic;
  Service: TLazBleGattService; Candidate, Characteristic: TLazBleGattCharacteristic;
  Count: Integer;
begin
  Result := False;
  Count := 0;
  for Service in Session.Services do
    if SameText(UTF8Encode(Service.Uuid), DeviceInformationServiceUuid) then Inc(Count);
  if Count = 0 then
  begin
    MarkError('Device Information Service was not found', LazBleErrorGattNotFound);
    Exit;
  end;
  if Count <> 1 then
  begin
    MarkError('Device Information Service must have one addressable instance',
      LazBleErrorInvalidProfileData);
    Exit;
  end;
  for Kind in TBleDeviceInformationCharacteristic do
  begin
    Count := 0;
    for Service in Session.Services do
      if SameText(UTF8Encode(Service.Uuid), DeviceInformationServiceUuid) then
        for Candidate in Service.Characteristics do
          if SameText(UTF8Encode(Candidate.Uuid), CharacteristicUuids[Kind]) then Inc(Count);
    if Count > 1 then
    begin
      MarkError(CharacteristicNames[Kind] + ': ambiguous characteristic instance',
        LazBleErrorInvalidProfileData);
      Exit;
    end;
    if not Session.TryGetCharacteristic(DeviceInformationServiceUuid,
      CharacteristicUuids[Kind], Characteristic) then Continue;
    if not Characteristic.CanRead then
    begin
      MarkError(CharacteristicNames[Kind] + ': Read is not supported',
        LazBleErrorGattPropertyNotSupported);
      Exit;
    end;
    Include(FAvailable, Kind);
  end;
  Result := True;
end;

procedure TBleDeviceInformationProfile.BeginRead;
begin
  Inc(FEpoch);
  FPendingData := Default(TBleDeviceInformationData);
  FIndex := -1;
  FReading := True;
  StartNextRead;
end;

procedure TBleDeviceInformationProfile.StartNextRead;
begin
  Inc(FIndex);
  while (FIndex <= Ord(High(TBleDeviceInformationCharacteristic))) and
    not (TBleDeviceInformationCharacteristic(FIndex) in FAvailable) do Inc(FIndex);
  if FIndex > Ord(High(TBleDeviceInformationCharacteristic)) then
  begin
    FinishRead(lbopSucceeded);
    Exit;
  end;
  FReadOperation := Session.ReadAsync(DeviceInformationServiceUuid,
    CharacteristicUuids[TBleDeviceInformationCharacteristic(FIndex)]);
  FReadOperation.OnCompleted := @ReadCompleted;
end;

procedure TBleDeviceInformationProfile.ReadCompleted(Sender: TObject);
var Operation: IBleGattOperation; Kind: TBleDeviceInformationCharacteristic;
begin
  if not FReading or not Assigned(FReadOperation) then Exit;
  Operation := FReadOperation;
  if (Operation as TObject) <> Sender then Exit;
  FReadOperation := nil;
  Operation.OnCompleted := nil;
  Kind := TBleDeviceInformationCharacteristic(FIndex);
  if Operation.State <> lbopSucceeded then
  begin
    FinishRead(Operation.State, Operation.ErrorCode,
      CharacteristicNames[Kind] + ': read failed: ' + Operation.ErrorMessage);
    Exit;
  end;
  if Assigned(FRefreshOperation) and FRefreshOperation.CancelRequested then
  begin
    FinishRead(lbopCancelled);
    Exit;
  end;
  if (Session.Generation <> AttachedGeneration) or (Session.State <> lbssConnected) then
  begin
    FinishRead(lbopFailed, LazBleErrorDeviceDisconnected, 'Device Information connection ended');
    Exit;
  end;
  if not DecodeValue(Kind, Operation.Value, FPendingData) then
  begin
    FinishRead(lbopFailed, LazBleErrorInvalidProfileData, CharacteristicNames[Kind] + ': invalid value');
    Exit;
  end;
  StartNextRead;
end;

procedure TBleDeviceInformationProfile.FinishRead(const AState: TLazBleOperationState;
  const ACode: Integer; const AMessage: string);
var Refresh: IBleOperation; RefreshObject: TDeviceInformationRefresh;
  Handler: TNotifyEvent; Epoch: QWord;
begin
  FReading := False;
  Refresh := FRefreshOperation;
  RefreshObject := TDeviceInformationRefresh(FRefreshObject);
  FRefreshOperation := nil;
  FRefreshObject := nil;
  if AState = lbopSucceeded then FData := FPendingData;
  FPendingData := Default(TBleDeviceInformationData);
  Epoch := FEpoch;
  try
    if AState = lbopSucceeded then
    begin
      if CurrentState = lbgpsAttaching then MarkReady;
      if (FEpoch <> Epoch) or (CurrentState <> lbgpsReady) then Exit;
      Handler := FOnUpdated;
      if Assigned(Handler) then Handler(Self);
    end
    else if (AState <> lbopCancelled) or not Assigned(Refresh) then
      MarkError(AMessage, ACode);
  finally
    if Assigned(Refresh) then RefreshObject.Finish(AState, ACode, AMessage);
  end;
end;

function TBleDeviceInformationProfile.RefreshAsync: IBleOperation;
var Operation: TDeviceInformationRefresh;
begin
  LazBleRequireMainThread;
  Operation := TDeviceInformationRefresh.Create(@RefreshCancelled);
  Result := Operation;
  if (CurrentState <> lbgpsReady) or FReading then
  begin
    Operation.Finish(lbopFailed, LazBleErrorInvalidState,
      'Device Information profile is not ready or a refresh is already pending');
    Exit;
  end;
  FRefreshOperation := Result;
  FRefreshObject := Operation;
  BeginRead;
end;

procedure TBleDeviceInformationProfile.RefreshCancelled(Sender: TObject);
begin
  if Assigned(FReadOperation) then FReadOperation.Cancel;
end;

procedure TBleDeviceInformationProfile.DoAttach;
begin
  if CurrentState <> lbgpsAttaching then Exit;
  FData := Default(TBleDeviceInformationData);
  FAvailable := [];
  if DiscoverCharacteristics then BeginRead;
end;

procedure TBleDeviceInformationProfile.DoDetach;
var Read: IBleGattOperation; Refresh: IBleOperation;
  RefreshObject: TDeviceInformationRefresh;
begin
  Inc(FEpoch);
  FReading := False;
  Read := FReadOperation; FReadOperation := nil;
  Refresh := FRefreshOperation; FRefreshOperation := nil;
  RefreshObject := TDeviceInformationRefresh(FRefreshObject); FRefreshObject := nil;
  FData := Default(TBleDeviceInformationData);
  FPendingData := Default(TBleDeviceInformationData);
  FAvailable := [];
  if Assigned(Read) then
  begin
    Read.OnCompleted := nil;
    Read.Cancel;
  end;
  if Assigned(Refresh) then RefreshObject.Finish(lbopCancelled, 0, '');
end;

end.
