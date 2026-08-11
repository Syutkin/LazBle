unit LazBleClientTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  LazBleOperation,
  LazBleGattProfile,
  LazBleClient,
  LazBleFacade,
  LazBleReconnect,
  LazBleSync,
  LazBleNus,
  FakeLazBleBackend,
  FakeLazBleReconnectTimer;

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
    function IsBound: Boolean;
    function TestAttachedGeneration: QWord;
    property AttachCount: Integer read FAttachCount;
    property DetachCount: Integer read FDetachCount;
  end;

  TTrackedGattProfile = class(TManualGattProfile)
  private
    FBackend: TFakeLazBleBackend;
    FBackendHadSinkWhenDestroyed: PBoolean;
    FDestroyCount: PInteger;
  public
    constructor Create(const ABackend: TFakeLazBleBackend;
      const ADestroyCount: PInteger;
      const ABackendHadSinkWhenDestroyed: PBoolean);
    destructor Destroy; override;
  end;

  TClientOperationObserver = class
  private
    FCompletionCount: Integer;
  public
    procedure Completed(Sender: TObject);
    property CompletionCount: Integer read FCompletionCount;
  end;

  TScanResultObserver = class
  private
    FResultCount: Integer;
    FLastDeviceId: string;
    FLastDeviceName: string;
    FLastRssi: SmallInt;
  public
    procedure ResultReceived(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    property ResultCount: Integer read FResultCount;
    property LastDeviceId: string read FLastDeviceId;
    property LastDeviceName: string read FLastDeviceName;
    property LastRssi: SmallInt read FLastRssi;
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
    FReconnectTimerFactory: ILazBleReconnectTimerFactory;
    FReconnectTimerFactoryObject: TFakeLazBleReconnectTimerFactory;
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId; const ADeviceId: string = '';
      const ADeviceName: string = ''; const ARssi: SmallInt = 0;
      const AGeneration: QWord = 0);
    procedure CompleteTransportClient(const AClient: TBleClient);
    procedure CompleteNusTransportClient(const AClient: TBleClient);
    procedure UseFakeReconnectTimer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ScanDeduplicatesWithoutChangingDiscoveryOrder;
    procedure ScanPublishesEachNewAndUpdatedResult;
    procedure CancellingScanCancelsBackendOperation;
    procedure TimedOutScanKeepsTimedOutStateAfterTerminalEvent;
    procedure AvailabilityCheckReturnsTypedResult;
    procedure AvailabilityCheckDoesNotOverlapScan;
    procedure ConnectCompletesAfterServiceDiscovery;
    procedure TwoClientsConnectIndependently;
    procedure ShutdownCompletesAfterBackendShutdown;
    procedure CreateClientAfterShutdownRaises;
    procedure SyncScanWaitsForTerminalEvent;
    procedure DefaultFacadeDoesNotLoadNativeLibraryWhenCreated;
    procedure DefaultSyncFacadeDoesNotLoadNativeLibraryWhenCreated;
    procedure ClientWaitsForRequiredProfiles;
    procedure ClientWaitsForRealNusSubscription;
    procedure OptionalProfileFailureDoesNotFailClient;
    procedure RequiredProfileFailureFailsClient;
    procedure RequiredProfileFailureDisconnectsSession;
    procedure RequiredProfileFailureAfterReadyInvalidatesClient;
    procedure SecondConnectAttachesRegisteredProfilesAgain;
    procedure SecondConnectAttachesAllProfilesToTheSameClient;
    procedure CreateClientRejectsDuplicateDevice;
    procedure FindClientReturnsRegisteredClient;
    procedure RemoveClientReleasesDeviceRegistration;
    procedure RemoveClientRejectsActiveClient;
    procedure RemoveClientReleasesClientInErrorState;
    procedure ProfileCannotBeAddedToTwoClients;
    procedure ProfileCannotBeAddedAfterConnectStarts;
    procedure ClientExposesGattOperations;
    procedure FacadeOwnsClientsProfilesAndDetachesBackend;
    procedure ShutdownCancelsActiveClientConnection;
    procedure ShutdownCancelsClientWhileProfileIsAttaching;
    procedure AutoReconnectIsDisabledByDefault;
    procedure InitialConnectFailureDoesNotStartReconnect;
    procedure UnexpectedDisconnectReconnectsAndReattachesProfiles;
    procedure ReconnectUsesCappedBackoffAndStopsAtMaximumAttempts;
    procedure DisconnectDuringReconnectSchedulesNextAttempt;
    procedure RequiredProfileReattachFailureContinuesReconnectCycle;
    procedure ManualDisconnectCancelsPendingReconnect;
    procedure ShutdownCancelsPendingReconnect;
  end;

