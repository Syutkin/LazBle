unit LazBleBatteryTests;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  LazBleOperation,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile,
  LazBleByteChannel,
  LazBleNus,
  LazBleBattery,
  FakeLazBleBackend,
  TestLazBleAccess;

type
  TTestBatteryProfile = class(TBleBatteryProfile)
  public
    procedure BindToSession(const ASession: TBleGattSession);
    procedure AttachProfile;
    procedure DetachProfile;
    function TestReadOperation: IBleGattOperation;
    function TestSubscription: IBleSubscription;
    function TestDetachOperation: IBleGattOperation;
  end;

  TTestNusProfile = class(TNusProfile)
  public
    procedure BindToSession(const ASession: TBleGattSession);
    procedure AttachProfile;
    function TestChannel: TBleByteChannel;
  end;

  TBatteryObserver = class
  private
    FCallCount: Integer;
    FDeviceId: string;
    FLevelPercent: Integer;
    FUpdatedCount: Integer;
  public
    procedure LevelChanged(Sender: TObject; const ADeviceId: string;
      const ALevelPercent: Integer);
    procedure Updated(Sender: TObject);
    property CallCount: Integer read FCallCount;
    property DeviceId: string read FDeviceId;
    property LevelPercent: Integer read FLevelPercent;
  end;

  TNusObserver = class
  private
    FCallCount: Integer;
  public
    procedure DataReceived(Sender: TObject; const ADeviceId: string;
      const AValue: TBytes);
    property CallCount: Integer read FCallCount;
  end;

  TLazBleBatteryTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FSession: TBleGattSession;
    FProfile: TTestBatteryProfile;
    FServices: TLazBleGattServices;
    procedure CreateFixture;
    procedure AddCharacteristic(const AUuid: string;
      const ANotify, AIndicate: Boolean);
    procedure CompleteSubscription(const AToken: TBleSubscriptionId);
    procedure PrepareExtension(const AUuid: string; const AIndicate: Boolean = False);
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId;
      const ASubscriptionId: TBleSubscriptionId;
      const AValue: array of Byte);
    procedure CompleteRead(const AValue: array of Byte);
    procedure ActivateProfile(const ALevelPercent: Byte);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AttachReadsBeforeSubscribing;
    procedure NotificationUpdatesLevel;
    procedure InvalidReadPayloadIsProfileError;
    procedure InvalidNotificationIsProfileError;
    procedure DetachCancelsPendingRead;
    procedure DetachCancelsPendingSubscription;
    procedure DetachUnsubscribesAndSetsUnknown;
    procedure NusAndBatteryShareOneSession;
    procedure ReadOnlyBatteryBecomesReady;
    procedure RefreshReadsWithoutResubscribing;
    procedure RefreshRejectsBusyAndDetached;
    procedure RefreshCancelAndDetach;
    procedure ExtendedStatusesUseTheirDeclaredModes;
    procedure LevelStatusMergesOptionalFields;
    procedure InvalidStatusDoesNotPartiallyApply;
    procedure CriticalStatusRequiresLevelStatusAndIndicate;
    procedure EnergyStatusDecodesDecimalFloatAndSignedRate;
    procedure EnergySpecialValuesAndPartialUpdates;
    procedure TimeStatusPreservesUnknownAndSaturation;
    procedure TruncatedEnergyIsAtomic;
    procedure HealthStatusDecodesAllFields;
    procedure HealthInformationUsesIndicateAndTemperatureBounds;
    procedure HealthInformationRequiresHealthStatus;
    procedure InvalidHealthDoesNotPartiallyApply;
    procedure BatteryInformationDecodesAllFields;
    procedure ServiceDatePreservesUnknown;
    procedure BatteryStringsAreUtf8AndMayBeEmpty;
    procedure InvalidUtf8KeepsPreviousValue;
    procedure RemovalInvalidatesAndInsertionRefreshes;
    procedure AbsentBatteryStillConfiguresSubscriptions;
  end;

implementation

procedure TTestBatteryProfile.BindToSession(const ASession: TBleGattSession);
begin
  BindSession(ASession);
end;

procedure TTestBatteryProfile.AttachProfile;
begin
  Attach;
end;

procedure TTestBatteryProfile.DetachProfile;
begin
  Detach;
end;

function TTestBatteryProfile.TestReadOperation: IBleGattOperation;
begin
  Result := ReadOperation;
end;

