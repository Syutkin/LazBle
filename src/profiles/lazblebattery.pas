unit LazBleBattery;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LazBleTypes, LazBleBackend, LazBleOperation, LazBleGattOperation,
  LazBleGattSubscription, LazBleGattSession, LazBleGattProfile, LazBleGattReader;

const
  BatteryServiceUuid = '0000180F-0000-1000-8000-00805F9B34FB';
  BatteryLevelCharacteristicUuid = '00002A19-0000-1000-8000-00805F9B34FB';
  BatteryLevelStatusCharacteristicUuid = '00002BED-0000-1000-8000-00805F9B34FB';
  BatteryCriticalStatusCharacteristicUuid = '00002BE9-0000-1000-8000-00805F9B34FB';
  BatteryEnergyStatusCharacteristicUuid = '00002BF0-0000-1000-8000-00805F9B34FB';
  BatteryTimeStatusCharacteristicUuid = '00002BEE-0000-1000-8000-00805F9B34FB';
  BatteryHealthStatusCharacteristicUuid = '00002BEA-0000-1000-8000-00805F9B34FB';
  BatteryHealthInformationCharacteristicUuid = '00002BEB-0000-1000-8000-00805F9B34FB';
  BatteryInformationCharacteristicUuid = '00002BEC-0000-1000-8000-00805F9B34FB';
  EstimatedServiceDateCharacteristicUuid = '00002BEF-0000-1000-8000-00805F9B34FB';
  BatteryManufacturerNameCharacteristicUuid = '00002A29-0000-1000-8000-00805F9B34FB';
  BatteryModelNumberCharacteristicUuid = '00002A24-0000-1000-8000-00805F9B34FB';
  BatterySerialNumberCharacteristicUuid = '00002A25-0000-1000-8000-00805F9B34FB';
  UnknownBatteryLevel = -1;