implementation

type
  TTestLazBleAccess = class(TLazBle)
  public
    constructor CreateInternal(const ABackend: ILazBleBackend;
      const AReconnectTimerFactory: ILazBleReconnectTimerFactory);
  end;

  TTestBleClientAccess = class(TBleClient)
  public
    function TestGeneration: QWord;
    function TestProfileCount: Integer;
  end;

procedure TScanResultObserver.ResultReceived(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
begin
  Inc(FResultCount);
  FLastDeviceId := ADeviceId;
  FLastDeviceName := ADeviceName;
  FLastRssi := ARssi;
end;

constructor TTestLazBleAccess.CreateInternal(const ABackend: ILazBleBackend;
  const AReconnectTimerFactory: ILazBleReconnectTimerFactory);
begin
  inherited Create(ABackend, AReconnectTimerFactory);
end;

function TTestBleClientAccess.TestGeneration: QWord;
begin
  Result := Generation;
end;

function TTestBleClientAccess.TestProfileCount: Integer;
begin
  Result := ProfileCount;
end;

function ClientGeneration(const AClient: TBleClient): QWord;
begin
  Result := TTestBleClientAccess(AClient).TestGeneration;
end;

function ClientProfileCount(const AClient: TBleClient): Integer;
begin
  Result := TTestBleClientAccess(AClient).TestProfileCount;
end;

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

function TManualGattProfile.IsBound: Boolean;
begin
  Result := Bound;
end;

function TManualGattProfile.TestAttachedGeneration: QWord;
begin
  Result := AttachedGeneration;
end;

constructor TTrackedGattProfile.Create(const ABackend: TFakeLazBleBackend;
  const ADestroyCount: PInteger;
  const ABackendHadSinkWhenDestroyed: PBoolean);
begin
  inherited Create;
  FBackend := ABackend;
  FDestroyCount := ADestroyCount;
  FBackendHadSinkWhenDestroyed := ABackendHadSinkWhenDestroyed;
end;

destructor TTrackedGattProfile.Destroy;
begin
  if Assigned(FDestroyCount) then
    Inc(FDestroyCount^);
  if Assigned(FBackendHadSinkWhenDestroyed) then
    FBackendHadSinkWhenDestroyed^ := Assigned(FBackend) and
      FBackend.HasEventSink;
  FBackend := nil;
  inherited Destroy;
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
    ClientGeneration(AClient));
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekServicesDiscovered, OperationId, AClient.DeviceId,
    '', 0, ClientGeneration(AClient));
end;

procedure TLazBleClientTest.CompleteNusTransportClient(
  const AClient: TBleClient);
var
  BackendEvent: TLazBleBackendEvent;
  OperationId: TBleOperationId;
begin
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekConnected, OperationId, AClient.DeviceId, '', 0,
    ClientGeneration(AClient));
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekServicesDiscovered;
  BackendEvent.OperationId := OperationId;
  BackendEvent.DeviceId := AClient.DeviceId;
  BackendEvent.Generation := ClientGeneration(AClient);
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
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
end;

