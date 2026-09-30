unit LazBleComponentTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  FpcUnit,
  TestRegistry,
  Forms,
  LResources,
  LazBleTypes,
  LazBleBackend,
  LazBleFacade,
  LazBleLclScan,
  LazBleComponent,
  FakeLazBleBackend;

type
  TComponentScanEmissionThread = class(TThread)
  private
    FBackend: TFakeLazBleBackend;
    FOperationId: TBleOperationId;
    FDeviceInfo: TBleDeviceInfo;
    FTerminalKind: TLazBleBackendEventKind;
    FErrorCode: Integer;
    FErrorMessage: string;
    FFinished: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABackend: TFakeLazBleBackend;
      const AOperationId: TBleOperationId; const ADeviceInfo: TBleDeviceInfo;
      const ATerminalKind: TLazBleBackendEventKind;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
    destructor Destroy; override;
    function WaitUntilFinished(const ATimeoutMs: Cardinal): TWaitResult;
  end;

  TComponentAvailabilityEmissionThread = class(TThread)
  private
    FBackend: TFakeLazBleBackend;
    FOperationId: TBleOperationId;
    FAvailable: Boolean;
    FEmitResult: Boolean;
    FTerminalKind: TLazBleBackendEventKind;
    FErrorCode: Integer;
    FErrorMessage: string;
    FFinished: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABackend: TFakeLazBleBackend;
      const AOperationId: TBleOperationId; const AAvailable,
      AEmitResult: Boolean; const ATerminalKind: TLazBleBackendEventKind;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
    destructor Destroy; override;
    function WaitUntilFinished(const ATimeoutMs: Cardinal): TWaitResult;
  end;

  TStreamingComponentOwner = class(TComponent)
  protected
    procedure GetChildren(Proc: TGetChildProc; Root: TComponent); override;
  public
    CompletionCount: Integer;
    AvailabilityCount: Integer;
  published
    procedure AvailabilityChanged(Sender: TObject;
      const AAvailability: TBleAvailability);
    procedure ScanCompleted(Sender: TObject;
      const AState: TLazBleLclScanState);
  end;

  TStreamingLazBleComponent = class(TLazBleComponent)
  protected
    function CreateFacade: TLazBle; override;
  end;

  TLazBleComponentTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FOwnerForm: TForm;
    FComponent: TLazBleComponent;
    FResultCount: Integer;
    FStateChanges: array of TLazBleLclScanState;
    FCompletionCount: Integer;
    FCompletedState: TLazBleLclScanState;
    FErrorCount: Integer;
    FErrorCode: Integer;
    FErrorMessage: string;
    FLastCallbackThreadId: TThreadID;
    FAvailabilityChanges: array of TBleAvailability;
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanStateChanged(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanCompleted(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanError(Sender: TObject; const AErrorCode: Integer;
      const AErrorMessage: string);
    procedure AvailabilityChanged(Sender: TObject;
      const AAvailability: TBleAvailability);
    procedure FindComponentClass(Reader: TReader; const AClassName: string;
      var AClass: TComponentClass);
    function Device(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt): TBleDeviceInfo;
    procedure WaitForEmission(const AThread: TComponentScanEmissionThread);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure StreamingRestoresPublishedPropertiesWithoutStartingScan;
    procedure StartScanUsesPropertiesAndForwardsMainThreadEvents;
    procedure CancelScanCancelsActiveOperation;
    procedure FailedScanForwardsTerminalError;
    procedure ClearScanResultsClearsSnapshot;
    procedure RefreshAvailabilityPublishesMainThreadResult;
    procedure AvailabilityFailureUpdatesError;
    procedure ShutdownSuppressesPendingAvailabilityCallback;
    procedure ShutdownCancelsScanAndSuppressesCallbacks;
    procedure ShutdownIsIdempotentAndRejectsNewWork;
    procedure FormCloseIgnoresQueuedScanCallbacksAndReleasesFacade;
  end;

implementation

var
  StreamingBackend: ILazBleBackend;

constructor TComponentScanEmissionThread.Create(
  const ABackend: TFakeLazBleBackend; const AOperationId: TBleOperationId;
  const ADeviceInfo: TBleDeviceInfo;
  const ATerminalKind: TLazBleBackendEventKind; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBackend := ABackend;
  FOperationId := AOperationId;
  FDeviceInfo := ADeviceInfo;
  FTerminalKind := ATerminalKind;
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
  FFinished := TEvent.Create(nil, True, False, '');
end;

destructor TComponentScanEmissionThread.Destroy;
begin
  FFinished.Free;
  inherited Destroy;
end;

procedure TComponentScanEmissionThread.Execute;
var
  BackendEvent: TLazBleBackendEvent;
begin
  try
    if FDeviceInfo.DeviceId <> '' then
    begin
      BackendEvent := Default(TLazBleBackendEvent);
      BackendEvent.Kind := lbekScanResult;
      BackendEvent.OperationId := FOperationId;
      BackendEvent.DeviceId := FDeviceInfo.DeviceId;
      BackendEvent.DeviceName := FDeviceInfo.DeviceName;
      BackendEvent.Rssi := FDeviceInfo.Rssi;
      FBackend.EmitProgress(BackendEvent);
    end;
    FBackend.CompleteOperation(FOperationId, FTerminalKind, FErrorCode,
      FErrorMessage);
  finally
    FFinished.SetEvent;
  end;
end;

function TComponentScanEmissionThread.WaitUntilFinished(
  const ATimeoutMs: Cardinal): TWaitResult;
begin
  Result := FFinished.WaitFor(ATimeoutMs);
end;

constructor TComponentAvailabilityEmissionThread.Create(
  const ABackend: TFakeLazBleBackend; const AOperationId: TBleOperationId;
  const AAvailable, AEmitResult: Boolean;
  const ATerminalKind: TLazBleBackendEventKind; const AErrorCode: Integer;
  const AErrorMessage: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBackend := ABackend;
  FOperationId := AOperationId;
  FAvailable := AAvailable;
  FEmitResult := AEmitResult;
  FTerminalKind := ATerminalKind;
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
  FFinished := TEvent.Create(nil, True, False, '');
end;

destructor TComponentAvailabilityEmissionThread.Destroy;
begin
  FFinished.Free;
  inherited Destroy;
end;

procedure TComponentAvailabilityEmissionThread.Execute;
var
  BackendEvent: TLazBleBackendEvent;
begin
  try
    if FEmitResult then
    begin
      BackendEvent := Default(TLazBleBackendEvent);
      BackendEvent.Kind := lbekAvailabilityResult;
      BackendEvent.OperationId := FOperationId;
      BackendEvent.Available := FAvailable;
      BackendEvent.BackendName := 'FakeBLE';
      BackendEvent.BackendVersion := '2.3.4';
      BackendEvent.AdapterId := 'hci-selected';
      FBackend.EmitProgress(BackendEvent);
    end;
    FBackend.CompleteOperation(FOperationId, FTerminalKind, FErrorCode,
      FErrorMessage);
  finally
    FFinished.SetEvent;
  end;
end;

function TComponentAvailabilityEmissionThread.WaitUntilFinished(
  const ATimeoutMs: Cardinal): TWaitResult;
begin
  Result := FFinished.WaitFor(ATimeoutMs);
end;

procedure TStreamingComponentOwner.AvailabilityChanged(Sender: TObject;
  const AAvailability: TBleAvailability);
begin
  Inc(AvailabilityCount);
end;

procedure TStreamingComponentOwner.ScanCompleted(Sender: TObject;
  const AState: TLazBleLclScanState);
begin
  Inc(CompletionCount);
end;

procedure TStreamingComponentOwner.GetChildren(Proc: TGetChildProc;
  Root: TComponent);
var
  Index: Integer;
begin
  for Index := 0 to ComponentCount - 1 do
    Proc(Components[Index]);
end;

function TStreamingLazBleComponent.CreateFacade: TLazBle;
begin
  Result := TLazBle.Create(StreamingBackend);
end;

procedure TLazBleComponentTest.SetUp;
begin
  inherited SetUp;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FOwnerForm := TForm.CreateNew(nil);
  FComponent := TLazBleComponent.Create(FOwnerForm, FBackend);
  FComponent.OnScanResult := @ScanResult;
  FComponent.OnScanStateChanged := @ScanStateChanged;
  FComponent.OnScanCompleted := @ScanCompleted;
  FComponent.OnError := @ScanError;
  FComponent.OnAvailabilityChanged := @AvailabilityChanged;
  FResultCount := 0;
  SetLength(FStateChanges, 0);
  FCompletionCount := 0;
  FCompletedState := lblssIdle;
  FErrorCount := 0;
  FErrorCode := 0;
  FErrorMessage := '';
  FLastCallbackThreadId := 0;
  SetLength(FAvailabilityChanges, 0);
end;

procedure TLazBleComponentTest.TearDown;
begin
  FOwnerForm.Free;
  FOwnerForm := nil;
  FComponent := nil;
  CheckSynchronize;
  FBackend := nil;
  FBackendObject := nil;
  inherited TearDown;
end;

procedure TLazBleComponentTest.ScanResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
begin
  Inc(FResultCount);
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleComponentTest.ScanStateChanged(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  Index: Integer;
begin
  Index := Length(FStateChanges);
  SetLength(FStateChanges, Index + 1);
  FStateChanges[Index] := AState;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleComponentTest.ScanCompleted(Sender: TObject;
  const AState: TLazBleLclScanState);
begin
  Inc(FCompletionCount);
  FCompletedState := AState;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleComponentTest.ScanError(Sender: TObject;
  const AErrorCode: Integer; const AErrorMessage: string);
begin
  Inc(FErrorCount);
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleComponentTest.AvailabilityChanged(Sender: TObject;
  const AAvailability: TBleAvailability);
var
  Index: Integer;
begin
  Index := Length(FAvailabilityChanges);
  SetLength(FAvailabilityChanges, Index + 1);
  FAvailabilityChanges[Index] := AAvailability;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleComponentTest.FindComponentClass(Reader: TReader;
  const AClassName: string; var AClass: TComponentClass);
begin
  AClass := TComponentClass(GetClass(AClassName));
end;

function TLazBleComponentTest.Device(const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt): TBleDeviceInfo;
begin
  Result := Default(TBleDeviceInfo);
  Result.DeviceId := ADeviceId;
  Result.DeviceName := ADeviceName;
  Result.Rssi := ARssi;
end;

procedure TLazBleComponentTest.WaitForEmission(
  const AThread: TComponentScanEmissionThread);
begin
  AssertEquals('Scan emission thread did not finish', Ord(wrSignaled),
    Ord(AThread.WaitUntilFinished(5000)));
end;

procedure TLazBleComponentTest.StreamingRestoresPublishedPropertiesWithoutStartingScan;
var
  Backend: ILazBleBackend;
  BackendObject: TFakeLazBleBackend;
  Loaded: TComponent;
  LoadedComponent: TStreamingLazBleComponent;
  LoadedOwner: TStreamingComponentOwner;
  Owner: TStreamingComponentOwner;
  Source: TStreamingLazBleComponent;
  Stream: TMemoryStream;
begin
  FComponent.Free;
  FComponent := nil;
  FBackend := nil;
  FBackendObject := nil;
  BackendObject := TFakeLazBleBackend.Create;
  Backend := BackendObject;
  StreamingBackend := Backend;
  Owner := TStreamingComponentOwner.Create(nil);
  Owner.Name := 'StreamingOwner';
  LoadedOwner := nil;
  Stream := TMemoryStream.Create;
  try
    Source := TStreamingLazBleComponent.Create(Owner);
    Source.Name := 'LazBle1';
    Source.AdapterId := 'hci-test';
    Source.ScanTimeoutMs := 4321;
    Source.OnAvailabilityChanged := @Owner.AvailabilityChanged;
    Source.OnScanCompleted := @Owner.ScanCompleted;
    WriteComponentAsTextToStream(Stream, Owner);
    Owner.Free;
    Owner := nil;

    Stream.Position := 0;
    Loaded := nil;
    ReadComponentFromTextStream(Stream, Loaded, @FindComponentClass);
    LoadedOwner := Loaded as TStreamingComponentOwner;
    LoadedComponent := LoadedOwner.FindComponent('LazBle1') as
      TStreamingLazBleComponent;

    AssertEquals('hci-test', LoadedComponent.AdapterId);
    AssertEquals(4321, Integer(LoadedComponent.ScanTimeoutMs));
    AssertTrue(TMethod(LoadedComponent.OnScanCompleted).Code =
      TMethod(@LoadedOwner.ScanCompleted).Code);
    AssertTrue(TMethod(LoadedComponent.OnScanCompleted).Data =
      TMethod(@LoadedOwner.ScanCompleted).Data);
    AssertTrue(TMethod(LoadedComponent.OnAvailabilityChanged).Code =
      TMethod(@LoadedOwner.AvailabilityChanged).Code);
    AssertTrue(TMethod(LoadedComponent.OnAvailabilityChanged).Data =
      TMethod(@LoadedOwner.AvailabilityChanged).Data);
    AssertEquals(0, BackendObject.CommandCount);
    AssertEquals(Ord(lbaUnknown), Ord(LoadedComponent.Availability));
    AssertEquals(Ord(lblssIdle), Ord(LoadedComponent.ScanState));
  finally
    Stream.Free;
    LoadedOwner.Free;
    Owner.Free;
    StreamingBackend := nil;
    Backend := nil;
  end;
end;

procedure TLazBleComponentTest.RefreshAvailabilityPublishesMainThreadResult;
var
  Thread: TComponentAvailabilityEmissionThread;
begin
  FComponent.AdapterId := 'hci-test';
  AssertEquals(Ord(lbaUnknown), Ord(FComponent.Availability));

  FComponent.RefreshAvailability;

  AssertEquals(Ord(lbaChecking), Ord(FComponent.Availability));
  AssertEquals(1, Length(FAvailabilityChanges));
  AssertEquals(Ord(lbaChecking), Ord(FAvailabilityChanges[0]));
  AssertEquals(Ord(lbckCheckAvailability),
    Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('hci-test', FBackendObject.Commands[0].AdapterId);
  Thread := TComponentAvailabilityEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], True, True, lbekOperationSucceeded);
  try
    Thread.Start;
    AssertEquals(Ord(wrSignaled), Ord(Thread.WaitUntilFinished(5000)));
    AssertEquals(Ord(lbaChecking), Ord(FComponent.Availability));
    CheckSynchronize;

    AssertEquals(Ord(lbaAvailable), Ord(FComponent.Availability));
    AssertEquals(2, Length(FAvailabilityChanges));
    AssertEquals(Ord(lbaAvailable), Ord(FAvailabilityChanges[1]));
    AssertEquals('FakeBLE', FComponent.BackendInfo.Name);
    AssertEquals('2.3.4', FComponent.BackendInfo.Version);
    AssertEquals('hci-selected', FComponent.BackendInfo.AdapterId);
    AssertEquals('2.3.4', FComponent.DiagnosticInfo.NativeVersion);
    AssertEquals(Int64(MainThreadID), Int64(FLastCallbackThreadId));
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleComponentTest.AvailabilityFailureUpdatesError;
var
  Thread: TComponentAvailabilityEmissionThread;
begin
  FComponent.RefreshAvailability;
  Thread := TComponentAvailabilityEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], False, False, lbekOperationFailed,
    71, 'availability failed');
  try
    Thread.Start;
    AssertEquals(Ord(wrSignaled), Ord(Thread.WaitUntilFinished(5000)));
    CheckSynchronize;

    AssertEquals(Ord(lbaUnavailable), Ord(FComponent.Availability));
    AssertEquals(1, FErrorCount);
    AssertEquals(71, FErrorCode);
    AssertEquals('availability failed', FErrorMessage);
    AssertEquals(71, FComponent.LastErrorCode);
    AssertEquals('availability failed', FComponent.LastErrorMessage);
    AssertEquals(Int64(MainThreadID), Int64(FLastCallbackThreadId));
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleComponentTest.ShutdownSuppressesPendingAvailabilityCallback;
var
  OperationId: TBleOperationId;
  Thread: TComponentAvailabilityEmissionThread;
begin
  FComponent.RefreshAvailability;
  OperationId := FBackendObject.OperationIds[0];
  AssertEquals(1, Length(FAvailabilityChanges));

  FComponent.Shutdown;

  AssertTrue(FBackendObject.CancellationWasRequested(OperationId));
  Thread := TComponentAvailabilityEmissionThread.Create(FBackendObject,
    OperationId, True, True, lbekOperationCancelled);
  try
    Thread.Start;
    AssertEquals(Ord(wrSignaled), Ord(Thread.WaitUntilFinished(5000)));
    AssertTrue(FBackendObject.CompleteShutdown);
    CheckSynchronize;

    AssertEquals(Ord(lbaUnavailable), Ord(FComponent.Availability));
    AssertEquals(1, Length(FAvailabilityChanges));
    AssertEquals(0, FErrorCount);
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleComponentTest.StartScanUsesPropertiesAndForwardsMainThreadEvents;
var
  Snapshot: TBleDeviceInfos;
  Thread: TComponentScanEmissionThread;
begin
  FComponent.AdapterId := 'hci2';
  FComponent.ScanTimeoutMs := 2468;
  FComponent.StartScan;

  AssertEquals(1, FBackendObject.CommandCount);
  AssertEquals('hci2', FBackendObject.Commands[0].AdapterId);
  AssertEquals(2468, Integer(FBackendObject.Commands[0].TimeoutMs));
  AssertEquals(1, Length(FStateChanges));
  AssertEquals(Ord(lblssScanning), Ord(FStateChanges[0]));

  Thread := TComponentScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], Device('device-a', 'First', -42),
    lbekOperationSucceeded);
  try
    Thread.Start;
    WaitForEmission(Thread);
    AssertEquals(0, FResultCount);
    AssertEquals(0, FCompletionCount);
    CheckSynchronize;

    AssertEquals(1, FResultCount);
    AssertEquals(1, FCompletionCount);
    AssertEquals(Ord(lblssSucceeded), Ord(FCompletedState));
    AssertEquals(Int64(MainThreadID), Int64(FLastCallbackThreadId));
    Snapshot := FComponent.ScanResults;
    AssertEquals(1, Length(Snapshot));
    AssertEquals('device-a', Snapshot[0].DeviceId);
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleComponentTest.CancelScanCancelsActiveOperation;
begin
  FComponent.StartScan;
  FComponent.CancelScan;

  AssertTrue(FBackendObject.CancellationWasRequested(
    FBackendObject.OperationIds[0]));