function TTestBatteryProfile.TestSubscription: IBleSubscription;
begin
  Result := Subscription;
end;

function TTestBatteryProfile.TestDetachOperation: IBleGattOperation;
begin
  Result := DetachOperation;
end;

procedure TTestNusProfile.BindToSession(const ASession: TBleGattSession);
begin
  BindSession(ASession);
end;

procedure TTestNusProfile.AttachProfile;
begin
  Attach;
end;

function TTestNusProfile.TestChannel: TBleByteChannel;
begin
  Result := Channel;
end;

procedure TBatteryObserver.LevelChanged(Sender: TObject;
  const ADeviceId: string; const ALevelPercent: Integer);
begin
  Inc(FCallCount);
  FDeviceId := ADeviceId;
  FLevelPercent := ALevelPercent;
end;

procedure TBatteryObserver.Updated(Sender: TObject);
begin
  Inc(FUpdatedCount);
end;

procedure TLazBleBatteryTest.AddCharacteristic(const AUuid: string;
  const ANotify, AIndicate: Boolean);
var
  Index: Integer;
begin
  Index := Length(FServices[0].Characteristics);
  SetLength(FServices[0].Characteristics, Index + 1);
  FServices[0].Characteristics[Index].Uuid := AUuid;
  FServices[0].Characteristics[Index].CanRead := True;
  FServices[0].Characteristics[Index].CanNotify := ANotify;
  FServices[0].Characteristics[Index].CanIndicate := AIndicate;
end;

procedure TLazBleBatteryTest.CompleteSubscription(const AToken: TBleSubscriptionId);
var
  Id: TBleOperationId;
begin
  Id := FBackendObject.OperationIds[FBackendObject.CommandCount - 1];
  AssertEquals(Ord(lbckSubscribe),
    Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].Kind));
  EmitEvent(lbekSubscribed, Id, AToken, []);
  AssertTrue(FBackendObject.CompleteOperation(Id, lbekOperationSucceeded));
end;

procedure TLazBleBatteryTest.PrepareExtension(const AUuid: string; const AIndicate: Boolean);
begin
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, False);
  AddCharacteristic(AUuid, not AIndicate, AIndicate);
  CreateFixture;
  FProfile.AttachProfile;
  CompleteRead([75]);
  CompleteSubscription(41);
  CompleteRead([0, 1, 0]);
  CompleteSubscription(42);
end;

procedure TNusObserver.DataReceived(Sender: TObject; const ADeviceId: string;
  const AValue: TBytes);
begin
  Inc(FCallCount);
end;

procedure TLazBleBatteryTest.EmitEvent(
  const AKind: TLazBleBackendEventKind;
  const AOperationId: TBleOperationId;
  const ASubscriptionId: TBleSubscriptionId;
  const AValue: array of Byte);
var
  BackendEvent: TLazBleBackendEvent;
  Index: Integer;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := AKind;
  BackendEvent.OperationId := AOperationId;
  BackendEvent.SubscriptionId := ASubscriptionId;
  BackendEvent.DeviceId := FSession.DeviceId;
  BackendEvent.Generation := FSession.Generation;
  SetLength(BackendEvent.Value, Length(AValue));
  for Index := 0 to High(AValue) do
    BackendEvent.Value[Index] := AValue[Index];
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
end;

procedure TLazBleBatteryTest.CompleteRead(const AValue: array of Byte);
var
  OperationId: TBleOperationId;
begin
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekReadResult, OperationId,
    InvalidBleSubscriptionId, AValue);
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationSucceeded));
end;

procedure TLazBleBatteryTest.ActivateProfile(const ALevelPercent: Byte);
var
  OperationId: TBleOperationId;
begin
  FProfile.AttachProfile;
  CompleteRead([ALevelPercent]);
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekSubscribed, OperationId, 41, []);
  AssertTrue(FBackendObject.CompleteOperation(
    OperationId, lbekOperationSucceeded));
  AssertTrue(FProfile.Ready);
end;