procedure TLazBleClientTest.UseFakeReconnectTimer;
begin
  FBle.Free;
  FBle := nil;
  FBackend := nil;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FReconnectTimerFactoryObject :=
    TFakeLazBleReconnectTimerFactory.Create;
  FReconnectTimerFactory := FReconnectTimerFactoryObject;
  FBle := TTestLazBleAccess.CreateInternal(FBackend,
    FReconnectTimerFactory);
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
  FReconnectTimerFactory := nil;
  FReconnectTimerFactoryObject := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleClientTest.ScanDeduplicatesWithoutChangingDiscoveryOrder;
var
  Devices: TBleDeviceInfos;
  Operation: IBleScanOperation;
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

procedure TLazBleClientTest.ScanPublishesEachNewAndUpdatedResult;
var
  Observer: TScanResultObserver;
  Operation: IBleScanOperation;
  OperationId: TBleOperationId;
begin
  Observer := TScanResultObserver.Create;
  Operation := FBle.ScanAsync('hci0', 5000);
  OperationId := FBackendObject.OperationIds[0];
  try
    EmitEvent(lbekScanResult, OperationId, 'device-existing',
      'Existing', -90);
    Operation.OnResult := @Observer.ResultReceived;
    AssertEquals(0, Observer.ResultCount);

    EmitEvent(lbekScanResult, OperationId, 'device-a', 'First', -80);
    EmitEvent(lbekScanResult, OperationId, 'device-b', 'Second', -40);
    EmitEvent(lbekScanResult, OperationId, 'device-a', 'First updated', -20);

    AssertEquals(3, Observer.ResultCount);
    AssertEquals('device-a', Observer.LastDeviceId);
    AssertEquals('First updated', Observer.LastDeviceName);
    AssertEquals(-20, Integer(Observer.LastRssi));

    Operation.OnResult := nil;
    EmitEvent(lbekScanResult, OperationId, 'device-c', 'Third', -60);
    AssertEquals(3, Observer.ResultCount);
  finally
    Operation.OnResult := nil;
    Observer.Free;
  end;
end;

procedure TLazBleClientTest.CancellingScanCancelsBackendOperation;
var
  Operation: IBleScanOperation;
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
  Operation: IBleScanOperation;
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

procedure TLazBleClientTest.AvailabilityCheckReturnsTypedResult;
var
  BackendEvent: TLazBleBackendEvent;
  Operation: IBleAvailabilityOperation;
  OperationId: TBleOperationId;
begin
  Operation := FBle.CheckAvailabilityAsync('hci-test');
  OperationId := FBackendObject.OperationIds[0];

  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertEquals(Ord(lbaUnknown), Ord(Operation.Availability));
  AssertEquals(Ord(lbckCheckAvailability),
    Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('hci-test', FBackendObject.Commands[0].AdapterId);

  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekAvailabilityResult;
  BackendEvent.OperationId := OperationId;
  BackendEvent.Available := True;
  BackendEvent.BackendName := 'FakeBLE';
  BackendEvent.BackendVersion := '2.3.4';
  BackendEvent.AdapterId := 'hci-selected';
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationSucceeded));

  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(Ord(lbaAvailable), Ord(Operation.Availability));
  AssertEquals('FakeBLE', FBle.BackendInfo.Name);
  AssertEquals('2.3.4', FBle.BackendInfo.Version);
  AssertEquals('hci-selected', FBle.BackendInfo.AdapterId);

  Operation := FBle.CheckAvailabilityAsync('hci-test');
  OperationId := FBackendObject.OperationIds[1];
  BackendEvent.OperationId := OperationId;
  BackendEvent.Available := False;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationSucceeded));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(Ord(lbaUnavailable), Ord(Operation.Availability));
end;

procedure TLazBleClientTest.AvailabilityCheckDoesNotOverlapScan;
var
  AvailabilityOperation: IBleAvailabilityOperation;
  AvailabilityOperationId: TBleOperationId;
  ScanOperation: IBleScanOperation;