type
  TBleBatteryCharacteristic = (bbcLevel, bbcLevelStatus, bbcCriticalStatus,
    bbcEnergyStatus, bbcTimeStatus, bbcHealthStatus, bbcHealthInformation,
    bbcInformation, bbcServiceDate, bbcManufacturerName, bbcModelNumber, bbcSerialNumber);
  TBleBatteryCharacteristics = set of TBleBatteryCharacteristic;
  TBleBatteryPowerConnection = (bbpcNo, bbpcYes, bbpcUnknown);
  TBleBatteryChargeState = (bbcsUnknown, bbcsCharging,
    bbcsDischargingActive, bbcsDischargingInactive);
  TBleBatteryChargeLevel = (bbclUnknown, bbclGood, bbclLow, bbclCritical);
  TBleBatteryChargingType = (bbctUnknown, bbctConstantCurrent,
    bbctConstantVoltage, bbctTrickle, bbctFloat);
  TBleBatteryServiceRequired = (bbsrFalse, bbsrTrue, bbsrUnknown);
  TBleBatteryChargingFault = (bbcfBattery, bbcfExternalPowerSource, bbcfOther);
  TBleBatteryChargingFaults = set of TBleBatteryChargingFault;

  TBleBatteryLevelStatus = record
    HasValue: Boolean;
    BatteryPresent: Boolean;
    WiredExternalPower, WirelessExternalPower: TBleBatteryPowerConnection;
    ChargeState: TBleBatteryChargeState;
    ChargeLevel: TBleBatteryChargeLevel;
    ChargingType: TBleBatteryChargingType;
    ChargingFaults: TBleBatteryChargingFaults;
    HasIdentifier, HasLevelPercent, HasAdditionalStatus: Boolean;
    Identifier: Word;
    LevelPercent: Byte;
    ServiceRequired: TBleBatteryServiceRequired;
    { False means no fault reported, or unknown, as defined by GSS. }
    BatteryFaultDetected: Boolean;
  end;

  TBleBatteryCriticalStatus = record
    HasValue: Boolean;
    CriticalPowerState, ImmediateServiceRequired: Boolean;
  end;

  TBleBatteryEnergyStatus = record
    HasValue: Boolean;
    ExternalSourcePowerWatts, PresentVoltageVolts: TBleGattValue;
    AvailableEnergyKWh, AvailableCapacityKWh: TBleGattValue;
    ChargeRateWatts, LastChargeEnergyKWh: TBleGattValue;
  end;

  TBleBatteryTimeStatus = record
    HasValue: Boolean;
    UntilDischargedMinutes, StandbyDischargeMinutes,
      UntilRechargedMinutes: TBleGattValue;
  end;

  TBleBatteryHealthStatus = record
    HasValue: Boolean;
    SummaryPercent, CycleCount, TemperatureCelsius,
      DeepDischargeCount: TBleGattValue;
  end;

  TBleBatteryHealthInformation = record
    HasValue: Boolean;
    DesignedCycleCount, MinTemperatureCelsius,
      MaxTemperatureCelsius: TBleGattValue;
  end;

  TBleBatteryChemistry = (bbchUnknown, bbchAlkaline, bbchLeadAcid,
    bbchLithiumIronDisulfide, bbchLithiumManganeseDioxide, bbchLithiumIon,
    bbchLithiumPolymer, bbchNickelOxyhydroxide, bbchNickelCadmium,
    bbchNickelMetalHydride, bbchSilverOxide, bbchZincChloride, bbchZincAir,
    bbchZincCarbon, bbchOther = 255);

  TBleBatteryInformation = record
    HasValue, Replaceable, Rechargeable: Boolean;
    ManufactureDaysSince1970, ExpirationDaysSince1970: TBleGattValue;
    DesignedCapacityKWh, LowEnergyKWh, CriticalEnergyKWh,
      NominalVoltageVolts: TBleGattValue;
    HasChemistry: Boolean;
    Chemistry: TBleBatteryChemistry;
    HasAggregationGroup: Boolean;
    AggregationGroup: Byte;
  end;

  TBleBatteryString = record
    HasValue: Boolean;
    Value: UTF8String;
  end;

  { A read-only snapshot. Optional fields retain received values until invalidated. }
  TBleBatteryData = record
    LevelStatus: TBleBatteryLevelStatus;
    CriticalStatus: TBleBatteryCriticalStatus;
    EnergyStatus: TBleBatteryEnergyStatus;
    TimeStatus: TBleBatteryTimeStatus;
    HealthStatus: TBleBatteryHealthStatus;
    HealthInformation: TBleBatteryHealthInformation;
    Information: TBleBatteryInformation;
    ServiceDaysSince1970: TBleGattValue;
    ManufacturerName, ModelNumber, SerialNumber: TBleBatteryString;
  end;

  TLazBleBatteryLevelEvent = procedure(Sender: TObject;
    const ADeviceId: string; const ALevelPercent: Integer) of object;

  TBleBatteryProfile = class(TBleGattProfile)
  private type
    TBatteryPhase = (bpDetached, bpReading, bpSubscribing, bpReady,
      bpRefreshing, bpError);
  private
    FPhase: TBatteryPhase;
    FEpoch: QWord;
    FIndex: Integer;
    FLevelPercent: Integer;
    FAvailable: TBleBatteryCharacteristics;
    FData: TBleBatteryData;
    FModes: array[TBleBatteryCharacteristic] of TLazBleSubscriptionMode;
    FSubscriptions: array[TBleBatteryCharacteristic] of IBleSubscription;
    FReadOperation, FDetachOperation: IBleGattOperation;
    FRefreshOperation: IBleOperation;
    FRefreshObject: TBleOperation;
    FRefreshNeeded: Boolean;
    FOnLevelChanged: TLazBleBatteryLevelEvent;
    FOnUpdated: TNotifyEvent;
    function DiscoverCharacteristics: Boolean;
    procedure StartNextRead;
    procedure SubscribeCurrent;
    procedure RefreshIfNeeded;
    procedure ReadCompleted(Sender: TObject);
    procedure NotificationReceived(Sender: TObject; const AValue: TBytes);
    procedure SubscriptionStateChanged(Sender: TObject;
      const AState: TLazBleSubscriptionState);
    function ApplyValue(const AKind: TBleBatteryCharacteristic;
      const AValue: TBytes): Boolean;
    procedure SetProfileError(const AMessage: string;
      const AErrorCode: Integer = LazBleErrorInvalidState);
    procedure RetireSubscriptions;
    procedure RefreshCancelled(Sender: TObject);
    procedure FinishRefresh(const AState: TLazBleOperationState;
      const ACode: Integer = 0; const AMessage: string = '');
    function GetLevelPercent: Integer;
    function GetData: TBleBatteryData;
    function GetAvailable: TBleBatteryCharacteristics;
    function GetSubscription: IBleSubscription;
    function GetOnLevelChanged: TLazBleBatteryLevelEvent;
    procedure SetOnLevelChanged(const AHandler: TLazBleBatteryLevelEvent);
    function GetOnUpdated: TNotifyEvent;
    procedure SetOnUpdated(const AHandler: TNotifyEvent);
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
    procedure RefreshState; override;
    property ReadOperation: IBleGattOperation read FReadOperation;
    property Subscription: IBleSubscription read GetSubscription;
    property DetachOperation: IBleGattOperation read FDetachOperation;
  public
    constructor Create;
    destructor Destroy; override;
    function RefreshAsync: IBleOperation;
    { 0..100, or UnknownBatteryLevel until read and after detach. }
    property LevelPercent: Integer read GetLevelPercent;
    property AvailableCharacteristics: TBleBatteryCharacteristics read GetAvailable;
    property Data: TBleBatteryData read GetData;
    property OnLevelChanged: TLazBleBatteryLevelEvent read GetOnLevelChanged
      write SetOnLevelChanged;
    { Fires for each accepted read/update, including repeated values. No replay. }
    property OnUpdated: TNotifyEvent read GetOnUpdated write SetOnUpdated;
  end;