end;

procedure TLazBleComponentTest.FailedScanForwardsTerminalError;
var
  Thread: TComponentScanEmissionThread;
begin
  FComponent.StartScan;
  Thread := TComponentScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], Default(TBleDeviceInfo),
    lbekOperationFailed, 55, 'scan failed');
  try
    Thread.Start;
    WaitForEmission(Thread);
    CheckSynchronize;

    AssertEquals(1, FErrorCount);
    AssertEquals(55, FErrorCode);
    AssertEquals('scan failed', FErrorMessage);
    AssertEquals(55, FComponent.LastErrorCode);
    AssertEquals('scan failed', FComponent.LastErrorMessage);
    AssertEquals(1, FCompletionCount);
    AssertEquals(Ord(lblssFailed), Ord(FCompletedState));
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleComponentTest.ClearScanResultsClearsSnapshot;
var
  Thread: TComponentScanEmissionThread;
begin
  FComponent.StartScan;
  Thread := TComponentScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], Device('device-a', 'First', -42),
    lbekOperationSucceeded);
  try
    Thread.Start;
    WaitForEmission(Thread);
    CheckSynchronize;
    AssertEquals(1, Length(FComponent.ScanResults));

    FComponent.ClearScanResults;

    AssertEquals(0, Length(FComponent.ScanResults));
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleComponentTest.ShutdownCancelsScanAndSuppressesCallbacks;
var
  OperationId: TBleOperationId;
  Thread: TComponentScanEmissionThread;
