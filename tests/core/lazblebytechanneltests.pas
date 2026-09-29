unit LazBleByteChannelTests;

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
  LazBleCentralManager,
  LazBleByteChannel,
  FakeLazBleBackend,
  TestLazBleAccess;

type
  TByteChannelObserver = class
  private
    FCallCount: Integer;
    FValue: TBytes;
  public
    procedure DataReceived(Sender: TObject; const AValue: TBytes);
    property CallCount: Integer read FCallCount;
    property Value: TBytes read FValue;
  end;

  TLazBleByteChannelTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FManager: TBleCentralManager;
    FSession: TBleGattSession;
    FChannel: TBleByteChannel;
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId;
      const ASubscriptionId: TBleSubscriptionId;
      const AValue: array of Byte);
    procedure ActivateChannel;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AttachUsesConfiguredNotifyCharacteristic;
    procedure SendUsesConfiguredWriteCharacteristicAndMode;
    procedure NotificationIsForwardedAsBytes;
    procedure DetachIsIdempotentAndStopsData;
    procedure SendBeforeAttachReturnsFailedOperation;
  end;

implementation

procedure TByteChannelObserver.DataReceived(Sender: TObject;
  const AValue: TBytes);
begin
  Inc(FCallCount);
  FValue := Copy(AValue);
end;

procedure TLazBleByteChannelTest.EmitEvent(
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

procedure TLazBleByteChannelTest.ActivateChannel;
var
  OperationId: TBleOperationId;
  Subscription: IBleSubscription;
begin
  Subscription := FChannel.Attach;
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekSubscribed, OperationId, 21, []);
  AssertTrue(FBackendObject.CompleteOperation(
    OperationId, lbekOperationSucceeded));
  AssertTrue(FChannel.Ready);
end;

procedure TLazBleByteChannelTest.SetUp;
var
  ConnectId: TBleOperationId;
begin
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FManager := TBleCentralManager.Create(FBackend);
  FSession := FManager.CreateSession('device-1');
  ConnectId := LazBleTestConnect(FSession);
  EmitEvent(lbekConnected, ConnectId, InvalidBleSubscriptionId, []);
  EmitEvent(lbekServicesDiscovered, FBackendObject.OperationIds[1],
    InvalidBleSubscriptionId, []);
  FChannel := TBleByteChannel.Create(FSession, 'service-x', 'write-x',
    'notify-x', lbwmCommand);
end;

procedure TLazBleByteChannelTest.TearDown;
begin
  FChannel.Free;
  FChannel := nil;
  FManager.Free;
  FManager := nil;
  FSession := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleByteChannelTest.AttachUsesConfiguredNotifyCharacteristic;
var
  Subscription: IBleSubscription;
begin
  Subscription := FChannel.Attach;

  AssertTrue(Assigned(Subscription));
  AssertEquals(Ord(lbchsSubscribing), Ord(FChannel.State));
  AssertEquals(Ord(lbckSubscribe), Ord(FBackendObject.Commands[2].Kind));
  AssertEquals('service-x', FBackendObject.Commands[2].ServiceUuid);
  AssertEquals('notify-x', FBackendObject.Commands[2].CharacteristicUuid);
  AssertTrue(Subscription = FChannel.Attach);
  AssertEquals(3, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.SendUsesConfiguredWriteCharacteristicAndMode;
var
  Operation: IBleGattOperation;
begin
  ActivateChannel;

  Operation := FChannel.SendAsync([$41, $42]);

  AssertTrue(Assigned(Operation));
  AssertEquals(Ord(lbckWrite),
    Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].Kind));
  AssertEquals('write-x',
    FBackendObject.Commands[FBackendObject.CommandCount - 1].CharacteristicUuid);
  AssertEquals(Ord(lbwmCommand), Ord(
    FBackendObject.Commands[FBackendObject.CommandCount - 1].WriteMode));
  AssertEquals(2, Length(
    FBackendObject.Commands[FBackendObject.CommandCount - 1].Value));
end;

procedure TLazBleByteChannelTest.NotificationIsForwardedAsBytes;
var
  Observer: TByteChannelObserver;
begin
  Observer := TByteChannelObserver.Create;
  try
    FChannel.OnData := @Observer.DataReceived;
    ActivateChannel;

    EmitEvent(lbekNotification, InvalidBleOperationId,
      21, [$10, $20]);

    AssertEquals(1, Observer.CallCount);
    AssertEquals(2, Length(Observer.Value));
    AssertEquals($20, Integer(Observer.Value[1]));
  finally
    Observer.Free;
  end;
end;

procedure TLazBleByteChannelTest.DetachIsIdempotentAndStopsData;
var
  FirstOperation: IBleGattOperation;
  Observer: TByteChannelObserver;
  SecondOperation: IBleGattOperation;
  SubscriptionId: TBleSubscriptionId;
begin
  Observer := TByteChannelObserver.Create;
  try
    FChannel.OnData := @Observer.DataReceived;
    ActivateChannel;
    SubscriptionId := 21;

    FirstOperation := FChannel.Detach;
    SecondOperation := FChannel.Detach;

    AssertTrue(FirstOperation = SecondOperation);
    AssertFalse(FChannel.Ready);
    EmitEvent(lbekNotification, InvalidBleOperationId, SubscriptionId, [$33]);
    AssertEquals(0, Observer.CallCount);
  finally
    Observer.Free;
  end;
end;

procedure TLazBleByteChannelTest.SendBeforeAttachReturnsFailedOperation;
var
  Operation: IBleGattOperation;
begin
  Operation := FChannel.SendAsync([$01]);

  AssertTrue(Assigned(Operation));
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertEquals(LazBleErrorInvalidState, Operation.ErrorCode);
  AssertEquals('BLE byte channel is not ready', Operation.ErrorMessage);
  AssertEquals(2, FBackendObject.CommandCount);
end;

initialization
  RegisterTest(TLazBleByteChannelTest);

end.
