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
  TestLazBleAccess,
  FakeLazBleBackend;

type
  TBackendLifetimeObserver = class
  private
    FDestroyed: Boolean;
  public
    property Destroyed: Boolean read FDestroyed;
  end;

  TTrackedFakeLazBleBackend = class(TFakeLazBleBackend)
  private
    FObserver: TBackendLifetimeObserver;
  public
    constructor Create(const AObserver: TBackendLifetimeObserver);
    destructor Destroy; override;
  end;

  TCentralObserver = class
  private
    FScanResultCount: Integer;
    FDeviceId: string;
    FDeviceName: string;
    FRssi: SmallInt;
    FScanCompletedCount: Integer;
    FScanSucceeded: Boolean;
    FSessionStateCount: Integer;
    FLastSessionState: TLazBleSessionState;
  public
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanCompleted(Sender: TObject; const ASucceeded: Boolean;
      const AErrorCode: Integer; const AErrorMessage: string);
    procedure SessionStateChanged(Sender: TObject;
      const AState: TLazBleSessionState);
    property ScanResultCount: Integer read FScanResultCount;
    property DeviceId: string read FDeviceId;
    property DeviceName: string read FDeviceName;
    property Rssi: SmallInt read FRssi;
    property ScanCompletedCount: Integer read FScanCompletedCount;
    property ScanSucceeded: Boolean read FScanSucceeded;
    property SessionStateCount: Integer read FSessionStateCount;
    property LastSessionState: TLazBleSessionState read FLastSessionState;
  end;

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
    procedure DiscoveryFailureMovesSessionToError;
    procedure SessionDisconnects;
    procedure SessionIgnoresEventsFromOldGeneration;
    procedure ScanCancellationDoesNotInterruptShutdown;
    procedure ShutdownWaitsForTerminalEventAndDetachesBackend;
    procedure ShutdownRetainsBackendUntilManagerIsDestroyed;
    procedure ScanPublishesResultsAndCompletion;
    procedure SessionPublishesStateChanges;
  end;

implementation

constructor TTrackedFakeLazBleBackend.Create(
  const AObserver: TBackendLifetimeObserver);
begin
  inherited Create;
  FObserver := AObserver;
end;

destructor TTrackedFakeLazBleBackend.Destroy;
begin
  FObserver.FDestroyed := True;
  inherited Destroy;
end;

procedure TCentralObserver.ScanResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
begin
  Inc(FScanResultCount);
  FDeviceId := ADeviceId;
  FDeviceName := ADeviceName;
  FRssi := ARssi;
end;