begin
  FComponent.StartScan;
  OperationId := FBackendObject.OperationIds[0];

  FComponent.Shutdown;

  AssertTrue(FBackendObject.ShutdownOperationId <> InvalidBleOperationId);
  AssertTrue(FBackendObject.CancellationWasRequested(OperationId));
  Thread := TComponentScanEmissionThread.Create(FBackendObject, OperationId,
    Device('device-a', 'Late result', -42), lbekOperationCancelled);
  try
    Thread.Start;
    WaitForEmission(Thread);
    AssertTrue(FBackendObject.CompleteShutdown);
    CheckSynchronize;

    AssertEquals(0, FResultCount);
    AssertEquals(0, FCompletionCount);
    AssertEquals(0, FErrorCount);
    AssertEquals(1, Length(FStateChanges));
    AssertEquals(Ord(lblssScanning), Ord(FStateChanges[0]));
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleComponentTest.ShutdownIsIdempotentAndRejectsNewWork;
var
  Client: TLazBleLclClient;
  Raised: Boolean;
  ShutdownOperationId: TBleOperationId;
begin
  FComponent.Shutdown;
  ShutdownOperationId := FBackendObject.ShutdownOperationId;

  FComponent.Shutdown;

  AssertTrue(ShutdownOperationId <> InvalidBleOperationId);
  AssertEquals(Int64(ShutdownOperationId),
    Int64(FBackendObject.ShutdownOperationId));
  Raised := False;
  try
    FComponent.StartScan;
  except
    on EInvalidOperation do
      Raised := True;
  end;
  AssertTrue(Raised);

  Client := nil;
  Raised := False;
  try
    Client := FComponent.CreateClient('device-a');
  except
    on EInvalidOperation do
      Raised := True;
  end;
  Client.Free;
  AssertTrue(Raised);
  AssertEquals(0, FComponent.ClientCount);
end;

procedure TLazBleComponentTest.
  FormCloseIgnoresQueuedScanCallbacksAndReleasesFacade;
var
  Thread: TComponentScanEmissionThread;
begin
  FComponent.StartScan;
  Thread := TComponentScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], Device('device-a', 'First', -42),
    lbekOperationSucceeded);
  try
    Thread.Start;
    WaitForEmission(Thread);
    FOwnerForm.Free;
    FOwnerForm := nil;
    FComponent := nil;

    CheckSynchronize;

    AssertEquals(0, FResultCount);
    AssertEquals(0, FCompletionCount);
    AssertFalse(FBackendObject.HasEventSink);
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

initialization
  RegisterClass(TStreamingComponentOwner);
  RegisterClass(TStreamingLazBleComponent);
  RegisterTest(TLazBleComponentTest);

finalization
  UnregisterClass(TStreamingLazBleComponent);
  UnregisterClass(TStreamingComponentOwner);

end.