procedure TLazBleBatteryTest.SetUp;
begin
  FServices := nil;
  SetLength(FServices, 2);
  FServices[0].Uuid := BatteryServiceUuid;
  SetLength(FServices[0].Characteristics, 1);
  FServices[0].Characteristics[0].Uuid := BatteryLevelCharacteristicUuid;
  FServices[0].Characteristics[0].CanRead := True;
  FServices[0].Characteristics[0].CanNotify := True;
  FServices[1].Uuid := NusServiceUuid;
  SetLength(FServices[1].Characteristics, 2);
  FServices[1].Characteristics[0].Uuid := NusRxCharacteristicUuid;
  FServices[1].Characteristics[0].CanWriteCommand := True;
  FServices[1].Characteristics[1].Uuid := NusTxCharacteristicUuid;
  FServices[1].Characteristics[1].CanNotify := True;
  CreateFixture;
end;

procedure TLazBleBatteryTest.CreateFixture;
var
  BackendEvent: TLazBleBackendEvent;
  ConnectId: TBleOperationId;
begin
  FreeAndNil(FProfile);
  FreeAndNil(FSession);
  FBackend := nil;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FSession := LazBleTestCreateSession('ble-device', @FBackendObject.Submit, @FBackendObject.Cancel);
  ConnectId := LazBleTestConnect(FSession);
  EmitEvent(lbekConnected, ConnectId, InvalidBleSubscriptionId, []);
  AssertTrue(FBackendObject.CompleteOperation(ConnectId, lbekOperationSucceeded));
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekServicesDiscovered;
  BackendEvent.OperationId := FBackendObject.OperationIds[1];
  BackendEvent.DeviceId := FSession.DeviceId;
  BackendEvent.Generation := FSession.Generation;
  BackendEvent.Services := FServices;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
  AssertTrue(FBackendObject.CompleteOperation(BackendEvent.OperationId, lbekOperationSucceeded));
  FProfile := TTestBatteryProfile.Create;
  FProfile.BindToSession(FSession);
end;

procedure TLazBleBatteryTest.TearDown;
begin
  FProfile.Free;
  FProfile := nil;
  FSession.Free;
  FSession := nil;
  FSession := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleBatteryTest.AttachReadsBeforeSubscribing;
begin
  FProfile.AttachProfile;

  AssertTrue(Assigned(FProfile.TestReadOperation));
  AssertEquals(3, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckRead), Ord(FBackendObject.Commands[2].Kind));
  AssertEquals(BatteryServiceUuid, FBackendObject.Commands[2].ServiceUuid);
  AssertEquals(BatteryLevelCharacteristicUuid,
    FBackendObject.Commands[2].CharacteristicUuid);

  CompleteRead([75]);

  AssertEquals(4, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckSubscribe), Ord(FBackendObject.Commands[3].Kind));
  AssertEquals(75, FProfile.LevelPercent);
end;

procedure TLazBleBatteryTest.NotificationUpdatesLevel;
var
  Observer: TBatteryObserver;
begin
  Observer := TBatteryObserver.Create;
  try
    FProfile.OnLevelChanged := @Observer.LevelChanged;
    ActivateProfile(75);
    EmitEvent(lbekNotification, InvalidBleOperationId,
      41, [64]);

    AssertEquals(64, FProfile.LevelPercent);
    AssertEquals(2, Observer.CallCount);
    AssertEquals('ble-device', Observer.DeviceId);
    AssertEquals(64, Observer.LevelPercent);
  finally
    Observer.Free;
  end;
end;

procedure TLazBleBatteryTest.InvalidReadPayloadIsProfileError;
begin
  FProfile.AttachProfile;
  CompleteRead([101]);

  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertEquals(3, FBackendObject.CommandCount);
  AssertEquals(Ord(lbssConnected), Ord(FSession.State));
end;

procedure TLazBleBatteryTest.InvalidNotificationIsProfileError;
begin
  ActivateProfile(75);
  EmitEvent(lbekNotification, InvalidBleOperationId,
    41, [70, 71]);

  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(LazBleErrorInvalidProfileData, FProfile.ErrorCode);
  AssertEquals(75, FProfile.LevelPercent);
  AssertEquals(Ord(lbssConnected), Ord(FSession.State));
end;

procedure TLazBleBatteryTest.DetachCancelsPendingRead;
var
  ReadOperationId: TBleOperationId;
begin
  FProfile.AttachProfile;
  ReadOperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  FProfile.DetachProfile;

  AssertTrue(FBackendObject.CancellationWasRequested(
    ReadOperationId));
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
end;

procedure TLazBleBatteryTest.DetachCancelsPendingSubscription;
var
  SubscriptionId: TBleOperationId;
begin
  FProfile.AttachProfile;
  CompleteRead([75]);
  SubscriptionId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  FProfile.DetachProfile;

  AssertTrue(FBackendObject.CancellationWasRequested(SubscriptionId));
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
end;