begin
  AvailabilityOperation := FBle.CheckAvailabilityAsync('');
  AvailabilityOperationId := FBackendObject.OperationIds[0];

  ScanOperation := FBle.ScanAsync('', 1000);

  AssertEquals(Ord(lbopFailed), Ord(ScanOperation.State));
  AssertTrue(FBackendObject.CompleteOperation(AvailabilityOperationId,
    lbekOperationFailed, 7, 'availability failed'));
  AssertEquals(Ord(lbopFailed), Ord(AvailabilityOperation.State));

  ScanOperation := FBle.ScanAsync('', 1000);
  AssertEquals(Ord(lbopPending), Ord(ScanOperation.State));
  AssertEquals(2, FBackendObject.CommandCount);
end;

procedure TLazBleClientTest.ConnectCompletesAfterServiceDiscovery;
var
  Client: TBleClient;
  Operation: IBleOperation;
begin
  Client := FBle.CreateClient('device-a');
  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);

  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertTrue(ClientGeneration(Client) > 0);
end;

procedure TLazBleClientTest.TwoClientsConnectIndependently;
var
  FirstClient: TBleClient;
  FirstConnectId: TBleOperationId;
  FirstDiscoveryId: TBleOperationId;
  SecondClient: TBleClient;
  SecondConnectId: TBleOperationId;
  SecondDiscoveryId: TBleOperationId;
begin
  FirstClient := FBle.CreateClient('device-a');
  SecondClient := FBle.CreateClient('device-b');
  FirstClient.ConnectAsync;
  FirstConnectId := FBackendObject.OperationIds[0];
  SecondClient.ConnectAsync;
  SecondConnectId := FBackendObject.OperationIds[1];

  EmitEvent(lbekConnected, FirstConnectId, FirstClient.DeviceId, '', 0,
    ClientGeneration(FirstClient));
  FirstDiscoveryId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekServicesDiscovered, FirstDiscoveryId,
    FirstClient.DeviceId, '', 0, ClientGeneration(FirstClient));

  AssertEquals(Ord(lbcstReady), Ord(FirstClient.State));
  AssertEquals(Ord(lbcstConnecting), Ord(SecondClient.State));

  EmitEvent(lbekConnected, SecondConnectId, SecondClient.DeviceId, '', 0,
    ClientGeneration(SecondClient));
  SecondDiscoveryId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekServicesDiscovered, SecondDiscoveryId,
    SecondClient.DeviceId, '', 0, ClientGeneration(SecondClient));

  AssertEquals(Ord(lbcstReady), Ord(FirstClient.State));
  AssertEquals(Ord(lbcstReady), Ord(SecondClient.State));
end;

procedure TLazBleClientTest.ShutdownCompletesAfterBackendShutdown;
var
  Operation: IBleOperation;
begin
  Operation := FBle.ShutdownAsync;

  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertTrue(FBackendObject.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.CreateClientAfterShutdownRaises;
var
  Raised: Boolean;
  ShutdownOperation: IBleOperation;
begin
  ShutdownOperation := FBle.ShutdownAsync;
  FBackendObject.CompleteShutdown;
  AssertEquals(Ord(lbopSucceeded), Ord(ShutdownOperation.State));

  Raised := False;
  try
    FBle.CreateClient('too-late');
  except
    on EInvalidOperation do
      Raised := True;
  end;
  AssertTrue(Raised);
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
  Operation: IBleOperation;
  Profile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile, True);
  AssertTrue(Profile.IsBound);

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
  Operation: IBleOperation;
  Profile: TNusProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TNusProfile.Create;
  Client.AddProfile(Profile, True);

  Operation := Client.ConnectAsync;
  CompleteNusTransportClient(Client);
  AssertEquals(Ord(lbopPending), Ord(Operation.State));

  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := lbekSubscribed;
  BackendEvent.OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  BackendEvent.SubscriptionId := 51;
  BackendEvent.DeviceId := Client.DeviceId;
  BackendEvent.Generation := ClientGeneration(Client);
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));

  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.OptionalProfileFailureDoesNotFailClient;
