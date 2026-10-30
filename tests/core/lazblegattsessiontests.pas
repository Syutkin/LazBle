unit LazBleGattSessionTests;

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
  FakeLazBleBackend,
  TestLazBleAccess;

type
  TDataObserver = class
  private
    FCallCount: Integer;
    FValue: TBytes;
  public
    procedure DataReceived(Sender: TObject; const AValue: TBytes);
    property CallCount: Integer read FCallCount;
    property Value: TBytes read FValue;
  end;

  TLazBleGattSessionTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FManager: TBleCentralManager;
    FSession: TBleGattSession;
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId;
      const ASubscriptionId: TBleSubscriptionId;
      const AValue: array of Byte);
    procedure EmitServicesDiscovered(const AOperationId: TBleOperationId);
    function Subscribe: IBleSubscription;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ReadPublishesManagedValue;
    procedure WritePreservesModeAndPayload;
    procedure SubscribeDeliversNotifications;
    procedure SubscribeFailureMarksTokenFailed;
    procedure UnsubscribeIsIdempotent;
    procedure DisconnectInvalidatesSubscriptionAndIgnoresOldNotification;
    procedure DiscoveryPublishesUpstreamGattRecords;
    procedure CompletedOperationOutlivesSession;
    procedure InvalidatedSubscriptionOutlivesSession;
    procedure DescriptorReadPublishesValueAndAddress;
    procedure DescriptorWriteOwnsSubmittedBytes;
    procedure DescriptorMissingTargetFailsLocally;
    procedure DescriptorRequiresConnectedSession;
    procedure DescriptorCancelPreservesActualFailure;
    procedure DescriptorRejectsOldGenerationResult;
    procedure IndicateUsesExistingSubscriptionLifecycle;
    procedure UnsupportedSubscriptionModeFailsLocally;
  end;

implementation

procedure TLazBleGattSessionTest.EmitServicesDiscovered(
  const AOperationId: TBleOperationId);
var
  BackendEvent: TLazBleBackendEvent;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekServicesDiscovered;
  BackendEvent.OperationId := AOperationId;
  BackendEvent.DeviceId := FSession.DeviceId;
  BackendEvent.Generation := FSession.Generation;
  SetLength(BackendEvent.Services, 1);
  BackendEvent.Services[0].Uuid := 'service-1';
  BackendEvent.Services[0].Data := [$10, $20];
  SetLength(BackendEvent.Services[0].Characteristics, 2);
  BackendEvent.Services[0].Characteristics[0].Uuid := 'characteristic-1';
  BackendEvent.Services[0].Characteristics[0].CanRead := True;
  BackendEvent.Services[0].Characteristics[0].CanNotify := True;
  SetLength(BackendEvent.Services[0].Characteristics[0].Descriptors, 1);
  BackendEvent.Services[0].Characteristics[0].Descriptors[0] :=
    'descriptor-1';
  BackendEvent.Services[0].Characteristics[1].Uuid := 'indicate-1';
  BackendEvent.Services[0].Characteristics[1].CanIndicate := True;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
end;

procedure TDataObserver.DataReceived(Sender: TObject; const AValue: TBytes);
begin
  Inc(FCallCount);
  FValue := Copy(AValue);
end;

procedure TLazBleGattSessionTest.EmitEvent(
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

function TLazBleGattSessionTest.Subscribe: IBleSubscription;
var
  OperationId: TBleOperationId;
begin
  Result := FSession.SubscribeAsync('service-1', 'characteristic-1');
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekSubscribed, OperationId, 7, []);
  AssertTrue(FBackendObject.CompleteOperation(
    OperationId, lbekOperationSucceeded));
  AssertEquals(Ord(lbsubActive), Ord(Result.State));
end;

procedure TLazBleGattSessionTest.SetUp;
var
  ConnectId: TBleOperationId;
  DiscoveryId: TBleOperationId;
begin
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FManager := TBleCentralManager.Create(FBackend);
  FSession := FManager.CreateSession('device-1');
  ConnectId := LazBleTestConnect(FSession);
  EmitEvent(lbekConnected, ConnectId, InvalidBleSubscriptionId, []);
  AssertTrue(FBackendObject.CompleteOperation(ConnectId, lbekOperationSucceeded));
  DiscoveryId := FBackendObject.OperationIds[1];
  EmitServicesDiscovered(DiscoveryId);
  AssertTrue(FBackendObject.CompleteOperation(DiscoveryId, lbekOperationSucceeded));
end;

procedure TLazBleGattSessionTest.DiscoveryPublishesUpstreamGattRecords;
var
  Characteristic: TLazBleGattCharacteristic;
  Services: TLazBleGattServices;
