unit LazBleCentralManagerTests;

{$mode objfpc}{$H+}

interface

uses
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  LazBleGattSession,
  LazBleCentralManager,
  FakeLazBleBackend;

type
  TLazBleCentralManagerTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FManager: TBleCentralManager;
    procedure EmitOperationEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId; const ADeviceId: string;
      const AGeneration: QWord);
    procedure ConnectSession(const ASession: TBleGattSession);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure ScanRejectsOverlappingOperationAndReturnsToIdle;
    procedure SessionConnectsThroughServiceDiscovery;
    procedure ReusesSessionForTheSameDevice;
    procedure ConnectFailureMovesSessionToError;
    procedure SessionDisconnects;
    procedure SessionIgnoresEventsFromOldGeneration;
    procedure ScanCancellationDoesNotInterruptShutdown;
    procedure ShutdownWaitsForTerminalEventAndDetachesBackend;
  end;

implementation

procedure TLazBleCentralManagerTest.EmitOperationEvent(
  const AKind: TLazBleBackendEventKind;
  const AOperationId: TBleOperationId; const ADeviceId: string;
  const AGeneration: QWord);
var
  BackendEvent: TLazBleBackendEvent;
begin
  BackendEvent := Default(TLazBleBackendEvent);
  BackendEvent.Kind := AKind;
  BackendEvent.OperationId := AOperationId;
  BackendEvent.DeviceId := ADeviceId;
  BackendEvent.Generation := AGeneration;
  AssertTrue(FBackendObject.EmitProgress(BackendEvent));
end;

procedure TLazBleCentralManagerTest.ConnectSession(
  const ASession: TBleGattSession);
var
  ConnectId: TBleOperationId;
  DiscoveryId: TBleOperationId;
begin
  ConnectId := ASession.Connect;
  EmitOperationEvent(lbekConnected, ConnectId, ASession.DeviceId,
    ASession.Generation);
  DiscoveryId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];
  EmitOperationEvent(lbekServicesDiscovered, DiscoveryId, ASession.DeviceId,
    ASession.Generation);
  AssertEquals(Ord(lbssConnected), Ord(ASession.State));
end;

procedure TLazBleCentralManagerTest.SetUp;
begin
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FManager := TBleCentralManager.Create(FBackend);
end;

procedure TLazBleCentralManagerTest.TearDown;
begin
  FManager.Free;
  FManager := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleCentralManagerTest.ScanRejectsOverlappingOperationAndReturnsToIdle;
var
  ScanId: TBleOperationId;