var
  Client: TBleClient;
  Operation: IBleOperation;
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
  Operation: IBleOperation;
  Profile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile, True);

  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);
  Profile.FailAttach('required failure');

  AssertEquals(Ord(lbcstDisconnecting), Ord(Client.State));
  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertTrue(Pos('required failure', Operation.ErrorMessage) > 0);
end;

procedure TLazBleClientTest.RequiredProfileFailureDisconnectsSession;
var
  Client: TBleClient;
  DisconnectId: TBleOperationId;
  Operation: IBleOperation;
  Profile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile, True);
  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);

  Profile.FailAttach('required failure');

  AssertEquals(Ord(lbopFailed), Ord(Operation.State));
  AssertEquals(Ord(lbckDisconnect), Ord(FBackendObject.Commands[
    FBackendObject.CommandCount - 1].Kind));
  DisconnectId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, DisconnectId, Client.DeviceId, '', 0,
    ClientGeneration(Client));
  AssertEquals(Ord(lbcstDisconnected), Ord(Client.State));

  Operation := Client.ConnectAsync;
  AssertEquals(Ord(lbopPending), Ord(Operation.State));
  AssertEquals(Ord(lbckConnect), Ord(FBackendObject.Commands[
    FBackendObject.CommandCount - 1].Kind));
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

  AssertEquals(Ord(lbcstDisconnecting), Ord(Client.State));
end;

procedure TLazBleClientTest.SecondConnectAttachesRegisteredProfilesAgain;
var
  Client: TBleClient;
  DisconnectId: TBleOperationId;
  Operation: IBleOperation;
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
    ClientGeneration(Client));
  AssertEquals(Ord(lbcstDisconnected), Ord(Client.State));

  Operation := Client.ConnectAsync;
  CompleteTransportClient(Client);
  AssertEquals(2, Profile.AttachCount);
  AssertTrue(Profile.TestAttachedGeneration = ClientGeneration(Client));
  Profile.CompleteAttach;

  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertEquals(Ord(lbopSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.SecondConnectAttachesAllProfilesToTheSameClient;
var
  Client: TBleClient;
  DisconnectId: TBleOperationId;
  FirstProfile: TManualGattProfile;
  SecondProfile: TManualGattProfile;
begin
  Client := FBle.CreateClient('device-a');
  FirstProfile := TManualGattProfile.Create;
  SecondProfile := TManualGattProfile.Create;
  Client.AddProfile(FirstProfile);
  Client.AddProfile(SecondProfile);

  Client.ConnectAsync;
  CompleteTransportClient(Client);
  FirstProfile.CompleteAttach;
  SecondProfile.CompleteAttach;
  AssertEquals(Ord(lbcstReady), Ord(Client.State));

  Client.DisconnectAsync;
  DisconnectId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, DisconnectId, Client.DeviceId, '', 0,
    ClientGeneration(Client));

  Client.ConnectAsync;
  CompleteTransportClient(Client);

  AssertEquals(2, FirstProfile.AttachCount);
  AssertEquals(2, SecondProfile.AttachCount);
  AssertTrue(FirstProfile.TestAttachedGeneration = ClientGeneration(Client));
  AssertTrue(SecondProfile.TestAttachedGeneration = ClientGeneration(Client));
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

procedure TLazBleClientTest.RemoveClientReleasesClientInErrorState;
var
  Client: TBleClient;
  OperationId: TBleOperationId;
begin
  Client := FBle.CreateClient('device-a');
  Client.ConnectAsync;
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationFailed, 42, 'Connection failed'));
  AssertEquals(Ord(lbcstError), Ord(Client.State));

  FBle.RemoveClient(Client);

  AssertNull(FBle.FindClient('device-a'));
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
  AssertEquals(1, ClientProfileCount(FirstClient));
  AssertEquals(0, ClientProfileCount(SecondClient));
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
    AssertFalse(Profile.IsBound);
    AssertEquals(0, ClientProfileCount(Client));
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

