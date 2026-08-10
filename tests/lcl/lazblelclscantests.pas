unit LazBleLclScanTests;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  FpcUnit,
  TestRegistry,
  LazBleTypes,
  LazBleBackend,
  LazBleFacade,
  LazBleLclScan,
  FakeLazBleBackend;

type
  TScanEmissionThread = class(TThread)
  private
    FBackend: TFakeLazBleBackend;
    FOperationId: TBleOperationId;
    FResults: TBleDeviceInfos;
    FTerminalKind: TLazBleBackendEventKind;
    FErrorCode: Integer;
    FErrorMessage: string;
    FFinished: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABackend: TFakeLazBleBackend;
      const AOperationId: TBleOperationId; const AResults: array of TBleDeviceInfo;
      const ATerminalKind: TLazBleBackendEventKind;
      const AErrorCode: Integer = 0; const AErrorMessage: string = '');
    destructor Destroy; override;
    function WaitUntilFinished(const ATimeoutMs: Cardinal): TWaitResult;
  end;

  TLazBleLclScanTest = class(TTestCase)
  private
    FBackend: ILazBleBackend;
    FBackendObject: TFakeLazBleBackend;
    FBle: TLazBle;
    FScan: TLazBleLclScan;
    FReceivedResults: TBleDeviceInfos;
    FStateChanges: array of TLazBleLclScanState;
    FCompletionCount: Integer;
    FCompletedState: TLazBleLclScanState;
    FLastCallbackThreadId: TThreadID;
    procedure ScanResult(Sender: TObject; const ADeviceId,
      ADeviceName: string; const ARssi: SmallInt);
    procedure ScanStateChanged(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure ScanCompleted(Sender: TObject;
      const AState: TLazBleLclScanState);
    procedure WaitForEmission(const AThread: TScanEmissionThread);
    function Device(const ADeviceId, ADeviceName: string;
      const ARssi: SmallInt): TBleDeviceInfo;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure StartPassesSettingsAndRejectsOverlap;
    procedure ResultsAndCompletionArriveOnMainThreadWithoutSorting;
    procedure CancelReportsCancelledAfterTerminalEvent;
    procedure FailurePreservesTerminalError;
    procedure RepeatedScanClearsPreviousSnapshot;
    procedure QueuedCallbacksAreIgnoredAfterDestroy;
  end;

implementation

constructor TScanEmissionThread.Create(const ABackend: TFakeLazBleBackend;
  const AOperationId: TBleOperationId;
  const AResults: array of TBleDeviceInfo;
  const ATerminalKind: TLazBleBackendEventKind; const AErrorCode: Integer;
  const AErrorMessage: string);
var
  Index: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBackend := ABackend;
  FOperationId := AOperationId;
  SetLength(FResults, Length(AResults));
  for Index := 0 to High(AResults) do
    FResults[Index] := AResults[Index];
  FTerminalKind := ATerminalKind;
  FErrorCode := AErrorCode;
  FErrorMessage := AErrorMessage;
  FFinished := TEvent.Create(nil, True, False, '');
end;

destructor TScanEmissionThread.Destroy;
begin
  FFinished.Free;
  inherited Destroy;
end;

procedure TScanEmissionThread.Execute;
var
  BackendEvent: TLazBleBackendEvent;
  DeviceInfo: TBleDeviceInfo;
begin
  try
    for DeviceInfo in FResults do
    begin
      BackendEvent := Default(TLazBleBackendEvent);
      BackendEvent.Kind := lbekScanResult;
      BackendEvent.OperationId := FOperationId;
      BackendEvent.DeviceId := DeviceInfo.DeviceId;
      BackendEvent.DeviceName := DeviceInfo.DeviceName;
      BackendEvent.Rssi := DeviceInfo.Rssi;
      FBackend.EmitProgress(BackendEvent);
    end;
    FBackend.CompleteOperation(FOperationId, FTerminalKind, FErrorCode,
      FErrorMessage);
  finally
    FFinished.SetEvent;
  end;
end;

function TScanEmissionThread.WaitUntilFinished(
  const ATimeoutMs: Cardinal): TWaitResult;
begin
  Result := FFinished.WaitFor(ATimeoutMs);
end;

procedure TLazBleLclScanTest.SetUp;
begin
  inherited SetUp;
  FBackendObject := TFakeLazBleBackend.Create;
  FBackend := FBackendObject;
  FBle := TLazBle.Create(FBackend);
  FScan := TLazBleLclScan.Create(FBle);
  FScan.OnResult := @ScanResult;
  FScan.OnStateChanged := @ScanStateChanged;
  FScan.OnCompleted := @ScanCompleted;
  SetLength(FReceivedResults, 0);
  SetLength(FStateChanges, 0);
  FCompletionCount := 0;
  FCompletedState := lblssIdle;
  FLastCallbackThreadId := 0;
end;

procedure TLazBleLclScanTest.TearDown;
begin
  FScan.Free;
  FScan := nil;
  CheckSynchronize;
  FBle.Free;
  FBle := nil;
  FBackend := nil;
  FBackendObject := nil;
  inherited TearDown;
end;

procedure TLazBleLclScanTest.ScanResult(Sender: TObject;
  const ADeviceId, ADeviceName: string; const ARssi: SmallInt);
var
  Index: Integer;
begin
  Index := Length(FReceivedResults);
  SetLength(FReceivedResults, Index + 1);
  FReceivedResults[Index].DeviceId := ADeviceId;
  FReceivedResults[Index].DeviceName := ADeviceName;
  FReceivedResults[Index].Rssi := ARssi;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleLclScanTest.ScanStateChanged(Sender: TObject;
  const AState: TLazBleLclScanState);
var
  Index: Integer;
begin
  Index := Length(FStateChanges);
  SetLength(FStateChanges, Index + 1);
  FStateChanges[Index] := AState;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleLclScanTest.ScanCompleted(Sender: TObject;
  const AState: TLazBleLclScanState);
begin
  Inc(FCompletionCount);
  FCompletedState := AState;
  FLastCallbackThreadId := GetCurrentThreadId;
end;

procedure TLazBleLclScanTest.WaitForEmission(
  const AThread: TScanEmissionThread);
begin
  AssertEquals('Scan emission thread did not finish', Ord(wrSignaled),
    Ord(AThread.WaitUntilFinished(5000)));
end;

function TLazBleLclScanTest.Device(const ADeviceId,
  ADeviceName: string; const ARssi: SmallInt): TBleDeviceInfo;
begin
  Result := Default(TBleDeviceInfo);
  Result.DeviceId := ADeviceId;
  Result.DeviceName := ADeviceName;
  Result.Rssi := ARssi;
end;

procedure TLazBleLclScanTest.StartPassesSettingsAndRejectsOverlap;
var
  Raised: Boolean;
begin
  FScan.Start('hci1', 4321);

  AssertEquals(Ord(lblssScanning), Ord(FScan.State));
  AssertEquals(1, FBackendObject.CommandCount);
  AssertEquals(Ord(lbckStartScan), Ord(FBackendObject.Commands[0].Kind));
  AssertEquals('hci1', FBackendObject.Commands[0].AdapterId);
  AssertEquals(4321, Integer(FBackendObject.Commands[0].TimeoutMs));
  AssertEquals(1, Length(FStateChanges));
  AssertEquals(Ord(lblssScanning), Ord(FStateChanges[0]));

  Raised := False;
  try
    FScan.Start('hci2', 1000);
  except
    on ELazBleLclScanActive do
      Raised := True;
  end;
  AssertTrue(Raised);
  AssertEquals(1, FBackendObject.CommandCount);
end;

procedure TLazBleLclScanTest.ResultsAndCompletionArriveOnMainThreadWithoutSorting;
var
  Snapshot: TBleDeviceInfos;
  Thread: TScanEmissionThread;
begin
  FScan.Start('hci0', 5000);
  Thread := TScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], [
      Device('device-a', 'First', -80),
      Device('device-b', 'Second', -40),
      Device('device-a', 'First updated', -20)
    ], lbekOperationSucceeded);
  try
    Thread.Start;
    WaitForEmission(Thread);
    AssertEquals(0, Length(FReceivedResults));
    AssertEquals(Ord(lblssScanning), Ord(FScan.State));

    CheckSynchronize;

    AssertEquals(3, Length(FReceivedResults));
    AssertEquals('device-a', FReceivedResults[0].DeviceId);
    AssertEquals('device-b', FReceivedResults[1].DeviceId);
    AssertEquals('device-a', FReceivedResults[2].DeviceId);
    AssertEquals('First updated', FReceivedResults[2].DeviceName);
    AssertEquals(Ord(lblssSucceeded), Ord(FScan.State));
    AssertEquals(1, FCompletionCount);
    AssertEquals(Ord(lblssSucceeded), Ord(FCompletedState));
    AssertEquals(2, Length(FStateChanges));
    AssertEquals(Ord(lblssScanning), Ord(FStateChanges[0]));
    AssertEquals(Ord(lblssSucceeded), Ord(FStateChanges[1]));
    AssertEquals(Int64(MainThreadID), Int64(FLastCallbackThreadId));

    Snapshot := FScan.Results;
    AssertEquals(2, Length(Snapshot));
    AssertEquals('device-a', Snapshot[0].DeviceId);
    AssertEquals(-20, Integer(Snapshot[0].Rssi));
    AssertEquals('device-b', Snapshot[1].DeviceId);
    AssertEquals(-40, Integer(Snapshot[1].Rssi));
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleLclScanTest.CancelReportsCancelledAfterTerminalEvent;
var
  Thread: TScanEmissionThread;