implementation

const
  CharacteristicUuids: array[TBleBatteryCharacteristic] of string = (
    BatteryLevelCharacteristicUuid, BatteryLevelStatusCharacteristicUuid,
    BatteryCriticalStatusCharacteristicUuid, BatteryEnergyStatusCharacteristicUuid,
    BatteryTimeStatusCharacteristicUuid, BatteryHealthStatusCharacteristicUuid,
    BatteryHealthInformationCharacteristicUuid, BatteryInformationCharacteristicUuid,
    EstimatedServiceDateCharacteristicUuid, BatteryManufacturerNameCharacteristicUuid,
    BatteryModelNumberCharacteristicUuid, BatterySerialNumberCharacteristicUuid);
  CharacteristicNames: array[TBleBatteryCharacteristic] of string = (
    'Battery Level', 'Battery Level Status', 'Battery Critical Status',
    'Battery Energy Status', 'Battery Time Status', 'Battery Health Status',
    'Battery Health Information', 'Battery Information', 'Estimated Service Date',
    'Manufacturer Name', 'Model Number', 'Serial Number');

type
  TBatteryRefreshOperation = class(TBleOperation)
  public
    constructor Create(const ACancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const ACode: Integer; const AMessage: string);
  end;

function BatteryValueFinished(const Reader: TBleGattReader;
  const AFlags, AKnownFlags: Cardinal): Boolean;
begin
  { BAS may append fields under new flags. This is not a general reader policy. }
  Result := Reader.Valid and (Reader.Finished or
    ((AFlags and not AKnownFlags) <> 0));
end;

function ReadNonnegativeSFloat(var Reader: TBleGattReader;
  const AAllowZero: Boolean = True): TBleGattValue;
begin
  Result := Reader.SFloat;
  if (Result.State = lgvsFinite) and ((Result.Value < 0) or
    (not AAllowZero and (Result.Value = 0))) then Reader.Invalidate;
end;

function ReadBatteryTime(var Reader: TBleGattReader): TBleGattValue;
var
  Raw: Cardinal;
begin
  Result := Default(TBleGattValue);
  Raw := Reader.UInt(3);
  if not Reader.Valid then Exit;
  case Raw of
    $FFFFFF: Result.State := lgvsUnknown;
    $FFFFFE:
      begin
        Result.State := lgvsGreaterThan;
        Result.Value := $FFFFFD;
      end;
  else
    Result.State := lgvsFinite;
    Result.Value := Raw;
  end;
end;

function ReadBatteryTemperature(var Reader: TBleGattReader): TBleGattValue;
var
  Raw: Integer;
begin
  Result := Default(TBleGattValue);
  Raw := Reader.UInt(1);
  if not Reader.Valid then Exit;
  case Raw of
    $7F:
      begin
        Result.State := lgvsGreaterThan;
        Result.Value := 126;
      end;
    $80:
      begin
        Result.State := lgvsLessThan;
        Result.Value := -127;
      end;
  else
    Result.State := lgvsFinite;
    if Raw >= $80 then Dec(Raw, $100);
    Result.Value := Raw;
  end;
end;

function ReadBatteryDateUTC(var Reader: TBleGattReader): TBleGattValue;
var
  Raw: Cardinal;
begin
  Result := Default(TBleGattValue);
  Raw := Reader.UInt(3);
  if not Reader.Valid then Exit;
  if Raw = 0 then Result.State := lgvsUnknown
  else if Raw = $FFFFFF then Reader.Invalidate
  else
  begin
    Result.State := lgvsFinite;
    Result.Value := Raw;
  end;
end;

procedure InvalidateBatteryData(var ASnapshot: TBleBatteryData);
var
  ExternalPower: TBleGattValue;
begin
  ASnapshot.LevelStatus.HasLevelPercent := False;
  ASnapshot.LevelStatus.LevelPercent := 0;
  ExternalPower := ASnapshot.EnergyStatus.ExternalSourcePowerWatts;
  ASnapshot.EnergyStatus := Default(TBleBatteryEnergyStatus);
  ASnapshot.EnergyStatus.ExternalSourcePowerWatts := ExternalPower;
  ASnapshot.EnergyStatus.HasValue := ExternalPower.State <> lgvsAbsent;
  ASnapshot.TimeStatus := Default(TBleBatteryTimeStatus);
  ASnapshot.HealthStatus := Default(TBleBatteryHealthStatus);
  ASnapshot.HealthInformation := Default(TBleBatteryHealthInformation);
  ASnapshot.Information := Default(TBleBatteryInformation);
  ASnapshot.ServiceDaysSince1970 := Default(TBleGattValue);
  ASnapshot.ManufacturerName := Default(TBleBatteryString);
  ASnapshot.ModelNumber := Default(TBleBatteryString);
  ASnapshot.SerialNumber := Default(TBleBatteryString);
