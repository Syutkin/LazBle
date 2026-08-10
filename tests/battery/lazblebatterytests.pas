unit LazBleBatteryTests;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  LazBleGattOperation,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile,
  LazBleCentralManager,
  LazBleNus,
  LazBleBattery,
  FakeLazBleBackend;

type
  TTestBatteryProfile = class(TBleBatteryProfile)
  public
    procedure BindToSession(const ASession: TBleGattSession);
  end;

  TTestNusProfile = class(TNusProfile)
  public
    procedure BindToSession(const ASession: TBleGattSession);
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
    FManager: TBleCentralManager;
    FSession: TBleGattSession;
    FProfile: TTestBatteryProfile;
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
  end;

implementation

procedure TTestBatteryProfile.BindToSession(const ASession: TBleGattSession);
begin
  BindSession(ASession);
end;

procedure TTestNusProfile.BindToSession(const ASession: TBleGattSession);
begin
  BindSession(ASession);
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
  Operation: TBleGattOperation;
begin
  Operation := FProfile.ReadOperation;
  EmitEvent(lbekReadResult, Operation.OperationId,
    InvalidBleSubscriptionId, AValue);
  AssertTrue(FBackendObject.CompleteOperation(Operation.OperationId,
    lbekOperationSucceeded));
end;

procedure TLazBleBatteryTest.ActivateProfile(const ALevelPercent: Byte);
begin
  FProfile.Attach;
  CompleteRead([ALevelPercent]);
  EmitEvent(lbekSubscribed, FProfile.Subscription.OperationId, 41, []);
  AssertTrue(FBackendObject.CompleteOperation(
    FProfile.Subscription.OperationId, lbekOperationSucceeded));
  AssertTrue(FProfile.Ready);
end;

procedure TLazBleBatteryTest.SetUp;
var
  ConnectId: TBleOperationId;
begin
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FManager := TBleCentralManager.Create(FBackend);
  FSession := FManager.CreateSession('entime-1');
  ConnectId := FSession.Connect;
  EmitEvent(lbekConnected, ConnectId, InvalidBleSubscriptionId, []);
  EmitEvent(lbekServicesDiscovered, FBackendObject.OperationIds[1],
    InvalidBleSubscriptionId, []);
  FProfile := TTestBatteryProfile.Create;
  FProfile.BindToSession(FSession);
end;

procedure TLazBleBatteryTest.TearDown;
begin
  FProfile.Free;
  FProfile := nil;
  FManager.Free;
  FManager := nil;
  FSession := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleBatteryTest.AttachReadsBeforeSubscribing;
begin
  FProfile.Attach;

  AssertTrue(Assigned(FProfile.ReadOperation));
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
      FProfile.Subscription.SubscriptionId, [64]);

    AssertEquals(64, FProfile.LevelPercent);
    AssertEquals(2, Observer.CallCount);
    AssertEquals('entime-1', Observer.DeviceId);
    AssertEquals(64, Observer.LevelPercent);
  finally
    Observer.Free;
  end;
end;

procedure TLazBleBatteryTest.InvalidReadPayloadIsProfileError;
begin
  FProfile.Attach;
  CompleteRead([101]);

  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertEquals(3, FBackendObject.CommandCount);
  AssertEquals(Ord(lbssConnected), Ord(FSession.State));
end;

procedure TLazBleBatteryTest.InvalidNotificationIsProfileError;
begin
  ActivateProfile(75);
  EmitEvent(lbekNotification, InvalidBleOperationId,
    FProfile.Subscription.SubscriptionId, [70, 71]);

  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(75, FProfile.LevelPercent);
  AssertEquals(Ord(lbssConnected), Ord(FSession.State));
end;

procedure TLazBleBatteryTest.DetachCancelsPendingRead;
var
  ReadOperation: TBleGattOperation;
begin
  FProfile.Attach;
  ReadOperation := FProfile.ReadOperation;
  FProfile.Detach;

  AssertTrue(FBackendObject.CancellationWasRequested(
    ReadOperation.OperationId));
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
end;

procedure TLazBleBatteryTest.DetachCancelsPendingSubscription;
var
  SubscriptionId: TBleOperationId;
begin
  FProfile.Attach;
  CompleteRead([75]);
  SubscriptionId := FProfile.Subscription.OperationId;
  FProfile.Detach;

  AssertTrue(FBackendObject.CancellationWasRequested(SubscriptionId));
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
end;

procedure TLazBleBatteryTest.DetachUnsubscribesAndSetsUnknown;
var
  DetachOperation: TBleGattOperation;
begin
  ActivateProfile(75);
  FProfile.Detach;
  DetachOperation := FProfile.DetachOperation;

  AssertTrue(Assigned(DetachOperation));
  FProfile.Detach;
  AssertTrue(DetachOperation = FProfile.DetachOperation);
  AssertEquals(Ord(lbckUnsubscribe),
    Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].Kind));
  AssertEquals(UnknownBatteryLevel, FProfile.LevelPercent);
  AssertEquals(Ord(lbgpsDetached), Ord(FProfile.State));
end;

procedure TLazBleBatteryTest.NusAndBatteryShareOneSession;
var
  NusProfile: TTestNusProfile;
  NusObserver: TNusObserver;
  NusSubscription: TBleSubscription;
begin
  NusProfile := TTestNusProfile.Create;
  NusProfile.BindToSession(FSession);
  NusObserver := TNusObserver.Create;
  try
    NusProfile.OnData := @NusObserver.DataReceived;
    NusProfile.Attach;
    NusSubscription := NusProfile.Channel.Subscription;
    ActivateProfile(80);
    EmitEvent(lbekSubscribed, NusSubscription.OperationId, 42, []);
    AssertTrue(FBackendObject.CompleteOperation(NusSubscription.OperationId,
      lbekOperationSucceeded));

    EmitEvent(lbekNotification, InvalidBleOperationId, 42, [$24, $23]);
    EmitEvent(lbekNotification, InvalidBleOperationId,
      FProfile.Subscription.SubscriptionId, [79]);

    AssertEquals(1, NusObserver.CallCount);
    AssertEquals(79, FProfile.LevelPercent);
    AssertEquals(Ord(lbssConnected), Ord(FSession.State));
  finally
    NusObserver.Free;
    NusProfile.Free;
  end;
end;

initialization
  RegisterTest(TLazBleBatteryTest);

end.