begin
  FScan.Start('', 5000);
  FScan.Cancel;
  AssertTrue(FBackendObject.CancellationWasRequested(
    FBackendObject.OperationIds[0]));
  AssertEquals(Ord(lblssScanning), Ord(FScan.State));

  Thread := TScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], [], lbekOperationCancelled);
  try
    Thread.Start;
    WaitForEmission(Thread);
    CheckSynchronize;

    AssertEquals(Ord(lblssCancelled), Ord(FScan.State));
    AssertEquals(1, FCompletionCount);
    AssertEquals(Ord(lblssCancelled), Ord(FCompletedState));
    AssertEquals(2, Length(FStateChanges));
    AssertEquals(Ord(lblssCancelled), Ord(FStateChanges[1]));
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleLclScanTest.FailurePreservesTerminalError;
var
  Thread: TScanEmissionThread;
begin
  FScan.Start('', 5000);
  Thread := TScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], [], lbekOperationFailed, 73,
    'adapter failed');
  try
    Thread.Start;
    WaitForEmission(Thread);
    CheckSynchronize;

    AssertEquals(Ord(lblssFailed), Ord(FScan.State));
    AssertEquals(73, FScan.ErrorCode);
    AssertEquals('adapter failed', FScan.ErrorMessage);
    AssertEquals(1, FCompletionCount);
    AssertEquals(2, Length(FStateChanges));
    AssertEquals(Ord(lblssFailed), Ord(FStateChanges[1]));
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleLclScanTest.RepeatedScanClearsPreviousSnapshot;
var
  Snapshot: TBleDeviceInfos;
  Thread: TScanEmissionThread;