end;

constructor TBatteryRefreshOperation.Create(const ACancel: TLazBleOperationCancelEvent);
begin
  inherited Create(ACancel);
end;

procedure TBatteryRefreshOperation.Finish(const AState: TLazBleOperationState;
  const ACode: Integer; const AMessage: string);
begin
  Complete(AState, ACode, AMessage);
end;

constructor TBleBatteryProfile.Create;
begin
  inherited Create;
  FLevelPercent := UnknownBatteryLevel;
  FIndex := -1;
end;

destructor TBleBatteryProfile.Destroy;
begin
  FOnLevelChanged := nil;
  FOnUpdated := nil;
  Detach;
  inherited Destroy;
end;

function TBleBatteryProfile.GetLevelPercent: Integer;
begin
  LazBleRequireMainThread;
  Result := FLevelPercent;
end;

function TBleBatteryProfile.GetData: TBleBatteryData;
begin
  LazBleRequireMainThread;
  Result := FData;
end;

function TBleBatteryProfile.GetAvailable: TBleBatteryCharacteristics;
begin
  LazBleRequireMainThread;
  Result := FAvailable;
end;

function TBleBatteryProfile.GetSubscription: IBleSubscription;
begin
  LazBleRequireMainThread;
  Result := FSubscriptions[bbcLevel];
end;

function TBleBatteryProfile.GetOnLevelChanged: TLazBleBatteryLevelEvent;
begin
  LazBleRequireMainThread;
  Result := FOnLevelChanged;
end;

procedure TBleBatteryProfile.SetOnLevelChanged(const AHandler: TLazBleBatteryLevelEvent);
begin
  LazBleRequireMainThread;
  FOnLevelChanged := AHandler;
end;

function TBleBatteryProfile.GetOnUpdated: TNotifyEvent;
begin
  LazBleRequireMainThread;
  Result := FOnUpdated;
end;

procedure TBleBatteryProfile.SetOnUpdated(const AHandler: TNotifyEvent);
begin
  LazBleRequireMainThread;
  FOnUpdated := AHandler;
end;

procedure TBleBatteryProfile.RetireSubscriptions;
var
  Kind: TBleBatteryCharacteristic;
  Token: IBleSubscription;
begin
  for Kind in TBleBatteryCharacteristic do
  begin
    Token := FSubscriptions[Kind];
    FSubscriptions[Kind] := nil;
    if not Assigned(Token) then Continue;
    Token.OnData := nil;
    Token.OnStateChanged := nil;
    FDetachOperation := Token.Unsubscribe;
  end;
end;

procedure TBleBatteryProfile.SetProfileError(const AMessage: string;
  const AErrorCode: Integer);
var
  Refresh: IBleOperation;
  Operation: TBatteryRefreshOperation;
begin
  FPhase := bpError;
  Refresh := FRefreshOperation;
  Operation := TBatteryRefreshOperation(FRefreshObject);
  FRefreshOperation := nil;
  FRefreshObject := nil;
  if Assigned(FReadOperation) then
  begin
    FReadOperation.OnCompleted := nil;
    FReadOperation.Cancel;
  end;
  RetireSubscriptions;
  MarkError(AMessage, AErrorCode);
  if Assigned(Refresh) then Operation.Finish(lbopFailed, AErrorCode, AMessage);
end;

function TBleBatteryProfile.DiscoverCharacteristics: Boolean;
var
  Kind: TBleBatteryCharacteristic;
  Characteristic, Candidate: TLazBleGattCharacteristic;
  Service: TLazBleGattService;
  Count: Integer;
begin
  Result := False;
  Count := 0;
  for Service in Session.Services do
    if SameText(UTF8Encode(Service.Uuid), BatteryServiceUuid) then Inc(Count);
  if Count <> 1 then
  begin
    SetProfileError('Battery Service must have one addressable instance');
    Exit;
  end;
  for Kind in TBleBatteryCharacteristic do
  begin
    Count := 0;
    for Service in Session.Services do
      if SameText(UTF8Encode(Service.Uuid), BatteryServiceUuid) then
        for Candidate in Service.Characteristics do
          if SameText(UTF8Encode(Candidate.Uuid), CharacteristicUuids[Kind]) then Inc(Count);
    if Count > 1 then
    begin
      SetProfileError(CharacteristicNames[Kind] + ': ambiguous characteristic instance',
        LazBleErrorInvalidProfileData);
      Exit;
    end;
    if not Session.TryGetCharacteristic(BatteryServiceUuid,
      CharacteristicUuids[Kind], Characteristic) then Continue;
    Include(FAvailable, Kind);
    if not Characteristic.CanRead or
      ((Kind in [bbcLevelStatus, bbcEnergyStatus, bbcTimeStatus, bbcHealthStatus,
          bbcServiceDate]) and
        not Characteristic.CanNotify) or
      ((Kind in [bbcCriticalStatus, bbcHealthInformation, bbcInformation,
          bbcManufacturerName, bbcModelNumber, bbcSerialNumber]) and
        not Characteristic.CanIndicate) then
    begin
      SetProfileError(CharacteristicNames[Kind] + ': missing required GATT property',
        LazBleErrorGattPropertyNotSupported);
      Exit;
    end;
    if (Kind <> bbcLevel) and Characteristic.CanIndicate then
      FModes[Kind] := lbsmIndicate
    else
      FModes[Kind] := lbsmNotify;
  end;
  if not (bbcLevel in FAvailable) then
    SetProfileError('Battery Level is missing', LazBleErrorGattNotFound)
  else if ((FAvailable * [bbcCriticalStatus, bbcEnergyStatus, bbcTimeStatus,
      bbcHealthStatus, bbcInformation, bbcServiceDate, bbcSerialNumber]) <> []) and
    not (bbcLevelStatus in FAvailable) then
    SetProfileError('Extended Battery characteristics require Battery Level Status')
  else if (bbcHealthInformation in FAvailable) and not (bbcHealthStatus in FAvailable) then
    SetProfileError('Battery Health Information requires Battery Health Status')
  else
    Result := True;