begin
  Services := FSession.Services;

  AssertEquals(1, Length(Services));
  AssertEquals('service-1', UTF8Encode(Services[0].Uuid));
  AssertEquals(2, Length(Services[0].Data));
  AssertEquals(2, Length(Services[0].Characteristics));
  AssertTrue(Services[0].Characteristics[0].CanRead);
  AssertTrue(Services[0].Characteristics[0].CanNotify);
  AssertEquals('descriptor-1',
    UTF8Encode(Services[0].Characteristics[0].Descriptors[0]));
  AssertTrue(FSession.HasService('SERVICE-1'));
  AssertFalse(FSession.HasService('missing-service'));
  AssertTrue(FSession.TryGetCharacteristic('SERVICE-1',
    'CHARACTERISTIC-1', Characteristic));
  AssertTrue(Characteristic.CanNotify);
  AssertFalse(FSession.TryGetCharacteristic('service-1',
    'missing-characteristic', Characteristic));

  Services := Copy(Services);
  Services[0].Data := Copy(Services[0].Data);
  Services[0].Characteristics := Copy(Services[0].Characteristics);
  Services[0].Characteristics[0].Descriptors := Copy(Services[0].Characteristics[0].Descriptors);
  Services[0].Uuid := 'changed';
  Services[0].Data[0] := $FF;
  Services[0].Characteristics[0].Descriptors[0] := 'changed';
  Services := FSession.Services;

  AssertEquals('service-1', UTF8Encode(Services[0].Uuid));
  AssertEquals($10, Integer(Services[0].Data[0]));
  AssertEquals('descriptor-1',
    UTF8Encode(Services[0].Characteristics[0].Descriptors[0]));
end;

procedure TLazBleGattSessionTest.TearDown;
begin
  FManager.Free;
  FManager := nil;
  FSession := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleGattSessionTest.ReadPublishesManagedValue;
var
  Operation: IBleGattOperation;
  OperationId: TBleOperationId;
  Value: TBytes;
begin
  Operation := FSession.ReadAsync('service', 'read');
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekReadResult, OperationId,
    InvalidBleSubscriptionId, [$10, $20]);
  AssertTrue(FBackendObject.CompleteOperation(
    OperationId, lbekOperationSucceeded));

  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(2, Length(Operation.Value));
  AssertEquals($20, Integer(Operation.Value[1]));
  Value := Copy(Operation.Value);
  Value[1] := $FF;
  AssertEquals($20, Integer(Operation.Value[1]));
end;

procedure TLazBleGattSessionTest.CompletedOperationOutlivesSession;
var
  Operation: IBleGattOperation;
  OperationId: TBleOperationId;
begin
  Operation := FSession.ReadAsync('service', 'read');
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekReadResult, OperationId, InvalidBleSubscriptionId, [$42]);
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationSucceeded));

  FManager.Free;
  FManager := nil;
  FSession := nil;

  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals($42, Integer(Operation.Value[0]));
end;

procedure TLazBleGattSessionTest.InvalidatedSubscriptionOutlivesSession;
var
  Subscription: IBleSubscription;
begin
  Subscription := Subscribe;

  FManager.Free;
  FManager := nil;
  FSession := nil;

  AssertEquals(Ord(lbsubInactive), Ord(Subscription.State));
  AssertTrue(Assigned(Subscription.Unsubscribe));
end;

procedure TLazBleGattSessionTest.WritePreservesModeAndPayload;
var
  Operation: IBleGattOperation;
begin
  Operation := FSession.WriteAsync('service', 'write', [$01, $02],
    lbwmCommand);

  AssertEquals(Ord(lbckWrite), Ord(FBackendObject.Commands[2].Kind));
  AssertEquals(Ord(lbwmCommand),
    Ord(FBackendObject.Commands[2].WriteMode));
  AssertEquals(2, Length(FBackendObject.Commands[2].Value));
  AssertTrue(FBackendObject.CompleteOperation(
    FBackendObject.OperationIds[FBackendObject.CommandCount - 1],
    lbekOperationFailed));
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
end;

procedure TLazBleGattSessionTest.SubscribeDeliversNotifications;
var
  Observer: TDataObserver;
  Subscription: IBleSubscription;
begin
  Observer := TDataObserver.Create;
  try
    Subscription := Subscribe;
    Subscription.OnData := @Observer.DataReceived;

    EmitEvent(lbekNotification, InvalidBleOperationId,
      7, [$31, $32]);

    AssertEquals(1, Observer.CallCount);
    AssertEquals(2, Length(Observer.Value));
    AssertEquals($32, Integer(Observer.Value[1]));
  finally
    Observer.Free;
  end;
end;

procedure TLazBleGattSessionTest.UnsubscribeIsIdempotent;
var
  FirstOperation: IBleGattOperation;
  SecondOperation: IBleGattOperation;
  Subscription: IBleSubscription;