procedure TLazBleClientTest.FacadeOwnsClientsProfilesAndDetachesBackend;
var
  BackendHadSinkWhenProfileDestroyed: Boolean;
  Client: TBleClient;
  DestroyCount: Integer;
  Profile: TTrackedGattProfile;
begin
  BackendHadSinkWhenProfileDestroyed := False;
  DestroyCount := 0;
  Client := FBle.CreateClient('device-a');
  Profile := TTrackedGattProfile.Create(FBackendObject, @DestroyCount,
    @BackendHadSinkWhenProfileDestroyed);
  Client.AddProfile(Profile);

  FBle.Free;
  FBle := nil;

  AssertEquals(1, DestroyCount);
  AssertTrue(BackendHadSinkWhenProfileDestroyed);
  AssertFalse(FBackendObject.HasEventSink);
end;

procedure TLazBleClientTest.ShutdownCancelsActiveClientConnection;
var
  Client: TBleClient;
  ConnectOperation: IBleOperation;
  ConnectOperationId: TBleOperationId;
  Index: Integer;
  OperationCount: Integer;
  ShutdownOperation: IBleOperation;
begin
  Client := FBle.CreateClient('device-a');
  ConnectOperation := Client.ConnectAsync;
  ConnectOperationId := FBackendObject.OperationIds[0];

  ShutdownOperation := FBle.ShutdownAsync;

  AssertTrue(FBackendObject.CancellationWasRequested(ConnectOperationId));
  OperationCount := FBackendObject.CommandCount;
  for Index := 0 to OperationCount - 1 do
  begin
    AssertTrue(FBackendObject.CancellationWasRequested(
      FBackendObject.OperationIds[Index]));
    AssertTrue(FBackendObject.CompleteOperation(
      FBackendObject.OperationIds[Index], lbekOperationCancelled));
  end;
  AssertEquals(Ord(lbopCancelled), Ord(ConnectOperation.State));
  AssertEquals(Ord(lbcstDisconnected), Ord(Client.State));
  AssertTrue(FBackendObject.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(ShutdownOperation.State));
  AssertFalse(FBackendObject.HasEventSink);
end;

procedure TLazBleClientTest.ShutdownCancelsClientWhileProfileIsAttaching;
var
  Client: TBleClient;
  ConnectOperation: IBleOperation;
  DisconnectOperationId: TBleOperationId;
  Profile: TManualGattProfile;
  ShutdownOperation: IBleOperation;
begin
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile);
  ConnectOperation := Client.ConnectAsync;
  CompleteTransportClient(Client);
  AssertTrue(FBackendObject.CompleteOperation(
    FBackendObject.OperationIds[0], lbekOperationSucceeded));
  AssertTrue(FBackendObject.CompleteOperation(
    FBackendObject.OperationIds[1], lbekOperationSucceeded));
  AssertEquals(Ord(lbcstAttachingProfiles), Ord(Client.State));

  ShutdownOperation := FBle.ShutdownAsync;

  AssertEquals(Ord(lbopCancelled), Ord(ConnectOperation.State));
  AssertEquals(1, Profile.DetachCount);
  DisconnectOperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  AssertTrue(FBackendObject.CancellationWasRequested(DisconnectOperationId));
  AssertTrue(FBackendObject.CompleteOperation(DisconnectOperationId,
    lbekOperationCancelled));
  AssertTrue(FBackendObject.CompleteShutdown);
  AssertEquals(Ord(lbopSucceeded), Ord(ShutdownOperation.State));
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

