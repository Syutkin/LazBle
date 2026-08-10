unit LazBleClientTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  LazBleGattProfile,
  LazBleClient,
  LazBleFacade,
  LazBleSync,
  LazBleNus,
  FakeLazBleBackend;

type
  TManualGattProfile = class(TBleGattProfile)
  private
    FAttachCount: Integer;
    FDetachCount: Integer;
  protected
    procedure DoAttach; override;
    procedure DoDetach; override;
  public
    procedure CompleteAttach;
    procedure FailAttach(const AMessage: string);
    property AttachCount: Integer read FAttachCount;
    property DetachCount: Integer read FDetachCount;
  end;

  TClientOperationObserver = class
  private
    FCompletionCount: Integer;
  public
    procedure Completed(Sender: TObject);
    property CompletionCount: Integer read FCompletionCount;
  end;

  TScanCompletionThread = class(TThread)
  private
    FBackend: TFakeLazBleBackend;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABackend: TFakeLazBleBackend);
  end;

  TLazBleClientTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FBle: TLazBle;
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId; const ADeviceId: string = '';
      const ADeviceName: string = ''; const ARssi: SmallInt = 0;
      const AGeneration: QWord = 0);
    procedure CompleteTransportClient(const AClient: TBleClient);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ScanDeduplicatesWithoutChangingDiscoveryOrder;
    procedure CancellingScanCancelsBackendOperation;
    procedure TimedOutScanKeepsTimedOutStateAfterTerminalEvent;
    procedure ConnectCompletesAfterServiceDiscovery;
    procedure ShutdownCompletesAfterBackendShutdown;
    procedure SyncScanWaitsForTerminalEvent;
    procedure DefaultFacadeDoesNotLoadNativeLibraryWhenCreated;
    procedure DefaultSyncFacadeDoesNotLoadNativeLibraryWhenCreated;
    procedure ClientWaitsForRequiredProfiles;
    procedure ClientWaitsForRealNusSubscription;
    procedure OptionalProfileFailureDoesNotFailClient;
    procedure RequiredProfileFailureFailsClient;
    procedure RequiredProfileFailureAfterReadyInvalidatesClient;
    procedure ReconnectAttachesRegisteredProfilesAgain;
    procedure CreateClientRejectsDuplicateDevice;
    procedure FindClientReturnsRegisteredClient;
    procedure RemoveClientReleasesDeviceRegistration;
    procedure RemoveClientRejectsActiveClient;
    procedure ProfileCannotBeAddedToTwoClients;
    procedure ProfileCannotBeAddedAfterConnectStarts;
    procedure ClientExposesGattOperations;
  end;

implementation

procedure TManualGattProfile.DoAttach;
begin
  Inc(FAttachCount);
end;

procedure TManualGattProfile.DoDetach;
begin
  Inc(FDetachCount);
end;

procedure TManualGattProfile.CompleteAttach;
begin
  MarkReady;
end;

procedure TManualGattProfile.FailAttach(const AMessage: string);
begin
  MarkError(AMessage);
end;

procedure TClientOperationObserver.Completed(Sender: TObject);
begin
  Inc(FCompletionCount);
end;

constructor TScanCompletionThread.Create(const ABackend: TFakeLazBleBackend);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBackend := ABackend;
end;

procedure TScanCompletionThread.Execute;
begin
  while (FBackend.CommandCount = 0) and not Terminated do
    Sleep(1);
  if not Terminated then
    FBackend.CompleteOperation(FBackend.OperationIds[0],
      lbekOperationSucceeded);
end;

procedure TLazBleClientTest.EmitEvent(const AKind: TLazBleBackendEventKind;
  const AOperationId: TBleOperationId; const ADeviceId: string;
  const ADeviceName: string; const ARssi: SmallInt;
  const AGeneration: QWord);
var
  BackendEvent: TLazBleBackendEvent;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := AKind;
  BackendEvent.OperationId := AOperationId;
  BackendEvent.DeviceId := ADeviceId;
  BackendEvent.DeviceName := ADeviceName;
  BackendEvent.Rssi := ARssi;
  BackendEvent.Generation := AGeneration;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