begin
  Subscription := Subscribe;

  FirstOperation := Subscription.Unsubscribe;
  SecondOperation := Subscription.Unsubscribe;

  AssertTrue(FirstOperation = SecondOperation);
  AssertEquals(Ord(lbsubUnsubscribing), Ord(Subscription.State));
  AssertTrue(FBackendObject.CompleteOperation(
    FBackendObject.OperationIds[FBackendObject.CommandCount - 1],
    lbekOperationSucceeded));
  AssertEquals(Ord(lbsubInactive), Ord(Subscription.State));
end;

procedure TLazBleGattSessionTest.SubscribeFailureMarksTokenFailed;
var
  Subscription: IBleSubscription;
begin
  Subscription := FSession.SubscribeAsync('service-1', 'characteristic-1');

  AssertTrue(FBackendObject.CompleteOperation(
    FBackendObject.OperationIds[FBackendObject.CommandCount - 1],
    lbekOperationFailed, 23, 'Subscription rejected'));

  AssertEquals(Ord(lbsubFailed), Ord(Subscription.State));
  AssertEquals(23, Subscription.ErrorCode);
  AssertEquals('Subscription rejected', Subscription.ErrorMessage);
end;

procedure TLazBleGattSessionTest.DisconnectInvalidatesSubscriptionAndIgnoresOldNotification;
var
  DisconnectId: TBleOperationId;
  Observer: TDataObserver;
  Subscription: IBleSubscription;
begin
  Observer := TDataObserver.Create;
  try
    Subscription := Subscribe;
    Subscription.OnData := @Observer.DataReceived;
    DisconnectId := LazBleTestDisconnect(FSession);
    EmitEvent(lbekDisconnected, DisconnectId,
      InvalidBleSubscriptionId, []);

    AssertEquals(Ord(lbsubInactive), Ord(Subscription.State));
    AssertEquals(0, Length(FSession.Services));
    EmitEvent(lbekNotification, InvalidBleOperationId,
      7, [$44]);
    AssertEquals(0, Observer.CallCount);
  finally
    Observer.Free;
  end;
end;