begin
  FScan.Start('', 5000);
  Thread := TScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], [Device('old-device', 'Old', -30)],
    lbekOperationSucceeded);
  Thread.Start;
  WaitForEmission(Thread);
  CheckSynchronize;
  Thread.WaitFor;
  Thread.Free;
  AssertEquals(1, Length(FScan.Results));

  FScan.Start('', 5000);
  AssertEquals(0, Length(FScan.Results));
  Thread := TScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[1], [Device('new-device', 'New', -90)],
    lbekOperationSucceeded);
  try
    Thread.Start;
    WaitForEmission(Thread);
    CheckSynchronize;
    Snapshot := FScan.Results;
    AssertEquals(1, Length(Snapshot));
    AssertEquals('new-device', Snapshot[0].DeviceId);
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

procedure TLazBleLclScanTest.QueuedCallbacksAreIgnoredAfterDestroy;
var
  Thread: TScanEmissionThread;
begin
  FScan.Start('', 5000);
  Thread := TScanEmissionThread.Create(FBackendObject,
    FBackendObject.OperationIds[0], [Device('device-a', 'First', -50)],
    lbekOperationSucceeded);
  try
    Thread.Start;
    WaitForEmission(Thread);
    FScan.Free;
    FScan := nil;

    CheckSynchronize;

    AssertEquals(0, Length(FReceivedResults));
    AssertEquals(0, FCompletionCount);
  finally
    Thread.WaitFor;
    Thread.Free;
  end;
end;

initialization
  RegisterTest(TLazBleLclScanTest);

end.