end;

procedure TLazBleClientTest.CompleteTransportClient(
  const AClient: TBleClient);
var
  OperationId: TBleOperationId;
begin
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekConnected, OperationId, AClient.DeviceId, '', 0,
    AClient.Generation);
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekServicesDiscovered, OperationId, AClient.DeviceId,
    '', 0, AClient.Generation);
end;

procedure TLazBleClientTest.SetUp;
begin
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FBle := TLazBle.Create(FBackend);
end;

procedure TLazBleClientTest.TearDown;
begin
  FBle.Free;
  FBle := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleClientTest.ScanDeduplicatesWithoutChangingDiscoveryOrder;
var
  Devices: TBleDeviceInfos;
  Operation: TBleScanOperation;
  OperationId: TBleOperationId;
begin
  Operation := FBle.ScanAsync('hci0', 5000);
  OperationId := FBackendObject.OperationIds[0];

  EmitEvent(lbekScanResult, OperationId, 'device-a', 'First', -80);
  EmitEvent(lbekScanResult, OperationId, 'device-b', 'Second', -40);
  EmitEvent(lbekScanResult, OperationId, 'device-a', 'First updated', -20);
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationSucceeded));

  Devices := Operation.Results;
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(2, Length(Devices));
  AssertEquals('device-a', Devices[0].DeviceId);
  AssertEquals('First updated', Devices[0].DeviceName);
  AssertEquals(-20, Integer(Devices[0].Rssi));
  AssertEquals('device-b', Devices[1].DeviceId);
  AssertEquals(-40, Integer(Devices[1].Rssi));
end;

procedure TLazBleClientTest.CancellingScanCancelsBackendOperation;
var
  Operation: TBleScanOperation;
  OperationId: TBleOperationId;
begin
  Operation := FBle.ScanAsync('', 5000);
  OperationId := FBackendObject.OperationIds[0];

  Operation.Cancel;

  AssertTrue(FBackendObject.CancellationWasRequested(OperationId));
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationCancelled));
  AssertEquals(Ord(lbopCancelled), Ord(Operation.State));
end;

procedure TLazBleClientTest.TimedOutScanKeepsTimedOutStateAfterTerminalEvent;
var
  Observer: TClientOperationObserver;
  Operation: TBleScanOperation;
  OperationId: TBleOperationId;
begin
  Observer := TClientOperationObserver.Create;
  Operation := FBle.ScanAsync('', 5000);
  Operation.OnCompleted := @Observer.Completed;
  OperationId := FBackendObject.OperationIds[0];
  try
    Operation.Timeout;

    AssertEquals(Ord(lbopTimedOut), Ord(Operation.State));
    AssertTrue(FBackendObject.CancellationWasRequested(OperationId));
    AssertTrue(FBackendObject.CompleteOperation(OperationId,
      lbekOperationCancelled));
    AssertEquals(Ord(lbopTimedOut), Ord(Operation.State));
    AssertEquals(1, Observer.CompletionCount);
  finally
    Operation.OnCompleted := nil;
    Observer.Free;
  end;
end;

procedure TLazBleClientTest.ConnectCompletesAfterServiceDiscovery;
var
  Client: TBleClient;
  Operation: TBleOperation;
begin
  Client := FBle.CreateClient('device-a');
  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);

  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertTrue(Client.Generation > 0);
end;

procedure TLazBleClientTest.ShutdownCompletesAfterBackendShutdown;
var
  Operation: TBleOperation;
