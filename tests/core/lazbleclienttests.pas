unit LazBleClientTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  fpcunit,
  testregistry,
  LazBleTypes,
  LazBleBackend,
  LazBleGattSession,
  LazBleClient,
  LazBleClientSync,
  FakeLazBleBackend;

type
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
    FClient: TBleClient;
    procedure EmitEvent(const AKind: TLazBleBackendEventKind;
      const AOperationId: TBleOperationId; const ADeviceId: string = '';
      const ADeviceName: string = ''; const ARssi: SmallInt = 0;
      const AGeneration: QWord = 0);
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
    procedure DefaultClientDoesNotLoadNativeLibraryWhenCreated;
    procedure DefaultSyncClientDoesNotLoadNativeLibraryWhenCreated;
  end;

implementation

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

procedure TLazBleClientTest.SetUp;
begin
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FClient := TBleClient.Create(FBackend);
end;

procedure TLazBleClientTest.TearDown;
begin
  FClient.Free;
  FClient := nil;
  FBackend := nil;
  FBackendObject := nil;
end;

procedure TLazBleClientTest.ScanDeduplicatesWithoutChangingDiscoveryOrder;
var
  Devices: TBleDeviceInfos;
  Operation: TBleScanOperation;
  OperationId: TBleOperationId;
begin
  Operation := FClient.ScanAsync('hci0', 5000);
  OperationId := FBackendObject.OperationIds[0];

  EmitEvent(lbekScanResult, OperationId, 'device-a', 'First', -80);
  EmitEvent(lbekScanResult, OperationId, 'device-b', 'Second', -40);
  EmitEvent(lbekScanResult, OperationId, 'device-a', 'First updated', -20);
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationSucceeded));

  Devices := Operation.Results;
  AssertEquals(Ord(lbcopsSucceeded), Ord(Operation.State));
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
  Operation := FClient.ScanAsync('', 5000);
  OperationId := FBackendObject.OperationIds[0];

  Operation.Cancel;

  AssertTrue(FBackendObject.CancellationWasRequested(OperationId));
  AssertTrue(FBackendObject.CompleteOperation(OperationId,
    lbekOperationCancelled));
  AssertEquals(Ord(lbcopsCancelled), Ord(Operation.State));
end;

procedure TLazBleClientTest.TimedOutScanKeepsTimedOutStateAfterTerminalEvent;
var
  Observer: TClientOperationObserver;
  Operation: TBleScanOperation;
  OperationId: TBleOperationId;
begin
  Observer := TClientOperationObserver.Create;
  Operation := FClient.ScanAsync('', 5000);
  Operation.OnCompleted := @Observer.Completed;
  OperationId := FBackendObject.OperationIds[0];
  try
    Operation.Timeout;

    AssertEquals(Ord(lbcopsTimedOut), Ord(Operation.State));
    AssertTrue(FBackendObject.CancellationWasRequested(OperationId));
    AssertTrue(FBackendObject.CompleteOperation(OperationId,
      lbekOperationCancelled));
    AssertEquals(Ord(lbcopsTimedOut), Ord(Operation.State));
    AssertEquals(1, Observer.CompletionCount);
  finally
    Operation.OnCompleted := nil;
    Observer.Free;
  end;
end;

procedure TLazBleClientTest.ConnectCompletesAfterServiceDiscovery;
var
  ConnectId: TBleOperationId;
  DiscoveryId: TBleOperationId;
  Operation: TBleConnectionOperation;
begin
  Operation := FClient.ConnectAsync('device-a');
  ConnectId := FBackendObject.OperationIds[0];
  EmitEvent(lbekConnected, ConnectId, 'device-a', '', 0,
    Operation.Session.Generation);
  DiscoveryId := FBackendObject.OperationIds[1];
  EmitEvent(lbekServicesDiscovered, DiscoveryId, 'device-a', '', 0,
    Operation.Session.Generation);

  AssertEquals(Ord(lbcopsSucceeded), Ord(Operation.State));
  AssertEquals(Ord(lbssConnected), Ord(Operation.Session.State));
end;

procedure TLazBleClientTest.ShutdownCompletesAfterBackendShutdown;
var
  Operation: TBleClientOperation;
begin
  Operation := FClient.ShutdownAsync;

  AssertEquals(Ord(lbcopsPending), Ord(Operation.State));
  AssertTrue(FBackendObject.CompleteShutdown);
  AssertEquals(Ord(lbcopsSucceeded), Ord(Operation.State));
end;

procedure TLazBleClientTest.SyncScanWaitsForTerminalEvent;
var
  ClientSync: TBleClientSync;
  CompletionThread: TScanCompletionThread;
  Devices: TBleDeviceInfos;
  ErrorMessage: string;
begin
  ClientSync := TBleClientSync.Create(FBackend);
  CompletionThread := TScanCompletionThread.Create(FBackendObject);
  try
    CompletionThread.Start;
    AssertTrue(ClientSync.Scan('', 1000, Devices, ErrorMessage));
    CompletionThread.WaitFor;
    AssertEquals('', ErrorMessage);
  finally
    CompletionThread.Terminate;
    CompletionThread.WaitFor;
    CompletionThread.Free;
    ClientSync.Free;
  end;
end;

procedure TLazBleClientTest.DefaultClientDoesNotLoadNativeLibraryWhenCreated;
var
  Client: TBleClient;
begin
  Client := TBleClient.Create;
  Client.Free;
end;

procedure TLazBleClientTest.DefaultSyncClientDoesNotLoadNativeLibraryWhenCreated;
var
  Client: TBleClientSync;
begin
  Client := TBleClientSync.Create;
  Client.Free;
end;

initialization
  RegisterTest(TLazBleClientTest);

end.