procedure TLazBleBatteryTest.DetachUnsubscribesAndSetsUnknown;
var
  DetachOperation: IBleGattOperation;
begin
  ActivateProfile(75);
  FProfile.DetachProfile;
  DetachOperation := FProfile.TestDetachOperation;

  AssertTrue(Assigned(DetachOperation));
  FProfile.DetachProfile;
  AssertTrue(DetachOperation = FProfile.TestDetachOperation);
  AssertEquals(Ord(lbckUnsubscribe),
    Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].Kind));
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
end;

procedure TLazBleBatteryTest.NusAndBatteryShareOneSession;
var
  NusProfile: TTestNusProfile;
  NusObserver: TNusObserver;
  NusOperationId: TBleOperationId;
  NusSubscription: IBleSubscription;
begin
  NusProfile := TTestNusProfile.Create;
  NusProfile.BindToSession(FSession);
  NusObserver := TNusObserver.Create;
  try
    NusProfile.OnData := @NusObserver.DataReceived;
    NusProfile.AttachProfile;
    NusSubscription := NusProfile.TestChannel.Subscription;
    NusOperationId := FBackendObject.OperationIds[
      FBackendObject.CommandCount - 1];
    ActivateProfile(80);
    EmitEvent(lbekSubscribed, NusOperationId, 42, []);
    AssertTrue(FBackendObject.CompleteOperation(NusOperationId,
      lbekOperationSucceeded));

    EmitEvent(lbekNotification, InvalidBleOperationId, 42, [$24, $23]);
    EmitEvent(lbekNotification, InvalidBleOperationId,
      41, [79]);

    AssertEquals(1, NusObserver.CallCount);
    AssertEquals(79, FProfile.LevelPercent);
    AssertEquals(Ord(lbssConnected), Ord(FSession.State));
  finally
    NusObserver.Free;
    NusProfile.Free;
  end;
end;

procedure TLazBleBatteryTest.ReadOnlyBatteryBecomesReady;
begin
  FServices[0].Characteristics[0].CanNotify := False;
  CreateFixture;
  FProfile.AttachProfile;
  CompleteRead([42]);
  AssertTrue(FProfile.Ready);
  AssertEquals(42, FProfile.LevelPercent);
  AssertEquals(3, FBackendObject.CommandCount);
end;

procedure TLazBleBatteryTest.RefreshReadsWithoutResubscribing;
var
  Operation: IBleOperation;
begin
  ActivateProfile(75);
  Operation := FProfile.RefreshAsync;
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertEquals(Ord(lbckRead), Ord(FBackendObject.Commands[4].Kind));
  CompleteRead([64]);
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(64, FProfile.LevelPercent);
  AssertTrue(FProfile.Ready);
  AssertEquals(5, FBackendObject.CommandCount);
end;

procedure TLazBleBatteryTest.RefreshRejectsBusyAndDetached;
var
  First, Rejected: IBleOperation;
begin
  Rejected := FProfile.RefreshAsync;
  AssertEquals(Ord(lbopFailed), Ord(Rejected.State));
  ActivateProfile(75);
  First := FProfile.RefreshAsync;
  Rejected := FProfile.RefreshAsync;
  AssertEquals(Ord(lbopFailed), Ord(Rejected.State));
  CompleteRead([64]);
  AssertEquals(Ord(lbopSucceeded), Ord(First.State));
end;

procedure TLazBleBatteryTest.RefreshCancelAndDetach;
var
  Operation: IBleOperation;
  ReadId: TBleOperationId;
begin
  ActivateProfile(75);
  Operation := FProfile.RefreshAsync;
  ReadId := FBackendObject.OperationIds[FBackendObject.CommandCount - 1];
  Operation.Cancel;
  AssertTrue(FBackendObject.CancellationWasRequested(ReadId));
  AssertTrue(FBackendObject.CompleteOperation(ReadId, lbekOperationCancelled));
  AssertEquals(Ord(lbopCancelled), Ord(Operation.State));
  AssertTrue(FProfile.Ready);
  Operation := FProfile.RefreshAsync;
  ReadId := FBackendObject.OperationIds[FBackendObject.CommandCount - 1];
  FProfile.DetachProfile;
  AssertEquals(Ord(lbopCancelled), Ord(Operation.State));
  AssertTrue(FBackendObject.CompleteOperation(ReadId, lbekOperationSucceeded));
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
end;

