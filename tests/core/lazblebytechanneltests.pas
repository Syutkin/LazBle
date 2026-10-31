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
    FSession: TBleGattSession;
    FChannel: TBleByteChannel;
    FWriteSize: Word;
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId;
      const ASubscriptionId: TBleSubscriptionId;
      const AValue: array of Byte);
    procedure ActivateChannel;
    procedure ReconnectWithWriteSize(const ASize: Word);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AttachUsesConfiguredNotifyCharacteristic;
    procedure SendUsesConfiguredWriteCharacteristicAndMode;
    procedure NotificationIsForwardedAsBytes;
    procedure DetachIsIdempotentAndStopsData;
    procedure SendBeforeAttachReturnsFailedOperation;
    procedure LongSendCompletesAfterSequentialChunks;
    procedure ConcurrentSendsDoNotInterleaveAndOwnTheirBytes;
    procedure FailedChunkStopsSendAndPreservesDiagnostic;
    procedure CancelStopsRemainingChunks;
    procedure CancelQueuedSendSkipsItsWrites;
    procedure DetachStopsRemainingChunks;
    procedure DestroyStopsSendAndAcceptsLateCompletion;
    procedure DisconnectStopsRemainingChunks;
    procedure EmptySendSucceedsWithoutWrite;
    procedure UsesCurrentConnectionWriteSize;
    procedure UnknownWriteSizeFailsWithoutWrite;
    procedure ExactBoundaryNeedsOneWrite;
    procedure CancelledFinalWriteRetainsNativeOutcome;
    procedure CancelPreservesNativeFailure;
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
  if AKind = lbekServicesDiscovered then
  begin
    BackendEvent.MaxWriteSize := FWriteSize;
    SetLength(BackendEvent.Services, 1); BackendEvent.Services[0].Uuid := 'service-x';
    SetLength(BackendEvent.Services[0].Characteristics, 1);
    BackendEvent.Services[0].Characteristics[0].Uuid := 'notify-x';
    BackendEvent.Services[0].Characteristics[0].CanNotify := True;
  end;
  SetLength(BackendEvent.Value, Length(AValue));
  for Index := 0 to High(AValue) do
    BackendEvent.Value[Index] := AValue[Index];
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
  if AKind in [lbekConnected, lbekServicesDiscovered] then
    AssertTrue(FBackendObject.CompleteOperation(AOperationId, lbekOperationSucceeded));
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
  FWriteSize := 20;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FSession := LazBleTestCreateSession('device-1', @FBackendObject.Submit, @FBackendObject.Cancel);
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
  FSession.Free;
  FSession := nil;
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

procedure TLazBleByteChannelTest.LongSendCompletesAfterSequentialChunks;
var Operation: IBleGattOperation; Data: TBytes; I: Integer;
begin
  ActivateChannel;
  SetLength(Data, 51);
  for I := 0 to High(Data) do Data[I] := I;
  Operation := FChannel.SendAsync(Data);
  AssertEquals(4, FBackendObject.CommandCount);
  AssertEquals(20, Length(FBackendObject.Commands[3].Value));
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertEquals(5, FBackendObject.CommandCount);
  AssertEquals(20, Length(FBackendObject.Commands[4].Value));
  AssertEquals(20, Integer(FBackendObject.Commands[4].Value[0]));
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[4], lbekOperationSucceeded));
  AssertEquals(6, FBackendObject.CommandCount);
  AssertEquals(11, Length(FBackendObject.Commands[5].Value));
  AssertEquals(40, Integer(FBackendObject.Commands[5].Value[0]));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[5], lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(6, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.ConcurrentSendsDoNotInterleaveAndOwnTheirBytes;
var First, Second: IBleGattOperation; Data: TBytes;
begin
  ActivateChannel;
  SetLength(Data, 21); Data[20] := $42;
  First := FChannel.SendAsync(Data);
  Second := FChannel.SendAsync([$99]);
  Data[20] := $FF;
  AssertEquals(4, FBackendObject.CommandCount);
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertEquals(1, Length(FBackendObject.Commands[4].Value));
  AssertEquals($42, Integer(FBackendObject.Commands[4].Value[0]));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[4], lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(First.State));
  AssertEquals($99, Integer(FBackendObject.Commands[5].Value[0]));
  AssertEquals(Ord(lbopPending), Ord(Second.State));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[5], lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Second.State));
end;