procedure TLazBleClientTest.AutoReconnectIsDisabledByDefault;
var
  Client: TBleClient;
  OperationId: TBleOperationId;
  Profile: TManualGattProfile;
begin
  UseFakeReconnectTimer;
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile);
  Client.ConnectAsync;
  CompleteTransportClient(Client);
  Profile.CompleteAttach;

  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));

  AssertEquals(Ord(lbcstDisconnected), Ord(Client.State));
  AssertFalse(Client.AutoReconnect);
  AssertFalse(FReconnectTimerFactoryObject.LastTimer.Active);
end;

procedure TLazBleClientTest.InitialConnectFailureDoesNotStartReconnect;
var
  Client: TBleClient;
  OperationId: TBleOperationId;
begin
  UseFakeReconnectTimer;
  Client := FBle.CreateClient('device-a');
  Client.AutoReconnect := True;
  Client.ConnectAsync;
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];

  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationFailed));

  AssertEquals(Ord(lbcstError), Ord(Client.State));
  AssertEquals(0, Client.ReconnectAttempt);
  AssertFalse(FReconnectTimerFactoryObject.LastTimer.Active);
end;

procedure TLazBleClientTest.UnexpectedDisconnectReconnectsAndReattachesProfiles;
var
  Client: TBleClient;
  CommandCount: Integer;
  OperationId: TBleOperationId;
  Profile: TManualGattProfile;
begin
  UseFakeReconnectTimer;
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile);
  Client.ReconnectOptions := TLazBleReconnectOptions.Create(100, 500, 3);
  Client.AutoReconnect := True;
  Client.ConnectAsync;
  CompleteTransportClient(Client);
  Profile.CompleteAttach;

  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));

  AssertEquals(Ord(lbcstWaitingToReconnect), Ord(Client.State));
  AssertEquals(1, Client.ReconnectAttempt);
  AssertEquals(100, Client.ReconnectDelayMs);
  CommandCount := FBackendObject.CommandCount;
  AssertTrue(FReconnectTimerFactoryObject.LastTimer.Trigger);
  AssertEquals(CommandCount + 1, FBackendObject.CommandCount);
  AssertEquals(Ord(lbcstConnecting), Ord(Client.State));

  CompleteTransportClient(Client);
  AssertEquals(2, Profile.AttachCount);
  Profile.CompleteAttach;

  AssertEquals(Ord(lbcstReady), Ord(Client.State));
  AssertEquals(0, Client.ReconnectAttempt);
  AssertEquals(0, Client.ReconnectDelayMs);
end;

procedure TLazBleClientTest.ReconnectUsesCappedBackoffAndStopsAtMaximumAttempts;
const
  ExpectedDelays: array[1..3] of Cardinal = (100, 200, 250);
var
  Attempt: Integer;
  Client: TBleClient;
  OperationId: TBleOperationId;
begin
  UseFakeReconnectTimer;
  Client := FBle.CreateClient('device-a');
  Client.ReconnectOptions := TLazBleReconnectOptions.Create(100, 250, 3);
  Client.AutoReconnect := True;
  Client.ConnectAsync;
  CompleteTransportClient(Client);
  AssertEquals(Ord(lbcstReady), Ord(Client.State));

  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));

  for Attempt := 1 to 3 do
  begin
    AssertEquals(Attempt, Client.ReconnectAttempt);
    AssertEquals(ExpectedDelays[Attempt], Client.ReconnectDelayMs);
    AssertTrue(FReconnectTimerFactoryObject.LastTimer.Trigger);
    OperationId := FBackendObject.OperationIds[
      FBackendObject.CommandCount - 1];
    AssertTrue(FBackendObject.CompleteOperation(OperationId,
      lbekOperationFailed));
  end;

  AssertEquals(Ord(lbcstError), Ord(Client.State));
  AssertEquals(3, Client.ReconnectAttempt);
  AssertFalse(FReconnectTimerFactoryObject.LastTimer.Active);