procedure TCentralObserver.ScanCompleted(Sender: TObject;
  const ASucceeded: Boolean; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  Inc(FScanCompletedCount);
  FScanSucceeded := ASucceeded;
end;

procedure TCentralObserver.SessionStateChanged(Sender: TObject;
  const AState: TLazBleSessionState);
begin
  Inc(FSessionStateCount);
  FLastSessionState := AState;
end;

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
  ConnectId := LazBleTestConnect(ASession);
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

  ConnectId := LazBleTestConnect(Session);

  AssertEquals(Ord(lbssConnecting), Ord(Session.State));
  AssertTrue(LazBleTestConnect(Session) = InvalidBleOperationId);
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
  ConnectId := LazBleTestConnect(Session);

  AssertTrue(FBackendObject.CompleteOperation(
    ConnectId, lbekOperationFailed));

  AssertEquals(Ord(lbssError), Ord(Session.State));
end;

procedure TLazBleCentralManagerTest.DiscoveryFailureMovesSessionToError;
var
  ConnectId: TBleOperationId;
  DiscoveryId: TBleOperationId;
  Session: TBleGattSession;
begin
  Session := FManager.CreateSession('device-1');
  ConnectId := LazBleTestConnect(Session);
  EmitOperationEvent(lbekConnected, ConnectId, 'device-1',
    Session.Generation);
  DiscoveryId := FBackendObject.OperationIds[
    FBackendObject.CommandCount - 1];

  AssertTrue(FBackendObject.CompleteOperation(
    DiscoveryId, lbekOperationFailed));

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

  DisconnectId := LazBleTestDisconnect(Session);

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
  LazBleTestDisconnect(Session);
  EmitOperationEvent(lbekDisconnected,
    FBackendObject.OperationIds[FBackendObject.CommandCount - 1],
    'device-1', 1);

  ConnectId := LazBleTestConnect(Session);
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

procedure TLazBleCentralManagerTest.ShutdownRetainsBackendUntilManagerIsDestroyed;
var
  Backend: ILazBleBackend;
  BackendObject: TTrackedFakeLazBleBackend;
  Manager: TBleCentralManager;
  Observer: TBackendLifetimeObserver;
begin
  FManager.Free;
  FManager := nil;
  FBackend := nil;
  FBackendObject := nil;

  Observer := TBackendLifetimeObserver.Create;
  try
    BackendObject := TTrackedFakeLazBleBackend.Create(Observer);
    Backend := BackendObject;
    Manager := TBleCentralManager.Create(Backend);
    try
      Manager.BeginShutdown;
      AssertTrue(BackendObject.CompleteShutdown);
      Backend := nil;

      AssertFalse(Observer.Destroyed);
    finally
      Manager.Free;
    end;
    AssertTrue(Observer.Destroyed);
  finally
    Backend := nil;
    Observer.Free;
  end;
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

procedure TLazBleCentralManagerTest.ScanPublishesResultsAndCompletion;
var
  BackendEvent: TLazBleBackendEvent;
  Observer: TCentralObserver;
  ScanId: TBleOperationId;
begin
  Observer := TCentralObserver.Create;
  try
    FManager.OnScanResult := @Observer.ScanResult;
    FManager.OnScanCompleted := @Observer.ScanCompleted;
    ScanId := FManager.StartScan('', 1000);

    BackendEvent := Default(TLazBleBackendEvent);
    BackendEvent.Kind := lbekScanResult;
    BackendEvent.OperationId := ScanId;
    BackendEvent.DeviceId := 'AA:BB:CC:DD:EE:FF';
    BackendEvent.DeviceName := 'ENTime';
    BackendEvent.Rssi := -42;
    AssertTrue(FBackendObject.EmitProgress(BackendEvent));
    AssertTrue(FBackendObject.CompleteOperation(ScanId,
      lbekOperationSucceeded));

    AssertEquals(1, Observer.ScanResultCount);
    AssertEquals('AA:BB:CC:DD:EE:FF', Observer.DeviceId);
    AssertEquals('ENTime', Observer.DeviceName);
    AssertEquals(-42, Integer(Observer.Rssi));
    AssertEquals(1, Observer.ScanCompletedCount);
    AssertTrue(Observer.ScanSucceeded);
  finally
    FManager.OnScanResult := nil;
    FManager.OnScanCompleted := nil;
    Observer.Free;
  end;
end;

procedure TLazBleCentralManagerTest.SessionPublishesStateChanges;
var
  Observer: TCentralObserver;
  Session: TBleGattSession;
begin
  Observer := TCentralObserver.Create;
  try
    Session := FManager.CreateSession('device-1');
    Session.OnStateChanged := @Observer.SessionStateChanged;
    LazBleTestConnect(Session);
    AssertEquals(Ord(lbssConnecting), Ord(Observer.LastSessionState));

    EmitOperationEvent(lbekConnected, FBackendObject.OperationIds[0],
      Session.DeviceId, Session.Generation);
    AssertEquals(Ord(lbssDiscovering), Ord(Observer.LastSessionState));
    EmitOperationEvent(lbekServicesDiscovered,
      FBackendObject.OperationIds[1], Session.DeviceId, Session.Generation);

    AssertEquals(3, Observer.SessionStateCount);
    AssertEquals(Ord(lbssConnected), Ord(Observer.LastSessionState));
  finally
    Session.OnStateChanged := nil;
    Observer.Free;
  end;
end;

initialization
  RegisterTest(TLazBleCentralManagerTest);

end.
