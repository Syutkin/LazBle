unit LazBleBattery;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, Math, LazBleTypes, LazBleBackend, LazBleOperation, LazBleGattOperation,
  LazBleGattSubscription, LazBleGattSession, LazBleGattProfile;

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

  TBleBatteryValueState = (bbvsAbsent, bbvsFinite, bbvsUnknown,
    bbvsGreaterThan, bbvsLessThan, bbvsNaN, bbvsNotAtResolution,
    bbvsPositiveInfinity, bbvsNegativeInfinity);
  { Value is meaningful for Finite, GreaterThan and LessThan; otherwise read State. }
  TBleBatteryValue = record
    State: TBleBatteryValueState;
    Value: Double;
  end;

  TBleBatteryEnergyStatus = record
    HasValue: Boolean;
    ExternalSourcePowerWatts, PresentVoltageVolts: TBleBatteryValue;
    AvailableEnergyKWh, AvailableCapacityKWh: TBleBatteryValue;
    ChargeRateWatts, LastChargeEnergyKWh: TBleBatteryValue;
  end;

  TBleBatteryTimeStatus = record
    HasValue: Boolean;
    UntilDischargedMinutes, StandbyDischargeMinutes,
      UntilRechargedMinutes: TBleBatteryValue;
  end;

  TBleBatteryHealthStatus = record
    HasValue: Boolean;
    SummaryPercent, CycleCount, TemperatureCelsius,
      DeepDischargeCount: TBleBatteryValue;
  end;

  TBleBatteryHealthInformation = record
    HasValue: Boolean;
    DesignedCycleCount, MinTemperatureCelsius,
      MaxTemperatureCelsius: TBleBatteryValue;
  end;

  TBleBatteryChemistry = (bbchUnknown, bbchAlkaline, bbchLeadAcid,
    bbchLithiumIronDisulfide, bbchLithiumManganeseDioxide, bbchLithiumIon,
    bbchLithiumPolymer, bbchNickelOxyhydroxide, bbchNickelCadmium,
    bbchNickelMetalHydride, bbchSilverOxide, bbchZincChloride, bbchZincAir,
    bbchZincCarbon, bbchOther = 255);

  TBleBatteryInformation = record
    HasValue, Replaceable, Rechargeable: Boolean;
    ManufactureDaysSince1970, ExpirationDaysSince1970: TBleBatteryValue;
    DesignedCapacityKWh, LowEnergyKWh, CriticalEnergyKWh,
      NominalVoltageVolts: TBleBatteryValue;
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
    ServiceDaysSince1970: TBleBatteryValue;
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
  { Bounds-checked little-endian reads, without alignment or host-endian assumptions. }
  TBatteryReader = record
    Data: TBytes;
    Position: SizeInt;
    Valid: Boolean;
    function UInt(const ABytes: Integer): Cardinal;
    function Finished(const AFlags, AKnownFlags: Cardinal): Boolean;
    function SFloat(const AAllowNegative: Boolean;
      const AAllowZero: Boolean = True): TBleBatteryValue;
    function TimeMinutes: TBleBatteryValue;
    function UIntValue(const ABytes: Integer): TBleBatteryValue;
    function Temperature: TBleBatteryValue;
    function DateUTC: TBleBatteryValue;
    function Utf8Text: UTF8String;
  end;

  TBatteryRefreshOperation = class(TBleOperation)
  public
    constructor Create(const ACancel: TLazBleOperationCancelEvent);
    procedure Finish(const AState: TLazBleOperationState;
      const ACode: Integer; const AMessage: string);
  end;

function TBatteryReader.UInt(const ABytes: Integer): Cardinal;
var
  I: Integer;
begin
  Result := 0;
  if not Valid or (Length(Data) - Position < ABytes) then
  begin
    Valid := False;
    Exit;
  end;
  for I := 0 to ABytes - 1 do
  begin
    Result := Result or (Cardinal(Data[Position]) shl (8 * I));
    Inc(Position);
  end;
end;

function TBatteryReader.Finished(const AFlags, AKnownFlags: Cardinal): Boolean;
begin
  { New flags may append fields. RFU bits alone do not invalidate known fields. }
  Result := Valid and ((Position = Length(Data)) or
    ((AFlags and not AKnownFlags) <> 0));
end;

function TBatteryReader.SFloat(const AAllowNegative: Boolean;
  const AAllowZero: Boolean): TBleBatteryValue;
var
  Raw: Cardinal;
  Mantissa, Exponent: Integer;
