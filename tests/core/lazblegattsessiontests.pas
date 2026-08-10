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
    procedure ReadCompletesWithCopiedValue;
    procedure WritePreservesModeAndPayload;
    procedure SubscribeDeliversNotifications;
    procedure SubscribeFailureMarksTokenFailed;
    procedure UnsubscribeIsIdempotent;
    procedure DisconnectInvalidatesSubscriptionAndIgnoresOldNotification;
    procedure DiscoveryPublishesAnIndependentGattSnapshot;
    procedure CompletedOperationOutlivesSession;
    procedure InvalidatedSubscriptionOutlivesSession;
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
  SetLength(BackendEvent.Services[0].Characteristics, 1);
  BackendEvent.Services[0].Characteristics[0].Uuid := 'characteristic-1';
  BackendEvent.Services[0].Characteristics[0].Properties := [
    lbgcpRead,
    lbgcpNotify
  ];
  SetLength(BackendEvent.Services[0].Characteristics[0].Descriptors, 1);
  BackendEvent.Services[0].Characteristics[0].Descriptors[0].Uuid :=
    'descriptor-1';
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
  Result := FSession.SubscribeAsync('service', 'notify');
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
  DiscoveryId := FBackendObject.OperationIds[1];
  EmitServicesDiscovered(DiscoveryId);
end;

procedure TLazBleGattSessionTest.DiscoveryPublishesAnIndependentGattSnapshot;
var
  Services: TLazBleGattServices;
begin
  Services := FSession.Services;

  AssertEquals(1, Length(Services));
  AssertEquals('service-1', Services[0].Uuid);
  AssertEquals(2, Length(Services[0].Data));
  AssertEquals(1, Length(Services[0].Characteristics));
  AssertTrue(lbgcpRead in Services[0].Characteristics[0].Properties);
  AssertTrue(lbgcpNotify in Services[0].Characteristics[0].Properties);
  AssertEquals('descriptor-1',
    Services[0].Characteristics[0].Descriptors[0].Uuid);

  Services[0].Uuid := 'changed';
  Services[0].Data[0] := $FF;
  Services[0].Characteristics[0].Descriptors[0].Uuid := 'changed';
  Services := FSession.Services;

  AssertEquals('service-1', Services[0].Uuid);
  AssertEquals($10, Integer(Services[0].Data[0]));
  AssertEquals('descriptor-1',
    Services[0].Characteristics[0].Descriptors[0].Uuid);
end;

procedure TLazBleGattSessionTest.TearDown;
begin
  FManager.Free;
  FManager := nil;
  FSession := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleGattSessionTest.ReadCompletesWithCopiedValue;
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
  Value := Operation.Value;
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
  Subscription := FSession.SubscribeAsync('service', 'notify');

  AssertTrue(FBackendObject.CompleteOperation(
    FBackendObject.OperationIds[FBackendObject.CommandCount - 1],
    lbekOperationFailed));

  AssertEquals(Ord(lbsubFailed), Ord(Subscription.State));
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

initialization
  RegisterTest(TLazBleGattSessionTest);

end.