procedure TLazBleBatteryTest.ExtendedStatusesUseTheirDeclaredModes;
var
  Observer: TBatteryObserver;
begin
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, True);
  AddCharacteristic(BatteryCriticalStatusCharacteristicUuid, False, True);
  CreateFixture;
  Observer := TBatteryObserver.Create;
  try
    FProfile.OnUpdated := @Observer.Updated;
    FProfile.AttachProfile;
    CompleteRead([75]);
    CompleteSubscription(41);
    CompleteRead([7, $A3, $12, $34, $12, 75, 5]);
    AssertEquals(Ord(lbsmIndicate),
      Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].SubscriptionMode));
    CompleteSubscription(42);
    CompleteRead([3]);
    AssertFalse(FProfile.Ready);
    CompleteSubscription(43);
    AssertTrue(FProfile.Ready);
    AssertTrue(bbcCriticalStatus in FProfile.AvailableCharacteristics);
    AssertTrue(FProfile.Data.LevelStatus.BatteryPresent);
    AssertEquals(Ord(bbcsCharging), Ord(FProfile.Data.LevelStatus.ChargeState));
    AssertEquals($1234, FProfile.Data.LevelStatus.Identifier);
    AssertEquals(75, FProfile.Data.LevelStatus.LevelPercent);
    AssertEquals(Ord(bbsrTrue), Ord(FProfile.Data.LevelStatus.ServiceRequired));
    AssertTrue(FProfile.Data.CriticalStatus.ImmediateServiceRequired);
    AssertEquals(3, Observer.FUpdatedCount);
  finally
    FProfile.OnUpdated := nil;
    Observer.Free;
  end;
end;

procedure TLazBleBatteryTest.LevelStatusMergesOptionalFields;
begin
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, False);
  CreateFixture;
  FProfile.AttachProfile;
  CompleteRead([75]);
  CompleteSubscription(41);
  CompleteRead([7, 1, 0, $34, $12, 75, 2]);
  CompleteSubscription(42);
  EmitEvent(lbekNotification, InvalidBleOperationId, 42, [0, $21, 0]);
  AssertTrue(FProfile.Data.LevelStatus.HasIdentifier);
  AssertTrue(FProfile.Data.LevelStatus.HasLevelPercent);
  AssertEquals($1234, FProfile.Data.LevelStatus.Identifier);
  AssertEquals(75, FProfile.Data.LevelStatus.LevelPercent);
  AssertEquals(Ord(bbcsCharging), Ord(FProfile.Data.LevelStatus.ChargeState));
  AssertEquals(Ord(bbsrUnknown), Ord(FProfile.Data.LevelStatus.ServiceRequired));
end;

procedure TLazBleBatteryTest.InvalidStatusDoesNotPartiallyApply;
begin
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, False);
  CreateFixture;
  FProfile.AttachProfile;
  CompleteRead([75]);
  CompleteSubscription(41);
  CompleteRead([2, 1, 0, 75]);
  CompleteSubscription(42);
  EmitEvent(lbekNotification, InvalidBleOperationId, 42, [2, $21, 0, 101]);
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(75, FProfile.Data.LevelStatus.LevelPercent);
  AssertEquals(Ord(bbcsUnknown), Ord(FProfile.Data.LevelStatus.ChargeState));
end;

procedure TLazBleBatteryTest.CriticalStatusRequiresLevelStatusAndIndicate;
begin
  AddCharacteristic(BatteryCriticalStatusCharacteristicUuid, False, True);
  CreateFixture;
  FProfile.AttachProfile;
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(2, FBackendObject.CommandCount);
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, False);
  FServices[0].Characteristics[1].CanIndicate := False;
  CreateFixture;
  FProfile.AttachProfile;
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
end;