end;

function TBleBatteryProfile.ApplyValue(const AKind: TBleBatteryCharacteristic;
  const AValue: TBytes): Boolean;
var
  Reader: TBleGattReader;
  Snapshot: TBleBatteryData;
  Flags, Power, Additional, RawChemistry: Cardinal;
  NewLevel: Integer;
  Epoch: QWord;
  Inserted: Boolean;
  Fault: TBleBatteryChargingFault;
begin
  Reader := TBleGattReader.Create(AValue);
  Snapshot := FData;
  NewLevel := FLevelPercent;
  Inserted := False;
  Result := False;
  case AKind of
    bbcLevel:
      begin
        NewLevel := Reader.UInt(1);
        if (NewLevel > 100) or not Reader.Finished then Exit;
      end;
    bbcLevelStatus:
      begin
        Flags := Reader.UInt(1);
        Power := Reader.UInt(2);
        if (((Power shr 1) and 3) = 3) or
          (((Power shr 3) and 3) = 3) or (((Power shr 9) and 7) > 4) then Exit;
        Inserted := Snapshot.LevelStatus.HasValue and
          not Snapshot.LevelStatus.BatteryPresent and ((Power and 1) <> 0);
        if Snapshot.LevelStatus.HasValue and
          (Snapshot.LevelStatus.BatteryPresent <> ((Power and 1) <> 0)) then
        begin
          InvalidateBatteryData(Snapshot);
          Snapshot.LevelStatus.HasAdditionalStatus := False;
          Snapshot.LevelStatus.ServiceRequired := bbsrUnknown;
          Snapshot.LevelStatus.BatteryFaultDetected := False;
        end;
        with Snapshot.LevelStatus do
        begin
          HasValue := True;
          BatteryPresent := (Power and 1) <> 0;
          WiredExternalPower := TBleBatteryPowerConnection((Power shr 1) and 3);
          WirelessExternalPower := TBleBatteryPowerConnection((Power shr 3) and 3);
          ChargeState := TBleBatteryChargeState((Power shr 5) and 3);
          ChargeLevel := TBleBatteryChargeLevel((Power shr 7) and 3);
          ChargingType := TBleBatteryChargingType((Power shr 9) and 7);
          ChargingFaults := [];
          for Fault in TBleBatteryChargingFault do
            if (Power and (Cardinal(1) shl (12 + Ord(Fault)))) <> 0 then
              Include(ChargingFaults, Fault);
          if (Flags and 1) <> 0 then
          begin
            Identifier := Reader.UInt(2);
            HasIdentifier := True;
          end;
          if (Flags and 2) <> 0 then
          begin
            LevelPercent := Reader.UInt(1);
            HasLevelPercent := True;
            if (LevelPercent > 100) or not BatteryPresent then Exit;
          end;
          if (Flags and 4) <> 0 then
          begin
            Additional := Reader.UInt(1);
            if (Additional and 3) = 3 then Exit;
            ServiceRequired := TBleBatteryServiceRequired(Additional and 3);
            BatteryFaultDetected := (Additional and 4) <> 0;
            HasAdditionalStatus := True;
          end;
        end;
        if not BatteryValueFinished(Reader, Flags, 7) then Exit;
      end;
    bbcCriticalStatus:
      begin
        Flags := Reader.UInt(1);
        Snapshot.CriticalStatus.HasValue := True;
        Snapshot.CriticalStatus.CriticalPowerState := (Flags and 1) <> 0;
        Snapshot.CriticalStatus.ImmediateServiceRequired := (Flags and 2) <> 0;
        if not Reader.Finished then Exit;
      end;
    bbcEnergyStatus:
      begin
        Flags := Reader.UInt(1);
        with Snapshot.EnergyStatus do
        begin
          HasValue := True;
          if (Flags and 1) <> 0 then ExternalSourcePowerWatts := ReadNonnegativeSFloat(Reader);
          if (Flags and 2) <> 0 then PresentVoltageVolts := Reader.SFloat;
          if (Flags and 4) <> 0 then AvailableEnergyKWh := ReadNonnegativeSFloat(Reader);
          if (Flags and 8) <> 0 then AvailableCapacityKWh := ReadNonnegativeSFloat(Reader);
          if (Flags and 16) <> 0 then ChargeRateWatts := Reader.SFloat;
          if (Flags and 32) <> 0 then LastChargeEnergyKWh := ReadNonnegativeSFloat(Reader);
        end;
        if not BatteryValueFinished(Reader, Flags, $3F) then Exit;
      end;
    bbcTimeStatus:
      begin
        Flags := Reader.UInt(1);
        with Snapshot.TimeStatus do
        begin
          HasValue := True;
          UntilDischargedMinutes := ReadBatteryTime(Reader);
          if (Flags and 1) <> 0 then StandbyDischargeMinutes := ReadBatteryTime(Reader);
          if (Flags and 2) <> 0 then UntilRechargedMinutes := ReadBatteryTime(Reader);
        end;
        if not BatteryValueFinished(Reader, Flags, 3) then Exit;
      end;
    bbcHealthStatus:
      begin
        Flags := Reader.UInt(1);
        with Snapshot.HealthStatus do
        begin
          HasValue := True;
          if (Flags and 1) <> 0 then
          begin
            SummaryPercent := Reader.UIntValue(1);
            if SummaryPercent.Value > 100 then Exit;
          end;
          if (Flags and 2) <> 0 then CycleCount := Reader.UIntValue(2);
          if (Flags and 4) <> 0 then TemperatureCelsius := ReadBatteryTemperature(Reader);
          if (Flags and 8) <> 0 then DeepDischargeCount := Reader.UIntValue(2);
        end;
        if not BatteryValueFinished(Reader, Flags, 15) then Exit;
      end;
    bbcHealthInformation:
      begin
        Flags := Reader.UInt(1);
        with Snapshot.HealthInformation do
        begin
          HasValue := True;
          if (Flags and 1) <> 0 then DesignedCycleCount := Reader.UIntValue(2);
          if (Flags and 2) <> 0 then
          begin
            MinTemperatureCelsius := ReadBatteryTemperature(Reader);
            MaxTemperatureCelsius := ReadBatteryTemperature(Reader);
          end;
        end;
        if not BatteryValueFinished(Reader, Flags, 3) then Exit;
      end;
    bbcInformation:
      begin
        Flags := Reader.UInt(2);
        Power := Reader.UInt(1);
        with Snapshot.Information do
        begin
          HasValue := True;
          Replaceable := (Power and 1) <> 0;
          Rechargeable := (Power and 2) <> 0;
          if (Flags and 1) <> 0 then ManufactureDaysSince1970 := ReadBatteryDateUTC(Reader);
          if (Flags and 2) <> 0 then ExpirationDaysSince1970 := ReadBatteryDateUTC(Reader);
          if (Flags and 4) <> 0 then DesignedCapacityKWh := ReadNonnegativeSFloat(Reader, False);
          if (Flags and 8) <> 0 then LowEnergyKWh := ReadNonnegativeSFloat(Reader, False);
          if (Flags and 16) <> 0 then CriticalEnergyKWh := ReadNonnegativeSFloat(Reader, False);
          if (Flags and 32) <> 0 then
          begin
            RawChemistry := Reader.UInt(1);
            if (RawChemistry > 13) and (RawChemistry <> 255) then Exit;
            HasChemistry := True;
            Chemistry := TBleBatteryChemistry(RawChemistry);
          end;
          if (Flags and 64) <> 0 then NominalVoltageVolts := Reader.SFloat;
          if (Flags and 128) <> 0 then
          begin
            AggregationGroup := Reader.UInt(1);
            if AggregationGroup = 255 then Exit;
            HasAggregationGroup := True;
          end;
        end;
        if not BatteryValueFinished(Reader, Flags, $FF) then Exit;
      end;
    bbcServiceDate:
      begin
        Snapshot.ServiceDaysSince1970 := ReadBatteryDateUTC(Reader);
        if not Reader.Finished then Exit;
      end;
    bbcManufacturerName:
      begin
        Snapshot.ManufacturerName.Value := Reader.Utf8Text;
        Snapshot.ManufacturerName.HasValue := True;
        if not Reader.Valid then Exit;
      end;
    bbcModelNumber:
      begin
        Snapshot.ModelNumber.Value := Reader.Utf8Text;
        Snapshot.ModelNumber.HasValue := True;
        if not Reader.Valid then Exit;
      end;
    bbcSerialNumber:
      begin
        Snapshot.SerialNumber.Value := Reader.Utf8Text;
        Snapshot.SerialNumber.HasValue := True;
        if not Reader.Valid then Exit;
      end;
  end;
  { BAS 3.6.1: this estimate is not meaningful when charging has stopped or
    Battery Information explicitly identifies a non-rechargeable battery. }
  if (Snapshot.LevelStatus.HasValue and
      (Snapshot.LevelStatus.ChargeState in [bbcsDischargingActive, bbcsDischargingInactive])) or
    (Snapshot.Information.HasValue and not Snapshot.Information.Rechargeable) then
    Snapshot.TimeStatus.UntilRechargedMinutes := Default(TBleGattValue);
  if Snapshot.LevelStatus.HasValue and not Snapshot.LevelStatus.BatteryPresent then
  begin
    InvalidateBatteryData(Snapshot);
    NewLevel := UnknownBatteryLevel;
  end;
  FData := Snapshot;
  if Inserted then FRefreshNeeded := True;
  Epoch := FEpoch;
  if NewLevel <> FLevelPercent then
  begin
    FLevelPercent := NewLevel;
    if (NewLevel <> UnknownBatteryLevel) and Assigned(FOnLevelChanged) then
      try FOnLevelChanged(Self, DeviceId, NewLevel);
      except LazBleReportCallbackException; end;
  end;
  if (Epoch = FEpoch) and not (FPhase in [bpDetached, bpError]) and Assigned(FOnUpdated) then
    try FOnUpdated(Self);
    except LazBleReportCallbackException; end;
  Result := True;
