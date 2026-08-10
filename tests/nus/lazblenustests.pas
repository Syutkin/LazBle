unit LazBleNusTests;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  LazBleGattSubscription,
  LazBleGattSession,
  LazBleGattProfile,
  LazBleCentralManager,
  LazBleNus,
  FakeLazBleBackend;

type
  TNusObserver = class
  private
    FCallCount: Integer;
    FDeviceId: string;
    FValue: TBytes;
  public
    procedure DataReceived(Sender: TObject; const ADeviceId: string;
      const AValue: TBytes);
    property CallCount: Integer read FCallCount;
    property DeviceId: string read FDeviceId;
    property Value: TBytes read FValue;
  end;

  TLazBleNusTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FManager: TBleCentralManager;
    FSession: TBleGattSession;
    FProfile: TNusProfile;
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId;
      const ASubscriptionId: TBleSubscriptionId;
      const AValue: array of Byte);
    procedure ActivateProfile;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AttachSubscribesToNusTx;
    procedure SendWritesToNusRxWithoutResponse;
    procedure DataIncludesDeviceIdentityAndOpaqueBytes;
    procedure DisconnectInvalidatesProfileReadiness;
  end;

implementation

procedure TNusObserver.DataReceived(Sender: TObject; const ADeviceId: string;
  const AValue: TBytes);
begin
  Inc(FCallCount);
  FDeviceId := ADeviceId;
  FValue := Copy(AValue);
end;

procedure TLazBleNusTest.EmitEvent(const AKind: TLazBleBackendEventKind;
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

procedure TLazBleNusTest.ActivateProfile;
var
  Subscription: TBleSubscription;
begin
  FProfile.Attach;
  Subscription := FProfile.Channel.Subscription;
  EmitEvent(lbekSubscribed, Subscription.OperationId, 31, []);
  AssertTrue(FBackendObject.CompleteOperation(
    Subscription.OperationId, lbekOperationSucceeded));
  AssertTrue(FProfile.Ready);
end;

procedure TLazBleNusTest.SetUp;
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
  FProfile := TNusProfile.Create(FSession);
end;

procedure TLazBleNusTest.TearDown;
begin
  FProfile.Free;
  FProfile := nil;
  FManager.Free;
  FManager := nil;
  FSession := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleNusTest.AttachSubscribesToNusTx;
begin
  FProfile.Attach;

  AssertTrue(Assigned(FProfile.Channel.Subscription));

  AssertEquals(Ord(lbckSubscribe), Ord(FBackendObject.Commands[2].Kind));
  AssertEquals(NusServiceUuid, FBackendObject.Commands[2].ServiceUuid);
  AssertEquals(NusTxCharacteristicUuid,
    FBackendObject.Commands[2].CharacteristicUuid);
end;

procedure TLazBleNusTest.SendWritesToNusRxWithoutResponse;
var
  Command: TLazBleBackendCommand;
begin
  ActivateProfile;

  AssertTrue(Assigned(FProfile.SendAsync([$41, $42])));
  Command := FBackendObject.Commands[FBackendObject.CommandCount - 1];

  AssertEquals(Ord(lbckWrite), Ord(Command.Kind));
  AssertEquals(NusServiceUuid, Command.ServiceUuid);
  AssertEquals(NusRxCharacteristicUuid, Command.CharacteristicUuid);
  AssertEquals(Ord(lbwmCommand), Ord(Command.WriteMode));
  AssertEquals(2, Length(Command.Value));
end;

procedure TLazBleNusTest.DataIncludesDeviceIdentityAndOpaqueBytes;
var
  Observer: TNusObserver;
begin
  Observer := TNusObserver.Create;
  try
    FProfile.OnData := @Observer.DataReceived;
    ActivateProfile;

    EmitEvent(lbekNotification, InvalidBleOperationId,
      FProfile.Channel.Subscription.SubscriptionId, [$00, $FF, $23]);

    AssertEquals(1, Observer.CallCount);
    AssertEquals('entime-1', Observer.DeviceId);
    AssertEquals(3, Length(Observer.Value));
    AssertEquals($FF, Integer(Observer.Value[1]));
  finally
    Observer.Free;
  end;
end;

procedure TLazBleNusTest.DisconnectInvalidatesProfileReadiness;
var
  DisconnectId: TBleOperationId;
begin
  ActivateProfile;

  DisconnectId := FSession.Disconnect;
  EmitEvent(lbekDisconnected, DisconnectId, InvalidBleSubscriptionId, []);

  AssertFalse(FProfile.Ready);
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
end;

initialization
  RegisterTest(TLazBleNusTest);

end.