procedure TLazBleBatteryTest.EnergyStatusDecodesDecimalFloatAndSignedRate;
begin
  PrepareExtension(BatteryEnergyStatusCharacteristicUuid);
  CompleteRead([$3F, $7D, $F0, $F4, $FF, 5, $F0, $7D, $E0, $85, $FF, 0, 0]);
  CompleteSubscription(43);
  AssertTrue(FProfile.Ready);
  AssertEquals(12.5, FProfile.Data.EnergyStatus.ExternalSourcePowerWatts.Value, 0.00001);
  AssertEquals(-1.2, FProfile.Data.EnergyStatus.PresentVoltageVolts.Value, 0.00001);
  AssertEquals(0.5, FProfile.Data.EnergyStatus.AvailableEnergyKWh.Value, 0.00001);
  AssertEquals(1.25, FProfile.Data.EnergyStatus.AvailableCapacityKWh.Value, 0.00001);
  AssertEquals(-12.3, FProfile.Data.EnergyStatus.ChargeRateWatts.Value, 0.00001);
  AssertEquals(Ord(bbvsFinite), Ord(FProfile.Data.EnergyStatus.LastChargeEnergyKWh.State));
  AssertEquals(0.0, FProfile.Data.EnergyStatus.LastChargeEnergyKWh.Value);
end;

procedure TLazBleBatteryTest.EnergySpecialValuesAndPartialUpdates;
begin
  PrepareExtension(BatteryEnergyStatusCharacteristicUuid);
  CompleteRead([$3F, $FE, 7, $FF, 7, 0, 8, $FE, 7, 2, 8, $FF, 7]);
  CompleteSubscription(43);
  AssertEquals(Ord(bbvsPositiveInfinity), Ord(FProfile.Data.EnergyStatus.ExternalSourcePowerWatts.State));
  AssertEquals(Ord(bbvsNaN), Ord(FProfile.Data.EnergyStatus.PresentVoltageVolts.State));
  AssertEquals(Ord(bbvsNotAtResolution), Ord(FProfile.Data.EnergyStatus.AvailableEnergyKWh.State));
  AssertEquals(Ord(bbvsNegativeInfinity), Ord(FProfile.Data.EnergyStatus.ChargeRateWatts.State));
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, [1, 10, 0]);
  AssertEquals(10.0, FProfile.Data.EnergyStatus.ExternalSourcePowerWatts.Value);
  AssertEquals(Ord(bbvsNaN), Ord(FProfile.Data.EnergyStatus.PresentVoltageVolts.State));
end;

procedure TLazBleBatteryTest.TimeStatusPreservesUnknownAndSaturation;
begin
  PrepareExtension(BatteryTimeStatusCharacteristicUuid);
  CompleteRead([3, $FF, $FF, $FF, $FE, $FF, $FF, 90, 0, 0]);
  CompleteSubscription(43);
  AssertEquals(Ord(bbvsUnknown), Ord(FProfile.Data.TimeStatus.UntilDischargedMinutes.State));
  AssertEquals(Ord(bbvsGreaterThan), Ord(FProfile.Data.TimeStatus.StandbyDischargeMinutes.State));
  AssertEquals($FFFFFD, FProfile.Data.TimeStatus.StandbyDischargeMinutes.Value);
  AssertEquals(90.0, FProfile.Data.TimeStatus.UntilRechargedMinutes.Value);
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, [0, 0, 0, 0]);
  AssertEquals(0.0, FProfile.Data.TimeStatus.UntilDischargedMinutes.Value);
  AssertEquals(90.0, FProfile.Data.TimeStatus.UntilRechargedMinutes.Value);
end;

procedure TLazBleBatteryTest.TruncatedEnergyIsAtomic;
begin
  PrepareExtension(BatteryEnergyStatusCharacteristicUuid);
  CompleteRead([1, 5, 0]);
  CompleteSubscription(43);
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, [3, 10, 0, 5]);
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(5.0, FProfile.Data.EnergyStatus.ExternalSourcePowerWatts.Value);
  AssertEquals(Ord(bbvsAbsent), Ord(FProfile.Data.EnergyStatus.PresentVoltageVolts.State));
end;

procedure TLazBleBatteryTest.HealthStatusDecodesAllFields;
begin
  PrepareExtension(BatteryHealthStatusCharacteristicUuid);
  CompleteRead([15, 85, $34, $12, $F6, 7, 0]);
  CompleteSubscription(43);
  AssertTrue(FProfile.Ready);
  AssertEquals(85.0, FProfile.Data.HealthStatus.SummaryPercent.Value);
  AssertEquals($1234, FProfile.Data.HealthStatus.CycleCount.Value);
  AssertEquals(-10.0, FProfile.Data.HealthStatus.TemperatureCelsius.Value);
  AssertEquals(7.0, FProfile.Data.HealthStatus.DeepDischargeCount.Value);
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, [4, $7F]);
  AssertEquals(Ord(bbvsGreaterThan), Ord(FProfile.Data.HealthStatus.TemperatureCelsius.State));
  AssertEquals(126.0, FProfile.Data.HealthStatus.TemperatureCelsius.Value);
  AssertEquals(85.0, FProfile.Data.HealthStatus.SummaryPercent.Value);
