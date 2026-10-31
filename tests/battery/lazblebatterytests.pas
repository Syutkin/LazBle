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
  public
    procedure LevelChanged(Sender: TObject; const ADeviceId: string;
      const ALevelPercent: Integer);
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

initialization
  RegisterTest(TLazBleBatteryTest);

end.