end;

procedure TBleBatteryProfile.StartNextRead;
var
  Epoch: QWord;
begin
  Inc(FIndex);
  while (FIndex <= Ord(High(TBleBatteryCharacteristic))) and
    not (TBleBatteryCharacteristic(FIndex) in FAvailable) do Inc(FIndex);
  if FIndex > Ord(High(TBleBatteryCharacteristic)) then
  begin
    if FPhase = bpRefreshing then
    begin
      if FRefreshNeeded then
      begin
        FRefreshNeeded := False;
        FIndex := -1;
        StartNextRead;
      end
      else FinishRefresh(lbopSucceeded);
    end
    else
    begin
      FPhase := bpReady;
      Epoch := FEpoch;
      MarkReady;
      if Epoch = FEpoch then RefreshIfNeeded;
    end;
    Exit;
  end;
  { These values have no meaning while the battery is removed. Keep their
    subscriptions so insertion and subsequent updates still work. }
  if FData.LevelStatus.HasValue and not FData.LevelStatus.BatteryPresent and
    (TBleBatteryCharacteristic(FIndex) in [bbcTimeStatus, bbcHealthStatus,
      bbcHealthInformation, bbcInformation, bbcServiceDate, bbcManufacturerName,
      bbcModelNumber, bbcSerialNumber]) then
  begin
    if FPhase = bpRefreshing then StartNextRead else SubscribeCurrent;
    Exit;
  end;
  FReadOperation := Session.ReadAsync(BatteryServiceUuid,
    CharacteristicUuids[TBleBatteryCharacteristic(FIndex)]);
  FReadOperation.OnCompleted := @ReadCompleted;