procedure TLazBleGattSessionTest.DescriptorReadPublishesValueAndAddress;
var Op: IBleGattOperation; Id: TBleOperationId; C: TLazBleBackendCommand;
begin
  Op := FSession.ReadDescriptorAsync('SERVICE-1', 'CHARACTERISTIC-1', 'DESCRIPTOR-1');
  C := FBackendObject.Commands[2]; Id := FBackendObject.OperationIds[2];
  AssertEquals(Ord(lbckReadDescriptor), Ord(C.Kind));
  AssertEquals('DESCRIPTOR-1', C.DescriptorUuid);
  AssertEquals(FSession.Generation, C.Generation);
  EmitEvent(lbekReadResult, Id, 0, [0, 255]);
  AssertTrue(FBackendObject.CompleteOperation(Id, lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
  AssertEquals(2, Length(Op.Value)); AssertEquals(255, Op.Value[1]);
end;

procedure TLazBleGattSessionTest.DescriptorWriteOwnsSubmittedBytes;
var Op: IBleGattOperation; Value: TBytes;
begin
  Value := TBytes.Create(12, 34);
  Op := FSession.WriteDescriptorAsync('service-1', 'characteristic-1', 'descriptor-1', Value);
  Value[0] := 99;
  AssertEquals(Ord(lbckWriteDescriptor), Ord(FBackendObject.Commands[2].Kind));
  AssertEquals('descriptor-1', FBackendObject.Commands[2].DescriptorUuid);
  AssertEquals(12, FBackendObject.Commands[2].Value[0]);
  AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[2], lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
end;

procedure TLazBleGattSessionTest.DescriptorMissingTargetFailsLocally;
var Op: IBleGattOperation;
begin
  Op := FSession.ReadDescriptorAsync('missing', 'characteristic-1', 'descriptor-1');
  AssertEquals(Ord(lbopFailed), Ord(Op.State));
  AssertEquals(LazBleErrorGattNotFound, Op.ErrorCode);
  Op := FSession.ReadDescriptorAsync('service-1', 'missing', 'descriptor-1');
  AssertEquals(LazBleErrorGattNotFound, Op.ErrorCode);
  Op := FSession.WriteDescriptorAsync('service-1', 'characteristic-1', 'missing', [1]);
  AssertEquals(LazBleErrorGattNotFound, Op.ErrorCode);
  AssertEquals('Invalid targets never reach the backend', 2, FBackendObject.CommandCount);
end;

procedure TLazBleGattSessionTest.DescriptorRequiresConnectedSession;
var Op: IBleGattOperation;
begin
  LazBleTestDisconnect(FSession);
  Op := FSession.ReadDescriptorAsync('service-1', 'characteristic-1', 'descriptor-1');
  AssertEquals(Ord(lbopFailed), Ord(Op.State));
  AssertEquals(LazBleErrorInvalidState, Op.ErrorCode);
  AssertEquals(3, FBackendObject.CommandCount);
end;

procedure TLazBleGattSessionTest.DescriptorCancelPreservesActualFailure;
var Op: IBleGattOperation; Id: TBleOperationId;
begin
  Op := FSession.ReadDescriptorAsync('service-1', 'characteristic-1', 'descriptor-1');
  Id := FBackendObject.OperationIds[2]; Op.Cancel;
  AssertTrue(Op.CancelRequested);
  AssertTrue(FBackendObject.CancellationWasRequested(Id));
  AssertEquals(Ord(lbopPending), Ord(Op.State));
  AssertTrue(FBackendObject.CompleteOperation(Id, lbekOperationFailed, 0, ''));
  AssertEquals(Ord(lbopFailed), Ord(Op.State));
  AssertEquals(0, Op.ErrorCode); AssertEquals('', Op.ErrorMessage);
end;

procedure TLazBleGattSessionTest.DescriptorRejectsOldGenerationResult;
var Op: IBleGattOperation; E: TLazBleBackendEvent; Id: TBleOperationId;
begin
  Op := FSession.ReadDescriptorAsync('service-1', 'characteristic-1', 'descriptor-1');
  Id := FBackendObject.OperationIds[2];
  E := Default(TLazBleBackendEvent); E.Kind := lbekReadResult;
  E.OperationId := Id; E.DeviceId := FSession.DeviceId;
  E.Generation := FSession.Generation + 1; E.Value := TBytes.Create(99);
  AssertTrue(FBackendObject.EmitProgress(E));
  AssertEquals(0, Length(Op.Value));
  EmitEvent(lbekReadResult, Id, 0, [42]);
  AssertTrue(FBackendObject.CompleteOperation(Id, lbekOperationSucceeded));
  AssertEquals(42, Op.Value[0]);
end;

procedure TLazBleGattSessionTest.IndicateUsesExistingSubscriptionLifecycle;
var S: IBleSubscription; Observer: TDataObserver;
  Id: TBleOperationId; Op: IBleGattOperation;
begin
  Observer := TDataObserver.Create;
  try
    S := FSession.SubscribeAsync('service-1', 'indicate-1', lbsmIndicate);
    S.OnData := @Observer.DataReceived; Id := FBackendObject.OperationIds[2];
    AssertEquals(Ord(lbsmIndicate), Ord(FBackendObject.Commands[2].SubscriptionMode));
    EmitEvent(lbekNotification, 0, 17, [1]);
    AssertEquals('No values before readiness', 0, Observer.CallCount);
    EmitEvent(lbekSubscribed, Id, 17, []);
    AssertTrue(FBackendObject.CompleteOperation(Id, lbekOperationSucceeded));
    EmitEvent(lbekNotification, 0, 17, [2]);
    AssertEquals(1, Observer.CallCount);
    Op := S.Unsubscribe;
    EmitEvent(lbekNotification, 0, 17, [3]);
    AssertEquals(1, Observer.CallCount);
    AssertTrue(FBackendObject.CompleteOperation(FBackendObject.OperationIds[3], lbekOperationSucceeded));
    AssertEquals(Ord(lbopSucceeded), Ord(Op.State));
    AssertEquals(Ord(lbsubInactive), Ord(S.State));
  finally Observer.Free; end;
end;

procedure TLazBleGattSessionTest.UnsupportedSubscriptionModeFailsLocally;
var S: IBleSubscription;
begin
  S := FSession.SubscribeAsync('service-1', 'characteristic-1', lbsmIndicate);
  AssertEquals(Ord(lbsubFailed), Ord(S.State));
  AssertEquals(LazBleErrorGattPropertyNotSupported, S.ErrorCode);
  AssertEquals(2, FBackendObject.CommandCount);
  S := FSession.SubscribeAsync('service-1', 'indicate-1');
  AssertEquals(Ord(lbsubFailed), Ord(S.State));
  AssertEquals(LazBleErrorGattPropertyNotSupported, S.ErrorCode);
  AssertEquals(2, FBackendObject.CommandCount);
  S := FSession.SubscribeAsync('service-1', 'missing');
  AssertEquals(Ord(lbsubFailed), Ord(S.State));
  AssertEquals(LazBleErrorGattNotFound, S.ErrorCode);
  AssertEquals(2, FBackendObject.CommandCount);
end;

initialization
  RegisterTest(TLazBleGattSessionTest);

end.