end;

procedure TLazBleBatteryTest.HealthInformationUsesIndicateAndTemperatureBounds;
begin
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, False);
  AddCharacteristic(BatteryHealthStatusCharacteristicUuid, True, False);
  AddCharacteristic(BatteryHealthInformationCharacteristicUuid, False, True);
  CreateFixture;
  FProfile.AttachProfile;
  CompleteRead([75]); CompleteSubscription(41);
  CompleteRead([0, 1, 0]); CompleteSubscription(42);
  CompleteRead([1, 90]); CompleteSubscription(43);
  CompleteRead([3, $E8, 3, $80, $7F]);
  AssertEquals(Ord(lbsmIndicate),
    Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].SubscriptionMode));
  CompleteSubscription(44);
  AssertTrue(FProfile.Ready);
  AssertEquals(1000.0, FProfile.Data.HealthInformation.DesignedCycleCount.Value);
  AssertEquals(Ord(bbvsLessThan),
    Ord(FProfile.Data.HealthInformation.MinTemperatureCelsius.State));
  AssertEquals(-127.0, FProfile.Data.HealthInformation.MinTemperatureCelsius.Value);
  AssertEquals(Ord(bbvsGreaterThan),
    Ord(FProfile.Data.HealthInformation.MaxTemperatureCelsius.State));
end;

procedure TLazBleBatteryTest.HealthInformationRequiresHealthStatus;
begin
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, False);
  AddCharacteristic(BatteryHealthInformationCharacteristicUuid, False, True);
  CreateFixture;
  FProfile.AttachProfile;
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(2, FBackendObject.CommandCount);
end;

procedure TLazBleBatteryTest.InvalidHealthDoesNotPartiallyApply;
begin
  PrepareExtension(BatteryHealthStatusCharacteristicUuid);
  CompleteRead([3, 85, 1, 0]); CompleteSubscription(43);
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, [3, 101, 2, 0]);
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(85.0, FProfile.Data.HealthStatus.SummaryPercent.Value);
  AssertEquals(1.0, FProfile.Data.HealthStatus.CycleCount.Value);
end;

procedure TLazBleBatteryTest.BatteryInformationDecodesAllFields;
begin
  PrepareExtension(BatteryInformationCharacteristicUuid, True);
  CompleteRead([$FF, 0, 3, $20, $4E, 0, 8, $52, 0,
    $7D, $E0, 1, $F0, 5, $E0, 5, $25, $F0, 0]);
  CompleteSubscription(43);
  AssertTrue(FProfile.Ready);
  AssertTrue(FProfile.Data.Information.Replaceable);
  AssertTrue(FProfile.Data.Information.Rechargeable);
  AssertEquals(20000.0, FProfile.Data.Information.ManufactureDaysSince1970.Value);
  AssertEquals(21000.0, FProfile.Data.Information.ExpirationDaysSince1970.Value);
  AssertEquals(1.25, FProfile.Data.Information.DesignedCapacityKWh.Value, 0.00001);
  AssertEquals(0.1, FProfile.Data.Information.LowEnergyKWh.Value, 0.00001);
  AssertEquals(0.05, FProfile.Data.Information.CriticalEnergyKWh.Value, 0.00001);
  AssertEquals(Ord(bbchLithiumIon), Ord(FProfile.Data.Information.Chemistry));
  AssertEquals(3.7, FProfile.Data.Information.NominalVoltageVolts.Value, 0.00001);
  AssertTrue(FProfile.Data.Information.HasAggregationGroup);
end;

procedure TLazBleBatteryTest.ServiceDatePreservesUnknown;
begin
  PrepareExtension(EstimatedServiceDateCharacteristicUuid);
  CompleteRead([0, 0, 0]); CompleteSubscription(43);
  AssertEquals(Ord(bbvsUnknown), Ord(FProfile.Data.ServiceDaysSince1970.State));
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, [1, 0, 0]);
  AssertEquals(1.0, FProfile.Data.ServiceDaysSince1970.Value);
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, [$FF, $FF, $FF]);
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(1.0, FProfile.Data.ServiceDaysSince1970.Value);
end;