end;

procedure TBleBatteryProfile.ReadCompleted(Sender: TObject);
var
  Operation: IBleGattOperation;
  Kind: TBleBatteryCharacteristic;
  Epoch: QWord;
begin
  if not (FPhase in [bpReading, bpRefreshing]) or not Assigned(FReadOperation) then Exit;
  Operation := FReadOperation;
  if (Operation as TObject) <> Sender then Exit;
  FReadOperation := nil;
  Operation.OnCompleted := nil;
  if Operation.State <> lbopSucceeded then
  begin
    if (FPhase = bpRefreshing) and (Operation.State = lbopCancelled) then
      FinishRefresh(lbopCancelled)
    else SetProfileError(CharacteristicNames[TBleBatteryCharacteristic(FIndex)] +
      ': read failed: ' + Operation.ErrorMessage, Operation.ErrorCode);
    Exit;
  end;
  Kind := TBleBatteryCharacteristic(FIndex);
  Epoch := FEpoch;
  if not ApplyValue(Kind, Operation.Value) then
  begin
    SetProfileError(CharacteristicNames[Kind] + ': invalid value', LazBleErrorInvalidProfileData);
    Exit;
  end;
  if (Epoch <> FEpoch) or not (FPhase in [bpReading, bpRefreshing]) then Exit;
  if FPhase = bpRefreshing then
  begin
    if FRefreshOperation.CancelRequested then FinishRefresh(lbopCancelled)
    else StartNextRead;
    Exit;
  end;
  SubscribeCurrent;
end;

procedure TBleBatteryProfile.SubscribeCurrent;
var
  Kind: TBleBatteryCharacteristic;
  Characteristic: TLazBleGattCharacteristic;