procedure TLazBleByteChannelTest.FailedChunkStopsSendAndPreservesDiagnostic;
var Operation: IBleGattOperation; Data: TBytes;
begin
  ActivateChannel;
  SetLength(Data, 41);
  Operation := FChannel.SendAsync(Data);
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[4], lbekOperationFailed, 17, 'write failed'));
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertEquals(17, Operation.ErrorCode);
  AssertEquals('write failed', Operation.ErrorMessage);
  AssertEquals(5, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.CancelStopsRemainingChunks;
var Operation: IBleGattOperation; Data: TBytes;
begin
  ActivateChannel;
  SetLength(Data, 41);
  Operation := FChannel.SendAsync(Data);
  Operation.Cancel;
  AssertTrue(FBackendObject.CancellationWasRequested(FBackendObject.OperationIds[3]));
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertEquals(Ord(lbopCancelled), Ord(Operation.State));
  AssertEquals(4, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.CancelQueuedSendSkipsItsWrites;
var First, Second: IBleGattOperation;
begin
  ActivateChannel;
  First := FChannel.SendAsync([$01]);
  Second := FChannel.SendAsync([$02]);
  Second.Cancel;
  AssertEquals(Ord(lbopCancelled), Ord(Second.State));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(First.State));
  AssertEquals(4, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.DetachStopsRemainingChunks;
var Operation, Queued: IBleGattOperation; Data: TBytes;
begin
  ActivateChannel;
  SetLength(Data, 41);
  Operation := FChannel.SendAsync(Data);
  Queued := FChannel.SendAsync([$02]);
  FChannel.Detach;
  AssertEquals(Ord(lbopCancelled), Ord(Queued.State));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertEquals(Ord(lbopCancelled), Ord(Operation.State));
  AssertEquals(5, FBackendObject.CommandCount); { one write and unsubscribe }
end;

procedure TLazBleByteChannelTest.DestroyStopsSendAndAcceptsLateCompletion;
var Operation: IBleGattOperation; Data: TBytes;
begin
  ActivateChannel;
  SetLength(Data, 41);
  Operation := FChannel.SendAsync(Data);
  FreeAndNil(FChannel);
  AssertEquals(Ord(lbopCancelled), Ord(Operation.State));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertEquals(Ord(lbopCancelled), Ord(Operation.State));
  AssertEquals(5, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.DisconnectStopsRemainingChunks;
var Operation: IBleGattOperation; Data: TBytes; DisconnectId: TBleOperationId;
begin
  ActivateChannel;
  SetLength(Data, 41);
  Operation := FChannel.SendAsync(Data);
  DisconnectId := LazBleTestDisconnect(FSession);
  EmitEvent(lbekDisconnected, DisconnectId, InvalidBleSubscriptionId, []);
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertTrue(Operation.State <> lbopPending);
  AssertTrue(Operation.State <> lbopSucceeded);
  AssertEquals(5, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.EmptySendSucceedsWithoutWrite;
var Operation: IBleGattOperation;
begin
  ActivateChannel;
  Operation := FChannel.SendAsync(nil);
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(3, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.ReconnectWithWriteSize(const ASize: Word);
var Id: TBleOperationId;
begin
  Id := LazBleTestDisconnect(FSession);
  EmitEvent(lbekDisconnected, Id, InvalidBleSubscriptionId, []);
  AssertTrue(FBackendObject.CompleteOperation(Id, lbekOperationSucceeded));
  AssertEquals(0, FSession.MaxWriteSize);
  FWriteSize := ASize;
  Id := LazBleTestConnect(FSession);
  EmitEvent(lbekConnected, Id, InvalidBleSubscriptionId, []);
  EmitEvent(lbekServicesDiscovered,
    FBackendObject.OperationIds[FBackendObject.CommandCount - 1],
    InvalidBleSubscriptionId, []);
  ActivateChannel;
end;

procedure TLazBleByteChannelTest.UsesCurrentConnectionWriteSize;
var Operation: IBleGattOperation; Data: TBytes; Index: Integer;
begin
  ReconnectWithWriteSize(244);
  AssertEquals(244, FSession.MaxWriteSize);
  SetLength(Data, 489);
  Index := FBackendObject.CommandCount;
  Operation := FChannel.SendAsync(Data);
  AssertEquals(244, Length(FBackendObject.Commands[Index].Value));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[Index], lbekOperationSucceeded));
  AssertEquals(244, Length(FBackendObject.Commands[Index + 1].Value));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[Index + 1], lbekOperationSucceeded));
  AssertEquals(1, Length(FBackendObject.Commands[Index + 2].Value));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[Index + 2], lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  ReconnectWithWriteSize(20);
  SetLength(Data, 21);
  Index := FBackendObject.CommandCount;
  Operation := FChannel.SendAsync(Data);
  AssertEquals(20, Length(FBackendObject.Commands[Index].Value));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[Index], lbekOperationSucceeded));
  AssertEquals(1, Length(FBackendObject.Commands[Index + 1].Value));
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[Index + 1], lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleByteChannelTest.UnknownWriteSizeFailsWithoutWrite;
var Operation: IBleGattOperation; Count: Integer;
begin
  ReconnectWithWriteSize(0);
  Count := FBackendObject.CommandCount;
  Operation := FChannel.SendAsync([$01]);
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertEquals(LazBleErrorInvalidNativeData, Operation.ErrorCode);
  AssertEquals(Count, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.ExactBoundaryNeedsOneWrite;
var Operation: IBleGattOperation; Data: TBytes;
begin
  ActivateChannel;
  SetLength(Data, 20);
  Operation := FChannel.SendAsync(Data);
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(4, FBackendObject.CommandCount);
end;

procedure TLazBleByteChannelTest.CancelledFinalWriteRetainsNativeOutcome;
var Operation: IBleGattOperation;
begin
  ActivateChannel;
  Operation := FChannel.SendAsync([$01]);
  Operation.Cancel;
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
  AssertTrue(Operation.CancelRequested);
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleByteChannelTest.CancelPreservesNativeFailure;
var Operation: IBleGattOperation; Data: TBytes;
begin
  ActivateChannel;
  SetLength(Data, 21);
  Operation := FChannel.SendAsync(Data);
  Operation.Cancel;
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationFailed, 17, 'native failure'));
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertEquals(17, Operation.ErrorCode);
  AssertEquals('native failure', Operation.ErrorMessage);
  AssertEquals(4, FBackendObject.CommandCount);
end;

initialization
  RegisterTest(TLazBleByteChannelTest);

end.