begin
  Result := Default(TBleBatteryValue);
  Raw := UInt(2);
  case Raw of
    $07FE: Result.State := bbvsPositiveInfinity;
    $0802: Result.State := bbvsNegativeInfinity;
    $07FF: Result.State := bbvsNaN;
    $0800: Result.State := bbvsNotAtResolution;
    $0801: Valid := False;
  else
    Result.State := bbvsFinite;
    Mantissa := Raw and $FFF;
    if Mantissa >= $800 then Dec(Mantissa, $1000);
    Exponent := Raw shr 12;
    if Exponent >= 8 then Dec(Exponent, 16);
    Result.Value := Mantissa * IntPower(10.0, Exponent);
    if (not AAllowNegative and (Result.Value < 0)) or
      (not AAllowZero and (Result.Value = 0)) then Valid := False;
  end;
end;

function TBatteryReader.TimeMinutes: TBleBatteryValue;
var
  Raw: Cardinal;
begin
  Result := Default(TBleBatteryValue);
  Raw := UInt(3);
  case Raw of
    $FFFFFF: Result.State := bbvsUnknown;
    $FFFFFE:
      begin
        Result.State := bbvsGreaterThan;
        Result.Value := $FFFFFD;
      end;
  else
    Result.State := bbvsFinite;
    Result.Value := Raw;
  end;
end;

function TBatteryReader.UIntValue(const ABytes: Integer): TBleBatteryValue;
begin
  Result := Default(TBleBatteryValue);
  Result.State := bbvsFinite;
  Result.Value := UInt(ABytes);
end;

function TBatteryReader.Temperature: TBleBatteryValue;
var
  Raw: Integer;
begin
  Result := Default(TBleBatteryValue);
  Raw := UInt(1);
  case Raw of
    $7F:
      begin
        Result.State := bbvsGreaterThan;
        Result.Value := 126;
      end;
    $80:
      begin
        Result.State := bbvsLessThan;
        Result.Value := -127;
      end;
  else
    Result.State := bbvsFinite;
    if Raw >= $80 then Dec(Raw, $100);
    Result.Value := Raw;
  end;
end;

function TBatteryReader.DateUTC: TBleBatteryValue;
var
  Raw: Cardinal;
begin
  Result := Default(TBleBatteryValue);
  Raw := UInt(3);
  if Raw = 0 then Result.State := bbvsUnknown
  else if Raw = $FFFFFF then Valid := False
  else
  begin
    Result.State := bbvsFinite;
    Result.Value := Raw;
  end;
end;

function TBatteryReader.Utf8Text: UTF8String;
var
  I, J, Continuations: SizeInt;
  First, Next: Byte;
begin
  Result := '';
  I := 0;
  while I < Length(Data) do
  begin
    First := Data[I];
    if First <= $7F then Continuations := 0
    else if (First >= $C2) and (First <= $DF) then Continuations := 1
    else if (First >= $E0) and (First <= $EF) then Continuations := 2
    else if (First >= $F0) and (First <= $F4) then Continuations := 3
    else
    begin
      Valid := False;
      Exit;
    end;
    if Length(Data) - I <= Continuations then
    begin
      Valid := False;
      Exit;
    end;
    for J := 1 to Continuations do
    begin
      Next := Data[I + J];
      if (Next < $80) or (Next > $BF) or
        ((J = 1) and (((First = $E0) and (Next < $A0)) or
          ((First = $ED) and (Next > $9F)) or
          ((First = $F0) and (Next < $90)) or
          ((First = $F4) and (Next > $8F)))) then
      begin
        Valid := False;
        Exit;
      end;
    end;
    Inc(I, Continuations + 1);
  end;
  if Length(Data) <> 0 then SetString(Result, PAnsiChar(@Data[0]), Length(Data));
  Position := Length(Data);
end;

procedure InvalidateBatteryData(var ASnapshot: TBleBatteryData);
var
  ExternalPower: TBleBatteryValue;
begin
  ASnapshot.LevelStatus.HasLevelPercent := False;
  ASnapshot.LevelStatus.LevelPercent := 0;
  ExternalPower := ASnapshot.EnergyStatus.ExternalSourcePowerWatts;
  ASnapshot.EnergyStatus := Default(TBleBatteryEnergyStatus);
  ASnapshot.EnergyStatus.ExternalSourcePowerWatts := ExternalPower;
  ASnapshot.EnergyStatus.HasValue := ExternalPower.State <> bbvsAbsent;
  ASnapshot.TimeStatus := Default(TBleBatteryTimeStatus);
  ASnapshot.HealthStatus := Default(TBleBatteryHealthStatus);
  ASnapshot.HealthInformation := Default(TBleBatteryHealthInformation);
  ASnapshot.Information := Default(TBleBatteryInformation);
  ASnapshot.ServiceDaysSince1970 := Default(TBleBatteryValue);
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
  Characteristic: TLazBleGattCharacteristic;
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
      SetProfileError(CharacteristicNames[Kind] + ': missing required GATT property');
      Exit;
    end;
    if (Kind <> bbcLevel) and Characteristic.CanIndicate then
      FModes[Kind] := lbsmIndicate
    else
      FModes[Kind] := lbsmNotify;
  end;
  if not (bbcLevel in FAvailable) then
    SetProfileError('Battery Level is missing')
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
  Reader: TBatteryReader;
  Snapshot: TBleBatteryData;
  Flags, Power, Additional, RawChemistry: Cardinal;
  NewLevel: Integer;
  Epoch: QWord;
  Inserted: Boolean;
  Fault: TBleBatteryChargingFault;