begin
  Kind := TBleBatteryCharacteristic(FIndex);
  Session.TryGetCharacteristic(BatteryServiceUuid, CharacteristicUuids[Kind], Characteristic);
  if (Kind = bbcLevel) and not Characteristic.CanNotify then
  begin
    StartNextRead;
    Exit;
  end;
  FPhase := bpSubscribing;
  FSubscriptions[Kind] := Session.SubscribeAsync(BatteryServiceUuid,
    CharacteristicUuids[Kind], FModes[Kind]);
  FSubscriptions[Kind].OnData := @NotificationReceived;
  FSubscriptions[Kind].OnStateChanged := @SubscriptionStateChanged;
  RefreshState;
end;

procedure TBleBatteryProfile.NotificationReceived(Sender: TObject; const AValue: TBytes);
var
  Kind: TBleBatteryCharacteristic;
begin
  if FPhase in [bpDetached, bpError] then Exit;
  for Kind in TBleBatteryCharacteristic do
    if Assigned(FSubscriptions[Kind]) and ((FSubscriptions[Kind] as TObject) = Sender) then
    begin
      if not ApplyValue(Kind, AValue) then
        SetProfileError(CharacteristicNames[Kind] + ': invalid value', LazBleErrorInvalidProfileData)
      else RefreshIfNeeded;
      Exit;
    end;
end;

procedure TBleBatteryProfile.SubscriptionStateChanged(Sender: TObject;
  const AState: TLazBleSubscriptionState);
begin
  RefreshState;
end;

procedure TBleBatteryProfile.RefreshState;
var
  Kind: TBleBatteryCharacteristic;
  Token: IBleSubscription;
begin
  if FPhase in [bpDetached, bpError] then Exit;
  for Kind in TBleBatteryCharacteristic do
  begin
    Token := FSubscriptions[Kind];
    if Assigned(Token) and (Token.State in [lbsubFailed, lbsubInactive]) then
    begin
      SetProfileError(CharacteristicNames[Kind] + ': subscription is not active: ' +
        Token.ErrorMessage, Token.ErrorCode);
      Exit;
    end;
  end;
  if (FPhase = bpSubscribing) and
    (FSubscriptions[TBleBatteryCharacteristic(FIndex)].State = lbsubActive) then
  begin
    FPhase := bpReading;
    StartNextRead;
  end;
end;

function TBleBatteryProfile.RefreshAsync: IBleOperation;
var
  Operation: TBatteryRefreshOperation;
begin
  LazBleRequireMainThread;
  Operation := TBatteryRefreshOperation.Create(@RefreshCancelled);
  Result := Operation;
  if (CurrentState <> lbgpsReady) or (FPhase <> bpReady) then
  begin
    Operation.Finish(lbopFailed, LazBleErrorInvalidState,
      'Battery profile is not ready or a refresh is already pending');
    Exit;
  end;
  FRefreshOperation := Result;
  FRefreshObject := Operation;
  FPhase := bpRefreshing;
  FRefreshNeeded := False;
  FIndex := -1;
  StartNextRead;
end;

procedure TBleBatteryProfile.RefreshIfNeeded;
var
  Operation: IBleOperation;
begin
  if FRefreshNeeded and (FPhase = bpReady) then Operation := RefreshAsync;
end;

procedure TBleBatteryProfile.RefreshCancelled(Sender: TObject);
begin
  if Assigned(FReadOperation) then FReadOperation.Cancel;
end;

procedure TBleBatteryProfile.FinishRefresh(const AState: TLazBleOperationState;
  const ACode: Integer; const AMessage: string);
var
  KeepAlive: IBleOperation;
  Operation: TBatteryRefreshOperation;
begin
  if not Assigned(FRefreshOperation) then Exit;
  KeepAlive := FRefreshOperation;
  Operation := TBatteryRefreshOperation(FRefreshObject);
  FRefreshOperation := nil;
  FRefreshObject := nil;
  if FPhase = bpRefreshing then FPhase := bpReady;
  Operation.Finish(AState, ACode, AMessage);
end;

procedure TBleBatteryProfile.DoAttach;
begin
  if CurrentState <> lbgpsAttaching then Exit;
  Inc(FEpoch);
  FData := Default(TBleBatteryData);
  FRefreshNeeded := False;
  FAvailable := [];
  FLevelPercent := UnknownBatteryLevel;
  FDetachOperation := nil;
  FPhase := bpReading;
  FIndex := -1;
  if DiscoverCharacteristics then StartNextRead;
end;

procedure TBleBatteryProfile.DoDetach;
begin
  Inc(FEpoch);
  FPhase := bpDetached;
  FRefreshNeeded := False;
  if Assigned(FReadOperation) then
  begin
    FReadOperation.OnCompleted := nil;
    FReadOperation.Cancel;
    FReadOperation := nil;
  end;
  RetireSubscriptions;
  FLevelPercent := UnknownBatteryLevel;
  FData := Default(TBleBatteryData);
  FAvailable := [];
  FinishRefresh(lbopCancelled);
end;

end.