end;

procedure TLazBleClientTest.DisconnectDuringReconnectSchedulesNextAttempt;
var
  Client: TBleClient;
  OperationId: TBleOperationId;
begin
  UseFakeReconnectTimer;
  Client := FBle.CreateClient('device-a');
  Client.ReconnectOptions := TLazBleReconnectOptions.Create(100, 500, 3);
  Client.AutoReconnect := True;
  Client.ConnectAsync;
  CompleteTransportClient(Client);

  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));
  AssertTrue(FReconnectTimerFactoryObject.LastTimer.Trigger);
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];

  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));

  AssertEquals(Ord(lbcstWaitingToReconnect), Ord(Client.State));
  AssertEquals(2, Client.ReconnectAttempt);
  AssertEquals(200, Client.ReconnectDelayMs);
  AssertTrue(FReconnectTimerFactoryObject.LastTimer.Active);
end;

procedure TLazBleClientTest.RequiredProfileReattachFailureContinuesReconnectCycle;
var
  Client: TBleClient;
  OperationId: TBleOperationId;
  Profile: TManualGattProfile;
begin
  UseFakeReconnectTimer;
  Client := FBle.CreateClient('device-a');
  Profile := TManualGattProfile.Create;
  Client.AddProfile(Profile);
  Client.ReconnectOptions := TLazBleReconnectOptions.Create(100, 500, 3);
  Client.AutoReconnect := True;
  Client.ConnectAsync;
  CompleteTransportClient(Client);
  Profile.CompleteAttach;

  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));
  AssertTrue(FReconnectTimerFactoryObject.LastTimer.Trigger);
  CompleteTransportClient(Client);
  Profile.FailAttach('subscribe failed');

  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  AssertEquals(Ord(lbckDisconnect),
    Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].Kind));
  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));

  AssertEquals(Ord(lbcstWaitingToReconnect), Ord(Client.State));
  AssertEquals(2, Client.ReconnectAttempt);
  AssertEquals(200, Client.ReconnectDelayMs);
end;

procedure TLazBleClientTest.ManualDisconnectCancelsPendingReconnect;
var
  Client: TBleClient;
  CommandCount: Integer;
  DisconnectOperation: IBleOperation;
  OperationId: TBleOperationId;
begin
  UseFakeReconnectTimer;
  Client := FBle.CreateClient('device-a');
  Client.AutoReconnect := True;
  Client.ConnectAsync;
  CompleteTransportClient(Client);
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));
  AssertTrue(FReconnectTimerFactoryObject.LastTimer.Active);

  CommandCount := FBackendObject.CommandCount;
  DisconnectOperation := Client.DisconnectAsync;

  AssertEquals(Ord(lbopSucceeded), Ord(DisconnectOperation.State));
  AssertEquals(Ord(lbcstDisconnected), Ord(Client.State));
  AssertFalse(FReconnectTimerFactoryObject.LastTimer.Trigger);
  AssertEquals(CommandCount, FBackendObject.CommandCount);
end;

procedure TLazBleClientTest.ShutdownCancelsPendingReconnect;
var
  Client: TBleClient;
  OperationId: TBleOperationId;
begin
  UseFakeReconnectTimer;
  Client := FBle.CreateClient('device-a');
  Client.AutoReconnect := True;
  Client.ConnectAsync;
  CompleteTransportClient(Client);
  OperationId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitEvent(lbekDisconnected, OperationId, Client.DeviceId, '', 0,
    ClientGeneration(Client));
  AssertTrue(FReconnectTimerFactoryObject.LastTimer.Active);

  FBle.ShutdownAsync;

  AssertFalse(FReconnectTimerFactoryObject.LastTimer.Trigger);
  AssertEquals(Ord(lbcstDisconnected), Ord(Client.State));
end;

initialization
  RegisterTest(TLazBleClientTest);

end.