begin
  ScanId := FManager.StartScan('hci0', 5000);

  AssertTrue(ScanId <> InvalidBleOperationId);
  AssertEquals(Ord(lbcsScanning), Ord(FManager.State));
  AssertTrue(FManager.StartScan('hci0', 5000) = InvalidBleOperationId);
  AssertEquals(Ord(lbckStartScan),
    Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('hci0', FBackendObject.Commands[0].AdapterId);
  AssertEquals(5000, Integer(FBackendObject.Commands[0].TimeoutMs));

  AssertTrue(FBackendObject.CompleteOperation(
    ScanId, lbekOperationSucceeded));
  AssertEquals(Ord(lbcsIdle), Ord(FManager.State));
end;

procedure TLazBleCentralManagerTest.SessionConnectsThroughServiceDiscovery;
var
  ConnectId: TBleOperationId;
  Session: TBleGattSession;
begin
  Session := FManager.CreateSession('device-1');

  ConnectId := Session.Connect;

  AssertEquals(Ord(lbssConnecting), Ord(Session.State));
  AssertTrue(Session.Connect = InvalidBleOperationId);
  AssertEquals(1, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckConnect),
    Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('device-1', FBackendObject.Commands[0].DeviceId);
  AssertTrue(FBackendObject.Commands[0].Generation = 1);

  EmitOperationEvent(lbekConnected, ConnectId, 'device-1', 1);

  AssertEquals(Ord(lbssDiscovering), Ord(Session.State));
  AssertEquals(Ord(lbckDiscoverServices),
    Ord(FBackendObject.Commands[1].Kind));
  EmitOperationEvent(lbekServicesDiscovered,
    FBackendObject.OperationIds[1], 'device-1', 1);
  AssertEquals(Ord(lbssConnected), Ord(Session.State));
end;

procedure TLazBleCentralManagerTest.ConnectFailureMovesSessionToError;
var
  ConnectId: TBleOperationId;
  Session: TBleGattSession;
begin
  Session := FManager.CreateSession('device-1');
  ConnectId := Session.Connect;

  AssertTrue(FBackendObject.CompleteOperation(
    ConnectId, lbekOperationFailed));

  AssertEquals(Ord(lbssError), Ord(Session.State));
end;

procedure TLazBleCentralManagerTest.ReusesSessionForTheSameDevice;
var
  FirstSession: TBleGattSession;
  SecondSession: TBleGattSession;
begin
  FirstSession := FManager.CreateSession('device-1');
  SecondSession := FManager.CreateSession('device-1');

  AssertTrue(FirstSession = SecondSession);
end;

procedure TLazBleCentralManagerTest.SessionDisconnects;
var
  DisconnectId: TBleOperationId;
  Session: TBleGattSession;
begin
  Session := FManager.CreateSession('device-1');
  ConnectSession(Session);

  DisconnectId := Session.Disconnect;

  AssertEquals(Ord(lbssDisconnecting), Ord(Session.State));
  AssertEquals(Ord(lbckDisconnect),
    Ord(FBackendObject.Commands[FBackendObject.CommandCount - 1].Kind));
  EmitOperationEvent(lbekDisconnected, DisconnectId, 'device-1',
    Session.Generation);
  AssertEquals(Ord(lbssDisconnected), Ord(Session.State));
end;

procedure TLazBleCentralManagerTest.SessionIgnoresEventsFromOldGeneration;
var
  ConnectId: TBleOperationId;
  Session: TBleGattSession;
begin
  Session := FManager.CreateSession('device-1');
  ConnectSession(Session);
  Session.Disconnect;
  EmitOperationEvent(lbekDisconnected,
    FBackendObject.OperationIds[FBackendObject.CommandCount - 1],
    'device-1', 1);

  ConnectId := Session.Connect;
  AssertTrue(Session.Generation = 2);
  EmitOperationEvent(lbekConnected, ConnectId, 'device-1', 1);

  AssertEquals(Ord(lbssConnecting), Ord(Session.State));
end;

procedure TLazBleCentralManagerTest.ShutdownWaitsForTerminalEventAndDetachesBackend;
var
  ShutdownId: TBleOperationId;
begin
  ShutdownId := FManager.BeginShutdown;

  AssertTrue(ShutdownId <> InvalidBleOperationId);
  AssertEquals(Ord(lbcsShuttingDown), Ord(FManager.State));
  AssertTrue(FBackendObject.HasEventSink);
  AssertTrue(FBackendObject.CompleteShutdown);

  AssertEquals(Ord(lbcsShutdown), Ord(FManager.State));
  AssertFalse(FBackendObject.HasEventSink);
  AssertTrue(FManager.StartScan('hci0', 1000) = InvalidBleOperationId);
end;

procedure TLazBleCentralManagerTest.ScanCancellationDoesNotInterruptShutdown;
var
  ScanId: TBleOperationId;
begin
  ScanId := FManager.StartScan('hci0', 5000);
  FManager.BeginShutdown;

  AssertTrue(FBackendObject.CompleteOperation(
    ScanId, lbekOperationCancelled));

  AssertEquals(Ord(lbcsShuttingDown), Ord(FManager.State));
  AssertTrue(FBackendObject.CompleteShutdown);
  AssertEquals(Ord(lbcsShutdown), Ord(FManager.State));
end;

initialization
  RegisterTest(TLazBleCentralManagerTest);

end.