begin
  Operation := FBle.ShutdownAsync;

  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertTrue(FBackendObject.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.SyncScanWaitsForTerminalEvent;
var
  BleSync: TLazBleSync;
  CompletionThread: TScanCompletionThread;
  Devices: TBleDeviceInfos;
  ErrorMessage: string;
begin
  BleSync := TLazBleSync.Create(FBackend);
  CompletionThread := TScanCompletionThread.Create(FBackendObject);
  try
    CompletionThread.Start;
    AssertTrue(BleSync.Scan('', 1000, Devices, ErrorMessage));
    CompletionThread.WaitFor;
    AssertEquals('', ErrorMessage);
  finally
    CompletionThread.Terminate;
    CompletionThread.WaitFor;
    CompletionThread.Free;
    BleSync.Free;
  end;
end;

procedure TLazBleClientTest.ClientWaitsForRequiredProfiles;
var
  Client: TBleClient;
  Operation: TBleOperation;
  Profile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile, True);
  AssertTrue(Profile.Bound);

  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);

  AssertEquals(Ord(lbcstAttachingProfiles), Ord(Client.State));
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  Profile.CompleteAttach;
  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.ClientWaitsForRealNusSubscription;
var
  BackendEvent: TLazBleBackendEvent;
  Client: TBleClient;
  Operation: TBleOperation;
  Profile: TNusProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TNusProfile.Create;
  Client.AddProfile(Profile, True);

  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);
  AssertEquals(Ord(lbopPending), Ord(Operation.State));

  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekSubscribed;
  BackendEvent.OperationId := Profile.Channel.Subscription.OperationId;
  BackendEvent.SubscriptionId := 51;
  BackendEvent.DeviceId := Client.DeviceId;
  BackendEvent.Generation := Client.Generation;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));

  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.OptionalProfileFailureDoesNotFailClient;
var
  Client: TBleClient;
  Operation: TBleOperation;
  OptionalProfile: TManualGattProfile;
  RequiredProfile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  RequiredProfile := TManualGattProfile.Create;
  OptionalProfile := TManualGattProfile.Create;
  Client.AddProfile(RequiredProfile, True);
  Client.AddProfile(OptionalProfile, False);

  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);
  OptionalProfile.FailAttach('optional failure');
  RequiredProfile.CompleteAttach;

  AssertEquals(Ord(lbgpsError), Ord(OptionalProfile.State));
  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.RequiredProfileFailureFailsClient;
var
  Client: TBleClient;
  Operation: TBleOperation;
  Profile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile, True);

  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);
  Profile.FailAttach('required failure');

  AssertEquals(Ord(lbcstError), Ord(Client.State));
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertTrue(Pos('required failure', Operation.ErrorMessage) > 0);
end;

procedure TLazBleClientTest.RequiredProfileFailureAfterReadyInvalidatesClient;
var
  Client: TBleClient;
  Profile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile, True);
  Client.ConnectAsync;
  CompleteTransportClient(Client);
  Profile.CompleteAttach;
  AssertEquals(Ord(lbcstReady), Ord(Client.State));

  Profile.FailAttach('subscription lost');

  AssertEquals(Ord(lbcstError), Ord(Client.State));
end;

procedure TLazBleClientTest.ReconnectAttachesRegisteredProfilesAgain;
var
  Client: TBleClient;
  DisconnectId: TBleOperationId;
  Operation: TBleOperation;
  Profile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile, True);

  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);
  Profile.CompleteAttach;
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));

  Client.DisconnectAsync;
  DisconnectId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, DisconnectId, Client.DeviceId, '', 0,
    Client.Generation);
  AssertEquals(Ord(lbcstDisconnected), Ord(Client.State));

  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);
  AssertEquals(2, Profile.AttachCount);
  AssertTrue(Profile.AttachedGeneration = Client.Generation);
  Profile.CompleteAttach;

  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.CreateClientRejectsDuplicateDevice;
var
  RaisedExpectedException: Boolean;
begin
  FBle.CreateClient('device-a');
  RaisedExpectedException := False;
  try
    FBle.CreateClient('device-a');
  except
    on ELazBleDuplicateClient do
      RaisedExpectedException := True;
  end;
  AssertTrue(RaisedExpectedException);
end;

procedure TLazBleClientTest.FindClientReturnsRegisteredClient;
var
  Client: TBleClient;