procedure TLazBleBatteryTest.BatteryStringsAreUtf8AndMayBeEmpty;
begin
  PrepareExtension(BatteryManufacturerNameCharacteristicUuid, True);
  CompleteRead([$41, $C3, $A9]); CompleteSubscription(43);
  AssertTrue(FProfile.Data.ManufacturerName.HasValue);
  AssertEquals(UTF8String(#$41#$C3#$A9), FProfile.Data.ManufacturerName.Value);
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, []);
  AssertTrue(FProfile.Data.ManufacturerName.HasValue);
  AssertEquals('', FProfile.Data.ManufacturerName.Value);
end;

procedure TLazBleBatteryTest.InvalidUtf8KeepsPreviousValue;
begin
  PrepareExtension(BatteryManufacturerNameCharacteristicUuid, True);
  CompleteRead([$41]); CompleteSubscription(43);
  EmitEvent(lbekNotification, InvalidBleOperationId, 43, [$C0, $80]);
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals('A', FProfile.Data.ManufacturerName.Value);
end;

procedure TLazBleBatteryTest.RemovalInvalidatesAndInsertionRefreshes;
begin
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, False);
  AddCharacteristic(BatteryEnergyStatusCharacteristicUuid, True, False);
  AddCharacteristic(BatteryManufacturerNameCharacteristicUuid, False, True);
  CreateFixture;
  FProfile.AttachProfile;
  CompleteRead([75]); CompleteSubscription(41);
  CompleteRead([2, 1, 0, 75]); CompleteSubscription(42);
  CompleteRead([9, 5, 0, 10, 0]); CompleteSubscription(43);
  CompleteRead([$41]); CompleteSubscription(44);
  EmitEvent(lbekNotification, InvalidBleOperationId, 42, [0, 0, 0]);
  AssertFalse(FProfile.Data.LevelStatus.BatteryPresent);
  AssertFalse(FProfile.Data.LevelStatus.HasLevelPercent);
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertFalse(FProfile.Data.ManufacturerName.HasValue);
  AssertEquals(Ord(bbvsAbsent), Ord(FProfile.Data.EnergyStatus.AvailableCapacityKWh.State));
  AssertEquals(5.0, FProfile.Data.EnergyStatus.ExternalSourcePowerWatts.Value);
  EmitEvent(lbekNotification, InvalidBleOperationId, 44, [$42]);
  AssertFalse(FProfile.Data.ManufacturerName.HasValue);
  EmitEvent(lbekNotification, InvalidBleOperationId, 42, [0, 1, 0]);
  AssertEquals(Ord(lbckRead), Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].Kind));
  CompleteRead([55]);
  CompleteRead([0, 1, 0]);
  CompleteRead([1, 4, 0]);
  CompleteRead([$43]);
  AssertTrue(FProfile.Ready);
  AssertEquals(55, FProfile.LevelPercent);
  AssertEquals('C', FProfile.Data.ManufacturerName.Value);
  AssertEquals(Ord(bbvsAbsent), Ord(FProfile.Data.EnergyStatus.AvailableCapacityKWh.State));
end;

procedure TLazBleBatteryTest.AbsentBatteryStillConfiguresSubscriptions;
begin
  AddCharacteristic(BatteryLevelStatusCharacteristicUuid, True, False);
  AddCharacteristic(BatteryHealthStatusCharacteristicUuid, True, False);
  AddCharacteristic(BatteryManufacturerNameCharacteristicUuid, False, True);
  CreateFixture;
  FProfile.AttachProfile;
  CompleteRead([0]); CompleteSubscription(41);
  CompleteRead([0, 0, 0]); CompleteSubscription(42);
  CompleteSubscription(43);
  CompleteSubscription(44);
  AssertTrue(FProfile.Ready);
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertFalse(FProfile.Data.HealthStatus.HasValue);
  AssertFalse(FProfile.Data.ManufacturerName.HasValue);
  EmitEvent(lbekNotification, InvalidBleOperationId, 42, [0, 1, 0]);
  CompleteRead([55]);
  CompleteRead([0, 1, 0]);
  CompleteRead([1, 95]);
  CompleteRead([$41]);
  AssertEquals(55, FProfile.LevelPercent);
  AssertEquals(95.0, FProfile.Data.HealthStatus.SummaryPercent.Value);
  AssertEquals('A', FProfile.Data.ManufacturerName.Value);
end;

initialization
  RegisterTest(TLazBleBatteryTest);

end.