begin
  Reader := Default(TBatteryReader);
  Reader.Data := AValue;
  Reader.Valid := True;
  Snapshot := FData;
  NewLevel := FLevelPercent;
  Inserted := False;
  Result := False;
  case AKind of
    bbcLevel:
      begin
        NewLevel := Reader.UInt(1);
        if (NewLevel > 100) or not Reader.Finished(0, 0) then Exit;
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
        if not Reader.Finished(Flags, 7) then Exit;
      end;
    bbcCriticalStatus:
      begin
        Flags := Reader.UInt(1);
        Snapshot.CriticalStatus.HasValue := True;
        Snapshot.CriticalStatus.CriticalPowerState := (Flags and 1) <> 0;
        Snapshot.CriticalStatus.ImmediateServiceRequired := (Flags and 2) <> 0;
        if not Reader.Finished(0, 0) then Exit;
      end;
    bbcEnergyStatus:
      begin
        Flags := Reader.UInt(1);
        with Snapshot.EnergyStatus do
        begin
          HasValue := True;
          if (Flags and 1) <> 0 then ExternalSourcePowerWatts := Reader.SFloat(False);
          if (Flags and 2) <> 0 then PresentVoltageVolts := Reader.SFloat(True);
          if (Flags and 4) <> 0 then AvailableEnergyKWh := Reader.SFloat(False);
          if (Flags and 8) <> 0 then AvailableCapacityKWh := Reader.SFloat(False);
          if (Flags and 16) <> 0 then ChargeRateWatts := Reader.SFloat(True);
          if (Flags and 32) <> 0 then LastChargeEnergyKWh := Reader.SFloat(False);
        end;
        if not Reader.Finished(Flags, $3F) then Exit;
      end;
    bbcTimeStatus:
      begin
        Flags := Reader.UInt(1);
        with Snapshot.TimeStatus do
        begin
          HasValue := True;
          UntilDischargedMinutes := Reader.TimeMinutes;
          if (Flags and 1) <> 0 then StandbyDischargeMinutes := Reader.TimeMinutes;
          if (Flags and 2) <> 0 then UntilRechargedMinutes := Reader.TimeMinutes;
        end;
        if not Reader.Finished(Flags, 3) then Exit;
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
          if (Flags and 4) <> 0 then TemperatureCelsius := Reader.Temperature;
          if (Flags and 8) <> 0 then DeepDischargeCount := Reader.UIntValue(2);
        end;
        if not Reader.Finished(Flags, 15) then Exit;
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
            MinTemperatureCelsius := Reader.Temperature;
            MaxTemperatureCelsius := Reader.Temperature;
          end;
        end;
        if not Reader.Finished(Flags, 3) then Exit;
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
          if (Flags and 1) <> 0 then ManufactureDaysSince1970 := Reader.DateUTC;
          if (Flags and 2) <> 0 then ExpirationDaysSince1970 := Reader.DateUTC;
          if (Flags and 4) <> 0 then DesignedCapacityKWh := Reader.SFloat(False, False);
          if (Flags and 8) <> 0 then LowEnergyKWh := Reader.SFloat(False, False);
          if (Flags and 16) <> 0 then CriticalEnergyKWh := Reader.SFloat(False, False);
          if (Flags and 32) <> 0 then
          begin
            RawChemistry := Reader.UInt(1);
            if (RawChemistry > 13) and (RawChemistry <> 255) then Exit;
            HasChemistry := True;
            Chemistry := TBleBatteryChemistry(RawChemistry);
          end;
          if (Flags and 64) <> 0 then NominalVoltageVolts := Reader.SFloat(True);
          if (Flags and 128) <> 0 then
          begin
            AggregationGroup := Reader.UInt(1);
            if AggregationGroup = 255 then Exit;
            HasAggregationGroup := True;
          end;
        end;
        if not Reader.Finished(Flags, $FF) then Exit;
      end;
    bbcServiceDate:
      begin
        Snapshot.ServiceDaysSince1970 := Reader.DateUTC;
        if not Reader.Finished(0, 0) then Exit;
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