begin
  Client := FBle.CreateClient('device-a');

  AssertTrue(Client = FBle.FindClient('DEVICE-A'));
  AssertNull(FBle.FindClient('device-b'));
end;

procedure TLazBleClientTest.RemoveClientReleasesDeviceRegistration;
var
  Client: TBleClient;
begin
  Client := FBle.CreateClient('device-a');

  FBle.RemoveClient(Client);

  AssertNull(FBle.FindClient('device-a'));
  AssertNotNull(FBle.CreateClient('device-a'));
end;

procedure TLazBleClientTest.RemoveClientRejectsActiveClient;
var
  Client: TBleClient;
  RaisedExpectedException: Boolean;
begin
  Client := FBle.CreateClient('device-a');
  Client.ConnectAsync;

  RaisedExpectedException := False;
  try
    FBle.RemoveClient(Client);
  except
    on EInvalidOperation do
      RaisedExpectedException := True;
  end;

  AssertTrue(RaisedExpectedException);
  AssertTrue(Client = FBle.FindClient('device-a'));
end;

procedure TLazBleClientTest.ProfileCannotBeAddedToTwoClients;
var
  FirstClient: TBleClient;
  Profile: TManualGattProfile;
  RaisedExpectedException: Boolean;
  SecondClient: TBleClient;
begin
  FirstClient := FBle.CreateClient('device-a');
  SecondClient := FBle.CreateClient('device-b');
  Profile := TManualGattProfile.Create;
  FirstClient.AddProfile(Profile);

  RaisedExpectedException := False;
  try
    SecondClient.AddProfile(Profile);
  except
    on EInvalidOperation do
      RaisedExpectedException := True;
  end;

  AssertTrue(RaisedExpectedException);
  AssertEquals(1, FirstClient.ProfileCount);
  AssertEquals(0, SecondClient.ProfileCount);
end;

procedure TLazBleClientTest.ProfileCannotBeAddedAfterConnectStarts;
var
  Client: TBleClient;
  Profile: TManualGattProfile;
  RaisedExpectedException: Boolean;
begin
  Client := FBle.CreateClient('device-a');
  Client.ConnectAsync;
  Profile := TManualGattProfile.Create;
  try
    RaisedExpectedException := False;
    try
      Client.AddProfile(Profile);
    except
      on EInvalidOperation do
        RaisedExpectedException := True;
    end;

    AssertTrue(RaisedExpectedException);
    AssertFalse(Profile.Bound);
    AssertEquals(0, Client.ProfileCount);
  finally
    Profile.Free;
  end;
end;

procedure TLazBleClientTest.ClientExposesGattOperations;
var
  Client: TBleClient;
begin
  Client := FBle.CreateClient('device-a');
  Client.ConnectAsync;
  CompleteTransportClient(Client);

  AssertNotNull(Client.ReadAsync('service-read', 'characteristic-read'));
  AssertNotNull(Client.WriteAsync('service-write', 'characteristic-write',
    [$01, $02], lbwmRequest));
  AssertNotNull(Client.SubscribeAsync('service-notify',
    'characteristic-notify'));

  AssertEquals(Ord(lbckRead), Ord(FBackendObject.Commands[2].Kind));
  AssertEquals(Ord(lbckWrite), Ord(FBackendObject.Commands[3].Kind));
  AssertEquals(Ord(lbckSubscribe), Ord(FBackendObject.Commands[4].Kind));
end;

procedure TLazBleClientTest.DefaultFacadeDoesNotLoadNativeLibraryWhenCreated;
var
  Client: TLazBle;
begin
  Client := TLazBle.Create;
  Client.Free;
end;

procedure TLazBleClientTest.DefaultSyncFacadeDoesNotLoadNativeLibraryWhenCreated;
var
  Client: TLazBleSync;
begin
  Client := TLazBleSync.Create;
  Client.Free;
end;

initialization
  RegisterTest(TLazBleClientTest);

end.
