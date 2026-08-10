unit LazBleComponentTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  FpcUnit,
  TestRegistry,
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

  TStreamingComponentOwner = class(TComponent)
  protected
    procedure GetChildren(Proc: TGetChildProc; Root: TComponent); override;
  public
    CompletionCount: Integer;
  published
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
    FComponent: TLazBleComponent;
    FResultCount: Integer;
    FStateChanges: array of TLazBleLclScanState;
    FCompletionCount: Integer;
    FCompletedState: TLazBleLclScanState;
    FErrorCount: Integer;
    FErrorCode: Integer;
    FErrorMessage: string;
    FLastCallbackThreadId: TThreadID;
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanStateChanged(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanCompleted(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanError(Sender: TObject; const AErrorCode: Integer;
      const AErrorMessage: string);
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
    procedure DestroyIgnoresQueuedCallbacksAndReleasesFacade;
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
  FComponent := TLazBleComponent.Create(nil, FBackend);
  FComponent.OnScanResult := @ScanResult;
  FComponent.OnScanStateChanged := @ScanStateChanged;
  FComponent.OnScanCompleted := @ScanCompleted;
  FComponent.OnError := @ScanError;
  FResultCount := 0;
  SetLength(FStateChanges, 0);
  FCompletionCount := 0;
  FCompletedState := lblssIdle;
  FErrorCount := 0;
  FErrorCode := 0;
  FErrorMessage := '';
  FLastCallbackThreadId := 0;
end;

procedure TLazBleComponentTest.TearDown;
begin
  FComponent.Free;
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
    AssertEquals(0, BackendObject.CommandCount);
    AssertEquals(Ord(lblssIdle), Ord(LoadedComponent.ScanState));
  finally
    Stream.Free;
    LoadedOwner.Free;
    Owner.Free;
    StreamingBackend := nil;
    Backend := nil;
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

procedure TLazBleComponentTest.DestroyIgnoresQueuedCallbacksAndReleasesFacade;
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
    FComponent.Free;
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
