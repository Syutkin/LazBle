unit LazBleNusTests;

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
  LazBleCentralManager,
  LazBleByteChannel,
  LazBleNus,
  FakeLazBleBackend,
  TestLazBleAccess;

type
  TTestNusProfile = class(TNusProfile)
  public
    procedure BindToSession(const ASession: TBleGattSession);
    procedure AttachProfile;
    function TestChannel: TBleByteChannel;
  end;

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
    FProfile: TTestNusProfile;
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId;
      const ASubscriptionId: TBleSubscriptionId;
      const AValue: array of Byte);
    procedure EmitServicesDiscovered(const AOperationId: TBleOperationId;
      const AIncludeNus: Boolean);
    procedure ActivateProfile;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure AttachSubscribesToNusTx;
    procedure SendWritesToNusRxWithoutResponse;
    procedure DataIncludesDeviceIdentityAndOpaqueBytes;
    procedure DisconnectInvalidatesProfileReadiness;
    procedure MissingServiceFailsWithoutSubscription;
    procedure SubscriptionFailurePreservesBackendDiagnostic;
    procedure SendBeforeBindingReturnsFailedOperation;
  end;

implementation

procedure TTestNusProfile.BindToSession(const ASession: TBleGattSession);
begin
  BindSession(ASession);
end;

procedure TLazBleNusTest.EmitServicesDiscovered(
  const AOperationId: TBleOperationId; const AIncludeNus: Boolean);
var
  BackendEvent: TLazBleBackendEvent;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekServicesDiscovered;
  BackendEvent.OperationId := AOperationId;
  BackendEvent.DeviceId := FSession.DeviceId;
  BackendEvent.Generation := FSession.Generation;
  if AIncludeNus then
  begin
    SetLength(BackendEvent.Services, 1);
    BackendEvent.Services[0].Uuid := NusServiceUuid;
    SetLength(BackendEvent.Services[0].Characteristics, 2);
    BackendEvent.Services[0].Characteristics[0].Uuid :=
      NusRxCharacteristicUuid;
    BackendEvent.Services[0].Characteristics[0].Properties :=
      [lbgcpWriteCommand];
    BackendEvent.Services[0].Characteristics[1].Uuid :=
      NusTxCharacteristicUuid;
    BackendEvent.Services[0].Characteristics[1].Properties := [lbgcpNotify];
  end;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
end;

procedure TTestNusProfile.AttachProfile;
begin
  Attach;
end;

function TTestNusProfile.TestChannel: TBleByteChannel;
begin
  Result := Channel;
end;

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
  OperationId: TBleOperationId;
  Subscription: IBleSubscription;
begin
  FProfile.AttachProfile;
  Subscription := FProfile.TestChannel.Subscription;
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekSubscribed, OperationId, 31, []);
  AssertTrue(FBackendObject.CompleteOperation(
    OperationId, lbekOperationSucceeded));
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
  ConnectId := LazBleTestConnect(FSession);
  EmitEvent(lbekConnected, ConnectId, InvalidBleSubscriptionId, []);
  EmitServicesDiscovered(FBackendObject.OperationIds[1], True);
  FProfile := TTestNusProfile.Create;
  FProfile.BindToSession(FSession);
end;

procedure TLazBleNusTest.MissingServiceFailsWithoutSubscription;
var
  CommandCount: Integer;
  ConnectId: TBleOperationId;
  DisconnectId: TBleOperationId;
begin
  DisconnectId := LazBleTestDisconnect(FSession);
  EmitEvent(lbekDisconnected, DisconnectId, InvalidBleSubscriptionId, []);
  ConnectId := LazBleTestConnect(FSession);
  EmitEvent(lbekConnected, ConnectId, InvalidBleSubscriptionId, []);
  EmitServicesDiscovered(FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1], False);
  CommandCount := FBackendObject.CommandCount;

  FProfile.AttachProfile;

  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(LazBleErrorGattNotFound, FProfile.ErrorCode);
  AssertTrue(Pos('NUS service', FProfile.ErrorMessage) > 0);
  AssertEquals(CommandCount, FBackendObject.CommandCount);
end;

procedure TLazBleNusTest.SubscriptionFailurePreservesBackendDiagnostic;
var
  OperationId: TBleOperationId;
begin
  FProfile.AttachProfile;
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];

  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationFailed, 17, 'Notifications are not supported'));

  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
  AssertEquals(17, FProfile.ErrorCode);
  AssertEquals('Notifications are not supported', FProfile.ErrorMessage);
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
  FProfile.AttachProfile;

  AssertTrue(Assigned(FProfile.TestChannel.Subscription));

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
      31, [$00, $FF, $23]);

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

  DisconnectId := LazBleTestDisconnect(FSession);
  EmitEvent(lbekDisconnected, DisconnectId, InvalidBleSubscriptionId, []);

  AssertFalse(FProfile.Ready);
  AssertEquals(Ord(lbgpsError), Ord(FProfile.State));
end;

procedure TLazBleNusTest.SendBeforeBindingReturnsFailedOperation;
var
  Operation: IBleGattOperation;
  Profile: TNusProfile;
begin
  Profile := TNusProfile.Create;
  try
    Operation := Profile.SendAsync([$01]);

    AssertTrue(Assigned(Operation));
    AssertEquals(Ord(lbopFailed), Ord(Operation.State));
    AssertEquals(LazBleErrorInvalidState, Operation.ErrorCode);
    AssertEquals('NUS profile is not bound to a client',
      Operation.ErrorMessage);
  finally
    Profile.Free;
  end;
end;

initialization
  RegisterTest(TLazBleNusTest);

end.
